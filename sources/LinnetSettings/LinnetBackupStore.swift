import CryptoKit
import Darwin
import Foundation

/// Owns bounded backup snapshot/copy, immutable manifests and portable formats.
/// It never mutates the live source directory or initializes librime.
enum LinnetBackupStore {
  static let portableFormatVersion = 1
  static let backupFormatVersion = 3
  fileprivate static let legacyBackupFormatVersion = 2
  static let portableExtension = "linnet-data"

  static let maximumPortableBytes = 64 * 1024 * 1024
  static let maximumLearningBytes = 16 * 1024 * 1024
  static let maximumLearningRows = 1_000_000
  static let maximumManifestBytes = 1024 * 1024
  static let maximumBackupArtifactBytes = 256 * 1024 * 1024
  static let maximumStableArtifactBytes = LinnetPersonalDataStore.maximumFileBytes
  static let maximumBackupBytes = 768 * 1024 * 1024
  static let maximumStableFiles = 128
  static let maximumLiveDirectoryEntries = 512
  // Must admit the largest user-selectable verified retention window while
  // still placing a hard bound on corrupt or incomplete directory floods.
  static let maximumHistoryEntries = 128

  enum Category: String, CaseIterable, Codable, Hashable, Sendable {
    case customWords
    case disabledWords
    case textExpander
    case chineseLearning
    case englishLearning

    var learningSchema: String? {
      switch self {
      case .chineseLearning: "linnet_zh"
      case .englishLearning: "linnet_en"
      default: nil
      }
    }
  }

  enum BackupOperation: String, Codable, Equatable, Sendable {
    case applyPersonalData
    case importLegacy
    case importPortable
    case restore
    case clearLearning
  }

  enum Failure: LocalizedError, Equatable, Sendable {
    case documentTooLarge
    case unsupportedVersion(Int)
    case invalidDocument(String)
    case invalidCategory(String)
    case invalidHash(String)
    case invalidRowCount(String)
    case missingArtifact(String)
    case unsafeArtifact(String)
    case artifactTooLarge(String)
    case incompleteBackup
    case backupAlreadyComplete
    case invalidRetentionLimit
    case historyTooLarge

    var errorDescription: String? {
      switch self {
      case .documentTooLarge: "The data document is too large."
      case .unsupportedVersion(let version): "Unsupported data version: \(version)."
      case .invalidDocument(let detail): "Invalid data document: \(detail)."
      case .invalidCategory(let detail): "Invalid data category: \(detail)."
      case .invalidHash(let name): "Data checksum mismatch: \(name)."
      case .invalidRowCount(let name): "Data row count mismatch: \(name)."
      case .missingArtifact(let name): "Data artifact is missing: \(name)."
      case .unsafeArtifact(let name): "Unsafe data artifact: \(name)."
      case .artifactTooLarge(let name): "Data artifact is too large: \(name)."
      case .incompleteBackup: "The backup is incomplete."
      case .backupAlreadyComplete: "The backup is already complete."
      case .invalidRetentionLimit: "The backup retention limit is invalid."
      case .historyTooLarge: "The backup history contains too many records."
      }
    }
  }

  struct PortableRow: Codable, Equatable, Sendable {
    let value: String
    let key: String?
  }

  struct PortablePersonalArtifact: Codable, Equatable, Sendable {
    let category: Category
    let rowCount: Int
    let sha256: String
    let rows: [PortableRow]
  }

  struct PortableLearningArtifact: Codable, Equatable, Sendable {
    let category: Category
    let schema: String
    let rowCount: Int
    let sha256: String
    let contents: String
  }

  struct PortableArchive: Codable, Equatable, Sendable {
    let formatVersion: Int
    let createdAt: Date
    let appVersion: String
    let dataVersion: String
    let categories: [Category]
    let personal: [PortablePersonalArtifact]
    let learning: [PortableLearningArtifact]
  }

  struct Replacement: Equatable, Sendable {
    let personalData: LinnetPersonalData
    let learning: [String: String]
  }

  struct BackupArtifact: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int
    let rowCount: Int?
    let sha256: String
  }

  struct BackupManifest: Codable, Equatable, Sendable {
    let formatVersion: Int
    let complete: Bool
    let backupID: UUID
    let transactionID: UUID
    let operation: BackupOperation
    let createdAt: Date
    let appVersion: String
    let dataVersion: String
    let personalRevision: String
    let artifacts: [BackupArtifact]
  }

  enum BackupState: Equatable, Sendable {
    case verified(BackupManifest)
    case incomplete
    case corrupt(Failure)
  }

  struct TransactionIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
  }

  struct BackupRecord: Equatable, Sendable {
    let transactionDirectory: URL
    let backupDirectory: URL
    let transactionID: UUID?
    let state: BackupState
    let transactionIdentity: TransactionIdentity?

    var createdAt: Date? {
      guard case .verified(let manifest) = state else { return nil }
      return manifest.createdAt
    }
  }

  static func encodePortable(
    personalData: LinnetPersonalData,
    learning: [String: String],
    categories: Set<Category>,
    createdAt: Date,
    appVersion: String,
    dataVersion: String
  ) throws -> Data {
    try validateVersionLabel(appVersion, name: "appVersion")
    try validateVersionLabel(dataVersion, name: "dataVersion")
    let normalized = try LinnetPersonalDataStore.normalized(personalData)
    let personal =
      try categories
      .filter { $0.learningSchema == nil }
      .sorted { $0.rawValue < $1.rawValue }
      .map { try personalArtifact($0, data: normalized) }
    let learningArtifacts =
      try categories
      .compactMap(\.learningSchema)
      .sorted()
      .map { schema -> PortableLearningArtifact in
        guard let contents = learning[schema] else {
          throw Failure.invalidCategory("missing \(schema)")
        }
        return try learningArtifact(schema: schema, contents: contents)
      }
    let allowedSchemas = Set(Category.allCases.compactMap(\.learningSchema))
    guard Set(learning.keys).isSubset(of: allowedSchemas) else {
      throw Failure.invalidCategory("unknown learning schema")
    }
    let archive = PortableArchive(
      formatVersion: portableFormatVersion,
      createdAt: createdAt,
      appVersion: appVersion,
      dataVersion: dataVersion,
      categories: categories.sorted { $0.rawValue < $1.rawValue },
      personal: personal,
      learning: learningArtifacts
    )
    let data = try encoder().encode(archive)
    guard data.count <= maximumPortableBytes else { throw Failure.documentTooLarge }
    return data
  }

  static func decodePortable(_ data: Data) throws -> PortableArchive {
    guard data.count <= maximumPortableBytes else { throw Failure.documentTooLarge }
    let personalCategoryCount = Category.allCases.filter { $0.learningSchema == nil }.count
    do {
      try LinnetPortableJSONBudget.validate(
        data,
        maximumArrayLength: LinnetPersonalDataStore.maximumRows,
        maximumTotalArrayElements:
          LinnetPersonalDataStore.maximumRows * personalCategoryCount + 32,
        maximumObjectMembers:
          LinnetPersonalDataStore.maximumRows * personalCategoryCount * 2 + 64,
        maximumStringBytes: maximumLearningBytes * 2 + 1024
      )
    } catch LinnetPortableJSONBudget.Failure.resourceLimit {
      throw Failure.documentTooLarge
    } catch {
      throw Failure.invalidDocument("JSON")
    }
    let archive: PortableArchive
    do {
      archive = try decoder().decode(PortableArchive.self, from: data)
    } catch {
      throw Failure.invalidDocument("JSON")
    }
    try validate(archive)
    return archive
  }

  static func replacement(
    currentPersonalData: LinnetPersonalData,
    currentLearning: [String: String],
    archive: PortableArchive
  ) throws -> Replacement {
    try validate(archive)
    let allowedSchemas = Set(Category.allCases.compactMap(\.learningSchema))
    guard Set(currentLearning.keys).isSubset(of: allowedSchemas) else {
      throw Failure.invalidCategory("unknown current learning schema")
    }

    var personal = currentPersonalData
    for artifact in archive.personal {
      switch artifact.category {
      case .customWords:
        personal.customWords = artifact.rows.map {
          .init(value: $0.value, code: $0.key ?? "")
        }
      case .disabledWords:
        personal.disabledWords = artifact.rows.map(\.value)
      case .textExpander:
        personal.expansions = artifact.rows.map {
          .init(value: $0.value, trigger: $0.key ?? "")
        }
      case .chineseLearning, .englishLearning:
        throw Failure.invalidCategory(artifact.category.rawValue)
      }
    }

    var learning = currentLearning
    for artifact in archive.learning {
      learning[artifact.schema] = artifact.contents
    }
    return Replacement(
      personalData: try LinnetPersonalDataStore.normalized(personal),
      learning: learning
    )
  }

  /// Publishes one immutable backup and enforces retention as one store-owned
  /// transition. The current draft is the only admitted 129th history entry.
  /// Every semantic rejection happens before an old verified transaction is
  /// removed; after the first old removal the new manifest is committed.
}

extension LinnetBackupStore {
  @discardableResult
  static func commitBackup(
    backupDirectory: URL,
    backupID: UUID,
    transactionID: UUID,
    operation: BackupOperation,
    createdAt: Date,
    appVersion: String,
    dataVersion: String,
    transactionsRoot: URL,
    keepingMostRecent maximumCount: Int,
    preserving protectedTransactionIDs: Set<UUID>
  ) throws -> BackupManifest {
    try requireDirectory(transactionsRoot)
    let root = transactionsRoot.standardizedFileURL
    let transaction = backupDirectory.deletingLastPathComponent().standardizedFileURL
    guard transaction.deletingLastPathComponent() == root,
      transaction.lastPathComponent == transactionID.uuidString,
      backupDirectory.standardizedFileURL
        == transaction.appending(path: "backup", directoryHint: .isDirectory),
      (try? requireDirectory(transaction)) != nil
    else {
      throw Failure.unsafeArtifact(transactionID.uuidString)
    }
    let manifestURL = backupDirectory.appending(path: "manifest.json")
    guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw Failure.backupAlreadyComplete
    }

    do {
      guard (1...maximumHistoryEntries).contains(maximumCount) else {
        throw Failure.invalidRetentionLimit
      }
      let document = try manifestDocument(
        backupDirectory: backupDirectory,
        backupID: backupID,
        transactionID: transactionID,
        operation: operation,
        createdAt: createdAt,
        appVersion: appVersion,
        dataVersion: dataVersion
      )
      let records = try backupRecords(
        in: transactionsRoot,
        maximumCount: maximumHistoryEntries + 1
      )
      guard records.count <= maximumHistoryEntries + 1,
        records.contains(where: {
          $0.transactionID == transactionID && $0.state == .incomplete
        })
      else {
        throw Failure.historyTooLarge
      }

      let protected = protectedTransactionIDs.union([transactionID])
      let verified = records.filter {
        if case .verified = $0.state { return true }
        return false
      }
      let deletionCount = max(
        0,
        max(
          records.count - maximumHistoryEntries,
          verified.count + 1 - maximumCount
        )
      )
      let candidates = verified.reversed().filter { record in
        guard let candidateID = record.transactionID else { return false }
        return !protected.contains(candidateID)
      }
      guard candidates.count >= deletionCount else { throw Failure.historyTooLarge }
      let deletions = Array(candidates.prefix(deletionCount))
      for record in deletions {
        guard let candidateID = record.transactionID,
          let observed = try? verifyBackup(at: record.backupDirectory),
          observed.transactionID == candidateID,
          deletableTransaction(
            record.transactionDirectory,
            backupDirectory: record.backupDirectory,
            transactionID: candidateID,
            transactionsRoot: transactionsRoot
          )
        else {
          throw Failure.unsafeArtifact(record.transactionDirectory.lastPathComponent)
        }
      }

      try document.contents.write(to: document.url, options: .atomic)
      var removedOldBackup = false
      for record in deletions {
        do {
          try FileManager.default.removeItem(at: record.transactionDirectory)
          removedOldBackup = true
        } catch {
          if !removedOldBackup {
            try rollbackOwnedTransaction(
              transactionID: transactionID,
              backupID: backupID,
              in: transactionsRoot
            )
            throw error
          }
          // The hard 128-entry capacity was restored by the first removal.
          // Once an old verified backup is gone, the new immutable backup is
          // the committed undo point; a later retention IO failure cannot turn
          // that accepted state into a reported operation failure.
          break
        }
      }
      return document.manifest
    } catch {
      if FileManager.default.fileExists(atPath: transaction.path) {
        try? rollbackOwnedTransaction(
          transactionID: transactionID,
          backupID: backupID,
          in: transactionsRoot
        )
      }
      throw error
    }
  }

  fileprivate static func manifestDocument(
    backupDirectory: URL,
    backupID: UUID,
    transactionID: UUID,
    operation: BackupOperation,
    createdAt: Date,
    appVersion: String,
    dataVersion: String
  ) throws -> (manifest: BackupManifest, contents: Data, url: URL) {
    try validateVersionLabel(appVersion, name: "appVersion")
    try validateVersionLabel(dataVersion, name: "dataVersion")
    try requireDirectory(backupDirectory)
    let manifestURL = backupDirectory.appending(path: "manifest.json")
    guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw Failure.backupAlreadyComplete
    }
    let transactionDirectory = backupDirectory.deletingLastPathComponent()
    guard backupDirectory.lastPathComponent == "backup",
      UUID(uuidString: transactionDirectory.lastPathComponent) == transactionID
    else {
      throw Failure.invalidDocument("transaction directory")
    }
    let artifacts = try collectBackupArtifacts(
      backupDirectory, formatVersion: backupFormatVersion)
    let personal = try LinnetPersonalDataStore.snapshot(
      from: backupDirectory.appending(path: "stable", directoryHint: .isDirectory)
    )
    let manifest = BackupManifest(
      formatVersion: backupFormatVersion,
      complete: true,
      backupID: backupID,
      transactionID: transactionID,
      operation: operation,
      createdAt: createdAt,
      appVersion: appVersion,
      dataVersion: dataVersion,
      personalRevision: personal.revision,
      artifacts: artifacts
    )
    let contents = try encoder(pretty: true).encode(manifest)
    guard contents.count <= maximumManifestBytes else {
      throw Failure.artifactTooLarge("manifest.json")
    }
    return (manifest, contents, manifestURL)
  }

  static func verifyBackup(at backupDirectory: URL) throws -> BackupManifest {
    guard FileManager.default.fileExists(atPath: backupDirectory.path) else {
      throw Failure.incompleteBackup
    }
    try requireDirectory(backupDirectory)
    let manifestURL = backupDirectory.appending(path: "manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw Failure.incompleteBackup
    }
    try requireRegularFile(manifestURL)
    let manifestData = try readBoundedRegularFile(manifestURL, limit: maximumManifestBytes)
    let manifest: BackupManifest
    do {
      manifest = try decoder().decode(BackupManifest.self, from: manifestData)
    } catch {
      throw Failure.invalidDocument("manifest")
    }
    guard manifest.formatVersion == backupFormatVersion
      || manifest.formatVersion == legacyBackupFormatVersion
    else {
      throw Failure.unsupportedVersion(manifest.formatVersion)
    }
    guard manifest.complete else { throw Failure.incompleteBackup }
    try validateVersionLabel(manifest.appVersion, name: "appVersion")
    try validateVersionLabel(manifest.dataVersion, name: "dataVersion")
    let transactionDirectory = backupDirectory.deletingLastPathComponent()
    guard backupDirectory.lastPathComponent == "backup",
      UUID(uuidString: transactionDirectory.lastPathComponent) == manifest.transactionID
    else {
      throw Failure.invalidDocument("transaction directory")
    }

    let actual = try collectBackupArtifacts(
      backupDirectory, formatVersion: manifest.formatVersion)
    guard Set(actual.map(\.path)).count == actual.count,
      Set(manifest.artifacts.map(\.path)).count == manifest.artifacts.count,
      actual.map(\.path) == manifest.artifacts.map(\.path)
    else {
      throw Failure.invalidDocument("artifact set")
    }
    for (current, recorded) in zip(actual, manifest.artifacts) {
      guard current.byteCount == recorded.byteCount else {
        throw Failure.invalidDocument("size \(recorded.path)")
      }
      guard current.rowCount == recorded.rowCount else {
        throw Failure.invalidRowCount(recorded.path)
      }
      guard current.sha256 == recorded.sha256 else {
        throw Failure.invalidHash(recorded.path)
      }
    }
    let stable = backupDirectory.appending(path: "stable", directoryHint: .isDirectory)
    let personalRevision: String
    if manifest.formatVersion == legacyBackupFormatVersion {
      personalRevision = try LinnetPersonalDataStore.legacyV2Snapshot(from: stable).revision
    } else {
      personalRevision = try LinnetPersonalDataStore.snapshot(from: stable).revision
    }
    guard personalRevision == manifest.personalRevision else {
      throw Failure.invalidHash("personal revision")
    }
    return manifest
  }

  static func listBackups(in transactionsRoot: URL) throws -> [BackupRecord] {
    guard FileManager.default.fileExists(atPath: transactionsRoot.path) else { return [] }
    return try backupRecords(in: transactionsRoot, maximumCount: maximumHistoryEntries)
  }

  fileprivate static func backupRecords(
    in transactionsRoot: URL,
    maximumCount: Int
  ) throws -> [BackupRecord] {
    try requireDirectory(transactionsRoot)
    let entries = try immediateChildren(
      of: transactionsRoot,
      maximumCount: maximumCount,
      overflow: .historyTooLarge
    )
    return entries.map(backupRecord).sorted {
      let left = $0.createdAt ?? .distantPast
      let right = $1.createdAt ?? .distantPast
      if left != right { return left > right }
      return $0.transactionDirectory.lastPathComponent > $1.transactionDirectory.lastPathComponent
    }
  }

  /// Deletes one user-confirmed history entry only while it is still the same
  /// direct-child transaction and is still not a verified backup. Automatic
  /// retention never calls this path.
  static func removeNonverifiedBackup(
    _ expected: BackupRecord,
    in transactionsRoot: URL,
    preserving protectedTransactionIDs: Set<UUID>
  ) throws {
    try requireDirectory(transactionsRoot)
    let root = transactionsRoot.standardizedFileURL
    guard let transactionID = expected.transactionID,
      !protectedTransactionIDs.contains(transactionID),
      expected.transactionDirectory.standardizedFileURL
        == root.appending(path: transactionID.uuidString, directoryHint: .isDirectory),
      expected.backupDirectory.standardizedFileURL
        == expected.transactionDirectory.appending(
          path: "backup", directoryHint: .isDirectory
        ).standardizedFileURL
    else { throw Failure.unsafeArtifact(expected.transactionDirectory.lastPathComponent) }
    if case .verified = expected.state { throw Failure.backupAlreadyComplete }

    let current = backupRecord(expected.transactionDirectory)
    if case .verified = current.state { throw Failure.backupAlreadyComplete }
    guard let identity = expected.transactionIdentity,
      current.transactionID == transactionID,
      current.transactionIdentity == identity,
      try transactionIdentity(expected.transactionDirectory) == identity
    else { throw Failure.unsafeArtifact(transactionID.uuidString) }

    try FileManager.default.removeItem(at: expected.transactionDirectory)
  }

  /// Creates the stable half of an automatic backup without following links or
  /// copying a byte beyond the canonical per-file and aggregate limits.
  static func snapshotStable(from live: URL, to backup: URL) throws
    -> LinnetPersonalDataStore.Snapshot {
    try requireDirectory(live)
    try requireDirectory(backup)
    guard try immediateChildren(of: backup, maximumCount: 1, overflow: .unsafeArtifact("stable"))
      .isEmpty
    else {
      throw Failure.unsafeArtifact("stable")
    }

    let snapshot = try LinnetPersonalDataStore.snapshot(from: live)
    let canonicalURLs = canonicalPersonalFiles.map { live.appending(path: $0) }
    let canonicalComplete = canonicalURLs.allSatisfy {
      FileManager.default.fileExists(atPath: $0.path)
    }
    for source in canonicalURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      if FileManager.default.fileExists(atPath: source.path) {
        _ = try copyBoundedRegularFile(
          source,
          to: backup.appending(path: source.lastPathComponent),
          limit: stableArtifactLimit(source.lastPathComponent)
        )
      }
    }
    if !canonicalComplete {
      try LinnetPersonalDataStore.writeBackupNormalization(
        snapshot.data,
        to: backup
      )
    }
    let liveDocument = live.appending(path: LinnetSettingsDocumentStore.fileName)
    if FileManager.default.fileExists(atPath: liveDocument.path) {
      _ = try copyBoundedRegularFile(
        liveDocument,
        to: backup.appending(path: LinnetSettingsDocumentStore.fileName),
        limit: LinnetSettingsDocumentStore.maximumDocumentBytes
      )
    } else {
      try LinnetSettingsDocumentStore.write(
        LinnetSettingsDocumentStore.adoptLegacy(from: live),
        to: backup
      )
    }
    var copiedBytes = try regularBytes(in: backup, maximumCount: maximumStableFiles)

    let candidates = try immediateChildren(
      of: live,
      maximumCount: maximumLiveDirectoryEntries,
      overflow: .unsafeArtifact("live directory entry limit")
    ).filter { url in
      let name = url.lastPathComponent
      guard !canonicalPersonalFiles.contains(name),
        name != LinnetSettingsDocumentStore.fileName
      else { return false }
      return stableFiles.contains(name) || name.hasSuffix(".custom.yaml")
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard candidates.count + canonicalPersonalFiles.count + 1 <= maximumStableFiles else {
      throw Failure.artifactTooLarge("stable file count")
    }
    for source in candidates {
      let name = source.lastPathComponent
      guard stableSourceNameIsAllowed(name) else { throw Failure.unsafeArtifact(name) }
      let remaining = maximumBackupBytes - copiedBytes
      let copied = try copyBoundedRegularFile(
        source,
        to: backup.appending(path: name),
        limit: min(stableArtifactLimit(name), remaining)
      )
      copiedBytes += copied
    }
    return snapshot
  }

  /// Copies an already bounded and verified stable directory into an empty
  /// candidate. Restore and staging callers cannot bypass the same contract.
  static func copyStable(from source: URL, to destination: URL) throws {
    try requireDirectory(source)
    try requireDirectory(destination)
    guard try immediateChildren(
      of: destination,
      maximumCount: 1,
      overflow: .unsafeArtifact("candidate")
    ).isEmpty else {
      throw Failure.unsafeArtifact("candidate")
    }
    let stable = try stableArtifactURLs(source, formatVersion: nil)
    switch stable.layout {
    case .current:
      var copiedBytes = 0
      for file in stable.files {
        let remaining = maximumBackupBytes - copiedBytes
        let copied = try copyBoundedRegularFile(
          file,
          to: destination.appending(path: file.lastPathComponent),
          limit: min(stableArtifactLimit(file.lastPathComponent), remaining)
        )
        copiedBytes += copied
      }
    case .legacyV2:
      try normalizeLegacyV2Stable(stable.files, from: source, to: destination)
    }
  }

  /// Deletes only this operation's unpublished backup transaction. A manifest
  /// is the publication boundary; complete or foreign history is never removed.
  static func discardIncompleteBackup(transactionID: UUID, in transactionsRoot: URL) throws {
    try requireDirectory(transactionsRoot)
    let transaction = transactionsRoot.appending(
      path: transactionID.uuidString,
      directoryHint: .isDirectory
    ).standardizedFileURL
    guard transaction.deletingLastPathComponent() == transactionsRoot.standardizedFileURL else {
      throw Failure.unsafeArtifact(transactionID.uuidString)
    }
    guard FileManager.default.fileExists(atPath: transaction.path) else { return }
    try requireDirectory(transaction)
    let manifest = transaction.appending(path: "backup/manifest.json")
    guard !FileManager.default.fileExists(atPath: manifest.path) else {
      throw Failure.backupAlreadyComplete
    }
    try FileManager.default.removeItem(at: transaction)
  }
}

extension LinnetBackupStore {
  fileprivate static let canonicalPersonalFiles = Set([
    LinnetPersonalDataStore.customWordsFile,
    LinnetPersonalDataStore.userSettingsFile,
    LinnetPersonalDataStore.expansionsFile
  ])
  fileprivate static let legacyV2PersonalFiles = Set([
    LinnetPersonalDataStore.customWordsFile,
    LinnetPersonalDataStore.legacyUserSettingsFile,
    LinnetPersonalDataStore.expansionsFile
  ])
  fileprivate static let stableFiles = Set(["installation.yaml", "user.yaml"])
  fileprivate static let learningFiles = Set(["linnet_zh.txt", "linnet_en.txt"])

  fileprivate enum StableLayout {
    case current
    case legacyV2

    var requiredFiles: Set<String> {
      switch self {
      case .current: canonicalPersonalFiles.union([LinnetSettingsDocumentStore.fileName])
      case .legacyV2: legacyV2PersonalFiles
      }
    }
  }

  fileprivate static func backupRecord(_ transactionDirectory: URL) -> BackupRecord {
    let transactionID = UUID(uuidString: transactionDirectory.lastPathComponent)
    let backup = transactionDirectory.appending(path: "backup", directoryHint: .isDirectory)
    let identity = try? transactionIdentity(transactionDirectory)
    do {
      guard identity != nil else {
        throw Failure.unsafeArtifact(transactionDirectory.lastPathComponent)
      }
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .verified(try verifyBackup(at: backup)),
        transactionIdentity: identity
      )
    } catch Failure.incompleteBackup {
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .incomplete,
        transactionIdentity: identity
      )
    } catch let failure as Failure {
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .corrupt(failure),
        transactionIdentity: identity
      )
    } catch {
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .corrupt(.invalidDocument("filesystem")),
        transactionIdentity: identity
      )
    }
  }

  fileprivate static func transactionIdentity(_ url: URL) throws -> TransactionIdentity {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafeArtifact(url.lastPathComponent) }
    return .init(
      device: UInt64(info.st_dev),
      inode: UInt64(info.st_ino),
      modifiedSeconds: info.st_mtimespec.tv_sec,
      modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      changedSeconds: info.st_ctimespec.tv_sec,
      changedNanoseconds: info.st_ctimespec.tv_nsec
    )
  }

  fileprivate static func rollbackOwnedTransaction(
    transactionID: UUID,
    backupID: UUID,
    in transactionsRoot: URL
  ) throws {
    let root = transactionsRoot.standardizedFileURL
    let transaction = root.appending(
      path: transactionID.uuidString,
      directoryHint: .isDirectory
    ).standardizedFileURL
    guard transaction.deletingLastPathComponent() == root,
      transaction.resolvingSymlinksInPath() == transaction,
      (try? requireDirectory(transaction)) != nil
    else {
      throw Failure.unsafeArtifact(transactionID.uuidString)
    }
    let backup = transaction.appending(path: "backup", directoryHint: .isDirectory)
    let manifestURL = backup.appending(path: "manifest.json")
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      let data = try readBoundedRegularFile(manifestURL, limit: maximumManifestBytes)
      let manifest: BackupManifest
      do {
        manifest = try decoder().decode(BackupManifest.self, from: data)
      } catch {
        throw Failure.invalidDocument("rollback manifest")
      }
      guard manifest.transactionID == transactionID, manifest.backupID == backupID else {
        throw Failure.unsafeArtifact(transactionID.uuidString)
      }
    }
    try FileManager.default.removeItem(at: transaction)
  }

  fileprivate static func deletableTransaction(
    _ transactionDirectory: URL,
    backupDirectory: URL,
    transactionID: UUID,
    transactionsRoot: URL
  ) -> Bool {
    let root = transactionsRoot.standardizedFileURL
    let transaction = transactionDirectory.standardizedFileURL
    let backup = backupDirectory.standardizedFileURL
    guard transaction.deletingLastPathComponent() == root,
      UUID(uuidString: transaction.lastPathComponent) == transactionID,
      backup == transaction.appending(path: "backup", directoryHint: .isDirectory),
      transaction.resolvingSymlinksInPath() == transaction,
      (try? requireDirectory(transaction)) != nil
    else {
      return false
    }
    return true
  }

  fileprivate static func encoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return encoder
  }

  fileprivate static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  fileprivate static func validateVersionLabel(_ value: String, name: String) throws {
    let count = value.lengthOfBytes(using: .utf8)
    guard !value.isEmpty, count <= 256,
      !value.contains("\n"), !value.contains("\r"), !value.contains("\0")
    else {
      throw Failure.invalidDocument(name)
    }
  }

  fileprivate static func personalArtifact(
    _ category: Category,
    data: LinnetPersonalData
  ) throws -> PortablePersonalArtifact {
    let rows: [PortableRow]
    switch category {
    case .customWords:
      rows = data.customWords.map { .init(value: $0.value, key: $0.code) }
    case .disabledWords:
      rows = data.disabledWords.map { .init(value: $0, key: nil) }
    case .textExpander:
      rows = data.expansions.map { .init(value: $0.value, key: $0.trigger) }
    case .chineseLearning, .englishLearning:
      throw Failure.invalidCategory(category.rawValue)
    }
    try validateRows(rows, category: category)
    return PortablePersonalArtifact(
      category: category,
      rowCount: rows.count,
      sha256: sha256(try encoder().encode(rows)),
      rows: rows
    )
  }

  fileprivate static func learningArtifact(
    schema: String,
    contents: String
  ) throws -> PortableLearningArtifact {
    guard let category = Category.allCases.first(where: { $0.learningSchema == schema }) else {
      throw Failure.invalidCategory(schema)
    }
    let data = Data(contents.utf8)
    guard data.count <= maximumLearningBytes else { throw Failure.artifactTooLarge(schema) }
    let rowCount = try validateLearningContents(contents, name: schema)
    return PortableLearningArtifact(
      category: category,
      schema: schema,
      rowCount: rowCount,
      sha256: sha256(data),
      contents: contents
    )
  }

  fileprivate static func validate(_ archive: PortableArchive) throws {
    guard archive.formatVersion == portableFormatVersion else {
      throw Failure.unsupportedVersion(archive.formatVersion)
    }
    try validateVersionLabel(archive.appVersion, name: "appVersion")
    try validateVersionLabel(archive.dataVersion, name: "dataVersion")
    let categories = Set(archive.categories)
    guard categories.count == archive.categories.count else {
      throw Failure.invalidCategory("duplicate category")
    }
    var payloadCategories = Set<Category>()
    for artifact in archive.personal {
      guard artifact.category.learningSchema == nil,
        payloadCategories.insert(artifact.category).inserted
      else {
        throw Failure.invalidCategory(artifact.category.rawValue)
      }
      try validateRows(artifact.rows, category: artifact.category)
      guard artifact.rowCount == artifact.rows.count else {
        throw Failure.invalidRowCount(artifact.category.rawValue)
      }
      guard artifact.sha256 == sha256(try encoder().encode(artifact.rows)) else {
        throw Failure.invalidHash(artifact.category.rawValue)
      }
    }
    for artifact in archive.learning {
      guard artifact.category.learningSchema == artifact.schema,
        payloadCategories.insert(artifact.category).inserted
      else {
        throw Failure.invalidCategory(artifact.schema)
      }
      let data = Data(artifact.contents.utf8)
      guard data.count <= maximumLearningBytes else {
        throw Failure.artifactTooLarge(artifact.schema)
      }
      let rowCount = try validateLearningContents(artifact.contents, name: artifact.schema)
      guard artifact.rowCount == rowCount else {
        throw Failure.invalidRowCount(artifact.schema)
      }
      guard artifact.sha256 == sha256(data) else {
        throw Failure.invalidHash(artifact.schema)
      }
    }
    guard payloadCategories == categories else {
      throw Failure.invalidCategory("payload does not match selected categories")
    }

    var candidate = LinnetPersonalData.empty
    for artifact in archive.personal {
      switch artifact.category {
      case .customWords:
        candidate.customWords = artifact.rows.map {
          .init(value: $0.value, code: $0.key ?? "")
        }
      case .disabledWords:
        candidate.disabledWords = artifact.rows.map(\.value)
      case .textExpander:
        candidate.expansions = artifact.rows.map {
          .init(value: $0.value, trigger: $0.key ?? "")
        }
      case .chineseLearning, .englishLearning:
        throw Failure.invalidCategory(artifact.category.rawValue)
      }
    }
    do {
      _ = try LinnetPersonalDataStore.normalized(candidate)
    } catch {
      throw Failure.invalidDocument("personal data")
    }
  }

  fileprivate static func validateRows(_ rows: [PortableRow], category: Category) throws {
    guard rows.count <= LinnetPersonalDataStore.maximumRows else {
      throw Failure.artifactTooLarge(category.rawValue)
    }
    for row in rows {
      guard row.value.lengthOfBytes(using: .utf8) <= LinnetPersonalDataStore.maximumFieldBytes,
        (row.key?.lengthOfBytes(using: .utf8) ?? 0)
          <= LinnetPersonalDataStore.maximumFieldBytes
      else {
        throw Failure.artifactTooLarge(category.rawValue)
      }
      switch category {
      case .disabledWords:
        guard row.key == nil else { throw Failure.invalidDocument(category.rawValue) }
      case .customWords, .textExpander:
        guard row.key != nil else { throw Failure.invalidDocument(category.rawValue) }
      case .chineseLearning, .englishLearning:
        throw Failure.invalidCategory(category.rawValue)
      }
    }
  }

  fileprivate static func learningRowCount(_ contents: String) -> Int {
    contents.split(whereSeparator: \.isNewline).filter {
      let row = $0.trimmingCharacters(in: .whitespaces)
      return !row.isEmpty && !row.hasPrefix("#")
    }.count
  }

  fileprivate static func validateLearningContents(_ contents: String, name: String) throws -> Int {
    guard !contents.contains("\0") else { throw Failure.invalidDocument(name) }
    var rowCount = 0
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard (2...3).contains(fields.count),
        !fields[0].isEmpty, !fields[1].isEmpty,
        fields.allSatisfy({ $0.utf8.count <= LinnetPersonalDataStore.maximumFieldBytes })
      else {
        throw Failure.invalidDocument(name)
      }
      rowCount += 1
      guard rowCount <= maximumLearningRows else { throw Failure.artifactTooLarge(name) }
    }
    return rowCount
  }

  fileprivate static func collectBackupArtifacts(
    _ backupDirectory: URL,
    formatVersion: Int
  ) throws -> [BackupArtifact] {
    let stable = backupDirectory.appending(path: "stable", directoryHint: .isDirectory)
    let learning = backupDirectory.appending(
      path: "user-dictionaries",
      directoryHint: .isDirectory
    )
    try requireDirectory(learning)
    let stableURLs = try stableArtifactURLs(
      stable, formatVersion: formatVersion).files
    let learningURLs = try immediateChildren(
      of: learning,
      maximumCount: learningFiles.count,
      overflow: .artifactTooLarge("learning file count")
    )
    var aggregateBytes = 0
    for url in stableURLs + learningURLs {
      let name = url.lastPathComponent
      let limit = stableURLs.contains(url) ? stableArtifactLimit(name) : maximumBackupArtifactBytes
      let byteCount = try regularFileSize(url, limit: limit)
      guard aggregateBytes <= maximumBackupBytes - byteCount else {
        throw Failure.artifactTooLarge("backup total")
      }
      aggregateBytes += byteCount
    }
    var artifacts: [BackupArtifact] = []
    for url in stableURLs {
      let name = url.lastPathComponent
      artifacts.append(try backupArtifact(url, path: "stable/\(name)", learning: false))
    }
    for url in learningURLs {
      let name = url.lastPathComponent
      guard learningFiles.contains(name) else { throw Failure.unsafeArtifact(name) }
      artifacts.append(
        try backupArtifact(
          url,
          path: "user-dictionaries/\(name)",
          learning: true
        ))
    }
    return artifacts.sorted { $0.path < $1.path }
  }

  fileprivate static func backupArtifact(_ url: URL, path: String, learning: Bool) throws
    -> BackupArtifact {
    let limit = learning ? maximumBackupArtifactBytes : stableArtifactLimit(url.lastPathComponent)
    let byteCount = try regularFileSize(url, limit: limit)
    let contents: String?
    if learning {
      let data = try readBoundedRegularFile(url, limit: maximumBackupArtifactBytes)
      guard let decoded = String(data: data, encoding: .utf8) else {
        throw Failure.invalidDocument(path)
      }
      _ = try validateLearningContents(decoded, name: path)
      contents = decoded
    } else {
      contents = nil
    }
    return BackupArtifact(
      path: path,
      byteCount: byteCount,
      rowCount: contents.map(learningRowCount),
      sha256: try sha256(url, expectedBytes: byteCount)
    )
  }

  fileprivate static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }

  fileprivate static func stableSourceNameIsAllowed(_ name: String) -> Bool {
    stableFiles.contains(name)
      || name == LinnetSettingsDocumentStore.fileName
      || (name.hasSuffix(".custom.yaml") && safeName(name))
  }

  static func stableArtifactLimit(_ name: String) -> Int {
    if name == LinnetSettingsDocumentStore.fileName {
      return LinnetSettingsDocumentStore.maximumDocumentBytes
    }
    return maximumStableArtifactBytes
  }

  fileprivate static func stableArtifactURLs(
    _ directory: URL,
    formatVersion: Int?
  ) throws -> (layout: StableLayout, files: [URL]) {
    let files = try immediateChildren(
      of: directory,
      maximumCount: maximumStableFiles,
      overflow: .artifactTooLarge("stable file count")
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    let names = Set(files.map(\.lastPathComponent))
    let layout: StableLayout
    switch formatVersion {
    case backupFormatVersion: layout = .current
    case legacyBackupFormatVersion: layout = .legacyV2
    case .some(let version): throw Failure.unsupportedVersion(version)
    case nil:
      if legacyV2PersonalFiles.isSubset(of: names) {
        layout = .legacyV2
      } else if canonicalPersonalFiles.isSubset(of: names) {
        layout = .current
      } else {
        throw Failure.incompleteBackup
      }
    }
    guard layout.requiredFiles.isSubset(of: names) else {
      throw Failure.incompleteBackup
    }
    for file in files {
      let name = file.lastPathComponent
      guard layout.requiredFiles.contains(name) || stableSourceNameIsAllowed(name) else {
        throw Failure.unsafeArtifact(name)
      }
    }
    let total = try files.reduce(into: 0) { partial, file in
      let bytes = try regularFileSize(
        file,
        limit: stableArtifactLimit(file.lastPathComponent)
      )
      guard partial <= maximumBackupBytes - bytes else {
        throw Failure.artifactTooLarge("backup total")
      }
      partial += bytes
    }
    guard total <= maximumBackupBytes else { throw Failure.artifactTooLarge("backup total") }
    return (layout, files)
  }

  /// The sole compatibility branch: verified v2 bytes are decoded with the
  /// frozen v2 codec and materialized as current canonical files. No v2 writer
  /// or steady-state fallback exists.
  fileprivate static func normalizeLegacyV2Stable(
    _ files: [URL],
    from source: URL,
    to destination: URL
  ) throws {
    let legacy = try LinnetPersonalDataStore.legacyV2Snapshot(from: source)
    let hadDocument = FileManager.default.fileExists(
      atPath: source.appending(path: LinnetSettingsDocumentStore.fileName).path)
    let document = try LinnetSettingsDocumentStore.load(from: source)
    if !hadDocument {
      guard document.english.sentenceCapitalization == legacy.sentenceCapitalization,
        document.english.tabBehavior.rawValue == legacy.tabBehavior
      else {
        throw Failure.invalidDocument("backup-v2 interaction adoption")
      }
    }

    let replacedFiles = legacyV2PersonalFiles
      .union(canonicalPersonalFiles)
      .union([LinnetSettingsDocumentStore.fileName])
    let preserved = files.filter { !replacedFiles.contains($0.lastPathComponent) }
    guard preserved.count + canonicalPersonalFiles.count + 1 <= maximumStableFiles else {
      throw Failure.artifactTooLarge("stable file count")
    }
    var copiedBytes = 0
    for file in preserved {
      let remaining = maximumBackupBytes - copiedBytes
      let copied = try copyBoundedRegularFile(
        file,
        to: destination.appending(path: file.lastPathComponent),
        limit: min(stableArtifactLimit(file.lastPathComponent), remaining)
      )
      copiedBytes += copied
    }
    try LinnetPersonalDataStore.writePersonalFiles(legacy.data, to: destination)
    try LinnetPersonalDataStore.writeRuntimeSettings(legacy.data, to: destination)
    try LinnetSettingsDocumentStore.write(document, to: destination)
    _ = try regularBytes(in: destination, maximumCount: maximumStableFiles)
  }

  fileprivate static func regularBytes(in directory: URL, maximumCount: Int) throws -> Int {
    let files = try immediateChildren(
      of: directory,
      maximumCount: maximumCount,
      overflow: .artifactTooLarge("stable file count")
    )
    var total = 0
    for file in files {
      let bytes = try regularFileSize(
        file,
        limit: stableArtifactLimit(file.lastPathComponent)
      )
      guard total <= maximumBackupBytes - bytes else {
        throw Failure.artifactTooLarge("backup total")
      }
      total += bytes
    }
    return total
  }

  fileprivate static func immediateChildren(
    of directory: URL,
    maximumCount: Int,
    overflow: Failure
  ) throws -> [URL] {
    guard maximumCount > 0 else { throw overflow }
    try requireDirectory(directory)
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    ) else {
      throw Failure.unsafeArtifact(directory.lastPathComponent)
    }
    var result: [URL] = []
    while let url = enumerator.nextObject() as? URL {
      result.append(url)
      guard result.count <= maximumCount else { throw overflow }
    }
    return result
  }

  fileprivate static func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
  }

  fileprivate static func requireRegularFile(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else {
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
  }

  fileprivate static func regularFileSize(_ url: URL, limit: Int) throws -> Int {
    var info = stat()
    guard limit >= 0,
      lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_size >= 0,
      info.st_size <= limit
    else {
      if info.st_size > limit { throw Failure.artifactTooLarge(url.lastPathComponent) }
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    return Int(info.st_size)
  }

  fileprivate static func copyBoundedRegularFile(
    _ source: URL,
    to destination: URL,
    limit: Int
  ) throws -> Int {
    let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
    guard sourceDescriptor >= 0 else { throw Failure.unsafeArtifact(source.lastPathComponent) }
    let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
    defer { try? sourceHandle.close() }
    var info = stat()
    guard limit >= 0,
      fstat(sourceDescriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_size >= 0,
      info.st_size <= limit
    else {
      if info.st_size > limit { throw Failure.artifactTooLarge(source.lastPathComponent) }
      throw Failure.unsafeArtifact(source.lastPathComponent)
    }
    let destinationDescriptor = open(
      destination.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard destinationDescriptor >= 0 else {
      throw Failure.unsafeArtifact(destination.lastPathComponent)
    }
    let destinationHandle = FileHandle(
      fileDescriptor: destinationDescriptor,
      closeOnDealloc: true
    )
    var copied = 0
    do {
      while true {
        let chunk = try sourceHandle.read(upToCount: 1024 * 1024) ?? Data()
        if chunk.isEmpty { break }
        guard copied <= limit - chunk.count else {
          throw Failure.artifactTooLarge(source.lastPathComponent)
        }
        try destinationHandle.write(contentsOf: chunk)
        copied += chunk.count
      }
      guard copied == Int(info.st_size) else {
        throw Failure.unsafeArtifact(source.lastPathComponent)
      }
      try destinationHandle.synchronize()
      try destinationHandle.close()
      return copied
    } catch {
      try? destinationHandle.close()
      throw error
    }
  }

  /// Reads one current-user regular file through a single no-follow descriptor.
  /// Both byte count and inode metadata must remain identical for the complete
  /// read; a concurrent grow, shrink, replacement or rewrite is never accepted.
  static func readBoundedRegularFile(_ url: URL, limit: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw Failure.missingArtifact(url.lastPathComponent) }
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard limit >= 0,
      fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == getuid(),
      before.st_size >= 0,
      before.st_size <= limit
    else {
      if before.st_size > limit { throw Failure.artifactTooLarge(url.lastPathComponent) }
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    var result = Data()
    result.reserveCapacity(Int(before.st_size))
    while true {
      let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if chunk.isEmpty { break }
      guard result.count <= limit - chunk.count else {
        throw Failure.artifactTooLarge(url.lastPathComponent)
      }
      result.append(chunk)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      result.count == Int(before.st_size),
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else {
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    return result
  }

  fileprivate static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func sha256(_ url: URL, expectedBytes: Int) throws -> String {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Failure.unsafeArtifact(url.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var hasher = SHA256()
    var observed = 0
    while true {
      let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if data.isEmpty { break }
      guard observed <= expectedBytes - data.count else {
        throw Failure.artifactTooLarge(url.lastPathComponent)
      }
      observed += data.count
      hasher.update(data: data)
    }
    guard observed == expectedBytes else { throw Failure.unsafeArtifact(url.lastPathComponent) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
