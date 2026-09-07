import CryptoKit
import Darwin
import Foundation

struct LinnetPersonalData: Equatable, Sendable {
  struct CustomWord: Equatable, Identifiable, Sendable {
    let id: UUID
    var value: String
    var code: String

    init(id: UUID = UUID(), value: String, code: String) {
      self.id = id
      self.value = value
      self.code = code
    }
  }

  struct Expansion: Equatable, Identifiable, Sendable {
    let id: UUID
    var value: String
    var trigger: String

    init(id: UUID = UUID(), value: String, trigger: String) {
      self.id = id
      self.value = value
      self.trigger = trigger
    }
  }

  struct DisabledWord: Equatable, Sendable {
    let identifier: UUID
    var value: String

    init(identifier: UUID = UUID(), value: String) {
      self.identifier = identifier
      self.value = value
    }
  }

  var customWords: [CustomWord]
  var disabledWords: [DisabledWord]
  var expansions: [Expansion]

  init(
    customWords: [CustomWord],
    disabledWords: [String],
    expansions: [Expansion]
  ) {
    self.customWords = customWords
    self.disabledWords = disabledWords.map { .init(value: $0) }
    self.expansions = expansions
  }

  init(
    customWords: [CustomWord],
    disabledWordRows: [DisabledWord],
    expansions: [Expansion]
  ) {
    self.customWords = customWords
    disabledWords = disabledWordRows
    self.expansions = expansions
  }

  static let empty = LinnetPersonalData(
    customWords: [],
    disabledWords: [],
    expansions: []
  )
}

enum LinnetPersonalDataStore {
  typealias CancellationCheck = @Sendable () throws -> Void

  enum Failure: LocalizedError, Equatable {
    case invalidData(LinnetPersonalDataValidation.Issue)
    case invalidFile(String)
    case unsafeFile(String)

    var errorDescription: String? {
      switch self {
      case .invalidData: "Personal data failed validation."
      case .invalidFile(let name): "Personal-data file is invalid: \(name)"
      case .unsafeFile(let name): "Personal-data file is not a regular user file: \(name)"
      }
    }
  }

  static let customWordsFile = "linnet_custom_words.txt"
  static let expansionsFile = "linnet_text_expander.txt"
  static let userSettingsFile = "linnet_user.custom.yaml"
  static let legacyUserSettingsFile = "linnet_user.yaml"

  static func load(from directory: URL) throws -> LinnetPersonalData {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return .empty
    }
    let customRows = try readTable(directory.appending(path: customWordsFile))
    let expansionRows = try readTable(directory.appending(path: expansionsFile))
    let customSettings = directory.appending(path: userSettingsFile)
    let legacySettings = directory.appending(path: legacyUserSettingsFile)
    let disabledWords: [String]
    if FileManager.default.fileExists(atPath: customSettings.path) {
      disabledWords = try readUserSettingsPatch(customSettings)
    } else if FileManager.default.fileExists(atPath: legacySettings.path) {
      disabledWords = try readLegacyUserSettings(legacySettings).disabledWords
    } else {
      disabledWords = []
    }
    return LinnetPersonalData(
      customWords: customRows.map { .init(value: $0.value, code: $0.code) },
      disabledWords: disabledWords,
      expansions: expansionRows.map { .init(value: $0.value, trigger: $0.code) }
    )
  }

  static func snapshot(from directory: URL) throws -> Snapshot {
    let data = try normalized(load(from: directory))
    return Snapshot(data: data, revision: try revision(for: data))
  }

  static func revision(for data: LinnetPersonalData) throws -> String {
    try revision(for: revisionSerialization(for: data))
  }

  fileprivate static func revision(for files: [String: String]) -> String {
    var hasher = SHA256()
    for (name, contents) in files.sorted(by: { $0.key < $1.key }) {
      hasher.update(data: Data(name.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: Data(contents.utf8))
      hasher.update(data: Data([0xff]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Writes the two user-authored table sources. Runtime interaction settings
  /// have a separate owner and are never rewritten by this boundary.
  static func writePersonalFiles(
    _ data: LinnetPersonalData,
    to directory: URL
  ) throws {
    for (name, contents) in try renderedPersonalFiles(for: data) {
      try publishChangedFile(contents, to: directory.appending(path: name))
    }
  }

  /// Writes the single runtime patch owned by personal disabled words. English
  /// interaction settings are projected from LinnetSettingsDocument into each
  /// schema and cannot enter this personal-data boundary.
  static func writeRuntimeSettings(
    _ data: LinnetPersonalData,
    to directory: URL
  ) throws {
    let (name, contents) = try renderedRuntimeSettings(for: data)
    try publishChangedFile(contents, to: directory.appending(path: name))
    try retireLegacySettings(in: directory)
  }

  /// Identical publication must preserve the inode and its COW-shared blocks.
  private static func publishChangedFile(_ contents: String, to file: URL) throws {
    var info = stat()
    if lstat(file.path, &info) == 0 {
      let opened = try openRegularFile(file)
      defer { try? opened.handle.close() }
      let existing = try opened.handle.readToEnd() ?? Data()
      try validateUnchangedFile(
        opened.handle.fileDescriptor, before: opened.info, observedBytes: existing.count, file: file)
      if existing == Data(contents.utf8) { return }
    } else if errno != ENOENT {
      throw Failure.unsafeFile(file.lastPathComponent)
    }
    try contents.write(to: file, atomically: true, encoding: .utf8)
  }

  /// Backup-boundary normalization fills only canonical personal files that
  /// are absent from an empty stable snapshot. Existing bytes are evidence and
  /// are never overwritten or reinterpreted here.
  static func writeBackupNormalization(
    _ data: LinnetPersonalData,
    to directory: URL
  ) throws {
    for (name, contents) in try renderedFiles(for: data) {
      let destination = directory.appending(path: name)
      var info = stat()
      if lstat(destination.path, &info) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
          throw Failure.unsafeFile(name)
        }
        continue
      }
      guard errno == ENOENT else { throw Failure.unsafeFile(name) }
      try contents.write(to: destination, atomically: true, encoding: .utf8)
    }
  }

}

extension LinnetPersonalDataStore {
  fileprivate struct TableRow {
    let value: String
    let code: String
  }

  static func validValue(_ value: String) -> Bool {
    !value.isEmpty && !value.contains("\t") && !value.contains("\n") && !value.contains("\r")
      && !value.contains("\0")
  }

  fileprivate static func renderedFiles(
    for data: LinnetPersonalData
  ) throws -> [String: String] {
    var files = try renderedPersonalFiles(for: data)
    let runtime = try renderedRuntimeSettings(for: data)
    files[runtime.name] = runtime.contents
    return files
  }

  fileprivate static func renderedPersonalFiles(
    for data: LinnetPersonalData
  ) throws -> [String: String] {
    let normalized = try normalized(data)
    let files = [
      customWordsFile: table(
        name: customWordsFile,
        rows: normalized.customWords.map { ($0.value, $0.code) }
      ),
      expansionsFile: table(
        name: expansionsFile,
        rows: normalized.expansions.map { ($0.value, $0.trigger) }
      )
    ]
    return files
  }

  fileprivate static func renderedRuntimeSettings(
    for data: LinnetPersonalData
  ) throws -> (name: String, contents: String) {
    let normalized = try normalized(data)
    let contents = try userSettingsYAML(normalized.disabledWords.map(\.value))
    return (userSettingsFile, contents)
  }

  /// Canonical personal revision bytes. This deliberately is not a runtime
  /// file renderer: English interaction remains document-owned and cannot
  /// enter the personal-data compare-and-swap identity.
  fileprivate static func revisionSerialization(
    for data: LinnetPersonalData
  ) throws -> [String: String] {
    let normalized = try normalized(data)
    let disabledWords = try normalized.disabledWords.map { row -> String in
      let data = try JSONEncoder().encode(row.value)
      guard let json = String(data: data, encoding: .utf8) else {
        throw Failure.invalidFile("disabled-words-revision")
      }
      return json
    }.joined(separator: "\n")
    return [
      "custom-words-revision": table(
        name: customWordsFile,
        rows: normalized.customWords.map { ($0.value, $0.code) }
      ),
      "disabled-words-revision": disabledWords,
      "expansions-revision": table(
        name: expansionsFile,
        rows: normalized.expansions.map { ($0.value, $0.trigger) }
      )
    ]
  }

  fileprivate static func readTable(_ file: URL) throws -> [TableRow] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    var rows: [TableRow] = []
    try forEachLine(in: file) { line in
      if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { return }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 2 else { throw Failure.invalidFile(file.lastPathComponent) }
      let value = String(fields[0])
      let code = String(fields[1])
      guard validValue(value), validValue(code)
      else {
        throw Failure.invalidFile(file.lastPathComponent)
      }
      rows.append(TableRow(value: value, code: code))
    }
    return rows
  }

  struct LegacyUserSettings: Equatable, Sendable {
    let disabledWords: [String]
    let sentenceCapitalization: Bool
    let tabBehavior: String
  }

  fileprivate struct LegacySettingsAccumulator {
    var sawRoot = false
    var inlineEmpty = false
    var sentenceCapitalization = false
    var tabBehavior = "smart_complete"
    var sawSentenceCapitalization = false
    var sawTabBehavior = false
    var values: [String] = []
  }

  fileprivate struct UserSettingsPatchAccumulator {
    var sawPatch = false
    var sawDisabledWords = false
    var inlineEmpty = false
    var sawSentenceCapitalization = false
    var sawTabBehavior = false
    var values: [String] = []
  }

  /// One-time adoption codec for the retired pre-release `linnet_user.yaml`.
  /// Steady-state reads use only `linnet_user.custom.yaml`.
  static func readLegacyUserSettings(_ file: URL) throws -> LegacyUserSettings {
    guard FileManager.default.fileExists(atPath: file.path) else {
      return .init(
        disabledWords: [],
        sentenceCapitalization: false,
        tabBehavior: "smart_complete"
      )
    }
    var accumulator = LegacySettingsAccumulator()
    try forEachLine(in: file) { line in
      if line.isEmpty || line.hasPrefix("#") { return }
      try parseLegacySettingsLine(line, accumulator: &accumulator)
    }
    guard accumulator.sawRoot else { throw Failure.invalidFile(legacyUserSettingsFile) }
    return .init(
      disabledWords: accumulator.values,
      sentenceCapitalization: accumulator.sentenceCapitalization,
      tabBehavior: accumulator.tabBehavior
    )
  }

  fileprivate static func parseLegacySettingsLine(
    _ line: String,
    accumulator: inout LegacySettingsAccumulator
  ) throws {
    if line == "disabled_words:" || line == "disabled_words: []" {
      guard !accumulator.sawRoot else { throw Failure.invalidFile(legacyUserSettingsFile) }
      accumulator.sawRoot = true
      accumulator.inlineEmpty = line.hasSuffix("[]")
      return
    }
    if line.hasPrefix("sentence_capitalization: ") {
      guard !accumulator.sawSentenceCapitalization else {
        throw Failure.invalidFile(legacyUserSettingsFile)
      }
      let value = String(line.dropFirst("sentence_capitalization: ".count))
      guard ["true", "false"].contains(value) else {
        throw Failure.invalidFile(legacyUserSettingsFile)
      }
      accumulator.sentenceCapitalization = value == "true"
      accumulator.sawSentenceCapitalization = true
      return
    }
    if line.hasPrefix("tab_behavior: ") {
      let value = String(line.dropFirst("tab_behavior: ".count))
      guard !accumulator.sawTabBehavior,
        ["pass", "navigate", "smart_complete"].contains(value)
      else { throw Failure.invalidFile(legacyUserSettingsFile) }
      accumulator.tabBehavior = value
      accumulator.sawTabBehavior = true
      return
    }
    guard accumulator.sawRoot, !accumulator.inlineEmpty, line.hasPrefix("  - "),
      let data = String(line.dropFirst(4)).data(using: .utf8),
      let value = try? JSONDecoder().decode(String.self, from: data),
      validValue(value)
    else {
      throw Failure.invalidFile(legacyUserSettingsFile)
    }
    accumulator.values.append(value)
  }

  /// Reads the standard Rime patch emitted by the canonical writer.
  fileprivate static func readUserSettingsPatch(_ file: URL) throws -> [String] {
    var accumulator = UserSettingsPatchAccumulator()
    try forEachLine(in: file) { line in
      if line.isEmpty || line.hasPrefix("#") { return }
      if line == "patch:" {
        guard !accumulator.sawPatch else { throw Failure.invalidFile(userSettingsFile) }
        accumulator.sawPatch = true
        return
      }
      try parseUserSettingsPatchLine(line, accumulator: &accumulator)
    }
    guard accumulator.sawPatch, accumulator.sawDisabledWords else {
      throw Failure.invalidFile(userSettingsFile)
    }
    return accumulator.values
  }

  fileprivate static func parseUserSettingsPatchLine(
    _ line: String,
    accumulator: inout UserSettingsPatchAccumulator
  ) throws {
    if line == "  disabled_words:" || line == "  disabled_words: []" {
      guard accumulator.sawPatch, !accumulator.sawDisabledWords else {
        throw Failure.invalidFile(userSettingsFile)
      }
      accumulator.sawDisabledWords = true
      accumulator.inlineEmpty = line.hasSuffix("[]")
      return
    }
    if line.hasPrefix("  sentence_capitalization: ") {
      let value = String(line.dropFirst("  sentence_capitalization: ".count))
      guard accumulator.sawPatch, !accumulator.sawSentenceCapitalization,
        ["true", "false"].contains(value)
      else { throw Failure.invalidFile(userSettingsFile) }
      accumulator.sawSentenceCapitalization = true
      return
    }
    if line.hasPrefix("  tab_behavior: ") {
      let value = String(line.dropFirst("  tab_behavior: ".count))
      guard accumulator.sawPatch, !accumulator.sawTabBehavior,
        ["pass", "navigate", "smart_complete"].contains(value)
      else { throw Failure.invalidFile(userSettingsFile) }
      accumulator.sawTabBehavior = true
      return
    }
    guard accumulator.sawPatch, accumulator.sawDisabledWords,
      !accumulator.inlineEmpty, line.hasPrefix("    - "),
      let data = String(line.dropFirst(6)).data(using: .utf8),
      let value = try? JSONDecoder().decode(String.self, from: data),
      validValue(value)
    else {
      throw Failure.invalidFile(userSettingsFile)
    }
    accumulator.values.append(value)
  }

  fileprivate static func forEachLine(
    in file: URL,
    _ body: (String) throws -> Void
  ) throws {
    let opened = try openRegularFile(file)
    let handle = opened.handle
    defer { try? handle.close() }
    var buffer = Data()
    var observedBytes = 0

    while true {
      let chunk = try handle.read(upToCount: 32 * 1024) ?? Data()
      if chunk.isEmpty { break }
      observedBytes += chunk.count
      buffer.append(chunk)
      var lineStart = buffer.startIndex
      while lineStart < buffer.endIndex,
        let newline = buffer[lineStart...].firstIndex(of: 0x0a) {
        try processLine(buffer[lineStart..<newline], from: file, body: body)
        lineStart = buffer.index(after: newline)
      }
      if lineStart > buffer.startIndex {
        buffer.removeSubrange(buffer.startIndex..<lineStart)
      }
    }
    if !buffer.isEmpty {
      try processLine(buffer[buffer.startIndex..<buffer.endIndex], from: file, body: body)
    }

    try validateUnchangedFile(
      handle.fileDescriptor,
      before: opened.info,
      observedBytes: observedBytes,
      file: file
    )
  }

  fileprivate static func openRegularFile(_ file: URL) throws -> (handle: FileHandle, info: stat) {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Failure.unsafeFile(file.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else {
      try? handle.close()
      throw Failure.unsafeFile(file.lastPathComponent)
    }
    return (handle, info)
  }

  fileprivate static func validateUnchangedFile(
    _ descriptor: Int32,
    before: stat,
    observedBytes: Int,
    file: URL
  ) throws {
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      observedBytes == Int(before.st_size),
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else {
      throw Failure.unsafeFile(file.lastPathComponent)
    }
  }

  fileprivate static func processLine(
    _ bytes: Data.SubSequence,
    from file: URL,
    body: (String) throws -> Void
  ) throws {
    var lineBytes = bytes
    if lineBytes.last == 0x0d { lineBytes = lineBytes.dropLast() }
    guard let line = String(data: Data(lineBytes), encoding: .utf8), !line.contains("\0") else {
      throw Failure.invalidFile(file.lastPathComponent)
    }
    try body(line)
  }

  static func table(name: String, rows: [(String, String)]) -> String {
    let body = rows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n")
    return """
      # Rime table
      # coding: utf-8
      #@/db_name\t\(name)
      #@/db_type\ttabledb
      #
      \(body)
      """ + "\n"
  }

  fileprivate static func userSettingsYAML(
    _ words: [String]
  ) throws -> String {
    let rows = try words.map { word -> String in
      let data = try JSONEncoder().encode(word)
      guard let json = String(data: data, encoding: .utf8) else {
        throw Failure.invalidFile(userSettingsFile)
      }
      return "    - \(json)"
    }
    let disabledWords = words.isEmpty
      ? ["  disabled_words: []"]
      : ["  disabled_words:"] + rows
    return (["patch:"] + disabledWords).joined(separator: "\n") + "\n"
  }

  fileprivate static func retireLegacySettings(in directory: URL) throws {
    let legacy = directory.appending(path: legacyUserSettingsFile)
    var info = stat()
    if lstat(legacy.path, &info) != 0 {
      guard errno == ENOENT else { throw Failure.unsafeFile(legacyUserSettingsFile) }
      return
    }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
      throw Failure.unsafeFile(legacyUserSettingsFile)
    }
    try FileManager.default.removeItem(at: legacy)
  }
}
