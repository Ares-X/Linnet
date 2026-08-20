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

  var customWords: [CustomWord]
  var disabledWords: [String]
  var expansions: [Expansion]

  init(
    customWords: [CustomWord],
    disabledWords: [String],
    expansions: [Expansion]
  ) {
    self.customWords = customWords
    self.disabledWords = disabledWords
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

  struct Snapshot: Equatable, Sendable {
    let data: LinnetPersonalData
    let revision: String
  }

  /// Decoded identity of the immutable backup-v2 personal-data boundary.
  /// Only restore/import code may consume this retired physical format.
  struct LegacyV2Snapshot: Equatable, Sendable {
    let data: LinnetPersonalData
    let sentenceCapitalization: Bool
    let tabBehavior: String
    let revision: String
  }

  enum Validation: Equatable, Sendable {
    enum Collection: Equatable, Sendable {
      case customWords
      case disabledWords
      case expansions
    }

    enum CustomField: Equatable, Sendable {
      case value
      case code
    }

    enum ExpansionField: Equatable, Sendable {
      case value
      case trigger
    }

    enum Location: Equatable, Sendable {
      case customWord(UUID, CustomField)
      case disabledWord(Int)
      case expansion(UUID, ExpansionField)
      case collection(Collection)
    }

    enum Reason: Equatable, Sendable {
      case missing
      case invalid
      case tooLarge
      case duplicate
      case tooMany
    }

    struct Issue: Equatable, Sendable {
      let location: Location
      let reason: Reason
    }

    case valid(LinnetPersonalData)
    case invalid(Issue)

    var normalized: LinnetPersonalData? {
      guard case .valid(let data) = self else { return nil }
      return data
    }

    var firstIssue: Issue? {
      guard case .invalid(let issue) = self else { return nil }
      return issue
    }

    var isValid: Bool { if case .valid = self { true } else { false } }
  }

  enum Failure: LocalizedError, Equatable {
    case invalidData(Validation.Issue)
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
      try contents.write(
        to: directory.appending(path: name),
        atomically: true,
        encoding: .utf8
      )
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
    try contents.write(
      to: directory.appending(path: name),
      atomically: true,
      encoding: .utf8
    )
    try retireLegacySettings(in: directory)
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

  static func validate(_ data: LinnetPersonalData) -> Validation {
    validate(data, checkCancellation: {})
  }

  static func validate(
    _ data: LinnetPersonalData,
    checkCancellation: CancellationCheck
  ) rethrows -> Validation {
    try checkCancellation()
    func failed(_ location: Validation.Location, _ reason: Validation.Reason) -> Validation {
      .invalid(.init(location: location, reason: reason))
    }
    func addRenderedBytes(_ bytes: Int, to total: inout Int) -> Bool {
      guard bytes >= 0, bytes <= maximumFileBytes - total else { return false }
      total += bytes
      return true
    }
    guard data.customWords.count <= maximumRows else {
      return failed(.collection(.customWords), .tooMany)
    }
    guard data.disabledWords.count <= maximumRows else {
      return failed(.collection(.disabledWords), .tooMany)
    }
    guard data.expansions.count <= maximumRows else {
      return failed(.collection(.expansions), .tooMany)
    }
    var customFileBytes = table(name: customWordsFile, rows: []).utf8.count
    var expansionFileBytes = table(name: expansionsFile, rows: []).utf8.count
    var customCodes = Set<String>()
    var customWords: [LinnetPersonalData.CustomWord] = []
    for row in data.customWords {
      try checkCancellation()
      let value = row.value.trimmingCharacters(in: .whitespaces)
      let code = row.code.trimmingCharacters(in: .whitespaces).lowercased()
      if value.isEmpty, code.isEmpty { continue }
      if value.isEmpty { return failed(.customWord(row.id, .value), .missing) }
      if code.isEmpty { return failed(.customWord(row.id, .code), .missing) }
      guard fieldIsBounded(value) else {
        return failed(.customWord(row.id, .value), .tooLarge)
      }
      guard fieldIsBounded(code) else {
        return failed(.customWord(row.id, .code), .tooLarge)
      }
      guard validValue(value) else {
        return failed(.customWord(row.id, .value), .invalid)
      }
      guard code.range(
        of: #"^[a-z0-9;']+(?: [a-z0-9;']+)*$"#,
        options: .regularExpression
      ) != nil else {
        return failed(.customWord(row.id, .code), .invalid)
      }
      guard customCodes.insert(code).inserted else {
        return failed(.customWord(row.id, .code), .duplicate)
      }
      let lineBytes = value.utf8.count + 1 + code.utf8.count
      guard lineBytes <= maximumLineBytes,
        addRenderedBytes(lineBytes + (customWords.isEmpty ? 0 : 1), to: &customFileBytes)
      else {
        return failed(.collection(.customWords), .tooLarge)
      }
      customWords.append(LinnetPersonalData.CustomWord(id: row.id, value: value, code: code))
    }

    var triggers = Set<String>()
    var expansions: [LinnetPersonalData.Expansion] = []
    for row in data.expansions {
      try checkCancellation()
      let value = row.value.trimmingCharacters(in: .whitespaces)
      let trigger = row.trigger.trimmingCharacters(in: .whitespaces)
      if value.isEmpty, trigger.isEmpty || trigger == "x;" { continue }
      if value.isEmpty { return failed(.expansion(row.id, .value), .missing) }
      if trigger.isEmpty || trigger == "x;" {
        return failed(.expansion(row.id, .trigger), .missing)
      }
      guard fieldIsBounded(value) else {
        return failed(.expansion(row.id, .value), .tooLarge)
      }
      guard fieldIsBounded(trigger) else {
        return failed(.expansion(row.id, .trigger), .tooLarge)
      }
      guard validValue(value) else {
        return failed(.expansion(row.id, .value), .invalid)
      }
      guard trigger.range(
        of: #"^x;[-0-9A-Za-z_]+$"#,
        options: .regularExpression
      ) != nil else {
        return failed(.expansion(row.id, .trigger), .invalid)
      }
      guard triggers.insert(trigger).inserted else {
        return failed(.expansion(row.id, .trigger), .duplicate)
      }
      let lineBytes = value.utf8.count + 1 + trigger.utf8.count
      guard lineBytes <= maximumLineBytes,
        addRenderedBytes(lineBytes + (expansions.isEmpty ? 0 : 1), to: &expansionFileBytes)
      else {
        return failed(.collection(.expansions), .tooLarge)
      }
      expansions.append(LinnetPersonalData.Expansion(id: row.id, value: value, trigger: trigger))
    }

    var disabledWords: [String] = []
    for (index, word) in data.disabledWords.enumerated() {
      try checkCancellation()
      let normalized = word.trimmingCharacters(in: .whitespaces).lowercased()
      if normalized.isEmpty { continue }
      guard fieldIsBounded(normalized) else {
        return failed(.disabledWord(index), .tooLarge)
      }
      guard validValue(normalized) else {
        return failed(.disabledWord(index), .invalid)
      }
      disabledWords.append(normalized)
    }
    try checkCancellation()
    let uniqueDisabledWords = Array(Set(disabledWords)).sorted()
    if !uniqueDisabledWords.isEmpty {
      var userSettingsBytes = 128
      for (index, word) in uniqueDisabledWords.enumerated() {
        try checkCancellation()
        guard let json = try? JSONEncoder().encode(word) else {
          return failed(.collection(.disabledWords), .invalid)
        }
        let lineBytes = 4 + json.count
        guard lineBytes <= maximumLineBytes,
          addRenderedBytes(lineBytes + (index == 0 ? 0 : 1), to: &userSettingsBytes)
        else {
          return failed(.collection(.disabledWords), .tooLarge)
        }
      }
    }
    try checkCancellation()
    return .valid(
      .init(
        customWords: customWords,
        disabledWords: uniqueDisabledWords,
        expansions: expansions
      )
    )
  }

  static func normalized(_ data: LinnetPersonalData) throws -> LinnetPersonalData {
    switch validate(data) {
    case .valid(let normalized):
      return normalized
    case .invalid(let issue):
      throw Failure.invalidData(issue)
    }
  }
}

extension LinnetPersonalDataStore {
  fileprivate struct TableRow {
    let value: String
    let code: String
  }

  fileprivate static func validValue(_ value: String) -> Bool {
    !value.isEmpty && !value.contains("\t") && !value.contains("\n") && !value.contains("\r")
      && !value.contains("\0")
  }

  fileprivate static func fieldIsBounded(_ value: String) -> Bool {
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
      ),
    ]
    try validateRenderedFiles(files)
    return files
  }

  fileprivate static func renderedRuntimeSettings(
    for data: LinnetPersonalData
  ) throws -> (name: String, contents: String) {
    let normalized = try normalized(data)
    let contents = try userSettingsYAML(normalized.disabledWords)
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
    let disabledWords = try normalized.disabledWords.map { word -> String in
      let data = try JSONEncoder().encode(word)
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
      ),
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
        normalized.disabledWords,
        sentenceCapitalization: sentenceCapitalization,
        tabBehavior: tabBehavior
      ),
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
    var sawRoot = false
    var inlineEmpty = false
    var sentenceCapitalization = false
    var tabBehavior = "smart_complete"
    var sawSentenceCapitalization = false
    var sawTabBehavior = false
    var values: [String] = []
    try forEachBoundedLine(in: file) { line in
      if line.isEmpty || line.hasPrefix("#") { return }
      if line == "disabled_words:" || line == "disabled_words: []" {
        guard !sawRoot else { throw Failure.invalidFile(legacyUserSettingsFile) }
        sawRoot = true
        inlineEmpty = line.hasSuffix("[]")
        return
      }
      if line.hasPrefix("sentence_capitalization: ") {
        guard !sawSentenceCapitalization else {
          throw Failure.invalidFile(legacyUserSettingsFile)
        }
        let value = String(line.dropFirst("sentence_capitalization: ".count))
        guard value == "true" || value == "false" else {
          throw Failure.invalidFile(legacyUserSettingsFile)
        }
        sentenceCapitalization = value == "true"
        sawSentenceCapitalization = true
        return
      }
      if line.hasPrefix("tab_behavior: ") {
        let value = String(line.dropFirst("tab_behavior: ".count))
        guard !sawTabBehavior, ["pass", "navigate", "smart_complete"].contains(value)
        else { throw Failure.invalidFile(legacyUserSettingsFile) }
        tabBehavior = value
        sawTabBehavior = true
        return
      }
      guard sawRoot, !inlineEmpty, line.hasPrefix("  - "),
        let data = String(line.dropFirst(4)).data(using: .utf8),
        let value = try? JSONDecoder().decode(String.self, from: data),
        validValue(value)
      else {
        throw Failure.invalidFile(legacyUserSettingsFile)
      }
      guard fieldIsBounded(value) else { throw Failure.fileTooLarge(legacyUserSettingsFile) }
      guard values.count < maximumRows else {
        throw Failure.fileTooLarge(legacyUserSettingsFile)
      }
      values.append(value)
    }
    guard sawRoot else { throw Failure.invalidFile(legacyUserSettingsFile) }
    return .init(
      disabledWords: values,
      sentenceCapitalization: sentenceCapitalization,
      tabBehavior: tabBehavior
    )
  }

  /// Reads the standard Rime patch emitted by the canonical writer.
  fileprivate static func readUserSettingsPatch(_ file: URL) throws -> [String] {
    var sawPatch = false
    var sawDisabledWords = false
    var inlineEmpty = false
    var sawSentenceCapitalization = false
    var sawTabBehavior = false
    var values: [String] = []
    try forEachBoundedLine(in: file) { line in
      if line.isEmpty || line.hasPrefix("#") { return }
      if line == "patch:" {
        guard !sawPatch else { throw Failure.invalidFile(userSettingsFile) }
        sawPatch = true
        return
      }
      if line == "  disabled_words:" || line == "  disabled_words: []" {
        guard sawPatch, !sawDisabledWords else { throw Failure.invalidFile(userSettingsFile) }
        sawDisabledWords = true
        inlineEmpty = line.hasSuffix("[]")
        return
      }
      if line.hasPrefix("  sentence_capitalization: ") {
        guard sawPatch, !sawSentenceCapitalization else {
          throw Failure.invalidFile(userSettingsFile)
        }
        let value = String(line.dropFirst("  sentence_capitalization: ".count))
        guard value == "true" || value == "false" else {
          throw Failure.invalidFile(userSettingsFile)
        }
        sawSentenceCapitalization = true
        return
      }
      if line.hasPrefix("  tab_behavior: ") {
        let value = String(line.dropFirst("  tab_behavior: ".count))
        guard sawPatch, !sawTabBehavior,
          ["pass", "navigate", "smart_complete"].contains(value)
        else { throw Failure.invalidFile(userSettingsFile) }
        sawTabBehavior = true
        return
      }
      guard sawPatch, sawDisabledWords, !inlineEmpty, line.hasPrefix("    - "),
        let data = String(line.dropFirst(6)).data(using: .utf8),
        let value = try? JSONDecoder().decode(String.self, from: data),
        validValue(value)
      else {
        throw Failure.invalidFile(userSettingsFile)
      }
      guard fieldIsBounded(value) else { throw Failure.fileTooLarge(userSettingsFile) }
      guard values.count < maximumRows else { throw Failure.fileTooLarge(userSettingsFile) }
      values.append(value)
    }
    guard sawPatch, sawDisabledWords else { throw Failure.invalidFile(userSettingsFile) }
    return values
  }

  fileprivate static func forEachBoundedLine(
    in file: URL,
    _ body: (String) throws -> Void
  ) throws {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Failure.unsafeFile(file.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == getuid()
    else {
      throw Failure.unsafeFile(file.lastPathComponent)
    }
    guard before.st_size >= 0, before.st_size <= maximumFileBytes else {
      throw Failure.fileTooLarge(file.lastPathComponent)
    }
    var buffer = Data()
    var observedBytes = 0

    func process(_ bytes: Data.SubSequence) throws {
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
        let newline = buffer[lineStart...].firstIndex(of: 0x0a)
      {
        try process(buffer[lineStart..<newline])
        lineStart = buffer.index(after: newline)
      }
      if lineStart > buffer.startIndex {
        buffer.removeSubrange(buffer.startIndex..<lineStart)
      }
      guard buffer.count <= maximumLineBytes + 1 else {
        throw Failure.fileTooLarge(file.lastPathComponent)
      }
    }
    if !buffer.isEmpty { try process(buffer[buffer.startIndex..<buffer.endIndex]) }

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

  fileprivate static func table(name: String, rows: [(String, String)]) -> String {
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
        "",
      ] + disabledWords + [
        "sentence_capitalization: \(sentenceCapitalization)",
        "tab_behavior: \(tabBehavior)",
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
