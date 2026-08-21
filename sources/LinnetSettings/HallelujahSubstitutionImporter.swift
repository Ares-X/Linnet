import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Offline, one-shot migration from Hallelujah's substitution store into the
/// Linnet `x;` stable table. The input process never links or calls this type.
enum HallelujahSubstitutionImporter {
  static let maximumSourceDatabaseBytes = 64 * 1024 * 1024
  static let maximumSourceSidecarBytes = 64 * 1024 * 1024
  static let maximumSourceAggregateBytes = 128 * 1024 * 1024
  static let maximumRows = 50_000
  static let maximumFieldBytes = 64 * 1024
  static let maximumCanonicalBytes = 16 * 1024 * 1024
  static let maximumExistingBytes = 16 * 1024 * 1024
  static let maximumOutputBytes = 24 * 1024 * 1024

  typealias CancellationCheck = () throws -> Void

  enum Outcome: Equatable, Sendable { case imported, unchanged }

  struct Collision: Equatable, Sendable {
    let trigger: String
    let keptKey: String
    let ignoredKey: String
  }

  struct ExistingConflict: Equatable, Sendable {
    let trigger: String
    let valuesMatch: Bool
  }

  struct SmokeProbe: Equatable, Sendable {
    let trigger: String
    let expectedValue: String
  }

  struct Report: Equatable, Sendable {
    let outcome: Outcome
    let fingerprint: String
    let importedCount: Int
    let collisions: [Collision]
    let existingConflicts: [ExistingConflict]
    let smokeProbe: SmokeProbe?
  }

  /// The sole product of external SQLite parsing. Coordinator carries this
  /// opaque, bounded value across the Host pause boundary; merge never reopens
  /// the external database.
  struct PreparedSource: Sendable {
    fileprivate let sourceDatabase: URL
    fileprivate let entries: [Entry]
    fileprivate let collisions: [Collision]
    let fingerprint: String

    var substitutionCount: Int { entries.count }
  }

  enum Failure: Error, Equatable, Sendable {
    case sourceOpen
    case sourceRead
    case unsafeSource(String)
    case sourceTooLarge(String)
    case tooManyRows
    case fieldTooLarge(row: Int)
    case canonicalTooLarge
    case existingTooLarge
    case outputTooLarge
    case deadlineExceeded
    case invalidSchema
    case invalidText(row: Int)
    case invalidTrigger(row: Int)
    case emptyValue(row: Int)
    /// Rime's line-oriented table has no quoting. LF, CR, TAB and NUL values
    /// are rejected instead of being silently escaped or changed.
    case unrepresentableValue(row: Int)
    case invalidExistingTable(line: Int)
    case duplicateExistingTrigger(String)
    case unsafeDestination
    case writeFailed
  }

  fileprivate struct Entry: Sendable {
    let trigger: String
    let value: String
    let weight: String?
  }

  private static let fingerprintKey = "/linnet_hallelujah_fingerprint"

  private final class OperationControl {
    private let deadline: ContinuousClock.Instant
    private let cancellation: CancellationCheck
    private var interruption: Error?

    init(timeout: TimeInterval, cancellation: @escaping CancellationCheck) {
      deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
      self.cancellation = cancellation
    }

    func checkpoint() throws {
      if let interruption { throw interruption }
      do {
        try cancellation()
        guard ContinuousClock.now < deadline else { throw Failure.deadlineExceeded }
      } catch {
        interruption = error
        throw error
      }
    }

    func rethrowInterruption(or fallback: Failure) throws -> Never {
      try checkpoint()
      throw fallback
    }

    func interruptSQLite() -> Int32 {
      do {
        try checkpoint()
        return 0
      } catch {
        return 1
      }
    }
  }

  private static let sqliteProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    pointer in
    guard let pointer else { return 1 }
    return Unmanaged<OperationControl>.fromOpaque(pointer).takeUnretainedValue()
      .interruptSQLite()
  }

  static func prepare(
    sourceDatabase: URL,
    timeout: TimeInterval,
    cancellation: @escaping CancellationCheck = { try Task.checkCancellation() }
  ) throws -> PreparedSource {
    let control = OperationControl(timeout: timeout, cancellation: cancellation)
    try control.checkpoint()
    try validateSourceFootprint(sourceDatabase)
    let loaded = try loadSource(sourceDatabase, control: control)
    try validateSourceFootprint(sourceDatabase)
    let fingerprint = try contentFingerprint(loaded.entries, control: control)
    return PreparedSource(
      sourceDatabase: URL(fileURLWithPath: try resolvedPath(sourceDatabase)),
      entries: loaded.entries,
      collisions: loaded.collisions,
      fingerprint: fingerprint
    )
  }

  static func merge(
    _ prepared: PreparedSource,
    destinationTable: URL,
    timeout: TimeInterval,
    cancellation: @escaping CancellationCheck = { try Task.checkCancellation() }
  ) throws -> Report {
    let control = OperationControl(timeout: timeout, cancellation: cancellation)
    try control.checkpoint()
    let destinationID = try destinationIdentity(destinationTable)
    guard prepared.sourceDatabase != destinationID else {
      throw Failure.unsafeDestination
    }

    let existing = try loadExisting(destinationTable, control: control)
    if existing.fingerprint == prepared.fingerprint {
      return Report(
        outcome: .unchanged, fingerprint: prepared.fingerprint, importedCount: 0,
        collisions: prepared.collisions, existingConflicts: [],
        smokeProbe: existing.entries.first.map {
          SmokeProbe(trigger: $0.trigger, expectedValue: $0.value)
        })
    }

    var merged = Dictionary(uniqueKeysWithValues: existing.entries.map { ($0.trigger, $0) })
    var conflicts: [ExistingConflict] = []
    var importedCount = 0
    for entry in prepared.entries {
      try control.checkpoint()
      if let current = merged[entry.trigger] {
        conflicts.append(
          ExistingConflict(trigger: entry.trigger, valuesMatch: current.value == entry.value))
      } else {
        guard merged.count < maximumRows else { throw Failure.outputTooLarge }
        merged[entry.trigger] = entry
        importedCount += 1
      }
    }

    let rows = merged.values.sorted { $0.trigger < $1.trigger }
    let output = try render(
      rows,
      fingerprint: prepared.fingerprint,
      destination: destinationTable,
      control: control
    )
    try control.checkpoint()
    do {
      try output.write(to: destinationTable, options: .atomic)
    } catch {
      throw Failure.writeFailed
    }
    return Report(
      outcome: .imported, fingerprint: prepared.fingerprint, importedCount: importedCount,
      collisions: prepared.collisions,
      existingConflicts: conflicts.sorted { $0.trigger < $1.trigger },
      smokeProbe: rows.first.map {
        SmokeProbe(trigger: $0.trigger, expectedValue: $0.value)
      })
  }

}

extension HallelujahSubstitutionImporter {
  private static func loadSource(
    _ url: URL,
    control: OperationControl
  ) throws -> (entries: [Entry], collisions: [Collision]) {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        try resolvedPath(url),
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW,
        nil
      )
        == SQLITE_OK, let database
    else {
      if database != nil { sqlite3_close_v2(database) }
      try control.rethrowInterruption(or: .sourceOpen)
    }
    defer { sqlite3_close_v2(database) }
    sqlite3_progress_handler(
      database,
      1_000,
      sqliteProgressCallback,
      Unmanaged.passUnretained(control).toOpaque()
    )
    defer { sqlite3_progress_handler(database, 0, nil, nil) }
    guard sqlite3_db_readonly(database, "main") == 1,
      sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK
    else {
      try control.rethrowInterruption(or: .sourceOpen)
    }
    try control.checkpoint()
    try validateSchema(database, control: control)

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT key, value FROM substitutions ORDER BY key COLLATE BINARY", -1,
        &statement, nil) == SQLITE_OK, let statement
    else { try control.rethrowInterruption(or: .sourceRead) }
    defer { sqlite3_finalize(statement) }

    var entries: [String: (entry: Entry, originalKey: String)] = [:]
    var collisions: [Collision] = []
    var row = 0
    var aggregateBytes = 0
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        try control.rethrowInterruption(or: .sourceRead)
      }
      row += 1
      guard row <= maximumRows else { throw Failure.tooManyRows }
      try control.checkpoint()
      let key = try text(statement, column: 0, row: row, maximumBytes: maximumFieldBytes)
      let value = try text(statement, column: 1, row: row, maximumBytes: maximumFieldBytes)
      let rowBytes = key.utf8.count + value.utf8.count + 16
      guard aggregateBytes <= maximumCanonicalBytes - rowBytes else {
        throw Failure.canonicalTooLarge
      }
      aggregateBytes += rowBytes
      guard let trigger = normalizeTrigger(key) else { throw Failure.invalidTrigger(row: row) }
      try validateValue(value, row: row)
      let entry = Entry(trigger: trigger, value: value, weight: nil)
      if let prior = entries[trigger] {
        collisions.append(
          Collision(trigger: trigger, keptKey: prior.originalKey, ignoredKey: key))
      } else {
        entries[trigger] = (entry, key)
      }
    }
    try control.checkpoint()
    return (entries.values.map(\.entry).sorted { $0.trigger < $1.trigger }, collisions)
  }

  private static func validateSchema(
    _ database: OpaquePointer,
    control: OperationControl
  ) throws {
    var tableStatement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='substitutions' AND tbl_name='substitutions'",
        -1, &tableStatement, nil) == SQLITE_OK, let tableStatement
    else {
      try control.rethrowInterruption(or: .invalidSchema)
    }
    let tableRow = sqlite3_step(tableStatement)
    let tableDone = tableRow == SQLITE_ROW ? sqlite3_step(tableStatement) : tableRow
    sqlite3_finalize(tableStatement)
    guard tableRow == SQLITE_ROW, tableDone == SQLITE_DONE else {
      try control.rethrowInterruption(or: .invalidSchema)
    }
    var schemaStatement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(substitutions)", -1, &schemaStatement, nil)
        == SQLITE_OK, let schemaStatement
    else { try control.rethrowInterruption(or: .invalidSchema) }
    defer { sqlite3_finalize(schemaStatement) }
    var columns: [(String, String, Int32, Int32, Bool)] = []
    var result = sqlite3_step(schemaStatement)
    while result == SQLITE_ROW {
      guard let name = rawText(schemaStatement, column: 1),
        let type = rawText(schemaStatement, column: 2)
      else { try control.rethrowInterruption(or: .invalidSchema) }
      columns.append(
        (
          name, type.uppercased(), sqlite3_column_int(schemaStatement, 3),
          sqlite3_column_int(schemaStatement, 5),
          sqlite3_column_type(schemaStatement, 4) == SQLITE_NULL
        ))
      result = sqlite3_step(schemaStatement)
    }
    guard result == SQLITE_DONE, columns.count == 2,
      columns[0].0 == "key", columns[0].1 == "TEXT", columns[0].2 == 0,
      columns[0].3 == 1, columns[0].4,
      columns[1].0 == "value", columns[1].1 == "TEXT", columns[1].2 == 0,
      columns[1].3 == 0, columns[1].4
    else { try control.rethrowInterruption(or: .invalidSchema) }
  }

  private static func text(
    _ statement: OpaquePointer,
    column: Int32,
    row: Int,
    maximumBytes: Int
  ) throws -> String {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT else {
      throw Failure.invalidText(row: row)
    }
    guard sqlite3_column_bytes(statement, column) <= maximumBytes else {
      throw Failure.fieldTooLarge(row: row)
    }
    guard
      let value = rawText(statement, column: column)
    else { throw Failure.invalidText(row: row) }
    return value
  }

  private static func rawText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard let bytes = sqlite3_column_text(statement, column) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
  }

  private static func normalizeTrigger(_ key: String) -> String? {
    guard !key.isEmpty else { return nil }
    var normalized: [UInt8] = []
    for byte in key.utf8 {
      switch byte {
      case 65...90: normalized.append(byte + 32)
      case 97...122, 48...57, 45, 95: normalized.append(byte)
      default: return nil
      }
    }
    return "x;" + String(decoding: normalized, as: UTF8.self)
  }

  private static func validateValue(_ value: String, row: Int) throws {
    guard !value.isEmpty else { throw Failure.emptyValue(row: row) }
    guard
      !value.unicodeScalars.contains(where: {
        $0 == "\n" || $0 == "\r" || $0 == "\t" || $0.value == 0
      })
    else { throw Failure.unrepresentableValue(row: row) }
  }

  private static func contentFingerprint(
    _ entries: [Entry],
    control: OperationControl
  ) throws -> String {
    var hasher = SHA256()
    hasher.update(data: Data("hallelujah-substitutions-v1\0".utf8))
    for entry in entries {
      try control.checkpoint()
      for field in [entry.trigger, entry.value] {
        let bytes = Data(field.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes)
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func loadExisting(
    _ url: URL,
    control: OperationControl
  ) throws -> (entries: [Entry], fingerprint: String?) {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT { return ([], nil) }
      throw Failure.invalidExistingTable(line: 0)
    }
    let data: Data
    do {
      data = try boundedData(
        url,
        maximumBytes: maximumExistingBytes,
        control: control
      )
    } catch Failure.existingTooLarge {
      throw Failure.existingTooLarge
    } catch is CancellationError {
      throw CancellationError()
    } catch Failure.deadlineExceeded {
      throw Failure.deadlineExceeded
    } catch {
      throw Failure.invalidExistingTable(line: 0)
    }
    guard let contents = String(data: data, encoding: .utf8) else {
      throw Failure.invalidExistingTable(line: 0)
    }
    var entries: [String: Entry] = [:]
    var fingerprint: String?
    var commentsEnabled = true
    var cursor = contents.startIndex
    var lineNumber = 0
    while cursor < contents.endIndex {
      try control.checkpoint()
      lineNumber += 1
      guard lineNumber <= maximumRows + 128 else { throw Failure.tooManyRows }
      let newline = contents[cursor...].firstIndex(of: "\n")
      let lineEnd = newline ?? contents.endIndex
      let lineSlice = contents[cursor..<lineEnd]
      cursor = newline.map { contents.index(after: $0) } ?? contents.endIndex
      guard lineSlice.utf8.count <= maximumFieldBytes * 3 + 2 else {
        throw Failure.invalidExistingTable(line: lineNumber)
      }
      let rawLine = String(lineSlice)
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
      if line.isEmpty { continue }
      if commentsEnabled && line == "# no comment" {
        commentsEnabled = false
        continue
      }
      if commentsEnabled && line.hasPrefix("#") {
        let prefix = "#@\(fingerprintKey)\t"
        if line.hasPrefix(prefix) {
          guard fingerprint == nil else { throw Failure.invalidExistingTable(line: lineNumber) }
          fingerprint = String(line.dropFirst(prefix.count))
        }
        continue
      }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 2 || fields.count == 3,
        fields.allSatisfy({ $0.utf8.count <= maximumFieldBytes }),
        !fields[0].isEmpty, fields[1].hasPrefix("x;"),
        let trigger = normalizeTrigger(String(fields[1].dropFirst(2)))
      else {
        throw Failure.invalidExistingTable(line: lineNumber)
      }
      try validateValue(fields[0], row: lineNumber)
      guard entries[trigger] == nil else { throw Failure.duplicateExistingTrigger(trigger) }
      guard entries.count < maximumRows else { throw Failure.tooManyRows }
      entries[trigger] = Entry(
        trigger: trigger, value: fields[0], weight: fields.count == 3 ? fields[2] : nil)
    }
    if let fingerprint,
      fingerprint.utf8.count != 64
        || fingerprint.utf8.contains(where: {
          !(48...57).contains($0) && !(97...102).contains($0)
        }) {
      throw Failure.invalidExistingTable(line: 0)
    }
    return (entries.values.sorted { $0.trigger < $1.trigger }, fingerprint)
  }

  private static func render(
    _ entries: [Entry],
    fingerprint: String,
    destination: URL,
    control: OperationControl
  ) throws
    -> Data {
    let name = destination.lastPathComponent
    guard !name.isEmpty, !name.contains("\t"), !name.contains("\n"), !name.contains("\r")
    else { throw Failure.unsafeDestination }
    var output = Data(
      ("# Rime table\n# coding: utf-8\n#@/db_name\t\(name)\n#@/db_type\ttabledb\n"
        + "#@\(fingerprintKey)\t\(fingerprint)\n# no comment\n").utf8
    )
    for entry in entries {
      try control.checkpoint()
      var line = entry.value + "\t" + entry.trigger
      if let weight = entry.weight { line += "\t" + weight }
      line += "\n"
      let bytes = Data(line.utf8)
      guard output.count <= maximumOutputBytes - bytes.count else {
        throw Failure.outputTooLarge
      }
      output.append(bytes)
    }
    return output
  }

  private static func destinationIdentity(_ url: URL) throws -> URL {
    var info = stat()
    if lstat(url.path, &info) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
        let path = try? resolvedPath(url)
      else {
        throw Failure.unsafeDestination
      }
      return URL(fileURLWithPath: path)
    }
    guard errno == ENOENT else { throw Failure.unsafeDestination }
    return url.standardizedFileURL
  }

  private static func validateSourceFootprint(_ database: URL) throws {
    var aggregate = try boundedRegularFileSize(
      database,
      maximumBytes: maximumSourceDatabaseBytes
    )
    for suffix in ["-wal", "-shm", "-journal"] {
      let sidecar = URL(fileURLWithPath: database.path + suffix)
      var info = stat()
      if lstat(sidecar.path, &info) != 0 {
        if errno == ENOENT { continue }
        throw Failure.unsafeSource(sidecar.lastPathComponent)
      }
      let bytes = try boundedRegularFileSize(
        sidecar,
        maximumBytes: maximumSourceSidecarBytes
      )
      guard aggregate <= maximumSourceAggregateBytes - bytes else {
        throw Failure.sourceTooLarge("SQLite source aggregate")
      }
      aggregate += bytes
    }
  }

  private static func resolvedPath(_ url: URL) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else {
      throw Failure.unsafeSource(url.lastPathComponent)
    }
    return String(cString: buffer)
  }

  private static func boundedRegularFileSize(_ url: URL, maximumBytes: Int) throws -> Int {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_size >= 0
    else {
      throw Failure.unsafeSource(url.lastPathComponent)
    }
    guard info.st_size <= maximumBytes else {
      throw Failure.sourceTooLarge(url.lastPathComponent)
    }
    return Int(info.st_size)
  }

  private static func boundedData(
    _ url: URL,
    maximumBytes: Int,
    control: OperationControl
  ) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Failure.invalidExistingTable(line: 0) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_size >= 0
    else {
      throw Failure.invalidExistingTable(line: 0)
    }
    guard info.st_size <= maximumBytes else { throw Failure.existingTooLarge }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    while true {
      try control.checkpoint()
      let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if chunk.isEmpty { break }
      guard data.count <= maximumBytes - chunk.count else {
        throw Failure.existingTooLarge
      }
      data.append(chunk)
    }
    return data
  }
}
