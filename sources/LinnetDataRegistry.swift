import Darwin
import CryptoKit
import Foundation

/// The single filesystem owner for Linnet's immutable language data and
/// mutable per-user state. Callers consume a validated snapshot; they never
/// search the App bundle, Packs, or UserData for alternative data sources.
struct LinnetDataRegistry: Sendable {
  static let stateFormat = "io.github.ares-x.linnet.active-set.v1"
  static let languageTransactionMarkerName = ".linnet-language-transaction.json"
  static let personalScratchMarkerName = ".linnet-personal-scratch.json"
  private static let transactionFormat = "io.github.ares-x.linnet.language-transaction.v2"
  private static let personalScratchFormat = "io.github.ares-x.linnet.personal-scratch.v1"
  private static let orphanSafetyAge: TimeInterval = 24 * 60 * 60
  private static let maximumGarbageCollectionEntries = LinnetPackContract.maximumFiles
  private static let maximumInstalledPackEntries = LinnetPackContract.maximumFiles * 2 + 2
  private static let maximumActiveProjectionEntries = LinnetPackContract.maximumFiles * 8 + 8
  // User-writable Registry JSON documents share the manifest cap.
  private static let ownedMetadataMaximumBytes = LinnetPackContract.maximumManifestBytes

  enum GrammarProfile: String, Codable, Equatable, Sendable {
    case compact
    case lts
  }

  enum Edition: String, Codable, Equatable, Hashable, Sendable {
    case standard
    case full
  }

  enum PackKind: String, Codable, Equatable, Sendable {
    case chinese
    case english
    case lts
    case extended
  }

  enum Publication: String, Codable, Equatable, Sendable {
    case prepared
    case committed
  }

  struct ActiveRequirement: Codable, Equatable, Sendable {
    let kind: PackKind
    let dataABI: UInt32

    enum CodingKeys: String, CodingKey {
      case kind
      case dataABI = "data_abi"
    }
  }

  struct ActivePack: Codable, Equatable, Sendable {
    let packID: String
    let kind: PackKind
    let version: String
    let sequence: UInt64
    let dataABI: UInt32
    let contentSHA256: String
    let minCore: String
    let requirements: [ActiveRequirement]
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

    var grammarProfile: GrammarProfile {
      .lts
    }

    var dataVersion: String {
      packs.map { "\($0.kind.rawValue)-\($0.version)" }.joined(separator: "_")
    }
  }

  struct RuntimeSnapshot: Equatable, Sendable {
    let rootDirectory: URL
    let sharedDataDirectory: URL
    let userDataDirectory: URL
    let prebuiltDataDirectory: URL
    let stagingDirectory: URL
    let downloadsDirectory: URL
    let transactionsDirectory: URL
    let backupsDirectory: URL
    let state: ActiveState
    let activeRevision: ActiveRevision
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

  private struct PersonalScratchMarker: Codable {
    let format: String
    let transactionID: UUID
    let createdAt: TimeInterval

    enum CodingKeys: String, CodingKey {
      case format
      case transactionID = "transaction_id"
      case createdAt = "created_at"
    }
  }

  private struct LanguageTransactionRecord: Codable {
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

  private struct LanguageTransactionCleanup {
    let transactionID: UUID
    let directory: URL
    let protectedPackPaths: [String]
    let retiresCommittedTransaction: Bool
  }

  private struct PackCleanup {
    let directory: URL
    let relativePath: String
  }

  private struct VerifiedInstalledManifest {
    let manifest: LinnetPackContract.Manifest
    let manifestData: Data
  }

  struct DataChannelReceipt: Codable, Equatable, Sendable {
    let format: String
    let sequence: UInt64
    let digest: String
  }

  private struct PackDeletionIdentity: Codable {
    let packID: String
    let kind: PackKind
    let version: String
    let sequence: UInt64
    let contentSHA256: String

    enum CodingKeys: String, CodingKey {
      case packID = "pack_id"
      case kind, version, sequence
      case contentSHA256 = "content_sha256"
    }
  }

  private enum OwnedFileReadFailure: Error {
    case missing
    case invalid
  }

  enum Failure: LocalizedError, Equatable {
    case applicationSupportUnavailable
    case invalidProductName
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
  private let coreVersion: String
  private let rootDevice: dev_t
  private let rootInode: ino_t

  init(
    productName: String,
    coreVersion: String,
    applicationSupportDirectory: URL? = nil
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
    let boundary = try Self.openOrCreateCanonicalRoot(
      applicationSupportDirectory: support, productName: productName)
    rootDirectory = boundary.url
    rootDevice = boundary.device
    rootInode = boundary.inode
    self.coreVersion = coreVersion
  }

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

  var activeStateURL: URL {
    rootDirectory.appending(path: "State/active.json", directoryHint: .notDirectory)
  }

  var activeSharedDataDirectory: URL {
    rootDirectory.appending(path: "Runtime/Active", directoryHint: .isDirectory)
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
      transactionsDirectory, backupsDirectory,
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

  func runtimeSnapshot() throws -> RuntimeSnapshot {
    try runtimeSnapshot(reconcilingStorage: true)
  }

  /// Host-only read while a swapped language candidate is still tentative.
  /// It deliberately cannot retire transaction state or accept a catalog.
  func tentativeRuntimeSnapshot() throws -> RuntimeSnapshot {
    try runtimeSnapshot(reconcilingStorage: false)
  }

  func beginDataChannelUpdate(
    accepting catalog: LinnetDataChannel.Verified,
    edition: Edition
  ) throws -> DataChannelUpdateTransaction {
    try prepareMutableDirectories()
    let receipt = try receiptForCatalog(catalog)
    try validateDataChannelReceipt(receipt)
    guard let set = catalog.catalog.activationSet(for: edition) else {
      throw Failure.invalidActiveState
    }
    let snapshot = try runtimeSnapshot(reconcilingStorage: false)
    let id = UUID()
    let directory = transactionsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    let download = downloadsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      try writeJSON(
        LanguageTransactionRecord(
          format: Self.transactionFormat,
          transactionID: id,
          createdAt: Date().timeIntervalSince1970,
          catalog: receipt,
          edition: edition,
          artifacts: set.packs,
          baseRevision: snapshot.activeRevision,
          phase: .downloading,
          candidateRevision: nil),
        to: directory.appending(path: Self.languageTransactionMarkerName))
      try FileManager.default.createDirectory(
        at: download, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch {
      try? FileManager.default.removeItem(at: download)
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    return .init(transactionID: id, downloadDirectory: download)
  }

  /// The only explicit cancellation owner for both downloading and prepared
  /// language transactions. Live prepared candidates remain recovery-owned.
  func cancelDataChannelUpdate(transactionID: UUID) throws {
    let directory = transactionsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    guard validatedLanguageTransaction(at: directory, now: Date()) != nil else {
      throw Failure.invalidActiveState
    }
    let active = try loadActiveStateDocument().state
    if active.transactionID == transactionID, active.publication == .prepared { return }
    try removeOwnedDownloadDirectory(transactionID: transactionID)
    try FileManager.default.removeItem(at: directory)
    try? reconcileLanguageStorage(activeState: active)
  }

  /// A process crash cannot turn a merely swapped candidate into a committed
  /// language release. Before ordinary startup reconciliation, restore the
  /// previous Active directory held by a prepared transaction, then discard
  /// only that transaction.
  @discardableResult
  func recoverPreparedLanguageActivation() throws -> Bool {
    try prepareMutableDirectories()
    let activeDocument = try loadActiveStateDocument()
    guard activeDocument.state.publication == .prepared,
      let transactionID = activeDocument.state.transactionID
    else { return false }
    let directory = transactionsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    guard let record = validatedLanguageTransaction(at: directory, now: Date()),
      record.phase == .prepared,
      record.candidateRevision == ActiveRevision(
        generation: activeDocument.state.generation,
        stateSHA256: Self.sha256(activeDocument.data))
    else { throw Failure.invalidActiveState }
    let previous = directory.appending(path: "language-active", directoryHint: .isDirectory)
    guard let previousState = try? loadActiveStateDocument(at: previous),
      previousState.state.publication == .committed,
      swapDirectories(activeSharedDataDirectory, previous)
    else { throw Failure.invalidActiveState }
    try? removeOwnedDownloadDirectory(transactionID: transactionID)
    try? FileManager.default.removeItem(at: directory)
    return true
  }

  private func runtimeSnapshot(reconcilingStorage: Bool) throws -> RuntimeSnapshot {
    try prepareMutableDirectories()
    let activeDocument = try loadActiveStateDocument()
    let state = activeDocument.state
    if reconcilingStorage, state.publication != .committed {
      throw Failure.invalidActiveState
    }
    let active = activeSharedDataDirectory.standardizedFileURL
    guard Self.isSecureOwnedDirectory(active),
      active.resolvingSymlinksInPath() == active
    else {
      throw Failure.unsafePath(active.path)
    }

    var manifests: [PackKind: LinnetPackContract.Manifest] = [:]
    for pack in state.packs {
      guard manifests[pack.kind] == nil else { throw Failure.invalidActiveState }
      manifests[pack.kind] = try verifiedInstalledManifest(for: pack).manifest
    }
    try verifyActiveProjection(state: state, manifests: manifests)
    if reconcilingStorage {
      // Runtime truth is the validated immutable Active view. Reconciliation
      // is a retryable projection/GC side effect and cannot block that view.
      try? reconcileLanguageStorage(activeState: state)
    }

    return RuntimeSnapshot(
      rootDirectory: rootDirectory,
      sharedDataDirectory: active,
      userDataDirectory: userDataDirectory,
      prebuiltDataDirectory: active.appending(path: "build", directoryHint: .isDirectory),
      stagingDirectory: stagingDirectory,
      downloadsDirectory: downloadsDirectory,
      transactionsDirectory: transactionsDirectory,
      backupsDirectory: backupsDirectory,
      state: state,
      activeRevision: .init(
        generation: state.generation,
        stateSHA256: Self.sha256(activeDocument.data))
    )
  }

  /// Reads the exact live activation document used by the Host CAS. Callers
  /// compare this value immediately before mutation; they do not infer a
  /// revision from pack directories or candidate state.
  func activeRevision() throws -> ActiveRevision {
    let document = try loadActiveStateDocument()
    return .init(
      generation: document.state.generation,
      stateSHA256: Self.sha256(document.data))
  }

  /// The only installation boundary for a catalog-selected `.linnetpack`.
  /// The canonical catalog authenticates the exact container; this method then
  /// validates compatibility, the manifest and every payload byte once.
  func verifyAndStagePack(
    package: URL, artifact: LinnetDataChannel.Artifact
  ) throws -> ActivePack {
    try prepareMutableDirectories()
    let resolvedPackage = package.resolvingSymlinksInPath().standardizedFileURL
    let resolvedDownloads = downloadsDirectory.resolvingSymlinksInPath().standardizedFileURL
    let downloadOwner = resolvedPackage.deletingLastPathComponent()
    guard (downloadOwner == resolvedDownloads
      || downloadOwner.deletingLastPathComponent() == resolvedDownloads),
      Self.isSecureOwnedDirectory(downloadOwner) else {
      throw Failure.unsafePath(package.path)
    }
    let values = try resolvedPackage.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw Failure.unsafePath(package.path)
    }
    try LinnetDataChannel.verifyDownloadedArtifact(artifact, at: resolvedPackage)
    let kindRoot = packsDirectory.appending(
      path: artifact.kind.rawValue, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: kindRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    guard Self.isSecureOwnedDirectory(kindRoot) else {
      throw Failure.unsafePath(kindRoot.path)
    }
    let identity = Self.packIdentity(sequence: artifact.sequence, version: artifact.version)
    let final = kindRoot.appending(path: identity, directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: final.path) {
      let installed = try verifiedInstalledPack(at: final)
      guard artifact.matches(installed) else { throw Failure.invalidActiveState }
      return installed
    }

    let partial = kindRoot.appending(
      path: ".\(identity).partial-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: partial, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      let staged = try LinnetPackContract.verify(
        package: resolvedPackage,
        coreVersion: self.coreVersion,
        extractingTo: partial
      )
      let active = Self.activePack(
        from: staged.manifest, manifestSHA256: staged.manifestSHA256)
      guard artifact.matches(active) else {
        throw LinnetPackContract.Failure.invalidManifest("catalog artifact identity")
      }
      try staged.manifestData.write(
        to: partial.appending(path: "manifest.json"), options: .withoutOverwriting)
      try makeImmutable(partial)
      try FileManager.default.moveItem(at: partial, to: final)
      return active
    } catch {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: partial.path)
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
  }

  /// Rebuilds the complete Active projection from one compatible target
  /// set. No pack can override another pack's file; collisions fail before
  /// the Host receives an activation request. This is deliberately the only
  /// activation constructor: ABI-coupled Chinese/LTS/Extended updates must
  /// travel in the same candidate, not as a sequence of partial activations.
  func prepareDataChannelUpdate(
    _ update: DataChannelUpdateTransaction,
    target: [ActivePack]
  ) throws -> ActivationCandidate {
    let snapshot = try runtimeSnapshot(reconcilingStorage: false)
    guard Set(target.map(\.kind)).count == target.count else { throw Failure.invalidActiveState }
    let current = Dictionary(uniqueKeysWithValues: snapshot.state.packs.map { ($0.kind, $0) })
    let requested = Dictionary(uniqueKeysWithValues: target.map { ($0.kind, $0) })
    for pack in target {
      if let previous = current[pack.kind] {
        guard pack.sequence > previous.sequence
          || (pack.sequence == previous.sequence && Self.sameImmutablePack(previous, pack))
        else { throw Failure.invalidActiveState }
      } else {
        guard pack.kind == .extended else { throw Failure.invalidActiveState }
      }
    }
    for previous in snapshot.state.packs where requested[previous.kind] == nil {
      guard previous.kind == .extended else { throw Failure.invalidActiveState }
    }
    var packs = target
    let order: [PackKind: Int] = [.chinese: 0, .english: 1, .lts: 2, .extended: 3]
    packs.sort { order[$0.kind, default: 99] < order[$1.kind, default: 99] }
    let edition: Edition = packs.contains(where: { $0.kind == .extended }) ? .full : .standard
    guard packsAreCompatible(packs, edition: edition) else {
      throw Failure.invalidActiveState
    }

    let transactionID = update.transactionID
    let transaction = transactionsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    let candidate = transaction.appending(path: "language-active", directoryHint: .isDirectory)
    guard update.downloadDirectory.standardizedFileURL
      == downloadsDirectory.appending(
        path: update.transactionID.uuidString, directoryHint: .isDirectory).standardizedFileURL,
      var record = validatedLanguageTransaction(at: transaction, now: Date()),
      record.phase == .downloading,
      record.baseRevision == snapshot.activeRevision,
      record.edition == edition,
      record.artifacts.count == packs.count,
      record.artifacts.allSatisfy({ artifact in
        packs.contains(where: { artifact.matches($0) })
      })
    else { throw Failure.invalidActiveState }
    try validateDataChannelReceipt(record.catalog)
    try FileManager.default.createDirectory(
      at: candidate,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      try FileManager.default.createDirectory(
        at: candidate.appending(path: "build", directoryHint: .isDirectory),
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let excluded = Set(["linnet_zh.dict.yaml", "linnet_zh_full.dict.yaml"])
      for pack in packs {
        let packRoot = rootDirectory.appending(path: pack.relativePath, directoryHint: .isDirectory)
        let manifest = try verifiedInstalledManifest(for: pack).manifest
        for entry in manifest.files {
          let relative = entry.path
          if excluded.contains(relative) { continue }
          _ = try verifiedManifestFile(entry, in: packRoot)
          let projected = candidate.appending(path: relative)
          try FileManager.default.createDirectory(
            at: projected.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          var projectedInfo = stat()
          guard lstat(projected.path, &projectedInfo) != 0, errno == ENOENT else {
            throw Failure.invalidActiveState
          }
          let parentDepth = max(0, relative.split(separator: "/").count - 1)
          let upward = String(repeating: "../", count: 2 + parentDepth)
          try FileManager.default.createSymbolicLink(
            atPath: projected.path,
            withDestinationPath: upward + pack.relativePath + "/" + relative)
        }
      }

      let generation = snapshot.state.generation + 1
      let grammar = candidate.appending(path: "linnet_grammar_active.yaml")
      try Data("grammar:\n  language: wanxiang-lts-zh-hans\n".utf8)
        .write(to: grammar, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: grammar.path)
      guard let chinese = packs.first(where: { $0.kind == .chinese }) else {
        throw Failure.invalidActiveState
      }
      let selectorPack = edition == .full
        ? packs.first(where: { $0.kind == .extended }) : chinese
      guard let selectorPack else { throw Failure.invalidActiveState }
      let selectorName = edition == .full
        ? "linnet_zh_full.dict.yaml" : "linnet_zh.dict.yaml"
      try FileManager.default.createSymbolicLink(
        atPath: candidate.appending(path: "linnet_zh.dict.yaml").path,
        withDestinationPath: "../../\(selectorPack.relativePath)/\(selectorName)"
      )
      let state = ActiveState(
        format: Self.stateFormat,
        edition: edition,
        generation: generation,
        activeView: "Runtime/Active",
        packs: packs,
        publication: .prepared,
        transactionID: transactionID,
        acceptedCatalog: record.catalog,
        rollbackPacks: rollbackPacksAfterPublication(
          previous: snapshot.state, candidate: packs)
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let stateData = try encoder.encode(state) + Data("\n".utf8)
      try stateData.write(to: candidate.appending(path: "activation.json"), options: .atomic)
      record.phase = .prepared
      record.candidateRevision = .init(
        generation: generation, stateSHA256: Self.sha256(stateData))
      try writeJSON(record, to: transaction.appending(path: Self.languageTransactionMarkerName))
      return ActivationCandidate(
        transactionID: transactionID,
        directory: candidate,
        expectedActiveRevision: snapshot.activeRevision)
    } catch {
      // The downloading record remains the single cleanup owner until the
      // prepared record is atomically published.
      try? FileManager.default.removeItem(at: candidate)
      throw error
    }
  }

  /// Completes the successful publication. Active becomes the immutable
  /// runtime state; the shared reconciler retires superseded data.
  func commitDataChannelUpdate(transactionID: UUID) throws {
    let transaction = transactionsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    let activeDocument = try loadActiveStateDocument()
    var active = activeDocument.state
    guard let record = validatedLanguageTransaction(at: transaction, now: Date()),
      record.phase == .prepared,
      record.candidateRevision == ActiveRevision(
        generation: active.generation, stateSHA256: Self.sha256(activeDocument.data)),
      active.publication == .prepared,
      active.transactionID == transactionID
    else { throw Failure.invalidActiveState }
    active.publication = .committed
    try writeJSON(active, to: activeSharedDataDirectory.appending(path: "activation.json"))
    // The committed Active document is the irreversible health-success fact;
    // transaction cleanup is retryable and cannot change publication truth.
    try? reconcileLanguageStorage(activeState: active)
  }

  /// The sole lifecycle owner for immutable packs and Registry-owned
  /// transaction artifacts. Invalid or foreign entries are preserved.
  private func reconcileLanguageStorage(
    activeState: ActiveState,
    now: Date = Date()
  ) throws {
    var traversalBudget = Self.maximumGarbageCollectionEntries
    guard let entries = try boundedOwnedDirectoryEntries(
      at: transactionsDirectory, recursively: false, remaining: &traversalBudget)
    else { throw Failure.invalidActiveState }
    var pendingPackPaths = Set<String>()
    var languageCleanups: [LanguageTransactionCleanup] = []
    var scratchCleanups: [URL] = []

    for entry in entries {
      if let record = validatedLanguageTransaction(at: entry, now: now) {
        let paths = record.artifacts.map(Self.packPath)
        let isLive = activeState.transactionID == record.transactionID
        if isLive, activeState.publication == .committed {
          languageCleanups.append(.init(
            transactionID: record.transactionID, directory: entry,
            protectedPackPaths: paths, retiresCommittedTransaction: true))
        } else if now.timeIntervalSince1970 - record.createdAt >= Self.orphanSafetyAge,
          !isLive
        {
          languageCleanups.append(.init(
            transactionID: record.transactionID, directory: entry,
            protectedPackPaths: paths, retiresCommittedTransaction: false))
        } else {
          pendingPackPaths.formUnion(paths)
        }
        continue
      }
      if let scratch = validatedPersonalScratch(at: entry, now: now),
        now.timeIntervalSince1970 - scratch.createdAt >= Self.orphanSafetyAge
      {
        scratchCleanups.append(entry)
      }
    }

    let packCleanups = try supersededPackCleanups(
      active: activeState.packs, rollback: activeState.rollbackPacks,
      pending: pendingPackPaths, remaining: &traversalBudget)
    let downloadCleanups = languageCleanups.map {
      downloadsDirectory.appending(path: $0.transactionID.uuidString, directoryHint: .isDirectory)
    }
    let allCleanupDirectories = languageCleanups.map(\.directory) + downloadCleanups
      + scratchCleanups + packCleanups.map(\.directory)
    var preflightedTrees: [String: [URL]] = [:]
    for directory in allCleanupDirectories {
      if let tree = try boundedOwnedDirectoryEntries(
        at: directory, recursively: true, remaining: &traversalBudget)
      {
        preflightedTrees[directory.standardizedFileURL.path] = tree
      }
    }
    var retirementMarkers: [String: Data] = [:]
    for cleanup in languageCleanups where cleanup.retiresCommittedTransaction {
      let marker = cleanup.directory.appending(path: Self.languageTransactionMarkerName)
      guard preflightedTrees[cleanup.directory.standardizedFileURL.path] != nil,
        let markerData = try? readOwnedFile(marker)
      else { throw Failure.invalidActiveState }
      retirementMarkers[cleanup.directory.standardizedFileURL.path] = markerData
    }

    var cleanupFailures = Set<String>()
    for cleanup in languageCleanups {
      do {
        try removeOwnedDownloadDirectory(transactionID: cleanup.transactionID)
        if cleanup.retiresCommittedTransaction {
          let key = cleanup.directory.standardizedFileURL.path
          guard let markerData = retirementMarkers[key], let tree = preflightedTrees[key] else {
            throw Failure.invalidActiveState
          }
          let immediate = tree.filter {
            $0.deletingLastPathComponent().standardizedFileURL == cleanup.directory.standardizedFileURL
          }
          try retireLanguageTransaction(
            at: cleanup.directory, markerData: markerData, entries: immediate)
        } else {
          try FileManager.default.removeItem(at: cleanup.directory)
        }
      } catch {
        cleanupFailures.formUnion(cleanup.protectedPackPaths)
      }
    }
    for directory in scratchCleanups { try? FileManager.default.removeItem(at: directory) }
    let protected = pendingPackPaths.union(cleanupFailures)
    for cleanup in packCleanups where !protected.contains(cleanup.relativePath) {
      try? FileManager.default.removeItem(at: cleanup.directory)
    }
  }

  private func validatedPersonalScratch(
    at directory: URL,
    now: Date
  ) -> PersonalScratchMarker? {
    guard transactionsDirectory.standardizedFileURL == directory.deletingLastPathComponent()
      .standardizedFileURL,
      Self.isSecureOwnedDirectory(transactionsDirectory),
      Self.isSecureOwnedDirectory(directory), contains(directory.resolvingSymlinksInPath()),
      let directoryID = UUID(uuidString: directory.lastPathComponent),
      directoryID.uuidString == directory.lastPathComponent,
      let marker: PersonalScratchMarker = readOwnedJSON(
        directory.appending(path: Self.personalScratchMarkerName)),
      marker.format == Self.personalScratchFormat,
      marker.transactionID == directoryID,
      marker.createdAt.isFinite, marker.createdAt > 0,
      marker.createdAt <= now.timeIntervalSince1970 + 300
    else { return nil }
    return marker
  }

  private func validatedLanguageTransaction(
    at directory: URL,
    now: Date
  ) -> LanguageTransactionRecord? {
    guard transactionsDirectory.standardizedFileURL == directory.deletingLastPathComponent()
      .standardizedFileURL,
      Self.isSecureOwnedDirectory(transactionsDirectory),
      Self.isSecureOwnedDirectory(directory), contains(directory.resolvingSymlinksInPath()),
      let directoryID = UUID(uuidString: directory.lastPathComponent),
      directoryID.uuidString == directory.lastPathComponent,
      let record: LanguageTransactionRecord = readOwnedJSON(
        directory.appending(path: Self.languageTransactionMarkerName)),
      record.format == Self.transactionFormat,
      record.transactionID == directoryID,
      record.createdAt.isFinite, record.createdAt > 0,
      record.createdAt <= now.timeIntervalSince1970 + 300,
      validDataChannelReceipt(record.catalog),
      record.baseRevision.generation > 0,
      Self.isSHA256(record.baseRevision.stateSHA256),
      validArtifacts(record.artifacts, edition: record.edition),
      (record.phase == .downloading && record.candidateRevision == nil)
        || (record.phase == .prepared
          && record.candidateRevision?.generation == record.baseRevision.generation + 1
          && record.candidateRevision.map({ Self.isSHA256($0.stateSHA256) }) == true)
    else { return nil }
    return record
  }

  private func removeOwnedDownloadDirectory(transactionID: UUID) throws {
    let directory = downloadsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    var info = stat()
    guard lstat(directory.path, &info) == 0 else {
      if errno == ENOENT { return }
      throw Failure.invalidActiveState
    }
    guard directory.deletingLastPathComponent().standardizedFileURL
      == downloadsDirectory.standardizedFileURL,
      Self.isSecureOwnedDirectory(downloadsDirectory),
      Self.isSecureOwnedDirectory(directory),
      contains(directory.resolvingSymlinksInPath())
    else { throw Failure.invalidActiveState }
    try FileManager.default.removeItem(at: directory)
  }

  /// Removes a fully projected committed transaction while keeping its marker
  /// as the last recovery fact. If the final directory removal fails, the
  /// exact marker is restored before the error is returned for a later retry.
  private func retireLanguageTransaction(
    at directory: URL,
    markerData: Data,
    entries: [URL]
  ) throws {
    let markerURL = directory.appending(path: Self.languageTransactionMarkerName)
    for entry in entries where entry.lastPathComponent != Self.languageTransactionMarkerName {
      try? FileManager.default.removeItem(at: entry)
    }
    guard unlink(markerURL.path) == 0 else {
      if errno == ENOENT, !FileManager.default.fileExists(atPath: directory.path) { return }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard rmdir(directory.path) == 0 else {
      let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      if FileManager.default.fileExists(atPath: directory.path) {
        try markerData.write(to: markerURL, options: .atomic)
      }
      throw failure
    }
  }

  private func rollbackPacksAfterPublication(
    previous: ActiveState,
    candidate: [ActivePack]
  ) -> [ActivePack] {
    var result = Dictionary(uniqueKeysWithValues: previous.rollbackPacks.map { ($0.kind, $0) })
    for current in candidate {
      guard let prior = previous.packs.first(where: { $0.kind == current.kind }) else { continue }
      if !Self.sameImmutablePack(prior, current) { result[current.kind] = prior }
    }
    for prior in previous.packs where !candidate.contains(where: { $0.kind == prior.kind }) {
      result[prior.kind] = prior
    }
    for current in candidate where
      result[current.kind].map({ Self.sameImmutablePack($0, current) }) == true
    {
      result.removeValue(forKey: current.kind)
    }
    let order: [PackKind: Int] = [.chinese: 0, .english: 1, .lts: 2, .extended: 3]
    return result.values.sorted { order[$0.kind, default: 99] < order[$1.kind, default: 99] }
  }

  private func supersededPackCleanups(
    active: [ActivePack],
    rollback: [ActivePack],
    pending: Set<String>,
    remaining: inout Int
  ) throws -> [PackCleanup] {
    let retained = Set((active + rollback).map(\.relativePath)).union(pending)
    var cleanups: [PackCleanup] = []
    for kind in [PackKind.chinese, .english, .lts, .extended] {
      let root = packsDirectory.appending(path: kind.rawValue, directoryHint: .isDirectory)
      guard let entries = try boundedOwnedDirectoryEntries(
        at: root, recursively: false, remaining: &remaining)
      else { continue }
      for entry in entries {
        let relative = "Data/Packs/\(kind.rawValue)/\(entry.lastPathComponent)"
        guard !retained.contains(relative), validatedPackDeletion(at: entry, kind: kind) else {
          continue
        }
        cleanups.append(.init(directory: entry, relativePath: relative))
      }
    }
    return cleanups
  }

  private func validatedPackDeletion(at directory: URL, kind: PackKind) -> Bool {
    guard Self.isSecureOwnedDirectory(directory), contains(directory.resolvingSymlinksInPath()),
      let identity: PackDeletionIdentity = readOwnedJSON(
        directory.appending(path: "manifest.json")),
      identity.kind == kind,
      identity.packID == LinnetPackContract.Kind(rawValue: kind.rawValue)?.packID,
      Self.isSafeIdentifier(identity.version), identity.sequence > 0,
      Self.isSHA256(identity.contentSHA256),
      directory.lastPathComponent == Self.packIdentity(
        sequence: identity.sequence, version: identity.version)
    else { return false }
    return true
  }

  /// Streams a Registry-owned directory under one reconciliation-wide budget.
  /// Callers finish every preflight before they execute the first deletion.
  private func boundedOwnedDirectoryEntries(
    at directory: URL,
    recursively: Bool,
    remaining: inout Int
  ) throws -> [URL]? {
    try verifyCanonicalRoot()
    var info = stat()
    guard lstat(directory.path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw Failure.invalidActiveState
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      contains(directory.resolvingSymlinksInPath())
    else { throw Failure.invalidActiveState }

    let options: FileManager.DirectoryEnumerationOptions = recursively
      ? [] : [.skipsSubdirectoryDescendants]
    var enumerationFailed = false
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      options: options,
      errorHandler: { _, _ in
        enumerationFailed = true
        return false
      })
    else { throw Failure.invalidActiveState }
    var entries: [URL] = []
    for case let entry as URL in enumerator {
      guard remaining > 0 else { throw Failure.invalidActiveState }
      remaining -= 1
      entries.append(entry)
      // Foundation does not traverse directory symlinks. Calling
      // skipDescendants() for a non-directory symlink leaks to the next real
      // directory and can hide its inventory from an exhaustive check.
      _ = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
    }
    guard !enumerationFailed else { throw Failure.invalidActiveState }
    return entries
  }

  private func readOwnedJSON<T: Decodable>(_ url: URL) -> T? {
    guard let data = try? readOwnedFile(url) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  /// Reads one user-writable Registry control file through the descriptor that
  /// was validated. Size and identity must remain stable for the whole read.
  private func readOwnedFile(
    _ url: URL,
    maximumBytes: Int = Self.ownedMetadataMaximumBytes,
    exactBytes: Int? = nil
  ) throws -> Data {
    try verifyCanonicalRoot()
    guard maximumBytes > 0, exactBytes.map({ $0 >= 0 && $0 <= maximumBytes }) != false else {
      throw OwnedFileReadFailure.invalid
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw errno == ENOENT ? OwnedFileReadFailure.missing : OwnedFileReadFailure.invalid
    }
    defer { close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == getuid(),
      (before.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      before.st_size >= 0,
      UInt64(before.st_size) <= UInt64(maximumBytes),
      exactBytes.map({ before.st_size == off_t($0) }) != false
    else { throw OwnedFileReadFailure.invalid }

    var descriptorPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &descriptorPath) == 0,
      contains(URL(fileURLWithPath: String(cString: descriptorPath)))
    else { throw OwnedFileReadFailure.invalid }

    let byteLimit = exactBytes ?? maximumBytes
    var data = Data()
    data.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: min(65_536, byteLimit + 1))
    while true {
      let request = min(buffer.count, byteLimit - data.count + 1)
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, request)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw OwnedFileReadFailure.invalid
      }
      if count == 0 { break }
      guard data.count + count <= byteLimit else { throw OwnedFileReadFailure.invalid }
      data.append(contentsOf: buffer.prefix(count))
    }

    var after = stat()
    guard fstat(descriptor, &after) == 0,
      (after.st_mode & S_IFMT) == S_IFREG,
      after.st_uid == getuid(),
      (after.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      data.count == Int(before.st_size),
      exactBytes.map({ data.count == $0 }) != false
    else { throw OwnedFileReadFailure.invalid }
    return data
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(value) + Data("\n".utf8)).write(to: url, options: .atomic)
  }

  private func receiptForCatalog(
    _ catalog: LinnetDataChannel.Verified
  ) throws -> DataChannelReceipt {
    guard catalog.catalog.sequence > 0, Self.isSHA256(catalog.digest) else {
      throw Failure.invalidActiveState
    }
    return .init(format: "io.github.ares-x.linnet.data-channel-receipt.v1",
      sequence: catalog.catalog.sequence, digest: catalog.digest)
  }

  private func validateDataChannelReceipt(_ candidate: DataChannelReceipt?) throws {
    guard let candidate else { return }
    guard validDataChannelReceipt(candidate) else { throw Failure.invalidActiveState }
    guard let previous = try acceptedDataChannelReceipt() else { return }
    guard candidate.sequence > previous.sequence
      || (candidate.sequence == previous.sequence && candidate.digest == previous.digest)
    else { throw Failure.staleDataChannel }
  }

  private func acceptedDataChannelReceipt() throws -> DataChannelReceipt? {
    let active = try loadActiveStateDocument().state
    if active.publication == .committed { return active.acceptedCatalog }
    guard let transactionID = active.transactionID else { throw Failure.invalidActiveState }
    let previous = transactionsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory).appending(
      path: "language-active", directoryHint: .isDirectory)
    let previousState = try loadActiveStateDocument(at: previous).state
    guard previousState.publication == .committed else { throw Failure.invalidActiveState }
    return previousState.acceptedCatalog
  }

  private func validDataChannelReceipt(_ receipt: DataChannelReceipt?) -> Bool {
    guard let receipt else { return true }
    return receipt.format == "io.github.ares-x.linnet.data-channel-receipt.v1"
      && receipt.sequence > 0 && Self.isSHA256(receipt.digest)
  }

  private func loadActiveStateDocument() throws -> (state: ActiveState, data: Data) {
    try loadActiveStateDocument(at: activeSharedDataDirectory)
  }

  private func loadActiveStateDocument(
    at directory: URL
  ) throws -> (state: ActiveState, data: Data) {
    try loadActiveStateDocument(atFile: directory.appending(path: "activation.json"))
  }

  private func loadActiveStateDocument(
    atFile stateURL: URL
  ) throws -> (state: ActiveState, data: Data) {
    let data: Data
    do {
      data = try readOwnedFile(stateURL)
    } catch OwnedFileReadFailure.missing {
      throw Failure.missingActiveState
    } catch {
      throw Failure.invalidActiveState
    }
    guard let state = try? JSONDecoder().decode(ActiveState.self, from: data),
      state.format == Self.stateFormat,
      state.generation > 0,
      state.activeView == "Runtime/Active",
      packsAreCompatible(state.packs, edition: state.edition),
      validDataChannelReceipt(state.acceptedCatalog),
      Set(state.rollbackPacks.map(\.kind)).count == state.rollbackPacks.count,
      state.rollbackPacks.allSatisfy(Self.validPackIdentity),
      state.publication == .committed || state.transactionID != nil
    else {
      throw Failure.invalidActiveState
    }
    return (state, data)
  }

  private func verifiedInstalledManifest(
    for pack: ActivePack
  ) throws -> VerifiedInstalledManifest {
    let directory = rootDirectory.appending(path: pack.relativePath, directoryHint: .isDirectory)
    let installed = try verifiedInstalledManifest(at: directory)
    guard Self.sha256(installed.manifestData) == pack.manifestSHA256,
      Self.activePack(from: installed.manifest, manifestSHA256: pack.manifestSHA256) == pack
    else { throw Failure.invalidActiveState }
    return installed
  }

  private func verifiedInstalledManifest(
    at directory: URL
  ) throws -> VerifiedInstalledManifest {
    let manifestData: Data
    do {
      manifestData = try readOwnedFile(directory.appending(path: "manifest.json"))
    } catch {
      throw Failure.invalidActiveState
    }
    let manifest: LinnetPackContract.Manifest
    do {
      manifest = try LinnetPackContract.parseManifest(
        manifestData, coreVersion: coreVersion)
    } catch {
      throw Failure.invalidActiveState
    }
    try verifyInstalledInventory(manifest, in: directory)
    return .init(manifest: manifest, manifestData: manifestData)
  }

  private func verifiedInstalledPack(at directory: URL) throws -> ActivePack {
    let installed = try verifiedInstalledManifest(at: directory)
    let manifestSHA256 = Self.sha256(installed.manifestData)
    let expectedPack = Self.activePack(
      from: installed.manifest, manifestSHA256: manifestSHA256)
    guard directory.standardizedFileURL == rootDirectory.appending(
      path: expectedPack.relativePath, directoryHint: .isDirectory).standardizedFileURL
    else { throw Failure.invalidActiveState }
    return expectedPack
  }

  private func verifyActiveProjection(
    state: ActiveState,
    manifests: [PackKind: LinnetPackContract.Manifest]
  ) throws {
    let active = activeSharedDataDirectory.standardizedFileURL
    let excluded = Set(["linnet_zh.dict.yaml", "linnet_zh_full.dict.yaml"])
    var expectedTargets: [String: URL] = [:]
    for pack in state.packs {
      guard let manifest = manifests[pack.kind] else { throw Failure.invalidActiveState }
      let packRoot = rootDirectory.appending(
        path: pack.relativePath, directoryHint: .isDirectory)
      for entry in manifest.files where !excluded.contains(entry.path) {
        guard expectedTargets.updateValue(
          packRoot.appending(path: entry.path, directoryHint: .notDirectory),
          forKey: entry.path) == nil
        else { throw Failure.invalidActiveState }
      }
    }
    expectedTargets.removeValue(forKey: "linnet_zh.dict.yaml")
    expectedTargets.removeValue(forKey: "linnet_zh_full.dict.yaml")
    guard let chinese = state.packs.first(where: { $0.kind == .chinese }) else {
      throw Failure.invalidActiveState
    }
    let selectorPack: ActivePack
    let selectorName: String
    if state.edition == .full {
      guard let extended = state.packs.first(where: { $0.kind == .extended }) else {
        throw Failure.invalidActiveState
      }
      selectorPack = extended
      selectorName = "linnet_zh_full.dict.yaml"
    } else {
      selectorPack = chinese
      selectorName = "linnet_zh.dict.yaml"
    }
    guard manifests[selectorPack.kind]?.files.contains(where: { $0.path == selectorName }) == true,
      expectedTargets.updateValue(
        rootDirectory.appending(path: selectorPack.relativePath)
          .appending(path: selectorName),
        forKey: "linnet_zh.dict.yaml") == nil
    else { throw Failure.invalidActiveState }

    for required in [
      "default.yaml", "squirrel.yaml", "linnet_zh.schema.yaml",
      "linnet_zh.dict.yaml", "linnet_en.schema.yaml",
      "wanxiang-lts-zh-hans.gram",
    ] where expectedTargets[required] == nil {
      throw Failure.incompleteActiveView(required)
    }
    var expectedDirectories: Set<String> = ["build"]
    for path in expectedTargets.keys {
      var components = path.split(separator: "/").map(String.init)
      _ = components.popLast()
      var prefix = ""
      for component in components {
        prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
        expectedDirectories.insert(prefix)
      }
    }
    let expectedEntries = Set(expectedTargets.keys)
      .union(["activation.json", "linnet_grammar_active.yaml"])
    var remaining = Self.maximumActiveProjectionEntries
    guard let entries = try boundedOwnedDirectoryEntries(
      at: active, recursively: true, remaining: &remaining)
    else { throw Failure.invalidActiveState }
    var actualEntries = Set<String>()
    var actualDirectories = Set<String>()
    let prefix = active.path + "/"
    for entry in entries {
      let path = entry.standardizedFileURL.path
      guard path.hasPrefix(prefix) else { throw Failure.invalidActiveState }
      let relative = String(path.dropFirst(prefix.count))
      var info = stat()
      guard !relative.isEmpty, lstat(entry.path, &info) == 0,
        info.st_uid == getuid()
      else { throw Failure.invalidActiveState }
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        guard (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
          actualDirectories.insert(relative).inserted else {
          throw Failure.invalidActiveState
        }
      case S_IFREG:
        guard (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
          (relative == "activation.json" || relative == "linnet_grammar_active.yaml"),
          actualEntries.insert(relative).inserted
        else { throw Failure.invalidActiveState }
      case S_IFLNK:
        guard let expected = expectedTargets[relative],
          entry.resolvingSymlinksInPath().standardizedFileURL
            == expected.resolvingSymlinksInPath().standardizedFileURL,
          actualEntries.insert(relative).inserted
        else { throw Failure.invalidActiveState }
      default:
        throw Failure.invalidActiveState
      }
    }
    guard actualEntries == expectedEntries, actualDirectories == expectedDirectories else {
      throw Failure.invalidActiveState
    }
    let grammar: Data
    do {
      grammar = try readOwnedFile(active.appending(path: "linnet_grammar_active.yaml"))
    } catch {
      throw Failure.invalidActiveState
    }
    guard grammar == Data("grammar:\n  language: wanxiang-lts-zh-hans\n".utf8) else {
      throw Failure.invalidActiveState
    }
  }

  private func verifyInstalledInventory(
    _ manifest: LinnetPackContract.Manifest,
    in directory: URL
  ) throws {
    var expectedFiles = Set(manifest.files.map(\.path))
    expectedFiles.insert("manifest.json")
    var expectedDirectories = Set<String>()
    for path in expectedFiles {
      var components = path.split(separator: "/").map(String.init)
      _ = components.popLast()
      var prefix = ""
      for component in components {
        prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
        expectedDirectories.insert(prefix)
      }
    }

    var remaining = Self.maximumInstalledPackEntries
    guard let entries = try boundedOwnedDirectoryEntries(
      at: directory, recursively: true, remaining: &remaining)
    else { throw Failure.invalidActiveState }
    var actualFiles = Set<String>()
    var actualDirectories = Set<String>()
    let prefix = directory.standardizedFileURL.path + "/"
    for entry in entries {
      let path = entry.standardizedFileURL.path
      guard path.hasPrefix(prefix) else { throw Failure.invalidActiveState }
      let relative = String(path.dropFirst(prefix.count))
      var info = stat()
      guard !relative.isEmpty, lstat(entry.path, &info) == 0,
        info.st_uid == getuid(),
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
      else { throw Failure.invalidActiveState }
      switch info.st_mode & S_IFMT {
      case S_IFREG:
        guard actualFiles.insert(relative).inserted else {
          throw Failure.invalidActiveState
        }
      case S_IFDIR:
        guard actualDirectories.insert(relative).inserted else {
          throw Failure.invalidActiveState
        }
      default:
        throw Failure.invalidActiveState
      }
    }
    guard actualFiles == expectedFiles, actualDirectories == expectedDirectories else {
      throw Failure.invalidActiveState
    }
    for entry in manifest.files {
      _ = try verifiedManifestFile(entry, in: directory)
    }
  }

  /// Verifies one manifest-owned file through the descriptor actually read.
  /// Every declared component must remain a user-owned, non-writable non-symlink.
  private func verifiedManifestFile(
    _ entry: LinnetPackContract.FileEntry,
    in directory: URL
  ) throws -> URL {
    try verifyCanonicalRoot()
    guard Self.isSecureOwnedDirectory(directory) else { throw Failure.invalidActiveState }
    let packRoot = directory.resolvingSymlinksInPath().standardizedFileURL
    guard contains(packRoot) else { throw Failure.invalidActiveState }

    let components = entry.path.split(separator: "/")
    guard !components.isEmpty else { throw Failure.invalidActiveState }
    var file = directory
    for (index, component) in components.enumerated() {
      let isLast = index == components.count - 1
      file = file.appending(
        path: String(component), directoryHint: isLast ? .notDirectory : .isDirectory)
      var componentInfo = stat()
      guard lstat(file.path, &componentInfo) == 0,
        componentInfo.st_uid == getuid(),
        (componentInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0,
        (componentInfo.st_mode & S_IFMT) == (isLast ? S_IFREG : S_IFDIR)
      else { throw Failure.invalidActiveState }
    }

    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.invalidActiveState }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == getuid(),
      (before.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      before.st_size >= 0, before.st_size == off_t(entry.bytes)
    else { throw Failure.invalidActiveState }

    var descriptorPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let expectedPath = packRoot.appending(path: entry.path).standardizedFileURL.path
    guard fcntl(descriptor, F_GETPATH, &descriptorPath) == 0,
      URL(fileURLWithPath: String(cString: descriptorPath))
        .resolvingSymlinksInPath().standardizedFileURL.path == expectedPath
    else { throw Failure.invalidActiveState }

    var hasher = SHA256()
    var total: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw Failure.invalidActiveState
      }
      if count == 0 { break }
      total += UInt64(count)
      guard total <= entry.bytes else { throw Failure.invalidActiveState }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      total == entry.bytes,
      hasher.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256
    else { throw Failure.invalidActiveState }
    return file
  }

  private static func activePack(
    from manifest: LinnetPackContract.Manifest,
    manifestSHA256: String
  ) -> ActivePack {
    let identity = packIdentity(sequence: manifest.sequence, version: manifest.version)
    return ActivePack(
      packID: manifest.packID,
      kind: packKind(manifest.kind),
      version: manifest.version,
      sequence: manifest.sequence,
      dataABI: manifest.dataABI,
      contentSHA256: manifest.contentSHA256,
      minCore: manifest.minCore,
      requirements: manifest.requires.map {
        ActiveRequirement(kind: packKind($0.kind), dataABI: $0.dataABI)
      },
      relativePath: "Data/Packs/\(manifest.kind.rawValue)/\(identity)",
      manifestSHA256: manifestSHA256)
  }

  private static func packKind(_ kind: LinnetPackContract.Kind) -> PackKind {
    switch kind {
    case .chinese: .chinese
    case .english: .english
    case .lts: .lts
    case .extended: .extended
    }
  }

  private func makeImmutable(_ directory: URL) throws {
    let contents = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    for entry in contents {
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw Failure.unsafePath(entry.path) }
      if values.isDirectory == true {
        try makeImmutable(entry)
      } else {
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: entry.path)
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
  }

  private func contains(_ url: URL) -> Bool {
    let root = rootDirectory.standardizedFileURL.path
    let candidate = url.standardizedFileURL.path
    return candidate == root || candidate.hasPrefix(root + "/")
  }

  private func verifyCanonicalRoot() throws {
    let descriptor = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.unsafePath(rootDirectory.path) }
    defer { close(descriptor) }
    var info = stat()
    var descriptorPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      info.st_dev == rootDevice, info.st_ino == rootInode,
      fcntl(descriptor, F_GETPATH, &descriptorPath) == 0,
      URL(fileURLWithPath: String(cString: descriptorPath)).path == rootDirectory.path
    else { throw Failure.unsafePath(rootDirectory.path) }
  }

  private func swapDirectories(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.path.withCString { lhsPath in
      rhs.path.withCString { rhsPath in
        renameatx_np(
          AT_FDCWD, lhsPath, AT_FDCWD, rhsPath,
          UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
        ) == 0
      }
    }
  }

  private static func applicationSupportDirectory() throws -> URL {
    guard let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw Failure.applicationSupportUnavailable
    }
    return directory
  }

  private static func openOrCreateCanonicalRoot(
    applicationSupportDirectory: URL,
    productName: String
  ) throws -> (url: URL, device: dev_t, inode: ino_t) {
    guard applicationSupportDirectory.isFileURL,
      applicationSupportDirectory.path.hasPrefix("/")
    else { throw Failure.unsafePath(applicationSupportDirectory.path) }
    let support = applicationSupportDirectory.standardizedFileURL
    var supportInfo = stat()
    if lstat(support.path, &supportInfo) != 0 {
      guard errno == ENOENT else { throw Failure.unsafePath(support.path) }
      do {
        try FileManager.default.createDirectory(
          at: support, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw Failure.unsafePath(support.path)
      }
      guard lstat(support.path, &supportInfo) == 0 else {
        throw Failure.unsafePath(support.path)
      }
    }
    guard (supportInfo.st_mode & S_IFMT) == S_IFDIR,
      supportInfo.st_uid == getuid(),
      (supportInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafePath(support.path) }

    let resolvedSupport = support.resolvingSymlinksInPath().standardizedFileURL
    let root = resolvedSupport.appending(
      component: productName, directoryHint: .isDirectory).standardizedFileURL
    var rootInfo = stat()
    if lstat(root.path, &rootInfo) != 0 {
      guard errno == ENOENT else { throw Failure.unsafePath(root.path) }
      do {
        try FileManager.default.createDirectory(
          at: root, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw Failure.unsafePath(root.path)
      }
      guard lstat(root.path, &rootInfo) == 0 else { throw Failure.unsafePath(root.path) }
    }
    guard (rootInfo.st_mode & S_IFMT) == S_IFDIR,
      rootInfo.st_uid == getuid(),
      (rootInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafePath(root.path) }

    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.unsafePath(root.path) }
    defer { close(descriptor) }
    var opened = stat()
    var descriptorPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fstat(descriptor, &opened) == 0,
      opened.st_dev == rootInfo.st_dev, opened.st_ino == rootInfo.st_ino,
      fcntl(descriptor, F_GETPATH, &descriptorPath) == 0
    else { throw Failure.unsafePath(root.path) }
    // Foundation can resolve the canonical /private/var path back to its /var
    // symlink alias. Preserve the descriptor-owned path so later
    // RENAME_NOFOLLOW_ANY operations do not traverse that alias.
    let openedRoot = URL(
      fileURLWithPath: String(cString: descriptorPath), isDirectory: true)
    guard openedRoot.standardizedFileURL == root else {
      throw Failure.unsafePath(root.path)
    }
    return (openedRoot, opened.st_dev, opened.st_ino)
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        .contains($0)
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func validPacks(_ packs: [ActivePack], edition: Edition) -> Bool {
    let requiredKinds: Set<PackKind> =
      edition == .full
      ? [.chinese, .english, .lts, .extended] : [.chinese, .english, .lts]
    guard Set(packs.map(\.kind)) == requiredKinds,
      Set(packs.map(\.packID)).count == packs.count
    else {
      return false
    }
    return packs.allSatisfy(validPackIdentity)
  }

  private static func validPackIdentity(_ pack: ActivePack) -> Bool {
    let identity = packIdentity(sequence: pack.sequence, version: pack.version)
    return isSafeIdentifier(pack.packID)
      && LinnetPackContract.Kind(rawValue: pack.kind.rawValue)?.packID == pack.packID
      && isSafeIdentifier(pack.version)
      && pack.sequence > 0
      && pack.dataABI > 0
      && isSHA256(pack.contentSHA256)
      && LinnetPackContract.supportsCore(required: pack.minCore, actual: pack.minCore)
      && pack.relativePath == "Data/Packs/\(pack.kind.rawValue)/\(identity)"
      && isSHA256(pack.manifestSHA256)
  }

  private func validArtifacts(
    _ artifacts: [LinnetDataChannel.Artifact],
    edition: Edition
  ) -> Bool {
    let required: Set<LinnetPackContract.Kind> = edition == .full
      ? [.chinese, .english, .lts, .extended] : [.chinese, .english, .lts]
    guard Set(artifacts.map(\.kind)) == required else { return false }
    return artifacts.allSatisfy { artifact in
      Self.isSafeIdentifier(artifact.version)
        && artifact.sequence > 0
        && artifact.dataABI > 0
        && Self.isSHA256(artifact.contentSHA256)
        && Self.isSHA256(artifact.containerSHA256)
        && artifact.bytes > 0
        && LinnetPackContract.supportsCore(
          required: artifact.minCore, actual: coreVersion)
    }
  }

  private static func packPath(_ artifact: LinnetDataChannel.Artifact) -> String {
    "Data/Packs/\(artifact.kind.rawValue)/\(artifact.sequence)-\(artifact.version)"
  }

  /// Manifest encodings differ between the initial PKG and signed transport.
  /// Stable payload identity and compatibility metadata, not the envelope
  /// digest, own same-sequence idempotence.
  private static func sameImmutablePack(_ lhs: ActivePack, _ rhs: ActivePack) -> Bool {
    lhs.packID == rhs.packID
      && lhs.kind == rhs.kind
      && lhs.version == rhs.version
      && lhs.sequence == rhs.sequence
      && lhs.dataABI == rhs.dataABI
      && lhs.contentSHA256 == rhs.contentSHA256
      && lhs.minCore == rhs.minCore
      && lhs.requirements == rhs.requirements
      && lhs.relativePath == rhs.relativePath
  }

  private func packsAreCompatible(_ packs: [ActivePack], edition: Edition) -> Bool {
    guard Self.validPacks(packs, edition: edition),
      packs.allSatisfy({
        LinnetPackContract.supportsCore(required: $0.minCore, actual: coreVersion)
      }),
      let chinese = packs.first(where: { $0.kind == .chinese })
    else { return false }
    return packs.allSatisfy { pack in
      switch pack.kind {
      case .chinese, .english:
        return pack.requirements.isEmpty
      case .lts, .extended:
        return pack.requirements == [.init(kind: .chinese, dataABI: pack.dataABI)]
          && pack.dataABI == chinese.dataABI
      }
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  private static func packIdentity(sequence: UInt64, version: String) -> String {
    "\(sequence)-\(version)"
  }

  private static func isSecureOwnedDirectory(_ directory: URL) -> Bool {
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid()
    else {
      return false
    }
    return (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
  }
}
