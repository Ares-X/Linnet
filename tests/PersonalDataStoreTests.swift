import Darwin
import Foundation

@main
struct PersonalDataStoreTests {
  static func main() {
    let directory = LinnetTestScratch.directory.appending(
      path: "LinnetPersonalDataStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let source = LinnetPersonalData(
        customWords: [.init(value: "Linnet", code: "rime duo")],
        disabledWords: ["Cloud", "cloud", "forbidden word"],
        expansions: [.init(value: "Best regards,", trigger: "x;br")]
      )
      try LinnetPersonalDataStore.writePersonalFiles(source, to: directory)
      try LinnetPersonalDataStore.writeRuntimeSettings(source, to: directory)
      let loaded = try LinnetPersonalDataStore.load(from: directory)
      guard loaded.customWords.map({ "\($0.value)\t\($0.code)" }) == ["Linnet\trime duo"],
        loaded.disabledWords.map(\.value) == ["cloud", "forbidden word"],
        loaded.expansions.map({ "\($0.value)\t\($0.trigger)" }) == ["Best regards,\tx;br"]
      else {
        fail("personal data did not round-trip through canonical files")
      }

      let yaml = try String(
        contentsOf: directory.appending(path: LinnetPersonalDataStore.userSettingsFile),
        encoding: .utf8
      )
      guard LinnetPersonalDataStore.userSettingsFile == "linnet_user.custom.yaml",
        yaml.hasPrefix("patch:\n"),
        yaml.contains("    - \"cloud\""),
        !yaml.contains("sentence_capitalization"),
        !yaml.contains("tab_behavior")
      else {
        fail("runtime settings were not emitted as a canonical Rime patch")
      }

      let snapshot = try LinnetPersonalDataStore.snapshot(from: directory)
      let equivalent = LinnetPersonalData(
        customWords: [.init(value: "Linnet", code: "rime duo")],
        disabledWords: ["forbidden word", "CLOUD", "cloud"],
        expansions: [.init(value: "Best regards,", trigger: "x;br")]
      )
      let equivalentRevision = try LinnetPersonalDataStore.revision(for: equivalent)
      guard snapshot.revision == equivalentRevision,
        snapshot.revision.count == 64
      else {
        fail("personal revision was not deterministic over normalized content")
      }
      let changedRevision = try LinnetPersonalDataStore.revision(
        for: .init(
          customWords: [.init(value: "Linnet 2", code: "rime duo")],
          disabledWords: ["cloud", "forbidden word"],
          expansions: [.init(value: "Best regards,", trigger: "x;br")]
        ))
      guard changedRevision != snapshot.revision else {
        fail("personal revision ignored a canonical source change")
      }
      try LinnetPersonalDataStore.writePersonalFiles(.empty, to: directory)
      try LinnetPersonalDataStore.writeRuntimeSettings(.empty, to: directory)
      let emptyYAML = try String(
        contentsOf: directory.appending(path: LinnetPersonalDataStore.userSettingsFile),
        encoding: .utf8
      )
      guard emptyYAML.contains("  disabled_words: []")
      else {
        fail("empty settings did not remain a canonical patch sequence")
      }

      let legacyDirectory = directory.appending(path: "legacy", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
      try """
        disabled_words:
          - "legacy-disabled"
        sentence_capitalization: true
        tab_behavior: pass
        """.write(
          to: legacyDirectory.appending(path: LinnetPersonalDataStore.legacyUserSettingsFile),
          atomically: true,
          encoding: .utf8
        )
      guard try LinnetPersonalDataStore.load(from: legacyDirectory).disabledWords.map(\.value)
        == ["legacy-disabled"]
      else { fail("legacy user settings were not explicitly adopted") }
      try LinnetPersonalDataStore.writeRuntimeSettings(.empty, to: legacyDirectory)
      guard !FileManager.default.fileExists(
        atPath: legacyDirectory.appending(path: LinnetPersonalDataStore.legacyUserSettingsFile).path
      ) else { fail("the retired legacy settings file remained authoritative after a write") }

      let backupBoundary = directory.appending(path: "backup-boundary", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: backupBoundary, withIntermediateDirectories: true)
      let existingPersonalBytes = Data("existing canonical evidence".utf8)
      try existingPersonalBytes.write(
        to: backupBoundary.appending(path: LinnetPersonalDataStore.customWordsFile)
      )
      try LinnetPersonalDataStore.writeBackupNormalization(.empty, to: backupBoundary)
      let firstBackupBytes = try Dictionary(
        uniqueKeysWithValues: [
          LinnetPersonalDataStore.customWordsFile,
          LinnetPersonalDataStore.expansionsFile,
          LinnetPersonalDataStore.userSettingsFile,
        ].map { name in
          (name, try Data(contentsOf: backupBoundary.appending(path: name)))
        }
      )
      guard firstBackupBytes[LinnetPersonalDataStore.customWordsFile] == existingPersonalBytes
      else { fail("backup normalization overwrote existing canonical evidence") }
      try LinnetPersonalDataStore.writeBackupNormalization(source, to: backupBoundary)
      let secondBackupBytes = try Dictionary(
        uniqueKeysWithValues: firstBackupBytes.keys.map { name in
          (name, try Data(contentsOf: backupBoundary.appending(path: name)))
        }
      )
      guard secondBackupBytes == firstBackupBytes else {
        fail("backup normalization changed an already-materialized canonical file")
      }

      let duplicateExpansion = LinnetPersonalData.Expansion(value: "Two", trigger: "x;br")
      expectIssue(
        .init(
          location: .expansion(duplicateExpansion.id, .trigger),
          reason: .duplicate
        ),
        in: .init(
          customWords: [],
          disabledWords: [],
          expansions: [
            .init(value: "One", trigger: "x;br"),
            duplicateExpansion,
          ]
        )
      )
      let invalidCustom = LinnetPersonalData.CustomWord(value: "Bad", code: "bad-code")
      expectIssue(
        .init(location: .customWord(invalidCustom.id, .code), reason: .invalid),
        in: .init(
          customWords: [
            .init(value: "Linnet", code: "rime duo"),
            .init(value: "", code: ""),
            invalidCustom,
          ],
          disabledWords: [],
          expansions: []
        )
      )
      let invalidDisabledWord = LinnetPersonalData.DisabledWord(value: "bad\0word")
      expectIssue(
        .init(location: .disabledWord(invalidDisabledWord.identifier), reason: .invalid),
        in: .init(
          customWords: [], disabledWordRows: [invalidDisabledWord], expansions: [])
      )
      let duplicateCustom = LinnetPersonalData.CustomWord(value: "Other", code: "rime duo")
      expectIssue(
        .init(location: .customWord(duplicateCustom.id, .code), reason: .duplicate),
        in: .init(
          customWords: [.init(value: "Linnet", code: "rime duo"), duplicateCustom],
          disabledWords: [],
          expansions: []
        )
      )
      let missingCustom = LinnetPersonalData.CustomWord(value: "Linnet", code: "")
      expectIssue(
        .init(location: .customWord(missingCustom.id, .code), reason: .missing),
        in: .init(customWords: [missingCustom], disabledWords: [], expansions: [])
      )
      let missingExpansion = LinnetPersonalData.Expansion(value: "Hello", trigger: "x;")
      expectIssue(
        .init(location: .expansion(missingExpansion.id, .trigger), reason: .missing),
        in: .init(customWords: [], disabledWords: [], expansions: [missingExpansion])
      )
      let invalidExpansion = LinnetPersonalData.Expansion(value: "Hello", trigger: "bad")
      expectIssue(
        .init(location: .expansion(invalidExpansion.id, .trigger), reason: .invalid),
        in: .init(customWords: [], disabledWords: [], expansions: [invalidExpansion])
      )
      let oversized = directory.appending(path: LinnetPersonalDataStore.customWordsFile)
      FileManager.default.createFile(atPath: oversized.path, contents: nil)
      let oversizedHandle = try FileHandle(forWritingTo: oversized)
      try oversizedHandle.truncate(atOffset: UInt64(LinnetPersonalDataStore.maximumFileBytes + 1))
      try oversizedHandle.close()
      expectFailure(.fileTooLarge(LinnetPersonalDataStore.customWordsFile)) {
        _ = try LinnetPersonalDataStore.load(from: directory)
      }

      let oversizedField = String(
        repeating: "a", count: LinnetPersonalDataStore.maximumFieldBytes + 1)
      let oversizedCustom = LinnetPersonalData.CustomWord(value: oversizedField, code: "large")
      expectIssue(
        .init(location: .customWord(oversizedCustom.id, .value), reason: .tooLarge),
        in: .init(customWords: [oversizedCustom], disabledWords: [], expansions: [])
      )
      let tooManyDisabled = Array(
        repeating: "word", count: LinnetPersonalDataStore.maximumRows + 1)
      expectIssue(
        .init(location: .collection(.disabledWords), reason: .tooMany),
        in: .init(customWords: [], disabledWords: tooManyDisabled, expansions: [])
      )
      let legalLargeValue = String(
        repeating: "a", count: LinnetPersonalDataStore.maximumFieldBytes - 64)
      let oversizedCustomOutput = (0..<1_030).map {
        LinnetPersonalData.CustomWord(value: legalLargeValue, code: "word\($0)")
      }
      expectIssue(
        .init(location: .collection(.customWords), reason: .tooLarge),
        in: .init(customWords: oversizedCustomOutput, disabledWords: [], expansions: [])
      )
      let legalLargeTrigger = "x;" + String(
        repeating: "a", count: LinnetPersonalDataStore.maximumFieldBytes - 70)
      let oversizedExpansionOutput = (0..<1_030).map {
        LinnetPersonalData.Expansion(value: "v", trigger: legalLargeTrigger + "\($0)")
      }
      expectIssue(
        .init(location: .collection(.expansions), reason: .tooLarge),
        in: .init(customWords: [], disabledWords: [], expansions: oversizedExpansionOutput)
      )
      let legalLargeDisabled = String(
        repeating: "b", count: LinnetPersonalDataStore.maximumFieldBytes - 70)
      let oversizedDisabledOutput = (0..<1_030).map { legalLargeDisabled + "\($0)" }
      expectIssue(
        .init(location: .collection(.disabledWords), reason: .tooLarge),
        in: .init(customWords: [], disabledWords: oversizedDisabledOutput, expansions: [])
      )
      let blankRows = try LinnetPersonalDataStore.normalized(
        .init(
          customWords: [
            .init(value: "Linnet", code: "rime duo"),
            .init(value: "", code: ""),
            .init(value: "  ", code: " "),
          ],
          disabledWords: ["cloud", ""],
          expansions: [
            .init(value: "Best regards,", trigger: "x;br"),
            .init(value: "", trigger: "x;"),
          ]
        ))
      guard blankRows.customWords.map({ "\($0.value)\t\($0.code)" }) == ["Linnet\trime duo"],
        blankRows.disabledWords.map(\.value) == ["cloud"],
        blankRows.expansions.map({ "\($0.value)\t\($0.trigger)" }) == ["Best regards,\tx;br"]
      else {
        fail("blank rows were not dropped during normalization")
      }
      let stableDisabledWord = LinnetPersonalData.DisabledWord(value: " Cloud ")
      let stableDisabledDraft = LinnetPersonalData(
        customWords: [], disabledWordRows: [stableDisabledWord], expansions: [])
      let stableDisabledResult = try LinnetPersonalDataStore.normalized(stableDisabledDraft)
      guard stableDisabledResult.disabledWords == [
        .init(identifier: stableDisabledWord.identifier, value: "cloud")
      ] else {
        fail("disabled-word normalization replaced the editable row identity")
      }
      let validationDraft = LinnetPersonalData(
        customWords: [.init(value: "Linnet", code: " RIME DUO "), .init(value: "", code: "")],
        disabledWords: ["Cloud", "cloud"],
        expansions: [.init(value: "Best regards,", trigger: "x;br"), .init(value: "", trigger: "x;")]
      )
      let blankValidation = LinnetPersonalDataStore.validate(validationDraft)
      guard case .valid(let validatedData) = blankValidation,
        blankValidation.firstIssue == nil,
        validatedData == (try LinnetPersonalDataStore.normalized(validationDraft))
      else { fail("typed validation diverged from canonical normalization") }
      try testBoundedStreamingLoad(
        in: directory.appending(path: "bounded-stream", directoryHint: .isDirectory)
      )
      print("PersonalDataStoreTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testBoundedStreamingLoad(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let custom = directory.appending(path: LinnetPersonalDataStore.customWordsFile)
    let tooManyRows = (0...LinnetPersonalDataStore.maximumRows)
      .map { "word\($0)\tcode\($0)" }
      .joined(separator: "\n") + "\n"
    try tooManyRows.write(to: custom, atomically: true, encoding: .utf8)
    expectFailure(.fileTooLarge(LinnetPersonalDataStore.customWordsFile)) {
      _ = try LinnetPersonalDataStore.load(from: directory)
    }

    let maximumLine = String(
      repeating: "a", count: LinnetPersonalDataStore.maximumFieldBytes - 2
    ) + "\ta\n"
    try maximumLine.write(to: custom, atomically: true, encoding: .utf8)
    guard try LinnetPersonalDataStore.load(from: directory).customWords.count == 1 else {
      fail("a personal-data line at the byte limit was rejected")
    }
    try ("a" + maximumLine).write(to: custom, atomically: true, encoding: .utf8)
    expectFailure(.fileTooLarge(LinnetPersonalDataStore.customWordsFile)) {
      _ = try LinnetPersonalDataStore.load(from: directory)
    }

    let chunkBoundaryComment = "#" + String(repeating: "a", count: 32 * 1024 - 2) + "界"
    try (chunkBoundaryComment + "\r\n云\tyun\r\n").write(
      to: custom, atomically: true, encoding: .utf8)
    let boundary = try LinnetPersonalDataStore.load(from: directory)
    guard boundary.customWords.map({ "\($0.value)\t\($0.code)" }) == ["云\tyun"] else {
      fail("UTF-8 split across a read chunk or CRLF parsing changed a row")
    }

    try LinnetPersonalDataStore.writePersonalFiles(.empty, to: directory)
    try LinnetPersonalDataStore.writeRuntimeSettings(.empty, to: directory)
    let settings = directory.appending(path: LinnetPersonalDataStore.userSettingsFile)
    let disabledRows = (0...LinnetPersonalDataStore.maximumRows)
      .map { "    - \"disabled-\($0)\"" }
      .joined(separator: "\n")
    try ("patch:\n  disabled_words:\n" + disabledRows + "\n").write(
      to: settings, atomically: true, encoding: .utf8)
    expectFailure(.fileTooLarge(LinnetPersonalDataStore.userSettingsFile)) {
      _ = try LinnetPersonalDataStore.load(from: directory)
    }
  }

  private static func expectIssue(
    _ expected: LinnetPersonalDataValidation.Issue,
    in data: LinnetPersonalData
  ) {
    let validation = LinnetPersonalDataStore.validate(data)
    guard !validation.isValid,
      validation.firstIssue == expected
    else { fail("typed validation did not return the expected first issue") }
    expectFailure(.invalidData(expected)) {
      _ = try LinnetPersonalDataStore.normalized(data)
    }
  }

  private static func expectFailure(
    _ expected: LinnetPersonalDataStore.Failure,
    operation: () throws -> Void
  ) {
    do {
      try operation()
      fail("expected failure was not raised")
    } catch let error as LinnetPersonalDataStore.Failure {
      guard error == expected else { fail("unexpected failure: \(error)") }
    } catch {
      fail("unexpected error type: \(error)")
    }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("PersonalDataStoreTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}
