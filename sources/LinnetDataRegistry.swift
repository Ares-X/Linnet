import Darwin
import Foundation

/// The single filesystem owner for Linnet's immutable language data and
/// mutable per-user state. Callers consume a validated snapshot; they never
/// search the App bundle, Packs, or UserData for alternative data sources.
struct LinnetDataRegistry: Sendable {
  static let stateFormat = "io.github.ares-x.linnet.active-set.v1"
  static let languageTransactionMarkerName = ".linnet-language-transaction.json"
  static let personalScratchMarkerName = ".linnet-personal-scratch.json"
  static let transactionFormat = "io.github.ares-x.linnet.language-transaction.v2"
  static let personalScratchFormat = "io.github.ares-x.linnet.personal-scratch.v1"
  static let orphanSafetyAge: TimeInterval = 24 * 60 * 60
  static let maximumGarbageCollectionEntries = LinnetPackContract.maximumFiles
  static let maximumInstalledPackEntries = LinnetPackContract.maximumFiles * 2 + 2
  static let maximumActiveProjectionEntries = LinnetPackContract.maximumFiles * 8 + 8
  // User-writable Registry JSON documents share the manifest cap.
  static let ownedMetadataMaximumBytes = LinnetPackContract.maximumManifestBytes

  enum Edition: String, Codable, Equatable, Hashable, Sendable {
    case standard
    case full
  }

  enum Publication: String, Codable, Equatable, Sendable {
    case prepared
    case committed
  }

  struct ActivePack: Codable, Equatable, Sendable {
    let packID: String
    let kind: LinnetPackContract.Kind
    let version: String
    let sequence: UInt64
    let dataABI: UInt32
    let contentSHA256: String
    let minCore: String
    let requirements: [LinnetPackContract.Requirement]
    let relativePath: String
    let manifestSHA256: String

    enum CodingKeys: String, CodingKey {
      case packID = "pack_id"
      case kind
      case version
      case sequence
      case dataABI = "data_abi"
      case contentSHA256 = "content_sha256"
      case minCore = "min_core"
      case requirements
      case relativePath = "relative_path"
      case manifestSHA256 = "manifest_sha256"
    }
  }

  struct ActiveState: Codable, Equatable, Sendable {
    let format: String
    let edition: Edition
    let generation: Int
    let activeView: String
    let packs: [ActivePack]
    var publication: Publication
    let transactionID: UUID?
    let acceptedCatalog: DataChannelReceipt?
    let rollbackPacks: [ActivePack]

    enum CodingKeys: String, CodingKey {
      case format
      case edition
      case generation
      case activeView = "active_view"
      case packs
      case publication
      case transactionID = "transaction_id"
      case acceptedCatalog = "accepted_catalog"
      case rollbackPacks = "rollback_packs"
    }

    init(
      format: String,
      edition: Edition,
      generation: Int,
      activeView: String,
      packs: [ActivePack],
      publication: Publication = .committed,
      transactionID: UUID? = nil,
      acceptedCatalog: DataChannelReceipt? = nil,
      rollbackPacks: [ActivePack] = []
    ) {
      self.format = format
      self.edition = edition
      self.generation = generation
      self.activeView = activeView
      self.packs = packs
      self.publication = publication
      self.transactionID = transactionID
      self.acceptedCatalog = acceptedCatalog
      self.rollbackPacks = rollbackPacks
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      format = try values.decode(String.self, forKey: .format)
      edition = try values.decode(Edition.self, forKey: .edition)
      generation = try values.decode(Int.self, forKey: .generation)
      activeView = try values.decode(String.self, forKey: .activeView)
      packs = try values.decode([ActivePack].self, forKey: .packs)
      publication = try values.decode(Publication.self, forKey: .publication)
      transactionID = try values.decode(UUID?.self, forKey: .transactionID)
      acceptedCatalog = try values.decode(
        DataChannelReceipt?.self, forKey: .acceptedCatalog)
      rollbackPacks = try values.decode(
        [ActivePack].self, forKey: .rollbackPacks)
    }

    func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(format, forKey: .format)
      try values.encode(edition, forKey: .edition)
      try values.encode(generation, forKey: .generation)
      try values.encode(activeView, forKey: .activeView)
      try values.encode(packs, forKey: .packs)
      try values.encode(publication, forKey: .publication)
      try values.encode(transactionID, forKey: .transactionID)
      try values.encode(acceptedCatalog, forKey: .acceptedCatalog)
      try values.encode(rollbackPacks, forKey: .rollbackPacks)
    }

    var dataVersion: String {
      packs.map { "\($0.kind.rawValue)-\($0.version)" }.joined(separator: "_")
    }
  }

  struct RuntimeSnapshot: Equatable, Sendable {
    let sharedDataDirectory: URL
    let userDataDirectory: URL
    let prebuiltDataDirectory: URL
    let stagingDirectory: URL
    let transactionsDirectory: URL
    let backupsDirectory: URL
    let state: ActiveState
    let activeRevision: ActiveRevision
  }

  enum InstalledRuntimeState: String, Equatable, Sendable {
    case healthy
    case missing
  }

  struct ActiveRevision: Codable, Equatable, Sendable {
    let generation: Int
    let stateSHA256: String

    enum CodingKeys: String, CodingKey {
      case generation
      case stateSHA256 = "state_sha256"
    }
  }

  struct ActivationCandidate: Equatable, Sendable {
    let transactionID: UUID
    let directory: URL
    let expectedActiveRevision: ActiveRevision
  }

  struct DataChannelUpdateTransaction: Equatable, Sendable {
    let transactionID: UUID
    let downloadDirectory: URL
  }

  struct PersonalScratchMarker: Codable {
    let format: String
    let transactionID: UUID
    let createdAt: TimeInterval

    enum CodingKeys: String, CodingKey {
      case format
      case transactionID = "transaction_id"
      case createdAt = "created_at"
    }
  }

  struct LanguageTransactionRecord: Codable {
    enum Phase: String, Codable {
      case downloading
      case prepared
    }
    let format: String
    let transactionID: UUID
    let createdAt: TimeInterval
    let catalog: DataChannelReceipt
    let edition: Edition
    let artifacts: [LinnetDataChannel.Artifact]
    let baseRevision: ActiveRevision
    var phase: Phase
    var candidateRevision: ActiveRevision?

    enum CodingKeys: String, CodingKey {
      case format
      case transactionID = "transaction_id"
      case createdAt = "created_at"
      case catalog, edition, artifacts
      case baseRevision = "base_revision"
      case phase
      case candidateRevision = "candidate_revision"
    }
  }

  struct LanguageTransactionCleanup {
    let transactionID: UUID
    let directory: URL
    let protectedPackPaths: [String]
    let retiresCommittedTransaction: Bool
  }

  struct PackCleanup {
    let directory: URL
    let relativePath: String
  }

  struct VerifiedInstalledManifest {
    let manifest: LinnetPackContract.Manifest
    let manifestData: Data
  }

  struct DataChannelReceipt: Codable, Equatable, Sendable {
    let format: String
    let sequence: UInt64
    let digest: String
  }

  struct PackDeletionIdentity: Codable {
    let packID: String
    let kind: LinnetPackContract.Kind
    let version: String
    let sequence: UInt64
    let contentSHA256: String

    enum CodingKeys: String, CodingKey {
      case packID = "pack_id"
      case kind, version, sequence
      case contentSHA256 = "content_sha256"
    }
  }

  enum OwnedFileReadFailure: Error {
    case missing
    case invalid
  }

  enum Failure: LocalizedError, Equatable {
    case applicationSupportUnavailable
    case invalidProductName
    case missingRegistryRoot
    case missingActiveState
    case invalidActiveState
    case staleDataChannel
    case unsafePath(String)
    case incompleteActiveView(String)

    var errorDescription: String? {
      switch self {
      case .applicationSupportUnavailable:
        "Application Support is unavailable."
      case .invalidProductName:
        "The product name is invalid."
      case .missingRegistryRoot:
        "Linnet data is not installed."
      case .missingActiveState:
        "Language data is not installed."
      case .invalidActiveState:
        "The active language-data state is invalid."
      case .staleDataChannel:
        "The language-data catalog is older than the accepted catalog."
      case .unsafePath:
        "The language-data path is unsafe."
      case .incompleteActiveView(let name):
        "The active language data is missing \(name)."
      }
    }
  }

  let rootDirectory: URL
  let coreVersion: String
  let rootDevice: dev_t
  let rootInode: ino_t

  enum RootAccess {
    case createIfMissing
    case existing
  }

  init(
    productName: String,
    coreVersion: String,
    applicationSupportDirectory: URL? = nil,
    rootAccess: RootAccess = .createIfMissing
  ) throws {
    guard !productName.isEmpty,
      productName != ".", productName != "..",
      !productName.contains("/"), !productName.contains(":")
    else {
      throw Failure.invalidProductName
    }
    guard LinnetPackContract.supportsCore(required: "0.0.0", actual: coreVersion) else {
      throw Failure.invalidActiveState
    }
    let support = try applicationSupportDirectory ?? Self.applicationSupportDirectory()
    let boundary: (url: URL, device: dev_t, inode: ino_t)
    switch rootAccess {
    case .createIfMissing:
      boundary = try Self.openOrCreateCanonicalRoot(
        applicationSupportDirectory: support, productName: productName)
    case .existing:
      boundary = try Self.openExistingCanonicalRoot(
        applicationSupportDirectory: support, productName: productName)
    }
    rootDirectory = boundary.url
    rootDevice = boundary.device
    rootInode = boundary.inode
    self.coreVersion = coreVersion
  }
}

extension LinnetDataRegistry {
  var userDataDirectory: URL {
    rootDirectory.appending(path: "UserData", directoryHint: .isDirectory)
  }

  var stagingDirectory: URL {
    rootDirectory.appending(path: "Build", directoryHint: .isDirectory)
  }

  var downloadsDirectory: URL {
    rootDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
  }

  var transactionsDirectory: URL {
    rootDirectory.appending(path: "Transactions", directoryHint: .isDirectory)
  }

  var backupsDirectory: URL {
    rootDirectory.appending(path: "Backups", directoryHint: .isDirectory)
  }

  var activeSharedDataDirectory: URL {
    rootDirectory.appending(path: "Runtime/Active", directoryHint: .isDirectory)
  }

  private var runtimeDirectory: URL {
    rootDirectory.appending(path: "Runtime", directoryHint: .isDirectory)
  }

  private var runtimeLogDirectory: URL {
    runtimeDirectory.appending(path: "Logs", directoryHint: .isDirectory)
  }

  var packsDirectory: URL {
    rootDirectory.appending(path: "Data/Packs", directoryHint: .isDirectory)
  }

  var settingsMutationLeaseURL: URL {
    rootDirectory.appending(path: "State/settings-mutation.lock")
  }

  /// The Registry owns catalog validation so it can fail closed against
  /// the Core version that is actually running, rather than a Settings label.
  func verifyDataChannel(_ data: Data) throws -> LinnetDataChannel.Verified {
    try LinnetDataChannel.verify(data, coreVersion: coreVersion)
  }

  func prepareMutableDirectories() throws {
    try verifyCanonicalRoot()
    for directory in [
      userDataDirectory, stagingDirectory, downloadsDirectory,
      transactionsDirectory, backupsDirectory
    ] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard Self.isSecureOwnedDirectory(directory) else {
        throw Failure.unsafePath(directory.path)
      }
    }
  }

  /// The Registry owns the only persistent runtime-log path. The read-only
  /// runtime inspector never calls this mutating preparation boundary.
  func prepareRuntimeLogDirectory() throws -> URL {
    try verifyCanonicalRoot()
    let runtimeInfo = try Self.existingOwnedDirectory(runtimeDirectory)
    guard runtimeInfo.st_dev == rootDevice else {
      throw Failure.unsafePath(runtimeDirectory.path)
    }
    let logInfo = try Self.ensureOwnedDirectory(
      runtimeLogDirectory, withIntermediateDirectories: false)
    guard logInfo.st_dev == rootDevice else {
      throw Failure.unsafePath(runtimeLogDirectory.path)
    }
    return runtimeLogDirectory
  }

  /// Creates and marks Settings-owned personal mutation scratch for
  /// Registry-only crash reclamation. Unmarked UUID directories remain foreign.
  func beginPersonalScratch(
    transactionID: UUID,
    createdAt: Date = Date()
  ) throws {
    let directory = transactionsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    guard directory.deletingLastPathComponent().standardizedFileURL
      == transactionsDirectory.standardizedFileURL,
      Self.isSecureOwnedDirectory(transactionsDirectory),
      !FileManager.default.fileExists(atPath: directory.path),
      (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) == nil,
      createdAt.timeIntervalSince1970.isFinite,
      createdAt.timeIntervalSince1970 > 0
    else { throw Failure.invalidActiveState }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      try writeJSON(
        PersonalScratchMarker(
          format: Self.personalScratchFormat,
          transactionID: transactionID,
          createdAt: createdAt.timeIntervalSince1970),
        to: directory.appending(path: Self.personalScratchMarkerName))
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

}
