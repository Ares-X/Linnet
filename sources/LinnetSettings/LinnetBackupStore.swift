import Foundation

/// Owns bounded backup snapshot/copy, immutable manifests and portable formats.
/// It never mutates the live source directory or initializes librime.
enum LinnetBackupStore {
  static let portableFormatVersion = 1
  static let backupFormatVersion = 3
  static let legacyBackupFormatVersion = 2
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

  struct CommitRequest: Sendable {
    let backupDirectory: URL
    let backupID: UUID
    let transactionID: UUID
    let operation: BackupOperation
    let createdAt: Date
    let appVersion: String
    let dataVersion: String
    let transactionsRoot: URL
    let maximumVerifiedBackups: Int
    let protectedTransactionIDs: Set<UUID>
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
        personal.disabledWords = artifact.rows.map { .init(value: $0.value) }
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
  static func commitBackup(_ request: CommitRequest) throws -> BackupManifest {
    let transaction = try validatedCommitTransaction(request)
    let manifestURL = request.backupDirectory.appending(path: "manifest.json")
    guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw Failure.backupAlreadyComplete
    }

    do {
      let document = try manifestDocument(
        backupDirectory: request.backupDirectory,
        backupID: request.backupID,
        transactionID: request.transactionID,
        operation: request.operation,
        createdAt: request.createdAt,
        appVersion: request.appVersion,
        dataVersion: request.dataVersion
      )
      let deletions = try retentionDeletions(for: request)
      try validateRetentionDeletions(deletions, transactionsRoot: request.transactionsRoot)
      try publishBackup(document, deletions: deletions, request: request)
      return document.manifest
    } catch {
      if FileManager.default.fileExists(atPath: transaction.path) {
        try? rollbackOwnedTransaction(
          transactionID: request.transactionID,
          backupID: request.backupID,
          in: request.transactionsRoot
        )
      }
      throw error
    }
  }

  static func validatedCommitTransaction(_ request: CommitRequest) throws -> URL {
    try requireDirectory(request.transactionsRoot)
    let root = request.transactionsRoot.standardizedFileURL
    let transaction = request.backupDirectory.deletingLastPathComponent().standardizedFileURL
    guard transaction.deletingLastPathComponent() == root,
      transaction.lastPathComponent == request.transactionID.uuidString,
      request.backupDirectory.standardizedFileURL
        == transaction.appending(path: "backup", directoryHint: .isDirectory),
      (try? requireDirectory(transaction)) != nil
    else {
      throw Failure.unsafeArtifact(request.transactionID.uuidString)
    }
    return transaction
  }

  static func retentionDeletions(for request: CommitRequest) throws -> [BackupRecord] {
    guard (1...maximumHistoryEntries).contains(request.maximumVerifiedBackups) else {
      throw Failure.invalidRetentionLimit
    }
    let records = try backupRecords(
      in: request.transactionsRoot,
      maximumCount: maximumHistoryEntries + 1
    )
    guard records.count <= maximumHistoryEntries + 1,
      records.contains(where: {
        $0.transactionID == request.transactionID && $0.state == .incomplete
      })
    else {
      throw Failure.historyTooLarge
    }
    let verified = records.filter {
      if case .verified = $0.state { return true }
      return false
    }
    let deletionCount = max(
      0,
      max(
        records.count - maximumHistoryEntries,
        verified.count + 1 - request.maximumVerifiedBackups
      )
    )
    let protected = request.protectedTransactionIDs.union([request.transactionID])
    let candidates = verified.reversed().filter { record in
      guard let candidateID = record.transactionID else { return false }
      return !protected.contains(candidateID)
    }
    guard candidates.count >= deletionCount else { throw Failure.historyTooLarge }
    return Array(candidates.prefix(deletionCount))
  }

  static func validateRetentionDeletions(
    _ deletions: [BackupRecord],
    transactionsRoot: URL
  ) throws {
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
  }

  static func publishBackup(
    _ document: (manifest: BackupManifest, contents: Data, url: URL),
    deletions: [BackupRecord],
    request: CommitRequest
  ) throws {
    try document.contents.write(to: document.url, options: .atomic)
    var removedOldBackup = false
    for record in deletions {
      do {
        try FileManager.default.removeItem(at: record.transactionDirectory)
        removedOldBackup = true
      } catch {
        guard removedOldBackup else {
          try rollbackOwnedTransaction(
            transactionID: request.transactionID,
            backupID: request.backupID,
            in: request.transactionsRoot
          )
          throw error
        }
        // Capacity was restored by the first removal; the new immutable
        // backup is now the committed undo point.
        break
      }
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
    let manifest = try readBackupManifest(at: backupDirectory)
    try validateBackupArtifacts(manifest, at: backupDirectory)
    let stable = backupDirectory.appending(path: "stable", directoryHint: .isDirectory)
    let personalRevision = try backupPersonalRevision(
      at: stable, formatVersion: manifest.formatVersion)
    guard personalRevision == manifest.personalRevision else {
      throw Failure.invalidHash("personal revision")
    }
    return manifest
  }

  static func readBackupManifest(at backupDirectory: URL) throws -> BackupManifest {
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
    return manifest
  }

  static func validateBackupArtifacts(
    _ manifest: BackupManifest,
    at backupDirectory: URL
  ) throws {
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
  }

  static func backupPersonalRevision(at stable: URL, formatVersion: Int) throws -> String {
    if formatVersion == legacyBackupFormatVersion {
      return try LinnetPersonalDataStore.legacyV2Snapshot(from: stable).revision
    }
    return try LinnetPersonalDataStore.snapshot(from: stable).revision
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
    for source in canonicalURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where FileManager.default.fileExists(atPath: source.path) {
      _ = try copyBoundedRegularFile(
        source,
        to: backup.appending(path: source.lastPathComponent),
        limit: stableArtifactLimit(source.lastPathComponent)
      )
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
