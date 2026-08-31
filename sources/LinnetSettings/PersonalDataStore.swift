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
  static let maximumRows = 50_000
  static let maximumFieldBytes = 64 * 1024
  static let maximumLineBytes = 64 * 1024
  static let maximumFileBytes = 64 * 1024 * 1024

  typealias CancellationCheck = @Sendable () throws -> Void

  enum Failure: LocalizedError, Equatable {
    case invalidData(LinnetPersonalDataValidation.Issue)
    case invalidFile(String)
    case unsafeFile(String)
    case fileTooLarge(String)

    var errorDescription: String? {
      switch self {
      case .invalidData: "Personal data failed validation."
      case .invalidFile(let name): "Personal-data file is invalid: \(name)"
      case .unsafeFile(let name): "Personal-data file is not a regular user file: \(name)"
      case .fileTooLarge(let name): "Personal-data file is too large: \(name)"
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

  /// Strict decoder for legal backup-v2 bytes written by bda21963. It reads
  /// only the retired three-file set and reproduces that writer's revision;
  /// steady-state load/write paths remain exclusively on the current format.
  static func legacyV2Snapshot(from directory: URL) throws -> LegacyV2Snapshot {
    let required = [customWordsFile, expansionsFile, legacyUserSettingsFile]
    guard required.allSatisfy({
      FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
    }) else {
      throw Failure.invalidFile("backup-v2 personal files")
    }
    let customRows = try readTable(directory.appending(path: customWordsFile))
    let expansionRows = try readTable(directory.appending(path: expansionsFile))
    let interaction = try readLegacyUserSettings(
      directory.appending(path: legacyUserSettingsFile))
    let data = try normalized(
      .init(
        customWords: customRows.map { .init(value: $0.value, code: $0.code) },
        disabledWords: interaction.disabledWords,
        expansions: expansionRows.map { .init(value: $0.value, trigger: $0.code) }
      ))
    let serialization = try legacyV2RevisionSerialization(
      for: data,
      sentenceCapitalization: interaction.sentenceCapitalization,
      tabBehavior: interaction.tabBehavior
    )
    return .init(
      data: data,
      sentenceCapitalization: interaction.sentenceCapitalization,
      tabBehavior: interaction.tabBehavior,
      revision: revision(for: serialization)
    )
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
      let opened = try openBoundedFile(file)
      defer { try? opened.handle.close() }
      let existing = try opened.handle.read(upToCount: maximumFileBytes + 1) ?? Data()
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

  static func fieldIsBounded(_ value: String) -> Bool {
    value.lengthOfBytes(using: .utf8) <= maximumFieldBytes
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
    try validateRenderedFiles(files)
    return files
  }

  fileprivate static func renderedRuntimeSettings(
    for data: LinnetPersonalData
  ) throws -> (name: String, contents: String) {
    let normalized = try normalized(data)
    let contents = try userSettingsYAML(normalized.disabledWords.map(\.value))
    try validateRenderedFiles([userSettingsFile: contents])
    return (userSettingsFile, contents)
  }

  fileprivate static func validateRenderedFiles(_ files: [String: String]) throws {
    for (name, contents) in files {
      guard contents.lengthOfBytes(using: .utf8) <= maximumFileBytes,
        linesAreBounded(contents)
      else {
        throw Failure.fileTooLarge(name)
      }
    }
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

  fileprivate static func legacyV2RevisionSerialization(
    for data: LinnetPersonalData,
    sentenceCapitalization: Bool,
    tabBehavior: String
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
      ),
      legacyUserSettingsFile: try legacyV2UserSettingsYAML(
        normalized.disabledWords.map(\.value),
        sentenceCapitalization: sentenceCapitalization,
        tabBehavior: tabBehavior
      )
    ]
    try validateRenderedFiles(files)
    return files
  }

  fileprivate static func readTable(_ file: URL) throws -> [TableRow] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    var rows: [TableRow] = []
    try forEachBoundedLine(in: file) { line in
      if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { return }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 2 else { throw Failure.invalidFile(file.lastPathComponent) }
      let value = String(fields[0])
      let code = String(fields[1])
      guard validValue(value), validValue(code), fieldIsBounded(value), fieldIsBounded(code)
      else {
        throw Failure.invalidFile(file.lastPathComponent)
      }
      guard rows.count < maximumRows else { throw Failure.fileTooLarge(file.lastPathComponent) }
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
    try forEachBoundedLine(in: file) { line in
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
    guard fieldIsBounded(value), accumulator.values.count < maximumRows else {
      throw Failure.fileTooLarge(legacyUserSettingsFile)
    }
    accumulator.values.append(value)
  }

  /// Reads the standard Rime patch emitted by the canonical writer.
  fileprivate static func readUserSettingsPatch(_ file: URL) throws -> [String] {
    var accumulator = UserSettingsPatchAccumulator()
    try forEachBoundedLine(in: file) { line in
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
    guard fieldIsBounded(value), accumulator.values.count < maximumRows else {
      throw Failure.fileTooLarge(userSettingsFile)
    }
    accumulator.values.append(value)
  }

  fileprivate static func forEachBoundedLine(
    in file: URL,
    _ body: (String) throws -> Void
  ) throws {
    let opened = try openBoundedFile(file)
    let handle = opened.handle
    defer { try? handle.close() }
    var buffer = Data()
    var observedBytes = 0

    while true {
      let chunk = try handle.read(upToCount: 32 * 1024) ?? Data()
      if chunk.isEmpty { break }
      guard observedBytes <= maximumFileBytes - chunk.count else {
        throw Failure.fileTooLarge(file.lastPathComponent)
      }
      observedBytes += chunk.count
      buffer.append(chunk)
      var lineStart = buffer.startIndex
      while lineStart < buffer.endIndex,
        let newline = buffer[lineStart...].firstIndex(of: 0x0a) {
        try processBoundedLine(buffer[lineStart..<newline], from: file, body: body)
        lineStart = buffer.index(after: newline)
      }
      if lineStart > buffer.startIndex {
        buffer.removeSubrange(buffer.startIndex..<lineStart)
      }
      guard buffer.count <= maximumLineBytes + 1 else {
        throw Failure.fileTooLarge(file.lastPathComponent)
      }
    }
    if !buffer.isEmpty {
      try processBoundedLine(buffer[buffer.startIndex..<buffer.endIndex], from: file, body: body)
    }

    try validateUnchangedFile(
      handle.fileDescriptor,
      before: opened.info,
      observedBytes: observedBytes,
      file: file
    )
  }

  fileprivate static func openBoundedFile(_ file: URL) throws -> (handle: FileHandle, info: stat) {
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
    guard info.st_size >= 0, info.st_size <= maximumFileBytes else {
      try? handle.close()
      throw Failure.fileTooLarge(file.lastPathComponent)
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

  fileprivate static func processBoundedLine(
    _ bytes: Data.SubSequence,
    from file: URL,
    body: (String) throws -> Void
  ) throws {
    var lineBytes = bytes
    if lineBytes.last == 0x0d { lineBytes = lineBytes.dropLast() }
    guard lineBytes.count <= maximumLineBytes else {
      throw Failure.fileTooLarge(file.lastPathComponent)
    }
    guard let line = String(data: Data(lineBytes), encoding: .utf8), !line.contains("\0") else {
      throw Failure.invalidFile(file.lastPathComponent)
    }
    try body(line)
  }

  fileprivate static func linesAreBounded(_ contents: String) -> Bool {
    var lineBytes = 0
    for byte in contents.utf8 {
      if byte == 0x0a {
        if lineBytes > maximumLineBytes { return false }
        lineBytes = 0
      } else {
        lineBytes += 1
      }
    }
    return lineBytes <= maximumLineBytes
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

  fileprivate static func legacyV2UserSettingsYAML(
    _ words: [String],
    sentenceCapitalization: Bool,
    tabBehavior: String
  ) throws -> String {
    guard ["pass", "navigate", "smart_complete"].contains(tabBehavior) else {
      throw Failure.invalidFile(legacyUserSettingsFile)
    }
    let rows = try words.map { word -> String in
      let data = try JSONEncoder().encode(word)
      guard let json = String(data: data, encoding: .utf8) else {
        throw Failure.invalidFile(legacyUserSettingsFile)
      }
      return "  - \(json)"
    }
    let disabledWords = words.isEmpty ? ["disabled_words: []"] : ["disabled_words:"] + rows
    return
      ([
        "# Linnet user-managed settings",
        "# encoding: utf-8",
        ""
      ] + disabledWords + [
        "sentence_capitalization: \(sentenceCapitalization)",
        "tab_behavior: \(tabBehavior)"
      ]).joined(separator: "\n") + "\n"
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
