import Darwin
import Foundation

@main
struct LinnetBackupStoreTests {
  static func main() {
    let root = LinnetTestScratch.directory.appending(
      path: "LinnetBackupStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      try makeDirectory(root)
      try testUnchangedWriters(root: root)
      try testCloneIsolation(root: root)
      try testPortableCodec()
      try testCloudRecoveryArchive(root: root.appending(path: "cloud-recovery", directoryHint: .isDirectory))
      try testBackupHistory(root: root)
      try testLegacyV3Compatibility(root: root.appending(path: "legacy-v3", directoryHint: .isDirectory))
      try testLegacyV2Compatibility(
        root: root.appending(path: "legacy-v2", directoryHint: .isDirectory)
      )
      try testSymlinkAndVersionGuards(root: root)
      try testRetention(root: root.appending(path: "retention", directoryHint: .isDirectory))
      try testHistoryLimit(root: root.appending(path: "history-limit", directoryHint: .isDirectory))
      try testAggregateLimit(root: root.appending(path: "aggregate-limit", directoryHint: .isDirectory))
      try testBoundedRegularFileReader(
        root: root.appending(path: "bounded-reader", directoryHint: .isDirectory)
      )
      try testCommitHistoryCapacity(
        root: root.appending(path: "commit-capacity", directoryHint: .isDirectory)
      )
      try testManualHistoryRecovery(
        root: root.appending(path: "manual-recovery", directoryHint: .isDirectory)
      )
      print("LinnetBackupStoreTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testUnchangedWriters(root: URL) throws {
    let directory = root.appending(path: "unchanged", directoryHint: .isDirectory)
    try makeDirectory(directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try LinnetPersonalDataStore.writePersonalFiles(.empty, to: directory)
    try LinnetPersonalDataStore.writeRuntimeSettings(.empty, to: directory)
    try LinnetSettingsDocumentStore.write(.default, to: directory)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let before = files.map { file -> ino_t in
      var info = stat()
      guard lstat(file.path, &info) == 0 else { fail("unchanged-writer fixture is unavailable") }
      return info.st_ino
    }
    try LinnetPersonalDataStore.writePersonalFiles(.empty, to: directory)
    try LinnetPersonalDataStore.writeRuntimeSettings(.empty, to: directory)
    try LinnetSettingsDocumentStore.write(.default, to: directory)
    for (file, inode) in zip(files, before) {
      var info = stat()
      guard lstat(file.path, &info) == 0, info.st_ino == inode else {
        fail("unchanged writer replaced \(file.lastPathComponent), breaking its COW sharing")
      }
    }
  }

  private static func testCloneIsolation(root: URL) throws {
    let source = root.appending(path: "clone-source", directoryHint: .isDirectory)
    let older = root.appending(path: "clone-older", directoryHint: .isDirectory)
    let newer = root.appending(path: "clone-newer", directoryHint: .isDirectory)
    let restored = root.appending(path: "clone-restored", directoryHint: .isDirectory)
    let database = source.appending(path: "linnet_en.userdb", directoryHint: .isDirectory)
    for directory in [source, older, newer, restored, database] { try makeDirectory(directory) }
    defer {
      for directory in [source, older, newer, restored] { try? FileManager.default.removeItem(at: directory) }
    }
    let bytes = Data(repeating: 0xa7, count: 4 * 1024 * 1024)
    let original = database.appending(path: "000007.ldb")
    try bytes.write(to: original)
    let recovery = database.appending(path: "lost", directoryHint: .isDirectory)
    try makeDirectory(recovery)
    try Data("retired LevelDB recovery bytes".utf8).write(
      to: recovery.appending(path: "000006.log"))
    try LinnetBackupStore.cloneLearningDictionaries(from: source, to: older)
    guard !FileManager.default.fileExists(
      atPath: older.appending(path: "linnet_en.userdb/lost").path
    ) else { fail("LevelDB recovery quarantine leaked into the active learning snapshot") }
    try LinnetBackupStore.cloneLearningDictionaries(from: source, to: newer)
    let retained = newer.appending(path: "linnet_en.userdb/000007.ldb")
    var originalInfo = stat()
    var cloneInfo = stat()
    guard lstat(original.path, &originalInfo) == 0, lstat(retained.path, &cloneInfo) == 0,
      originalInfo.st_ino != cloneInfo.st_ino,
      originalInfo.st_size == cloneInfo.st_size
    else { fail("local snapshot shares a mutable inode or lost bytes") }
    let writer = try FileHandle(forWritingTo: original)
    try writer.seek(toOffset: 64)
    try writer.write(contentsOf: Data([0x19]))
    try writer.close()
    try FileManager.default.removeItem(at: older)
    try LinnetBackupStore.cloneLearningDictionaries(from: newer, to: restored)
    guard try Data(contentsOf: retained) == bytes,
      try Data(contentsOf: restored.appending(path: "linnet_en.userdb/000007.ldb")) == bytes,
      try Data(contentsOf: original) != bytes
    else { fail("snapshot isolation or independent restore depended on a previous backup") }
    let symlink = database.appending(path: "unsafe.ldb")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
    expectFailure(.unsafeArtifact("unsafe.ldb")) {
      try LinnetBackupStore.cloneLearningDictionaries(from: source, to: restored)
    }
    try FileManager.default.removeItem(at: symlink)
    let foreign = database.appending(path: "foreign", directoryHint: .isDirectory)
    try makeDirectory(foreign)
    expectFailure(.unsafeArtifact("foreign")) {
      try LinnetBackupStore.cloneLearningDictionaries(from: source, to: restored)
    }
    try FileManager.default.removeItem(at: foreign)
    try FileManager.default.removeItem(at: recovery)
    try FileManager.default.createSymbolicLink(
      at: recovery,
      withDestinationURL: original
    )
    expectFailure(.unsafeArtifact("lost")) {
      try LinnetBackupStore.cloneLearningDictionaries(from: source, to: restored)
    }
  }

  private static func testCloudRecoveryArchive(root: URL) throws {
    let fileManager = FileManager.default
    try makeDirectory(root)
    defer { try? fileManager.removeItem(at: root) }
    let first = try LinnetBackupStore.encodePortable(
      personalData: .init(
        customWords: [.init(value: "one", code: "one")], disabledWords: [], expansions: []),
      learning: [:], categories: [.customWords],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      appVersion: "1.0.0", dataVersion: "2026.08.31")
    let baseline = try LinnetCloudRecoveryArchive.publish(portable: first, in: root, repair: false)
    guard baseline.kind == LinnetCloudRecoveryArchive.Outcome.Kind.uploaded else {
      fail("first cloud recovery did not create its base")
    }
    let sameContentLater = try LinnetBackupStore.encodePortable(
      personalData: .init(
        customWords: [.init(value: "one", code: "one")], disabledWords: [], expansions: []),
      learning: [:], categories: [.customWords],
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      appVersion: "1.0.0", dataVersion: "2026.08.31")
    let unchanged = try LinnetCloudRecoveryArchive.publish(
      portable: sameContentLater, in: root, repair: false)
    guard unchanged.kind == LinnetCloudRecoveryArchive.Outcome.Kind.unchanged,
      unchanged.verifiedAt == baseline.verifiedAt else {
      fail("portable createdAt defeated cloud recovery no-op")
    }
    let changed = try LinnetBackupStore.encodePortable(
      personalData: .init(
        customWords: [.init(value: "two", code: "two")], disabledWords: [], expansions: []),
      learning: [:], categories: [.customWords],
      createdAt: Date(timeIntervalSince1970: 1_800_000_001),
      appVersion: "1.0.0", dataVersion: "2026.08.31")
    let update = try LinnetCloudRecoveryArchive.publish(portable: changed, in: root, repair: false)
    guard update.kind == LinnetCloudRecoveryArchive.Outcome.Kind.uploaded else {
      fail("cloud recovery did not publish a delta")
    }
    let bases = try fileManager.contentsOfDirectory(
      at: LinnetCloudRecoveryArchive.root(in: root).appending(path: "bases"),
      includingPropertiesForKeys: nil)
    guard bases.count == 1 else { fail("ordinary cloud update wrote another full base") }
    let deltaFiles = try fileManager.contentsOfDirectory(
      at: LinnetCloudRecoveryArchive.root(in: root).appending(path: "deltas"),
      includingPropertiesForKeys: nil)
    guard let delta = deltaFiles.first else { fail("cloud recovery did not publish a delta object") }
    let direct = root.appending(path: "direct-delta", directoryHint: .isDirectory)
    try LinnetDirectoryDelta.apply(base: bases[0], delta: delta, output: direct)
    guard try Data(contentsOf: direct.appending(path: "payload.linnet-data")) == changed else {
      fail("published delta did not reconstruct the staged portable payload")
    }
    let inspect = root.appending(path: "inspect", directoryHint: .isDirectory)
    try makeDirectory(inspect)
    let materialized = try LinnetCloudRecoveryArchive.materializeLatest(in: root, workspace: inspect)
    guard let materialized else { fail("cloud recovery chain did not materialize") }
    let reconstructed = try Data(contentsOf: materialized)
    guard reconstructed == changed else {
      let words = try LinnetBackupStore.decodePortable(reconstructed).personal
        .flatMap(\.rows).map(\.value).joined(separator: ",")
      fail("cloud recovery chain chose \(words), not the updated recovery payload")
    }
    let cloudRoot = LinnetCloudRecoveryArchive.root(in: root)
    let deltas = try fileManager.contentsOfDirectory(
      at: cloudRoot.appending(path: "deltas"), includingPropertiesForKeys: nil)
    for delta in deltas { try fileManager.removeItem(at: delta) }
    let fallbackWorkspace = root.appending(path: "fallback", directoryHint: .isDirectory)
    try makeDirectory(fallbackWorkspace)
    let fallback = try LinnetCloudRecoveryArchive.materializeLatest(
      in: root, workspace: fallbackWorkspace)
    guard let fallback, try Data(contentsOf: fallback) == first else {
      fail("a broken latest chain blocked a valid older recovery head")
    }
    try fileManager.removeItem(at: cloudRoot.appending(path: "heads"))
    do {
      _ = try LinnetCloudRecoveryArchive.publish(portable: changed, in: root, repair: false)
      fail("orphaned cloud objects silently wrote a full base")
    } catch LinnetCloudRecoveryArchive.Failure.needsConfirmedRepair { }
    let repaired = try LinnetCloudRecoveryArchive.publish(portable: changed, in: root, repair: true)
    guard repaired.kind == LinnetCloudRecoveryArchive.Outcome.Kind.uploaded else {
      fail("confirmed cloud repair did not publish a base")
    }
  }

  private static func testPortableCodec() throws {
    let exportedPersonal = LinnetPersonalData(
      customWords: [.init(value: "Linnet", code: "rime duo")],
      disabledWords: ["exported-disabled"],
      expansions: [.init(value: "Exported expansion", trigger: "x;exported")]
    )
    let categories: Set<LinnetBackupStore.Category> = [
      .customWords,
      .englishLearning,
    ]
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let learning = [
      "linnet_zh": "# export\n你好\tni hao\t5\n",
      "linnet_en": "# export\nhello\thello\t4\n",
    ]
    let encoded = try LinnetBackupStore.encodePortable(
      personalData: exportedPersonal,
      learning: learning,
      categories: categories,
      createdAt: timestamp,
      appVersion: "1.0.0",
      dataVersion: "2026.08.06"
    )
    let sameContentNewIDs = LinnetPersonalData(
      customWords: [.init(value: "Linnet", code: "rime duo")],
      disabledWords: ["exported-disabled"],
      expansions: [.init(value: "Exported expansion", trigger: "x;exported")]
    )
    let encodedAgain = try LinnetBackupStore.encodePortable(
      personalData: sameContentNewIDs,
      learning: learning,
      categories: categories,
      createdAt: timestamp,
      appVersion: "1.0.0",
      dataVersion: "2026.08.06"
    )
    guard encoded == encodedAgain else {
      fail("portable encoding depended on transient row identifiers")
    }
    guard let portableText = String(data: encoded, encoding: .utf8),
      !portableText.contains("exported-disabled"),
      !portableText.contains("Exported expansion")
    else {
      fail("portable encoding leaked unselected personal categories")
    }

    let archive = try LinnetBackupStore.decodePortable(encoded)
    let currentPersonal = LinnetPersonalData(
      customWords: [.init(value: "Old", code: "old")],
      disabledWords: ["keep-disabled"],
      expansions: [.init(value: "Keep expansion", trigger: "x;keep")]
    )
    let replacement = try LinnetBackupStore.replacement(
      currentPersonalData: currentPersonal,
      archive: archive
    )
    guard replacement.personalData.customWords.map(\.value) == ["Linnet"],
      replacement.personalData.disabledWords.map(\.value) == ["keep-disabled"],
      replacement.personalData.expansions.map(\.trigger) == ["x;keep"],
      replacement.learning["linnet_zh"] == nil,
      replacement.learning["linnet_en"] == learning["linnet_en"]
    else {
      fail("portable replacement did not leave unselected categories untouched")
    }
    let second = try LinnetBackupStore.replacement(
      currentPersonalData: replacement.personalData,
      archive: archive
    )
    guard
      try LinnetPersonalDataStore.revision(for: second.personalData)
        == LinnetPersonalDataStore.revision(for: replacement.personalData),
      second.learning == replacement.learning
    else {
      fail("portable replacement was not idempotent")
    }

    let clearedData = try LinnetBackupStore.encodePortable(
      personalData: .empty,
      learning: [:],
      categories: [.textExpander],
      createdAt: timestamp,
      appVersion: "1.0.0",
      dataVersion: "2026.08.06"
    )
    let cleared = try LinnetBackupStore.replacement(
      currentPersonalData: currentPersonal,
      archive: LinnetBackupStore.decodePortable(clearedData)
    )
    guard cleared.personalData.expansions.isEmpty,
      cleared.personalData.customWords.map(\.value) == ["Old"],
      cleared.personalData.disabledWords.map(\.value) == ["keep-disabled"]
    else {
      fail("an explicitly selected empty category did not replace current data")
    }

    guard let first = archive.personal.first else { fail("portable fixture has no payload") }
    let corrupt = LinnetBackupStore.PortableArchive(
      formatVersion: archive.formatVersion,
      createdAt: archive.createdAt,
      appVersion: archive.appVersion,
      dataVersion: archive.dataVersion,
      categories: archive.categories,
      personal: [
        .init(
          category: first.category,
          rowCount: first.rowCount,
          sha256: String(repeating: "0", count: 64),
          rows: first.rows
        )
      ],
      learning: archive.learning
    )
    expectFailure(.invalidHash("customWords")) {
      _ = try LinnetBackupStore.decodePortable(try encode(corrupt))
    }
    let unsupported = LinnetBackupStore.PortableArchive(
      formatVersion: 99,
      createdAt: archive.createdAt,
      appVersion: archive.appVersion,
      dataVersion: archive.dataVersion,
      categories: archive.categories,
      personal: archive.personal,
      learning: archive.learning
    )
    expectFailure(.unsupportedVersion(99)) {
      _ = try LinnetBackupStore.decodePortable(try encode(unsupported))
    }
    let missingPayload = LinnetBackupStore.PortableArchive(
      formatVersion: archive.formatVersion,
      createdAt: archive.createdAt,
      appVersion: archive.appVersion,
      dataVersion: archive.dataVersion,
      categories: archive.categories + [.disabledWords],
      personal: archive.personal,
      learning: archive.learning
    )
    expectFailure(.invalidCategory("payload does not match selected categories")) {
      _ = try LinnetBackupStore.decodePortable(try encode(missingPayload))
    }
    guard let learningArtifact = archive.learning.first else {
      fail("portable fixture has no learning payload")
    }
    let wrongSchema = LinnetBackupStore.PortableArchive(
      formatVersion: archive.formatVersion,
      createdAt: archive.createdAt,
      appVersion: archive.appVersion,
      dataVersion: archive.dataVersion,
      categories: archive.categories,
      personal: archive.personal,
      learning: [
        .init(
          category: learningArtifact.category,
          schema: "unknown",
          rowCount: learningArtifact.rowCount,
          sha256: learningArtifact.sha256,
          contents: learningArtifact.contents
        )
      ]
    )
    expectFailure(.invalidCategory("unknown")) {
      _ = try LinnetBackupStore.decodePortable(try encode(wrongSchema))
    }
    expectFailure(.artifactTooLarge("linnet_en")) {
      _ = try LinnetBackupStore.encodePortable(
        personalData: .empty,
        learning: [
          "linnet_en": String(
            repeating: "a",
            count: LinnetBackupStore.maximumLearningBytes + 1
          )
        ],
        categories: [.englishLearning],
        createdAt: timestamp,
        appVersion: "1.0.0",
        dataVersion: "2026.08.06"
      )
    }
    expectFailure(.documentTooLarge) {
      _ = try LinnetBackupStore.decodePortable(
        Data(count: LinnetBackupStore.maximumPortableBytes + 1)
      )
    }
    let row = #"{"value":"a","key":"a"}"#
    let rowCount = LinnetPersonalDataStore.maximumRows + 1
    let rows = String(repeating: "\(row),", count: rowCount - 1) + row
    let structuralFlood = Data(
      """
      {"formatVersion":1,"createdAt":"2023-11-14T22:13:20Z","appVersion":"1.0.0","dataVersion":"fixture","categories":["customWords"],"personal":[{"category":"customWords","rowCount":\(rowCount),"sha256":"\(String(repeating: "0", count: 64))","rows":[\(rows)]}],"learning":[]}
      """.utf8
    )
    expectFailure(.documentTooLarge) {
      _ = try LinnetBackupStore.decodePortable(structuralFlood)
    }
  }

  private static func testBackupHistory(root: URL) throws {
    let verifiedTransaction = UUID()
    let verified = try makeBackup(
      root: root,
      transactionID: verifiedTransaction,
      customValue: "Verified"
    )
    let manifest = try commit(
      verified,
      transactionID: verifiedTransaction,
      operation: .applyPersonalData,
      createdAt: Date(timeIntervalSince1970: 200)
    )
    guard manifest.formatVersion == 4,
      manifest.artifacts.contains(where: { $0.path == "user-dictionaries/linnet_en.userdb/000001.ldb" && $0.rowCount == nil }),
      try LinnetBackupStore.verifyBackup(at: verified) == manifest
    else {
      fail("a newly written native manifest-v4 backup did not verify")
    }
    expectFailure(.backupAlreadyComplete) {
      _ = try commit(
        verified,
        transactionID: verifiedTransaction,
        operation: .applyPersonalData,
        createdAt: .now
      )
    }
    guard try LinnetBackupStore.verifyBackup(at: verified) == manifest else {
      fail("a duplicate commit changed an existing verified backup")
    }

    let incompleteTransaction = UUID()
    _ = try makeBackup(
      root: root,
      transactionID: incompleteTransaction,
      customValue: "Incomplete"
    )
    let emptyTransaction = UUID()
    try makeDirectory(
      root.appending(path: emptyTransaction.uuidString, directoryHint: .isDirectory)
    )

    let corruptTransaction = UUID()
    let corrupt = try makeBackup(
      root: root,
      transactionID: corruptTransaction,
      customValue: "Cloud"
    )
    _ = try commit(
      corrupt,
      transactionID: corruptTransaction,
      operation: .restore,
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let customFile = corrupt.appending(
      path: "stable/\(LinnetPersonalDataStore.customWordsFile)"
    )
    let original = try String(contentsOf: customFile, encoding: .utf8)
    try original.replacingOccurrences(of: "Cloud", with: "Claud").write(
      to: customFile,
      atomically: true,
      encoding: .utf8
    )
    expectFailure(.invalidHash("stable/\(LinnetPersonalDataStore.customWordsFile)")) {
      _ = try LinnetBackupStore.verifyBackup(at: corrupt)
    }

    let history = try LinnetBackupStore.listBackups(in: root)
    guard history.count == 4,
      history.contains(where: {
        $0.transactionID == verifiedTransaction && isVerified($0.state)
      }),
      history.contains(where: {
        $0.transactionID == incompleteTransaction && $0.state == .incomplete
      }),
      history.contains(where: {
        $0.transactionID == emptyTransaction && $0.state == .incomplete
      }),
      history.contains(where: {
        $0.transactionID == corruptTransaction && isCorrupt($0.state)
      })
    else {
      fail("backup history did not preserve verified, incomplete, and corrupt states")
    }
  }

  private static func testLegacyV2Compatibility(root: URL) throws {
    try makeDirectory(root)
    let fixture = try makeLegacyV2Backup(root: root)

    let history = try LinnetBackupStore.listBackups(in: root)
    guard history.count == 1,
      history[0].state == .verified(fixture.manifest),
      try LinnetBackupStore.verifyBackup(at: fixture.backup) == fixture.manifest
    else {
      fail("a frozen legal v2 backup did not survive list and verification")
    }

    let restored = root.appending(path: "restored", directoryHint: .isDirectory)
    try makeDirectory(restored)
    try LinnetBackupStore.copyStable(
      from: fixture.backup.appending(path: "stable", directoryHint: .isDirectory),
      to: restored
    )
    let restoredPersonal = try LinnetPersonalDataStore.load(from: restored)
    let restoredDocument = try LinnetSettingsDocumentStore.load(from: restored)
    let restoredRuntime = try String(
      contentsOf: restored.appending(path: LinnetPersonalDataStore.userSettingsFile),
      encoding: .utf8
    )
    guard restoredPersonal.customWords.map(\.value) == ["Legacy Cloud"],
      restoredPersonal.disabledWords.map(\.value) == ["legacy-disabled"],
      restoredPersonal.expansions.map(\.trigger) == ["x;legacy"],
      restoredDocument.english.sentenceCapitalization,
      restoredDocument.english.tabBehavior == .pass,
      restoredRuntime.hasPrefix("patch:\n"),
      !FileManager.default.fileExists(
        atPath: restored.appending(path: LinnetPersonalDataStore.legacyUserSettingsFile).path
      )
    else {
      fail("v2 restore did not normalize exactly once into the current canonical files")
    }

    let rewrittenID = UUID()
    let rewrittenTransaction = root.appending(
      path: rewrittenID.uuidString, directoryHint: .isDirectory)
    let rewrittenBackup = rewrittenTransaction.appending(
      path: "backup", directoryHint: .isDirectory)
    let rewrittenStable = rewrittenBackup.appending(
      path: "stable", directoryHint: .isDirectory)
    let rewrittenLearning = rewrittenBackup.appending(
      path: "user-dictionaries", directoryHint: .isDirectory)
    for directory in [rewrittenTransaction, rewrittenBackup, rewrittenStable, rewrittenLearning] {
      try makeDirectory(directory)
    }
    _ = try LinnetBackupStore.snapshotStable(from: restored, to: rewrittenStable)
    let rewritten = try commit(
      rewrittenBackup,
      transactionID: rewrittenID,
      operation: .restore,
      createdAt: Date(timeIntervalSince1970: 301)
    )
    guard rewritten.formatVersion == 4,
      rewritten.artifacts.contains(where: {
        $0.path == "stable/\(LinnetPersonalDataStore.userSettingsFile)"
      }),
      !rewritten.artifacts.contains(where: {
        $0.path == "stable/\(LinnetPersonalDataStore.legacyUserSettingsFile)"
      })
    else {
      fail("a restored v2 backup was not rewritten solely as v4")
    }

    let mislabeled = LinnetBackupStore.BackupManifest(
      formatVersion: 2,
      complete: rewritten.complete,
      backupID: rewritten.backupID,
      transactionID: rewritten.transactionID,
      operation: rewritten.operation,
      createdAt: rewritten.createdAt,
      appVersion: rewritten.appVersion,
      dataVersion: rewritten.dataVersion,
      personalRevision: rewritten.personalRevision,
      artifacts: rewritten.artifacts
    )
    try encode(mislabeled).write(
      to: rewrittenBackup.appending(path: "manifest.json"), options: .atomic)
    expectFailure(.incompleteBackup) {
      _ = try LinnetBackupStore.verifyBackup(at: rewrittenBackup)
    }

    let damaged = LinnetBackupStore.BackupManifest(
      formatVersion: fixture.manifest.formatVersion,
      complete: fixture.manifest.complete,
      backupID: fixture.manifest.backupID,
      transactionID: fixture.manifest.transactionID,
      operation: fixture.manifest.operation,
      createdAt: fixture.manifest.createdAt,
      appVersion: fixture.manifest.appVersion,
      dataVersion: fixture.manifest.dataVersion,
      personalRevision: String(repeating: "0", count: 64),
      artifacts: fixture.manifest.artifacts
    )
    try encode(damaged).write(
      to: fixture.backup.appending(path: "manifest.json"), options: .atomic)
    expectFailure(.invalidHash("personal revision")) {
      _ = try LinnetBackupStore.verifyBackup(at: fixture.backup)
    }
  }

  private static func testSymlinkAndVersionGuards(root: URL) throws {
    let symlinkTransaction = UUID()
    let symlinkBackup = try makeBackup(
      root: root,
      transactionID: symlinkTransaction,
      customValue: "Symlink"
    )
    let custom = symlinkBackup.appending(
      path: "stable/\(LinnetPersonalDataStore.customWordsFile)"
    )
    let outside = root.appending(path: "outside.txt")
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: custom)
    try FileManager.default.createSymbolicLink(at: custom, withDestinationURL: outside)
    expectFailure(.unsafeArtifact(LinnetPersonalDataStore.customWordsFile)) {
      _ = try commit(
        symlinkBackup,
        transactionID: symlinkTransaction,
        operation: .clearLearning,
        createdAt: .now
      )
    }
    guard !FileManager.default.fileExists(
      atPath: root.appending(path: symlinkTransaction.uuidString).path
    ), try Data(contentsOf: outside) == Data("outside".utf8) else {
      fail("an unsafe-artifact commit did not remove only its own transaction")
    }

    let versionTransaction = UUID()
    let versionBackup = try makeBackup(
      root: root,
      transactionID: versionTransaction,
      customValue: "Version"
    )
    let manifest = try commit(
      versionBackup,
      transactionID: versionTransaction,
      operation: .importPortable,
      createdAt: .now
    )
    let unsupported = LinnetBackupStore.BackupManifest(
      formatVersion: 99,
      complete: manifest.complete,
      backupID: manifest.backupID,
      transactionID: manifest.transactionID,
      operation: manifest.operation,
      createdAt: manifest.createdAt,
      appVersion: manifest.appVersion,
      dataVersion: manifest.dataVersion,
      personalRevision: manifest.personalRevision,
      artifacts: manifest.artifacts
    )
    try encode(unsupported).write(
      to: versionBackup.appending(path: "manifest.json"),
      options: .atomic
    )
    expectFailure(.unsupportedVersion(99)) {
      _ = try LinnetBackupStore.verifyBackup(at: versionBackup)
    }
  }

  private static func testRetention(root: URL) throws {
    try makeDirectory(root)
    var verifiedTransactions: [UUID] = []
    for index in 0..<13 {
      let transactionID = UUID()
      verifiedTransactions.append(transactionID)
      let backup = try makeBackup(
        root: root,
        transactionID: transactionID,
        customValue: "Retention \(index)"
      )
      _ = try commit(
        backup,
        transactionID: transactionID,
        operation: .applyPersonalData,
        createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
      )
    }

    let incompleteTransaction = UUID()
    _ = try makeBackup(
      root: root,
      transactionID: incompleteTransaction,
      customValue: "Incomplete retention"
    )
    let corruptTransaction = UUID()
    let corruptBackup = try makeBackup(
      root: root,
      transactionID: corruptTransaction,
      customValue: "Corrupt retention"
    )
    _ = try commit(
      corruptBackup,
      transactionID: corruptTransaction,
      operation: .restore,
      createdAt: Date(timeIntervalSince1970: 100)
    )
    try "changed\n".write(
      to: corruptBackup.appending(
        path: "stable/\(LinnetPersonalDataStore.customWordsFile)"
      ),
      atomically: true,
      encoding: .utf8
    )

    let invalidLimit = UUID()
    let invalidLimitBackup = try makeBackup(
      root: root, transactionID: invalidLimit, customValue: "Invalid limit"
    )
    expectFailure(.invalidRetentionLimit) {
      _ = try commit(
        invalidLimitBackup,
        transactionID: invalidLimit,
        operation: .applyPersonalData,
        createdAt: .now,
        keepingMostRecent: 0
      )
    }
    guard !FileManager.default.fileExists(
      atPath: root.appending(path: invalidLimit.uuidString).path)
    else { fail("an invalid retention commit leaked its current transaction") }

    let current = UUID()
    let currentBackup = try makeBackup(
      root: root, transactionID: current, customValue: "Retention current"
    )
    _ = try commit(
      currentBackup,
      transactionID: current,
      operation: .applyPersonalData,
      createdAt: Date(timeIntervalSince1970: 200),
      keepingMostRecent: 10,
      preserving: [verifiedTransactions[0], verifiedTransactions[1]]
    )
    guard
      FileManager.default.fileExists(
        atPath: root.appending(path: verifiedTransactions[0].uuidString).path
      ),
      FileManager.default.fileExists(
        atPath: root.appending(path: verifiedTransactions[1].uuidString).path
      ),
      FileManager.default.fileExists(
        atPath: root.appending(path: incompleteTransaction.uuidString).path
      ),
      FileManager.default.fileExists(
        atPath: root.appending(path: corruptTransaction.uuidString).path
      ),
      FileManager.default.fileExists(atPath: root.appending(path: current.uuidString).path),
      verifiedTransactions[2...5].allSatisfy({
        !FileManager.default.fileExists(atPath: root.appending(path: $0.uuidString).path)
      })
    else {
      fail("commit retention deleted an invalid/protected record or kept an expired record")
    }

    let history = try LinnetBackupStore.listBackups(in: root)
    guard history.filter({ isVerified($0.state) }).count == 10,
      history.contains(where: {
        $0.transactionID == incompleteTransaction && $0.state == .incomplete
      }),
      history.contains(where: {
        $0.transactionID == corruptTransaction && isCorrupt($0.state)
      })
    else {
      fail("commit retention did not converge to ten verified backups")
    }
  }

  private static func testHistoryLimit(root: URL) throws {
    try makeDirectory(root)
    for _ in 0...LinnetBackupStore.maximumHistoryEntries {
      try makeDirectory(
        root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
      )
    }
    expectFailure(.historyTooLarge) {
      _ = try LinnetBackupStore.listBackups(in: root)
    }
  }

  private static func testAggregateLimit(root: URL) throws {
    try makeDirectory(root)
    let transactionID = UUID()
    let backup = try makeBackup(
      root: root,
      transactionID: transactionID,
      customValue: "Aggregate"
    )
    let stable = backup.appending(path: "stable", directoryHint: .isDirectory)
    for index in 0..<13 {
      let file = stable.appending(path: "aggregate-\(index).custom.yaml")
      FileManager.default.createFile(atPath: file.path, contents: nil)
      let handle = try FileHandle(forWritingTo: file)
      try handle.truncate(atOffset: UInt64(LinnetBackupStore.maximumStableArtifactBytes))
      try handle.close()
    }
    expectFailure(.artifactTooLarge("backup total")) {
      _ = try commit(
        backup,
        transactionID: transactionID,
        operation: .applyPersonalData,
        createdAt: .now
      )
    }
    guard !FileManager.default.fileExists(
      atPath: root.appending(path: transactionID.uuidString).path
    ) else { fail("an aggregate-limit failure leaked its current transaction") }
  }

  private static func testBoundedRegularFileReader(root: URL) throws {
    try makeDirectory(root)
    let regular = root.appending(path: "regular.data")
    let payload = Data(repeating: 0x5a, count: 2 * 1024 * 1024 + 17)
    try payload.write(to: regular)
    guard try LinnetBackupStore.readBoundedRegularFile(regular, limit: payload.count) == payload else {
      fail("the bounded regular-file reader changed legal bytes")
    }

    let symlink = root.appending(path: "symlink.data")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
    expectFailure(.unsafeArtifact(symlink.lastPathComponent)) {
      _ = try LinnetBackupStore.readBoundedRegularFile(symlink, limit: payload.count)
    }
    expectFailure(.artifactTooLarge(regular.lastPathComponent)) {
      _ = try LinnetBackupStore.readBoundedRegularFile(regular, limit: payload.count - 1)
    }

    try expectConcurrentSizeMutationRejected(
      file: root.appending(path: "grow.data"), grow: true)
    try expectConcurrentSizeMutationRejected(
      file: root.appending(path: "shrink.data"), grow: false)
  }

  private static func expectConcurrentSizeMutationRejected(file: URL, grow: Bool) throws {
    let initialBytes = 64 * 1024 * 1024
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let initial = try FileHandle(forWritingTo: file)
    try initial.truncate(atOffset: UInt64(initialBytes))
    try initial.close()

    let descriptor = open(file.path, O_WRONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { fail("could not open the bounded-reader mutation probe") }
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      started.signal()
      for index in 0..<20_000 {
        let delta = index.isMultiple(of: 2) ? 0 : (grow ? 1 : -1)
        _ = ftruncate(descriptor, off_t(initialBytes + delta))
        usleep(10)
      }
      close(descriptor)
      finished.signal()
    }
    started.wait()
    var rejected = false
    do {
      _ = try LinnetBackupStore.readBoundedRegularFile(file, limit: initialBytes + 1)
    } catch is LinnetBackupStore.Failure {
      rejected = true
    }
    finished.wait()
    guard rejected else {
      fail("a file that \(grow ? "grew" : "shrank") during a bounded read was accepted")
    }
  }

  private static func testCommitHistoryCapacity(root: URL) throws {
    let recoverable = root.appending(path: "recoverable", directoryHint: .isDirectory)
    try makeDirectory(recoverable)
    var verified: [UUID] = []
    for index in 0..<100 {
      let transactionID = UUID()
      verified.append(transactionID)
      let backup = try makeBackup(
        root: recoverable,
        transactionID: transactionID,
        customValue: "Verified \(index)"
      )
      _ = try commit(
        backup,
        transactionID: transactionID,
        operation: .applyPersonalData,
        createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
      )
    }
    for _ in 0..<28 {
      try makeDirectory(recoverable.appending(path: UUID().uuidString, directoryHint: .isDirectory))
    }
    let current = UUID()
    let currentBackup = try makeBackup(
      root: recoverable, transactionID: current, customValue: "Current"
    )
    _ = try LinnetBackupStore.commitBackup(.init(
      backupDirectory: currentBackup,
      backupID: UUID(),
      transactionID: current,
      operation: .restore,
      createdAt: Date(timeIntervalSince1970: 1_000),
      appVersion: "1.0.0",
      dataVersion: "2026.08.06",
      transactionsRoot: recoverable,
      maximumVerifiedBackups: 100,
      protectedTransactionIDs: [current, verified[0]]
    ))
    let recovered = try LinnetBackupStore.listBackups(in: recoverable)
    guard recovered.count == LinnetBackupStore.maximumHistoryEntries,
      recovered.filter({ isVerified($0.state) }).count == 100,
      recovered.contains(where: { $0.transactionID == current && isVerified($0.state) }),
      recovered.contains(where: { $0.transactionID == verified[0] && isVerified($0.state) }),
      !FileManager.default.fileExists(
        atPath: recoverable.appending(path: verified[1].uuidString).path)
    else {
      fail("latest-100 could not make progress with 28 preserved invalid records")
    }

    let exhausted = root.appending(path: "exhausted", directoryHint: .isDirectory)
    try makeDirectory(exhausted)
    let sentinelID = UUID()
    let sentinel = exhausted.appending(path: sentinelID.uuidString, directoryHint: .isDirectory)
    try makeDirectory(sentinel)
    let sentinelFile = sentinel.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: sentinelFile)
    for _ in 1..<LinnetBackupStore.maximumHistoryEntries {
      try makeDirectory(exhausted.appending(path: UUID().uuidString, directoryHint: .isDirectory))
    }
    let oldNames = try Set(FileManager.default.contentsOfDirectory(atPath: exhausted.path))
    let rejected = UUID()
    let rejectedBackup = try makeBackup(
      root: exhausted, transactionID: rejected, customValue: "Rejected"
    )
    expectFailure(.historyTooLarge) {
      _ = try LinnetBackupStore.commitBackup(.init(
        backupDirectory: rejectedBackup,
        backupID: UUID(),
        transactionID: rejected,
        operation: .applyPersonalData,
        createdAt: .now,
        appVersion: "1.0.0",
        dataVersion: "2026.08.06",
        transactionsRoot: exhausted,
        maximumVerifiedBackups: 100,
        protectedTransactionIDs: [rejected]
      ))
    }
    guard try Set(FileManager.default.contentsOfDirectory(atPath: exhausted.path)) == oldNames,
      try Data(contentsOf: sentinelFile) == Data("keep".utf8)
    else {
      fail("an exhausted invalid history changed pre-existing bytes or members")
    }

    guard let removable = try LinnetBackupStore.listBackups(in: exhausted).first(where: {
      $0.transactionID == sentinelID
    }) else { fail("the exhausted-history recovery record was not listed") }
    try LinnetBackupStore.removeNonverifiedBackup(removable, in: exhausted, preserving: [])
    let recoveredID = UUID()
    let recoveredBackup = try makeBackup(
      root: exhausted, transactionID: recoveredID, customValue: "Recovered"
    )
    _ = try commit(
      recoveredBackup,
      transactionID: recoveredID,
      operation: .applyPersonalData,
      createdAt: .now
    )
    guard try LinnetBackupStore.listBackups(in: exhausted).count
      == LinnetBackupStore.maximumHistoryEntries
    else { fail("manual recovery did not unblock the next automatic backup") }
  }

  private static func testManualHistoryRecovery(root: URL) throws {
    try makeDirectory(root)

    let verifiedID = UUID()
    let verifiedBackup = try makeBackup(
      root: root, transactionID: verifiedID, customValue: "Verified"
    )
    _ = try commit(
      verifiedBackup,
      transactionID: verifiedID,
      operation: .applyPersonalData,
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let incompleteID = UUID()
    let incompleteDirectory = root.appending(
      path: incompleteID.uuidString, directoryHint: .isDirectory)
    try makeDirectory(incompleteDirectory)
    let incompleteSentinel = incompleteDirectory.appending(path: "incomplete.txt")
    try Data("incomplete".utf8).write(to: incompleteSentinel)

    let initial = try LinnetBackupStore.listBackups(in: root)
    guard let verified = initial.first(where: { $0.transactionID == verifiedID }),
      let incomplete = initial.first(where: { $0.transactionID == incompleteID })
    else { fail("manual-recovery fixtures were not classified") }
    let verifiedManifest = try Data(
      contentsOf: verifiedBackup.appending(path: "manifest.json"))
    expectFailure(.backupAlreadyComplete) {
      try LinnetBackupStore.removeNonverifiedBackup(
        verified, in: root, preserving: [])
    }
    guard try Data(contentsOf: verifiedBackup.appending(path: "manifest.json"))
      == verifiedManifest
    else { fail("manual recovery changed a verified backup") }

    expectFailure(.unsafeArtifact(incompleteID.uuidString)) {
      try LinnetBackupStore.removeNonverifiedBackup(
        incomplete, in: root, preserving: [incompleteID])
    }
    guard try Data(contentsOf: incompleteSentinel) == Data("incomplete".utf8) else {
      fail("manual recovery changed a protected incomplete backup")
    }

    let nested = root.appending(path: "nested", directoryHint: .isDirectory)
      .appending(path: incompleteID.uuidString, directoryHint: .isDirectory)
    try makeDirectory(nested)
    let nestedSentinel = nested.appending(path: "nested.txt")
    try Data("nested".utf8).write(to: nestedSentinel)
    let forged = LinnetBackupStore.BackupRecord(
      transactionDirectory: nested,
      backupDirectory: nested.appending(path: "backup", directoryHint: .isDirectory),
      transactionID: incompleteID,
      state: .incomplete,
      transactionIdentity: incomplete.transactionIdentity
    )
    expectFailure(.unsafeArtifact(incompleteID.uuidString)) {
      try LinnetBackupStore.removeNonverifiedBackup(forged, in: root, preserving: [])
    }
    guard try Data(contentsOf: nestedSentinel) == Data("nested".utf8) else {
      fail("manual recovery accepted a non-direct-child path")
    }

    try LinnetBackupStore.removeNonverifiedBackup(incomplete, in: root, preserving: [])
    guard !FileManager.default.fileExists(atPath: incompleteDirectory.path),
      FileManager.default.fileExists(atPath: verifiedBackup.path)
    else { fail("manual recovery did not remove only the selected UUID") }

    let corruptID = UUID()
    let corruptBackup = try makeBackup(
      root: root, transactionID: corruptID, customValue: "Corrupt"
    )
    _ = try commit(
      corruptBackup,
      transactionID: corruptID,
      operation: .importPortable,
      createdAt: Date(timeIntervalSince1970: 1.5)
    )
    let corruptFile = corruptBackup.appending(
      path: "stable/\(LinnetPersonalDataStore.customWordsFile)")
    try Data("changed".utf8).write(to: corruptFile)
    guard let corrupt = try LinnetBackupStore.listBackups(in: root).first(where: {
      $0.transactionID == corruptID && isCorrupt($0.state)
    }) else { fail("invalid manual-recovery fixture was not classified") }
    try LinnetBackupStore.removeNonverifiedBackup(corrupt, in: root, preserving: [])
    guard !FileManager.default.fileExists(
      atPath: corruptBackup.deletingLastPathComponent().path),
      FileManager.default.fileExists(atPath: verifiedBackup.path)
    else { fail("manual recovery did not remove only the invalid UUID") }

    let staleID = UUID()
    let staleBackup = try makeBackup(root: root, transactionID: staleID, customValue: "Stale")
    guard let stale = try LinnetBackupStore.listBackups(in: root).first(where: {
      $0.transactionID == staleID
    }) else { fail("stale manual-recovery fixture was not listed") }
    _ = try commit(
      staleBackup,
      transactionID: staleID,
      operation: .restore,
      createdAt: Date(timeIntervalSince1970: 2)
    )
    expectFailure(.backupAlreadyComplete) {
      try LinnetBackupStore.removeNonverifiedBackup(stale, in: root, preserving: [])
    }
    guard FileManager.default.fileExists(atPath: staleBackup.path) else {
      fail("a stale record deleted a newly verified backup")
    }

    let replacedID = UUID()
    let replacedDirectory = root.appending(
      path: replacedID.uuidString, directoryHint: .isDirectory)
    try makeDirectory(replacedDirectory)
    guard let replaced = try LinnetBackupStore.listBackups(in: root).first(where: {
      $0.transactionID == replacedID
    }) else { fail("replacement fixture was not listed") }
    try FileManager.default.removeItem(at: replacedDirectory)
    try makeDirectory(replacedDirectory)
    let replacementSentinel = replacedDirectory.appending(path: "replacement.txt")
    try Data("replacement".utf8).write(to: replacementSentinel)
    expectFailure(.unsafeArtifact(replacedID.uuidString)) {
      try LinnetBackupStore.removeNonverifiedBackup(replaced, in: root, preserving: [])
    }
    guard try Data(contentsOf: replacementSentinel) == Data("replacement".utf8) else {
      fail("manual recovery accepted a concurrently replaced directory")
    }

    let outside = root.appending(path: "outside", directoryHint: .isDirectory)
    try makeDirectory(outside)
    let outsideSentinel = outside.appending(path: "outside.txt")
    try Data("outside".utf8).write(to: outsideSentinel)
    let linkedID = UUID()
    let linked = root.appending(path: linkedID.uuidString)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    guard let linkedRecord = try LinnetBackupStore.listBackups(in: root).first(where: {
      $0.transactionID == linkedID
    }) else { fail("symlink fixture was not listed") }
    expectFailure(.unsafeArtifact(linkedID.uuidString)) {
      try LinnetBackupStore.removeNonverifiedBackup(linkedRecord, in: root, preserving: [])
    }
    guard try Data(contentsOf: outsideSentinel) == Data("outside".utf8) else {
      fail("manual recovery followed a transaction symlink")
    }
  }

  private static func makeBackup(
    root: URL,
    transactionID: UUID,
    customValue: String,
    legacyTable: Bool = false
  ) throws -> URL {
    let transaction = root.appending(
      path: transactionID.uuidString,
      directoryHint: .isDirectory
    )
    let backup = transaction.appending(path: "backup", directoryHint: .isDirectory)
    let stable = backup.appending(path: "stable", directoryHint: .isDirectory)
    let learning = backup.appending(
      path: "user-dictionaries",
      directoryHint: .isDirectory
    )
    for directory in [transaction, backup, stable, learning] { try makeDirectory(directory) }
    let personal = LinnetPersonalData(
      customWords: [.init(value: customValue, code: "custom")],
      disabledWords: ["disabled"],
      expansions: [.init(value: "Expansion", trigger: "x;test")]
    )
    try LinnetPersonalDataStore.writePersonalFiles(personal, to: stable)
    try LinnetPersonalDataStore.writeRuntimeSettings(personal, to: stable)
    try LinnetSettingsDocumentStore.write(.default, to: stable)
    try "# user\n".write(
      to: stable.appending(path: "user.yaml"),
      atomically: true,
      encoding: .utf8
    )
    if legacyTable {
      try "# Rime user dictionary export\nhello\thello\t3\n".write(
        to: learning.appending(path: "linnet_en.txt"), atomically: true, encoding: .utf8)
    } else {
      let database = learning.appending(path: "linnet_en.userdb", directoryHint: .isDirectory)
      try makeDirectory(database)
      try Data([0, 0x91, 0xff, 0x0a]).write(to: database.appending(path: "000001.ldb"))
    }
    return backup
  }

  private static func testLegacyV3Compatibility(root: URL) throws {
    try makeDirectory(root)
    let transactionID = UUID()
    let backup = try makeBackup(root: root, transactionID: transactionID, customValue: "Legacy V3", legacyTable: true)
    let stable = backup.appending(path: "stable", directoryHint: .isDirectory)
    let manifest = LinnetBackupStore.BackupManifest(
      formatVersion: 3, complete: true, backupID: UUID(), transactionID: transactionID,
      operation: .applyPersonalData, createdAt: Date(timeIntervalSince1970: 301),
      appVersion: "0.1.10", dataVersion: "fixture-v3",
      personalRevision: try LinnetPersonalDataStore.snapshot(from: stable).revision,
      artifacts: try LinnetBackupStore.collectBackupArtifacts(backup, formatVersion: 3))
    try encode(manifest).write(to: backup.appending(path: "manifest.json"))
    guard try LinnetBackupStore.verifyBackup(at: backup) == manifest,
      manifest.artifacts.contains(where: { $0.path == "user-dictionaries/linnet_en.txt" && $0.rowCount == 1 })
    else { fail("a shipped v3 table backup cannot be verified") }
    let candidate = root.appending(path: "candidate", directoryHint: .isDirectory)
    try makeDirectory(candidate)
    try LinnetBackupStore.copyStable(from: stable, to: candidate)
    guard try LinnetPersonalDataStore.snapshot(from: candidate).revision == manifest.personalRevision else {
      fail("v3 stable restore changed the personal data")
    }
  }

  /// Frozen bytes and digest values produced by the v2 codec at bda21963.
  /// This fixture never executes an old binary or touches live user data.
  private static func makeLegacyV2Backup(root: URL) throws -> (
    backup: URL, manifest: LinnetBackupStore.BackupManifest
  ) {
    let transactionID = UUID()
    let transaction = root.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    let backup = transaction.appending(path: "backup", directoryHint: .isDirectory)
    let stable = backup.appending(path: "stable", directoryHint: .isDirectory)
    let learning = backup.appending(
      path: "user-dictionaries", directoryHint: .isDirectory)
    for directory in [transaction, backup, stable, learning] { try makeDirectory(directory) }

    let files: [(name: String, contents: String, sha256: String)] = [
      (
        "linnet_custom_words.txt",
        "# Rime table\n# coding: utf-8\n#@/db_name\tlinnet_custom_words.txt\n#@/db_type\ttabledb\n#\nLegacy Cloud\tlegacy\n",
        "f94e48b117b3739c706ebcc4c1d3322e6620d2c5f3ffb37445bd720ad5002f3d"
      ),
      (
        "linnet_text_expander.txt",
        "# Rime table\n# coding: utf-8\n#@/db_name\tlinnet_text_expander.txt\n#@/db_type\ttabledb\n#\nLegacy expansion\tx;legacy\n",
        "3bec19871ee3dd10b8a25dc7c0236b77aae307dea00f83a0ac68bb848bdae2de"
      ),
      (
        "linnet_user.yaml",
        "# Linnet user-managed settings\n# encoding: utf-8\n\ndisabled_words:\n  - \"legacy-disabled\"\nsentence_capitalization: true\ntab_behavior: pass\n",
        "2e1674b6563e3bc56f3e297b348aa095bac288de214efd2f10b9eba382d86b93"
      ),
    ]
    for file in files {
      try file.contents.write(
        to: stable.appending(path: file.name), atomically: true, encoding: .utf8)
    }
    let manifest = LinnetBackupStore.BackupManifest(
      formatVersion: 2,
      complete: true,
      backupID: UUID(),
      transactionID: transactionID,
      operation: .applyPersonalData,
      createdAt: Date(timeIntervalSince1970: 300),
      appVersion: "1.0.0",
      dataVersion: "2026.08.06",
      personalRevision: "0420c8a4302ec4150da23ba08f21ca6f735774dd87d060d8d1543d04591a3954",
      artifacts: files.map {
        .init(
          path: "stable/\($0.name)",
          byteCount: $0.contents.utf8.count,
          rowCount: nil,
          sha256: $0.sha256
        )
      }
    )
    try encode(manifest).write(to: backup.appending(path: "manifest.json"), options: .atomic)
    return (backup, manifest)
  }

  @discardableResult
  private static func commit(
    _ backup: URL,
    transactionID: UUID,
    operation: LinnetBackupStore.BackupOperation,
    createdAt: Date,
    keepingMostRecent: Int = 100,
    preserving: Set<UUID> = []
  ) throws -> LinnetBackupStore.BackupManifest {
    try LinnetBackupStore.commitBackup(.init(
      backupDirectory: backup,
      backupID: UUID(),
      transactionID: transactionID,
      operation: operation,
      createdAt: createdAt,
      appVersion: "1.0.0",
      dataVersion: "2026.08.06",
      transactionsRoot: backup.deletingLastPathComponent().deletingLastPathComponent(),
      maximumVerifiedBackups: keepingMostRecent,
      protectedTransactionIDs: preserving.union([transactionID])
    ))
  }

  private static func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private static func expectFailure(
    _ expected: LinnetBackupStore.Failure,
    operation: () throws -> Void
  ) {
    do {
      try operation()
      fail("expected failure was not raised: \(expected)")
    } catch let error as LinnetBackupStore.Failure {
      guard error == expected else { fail("unexpected failure: \(error), expected: \(expected)") }
    } catch {
      fail("unexpected error type: \(error)")
    }
  }

  private static func isVerified(_ state: LinnetBackupStore.BackupState) -> Bool {
    if case .verified = state { return true }
    return false
  }

  private static func isCorrupt(_ state: LinnetBackupStore.BackupState) -> Bool {
    if case .corrupt = state { return true }
    return false
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("LinnetBackupStoreTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}
