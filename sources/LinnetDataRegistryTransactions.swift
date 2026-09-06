import Foundation

extension LinnetDataRegistry {
  static func inspectInstalledRuntime(
    productName: String,
    coreVersion: String,
    applicationSupportDirectory: URL
  ) throws -> InstalledRuntimeState {
    do {
      let registry = try LinnetDataRegistry(
        productName: productName,
        coreVersion: coreVersion,
        applicationSupportDirectory: applicationSupportDirectory,
        rootAccess: .existing)
      try registry.verifyCanonicalRoot()
      guard try registry.validateInstalledRootLayout() else { return .missing }
      _ = try registry.validatedRuntimeSnapshot(requirement: .committed)
      return .healthy
    } catch Failure.missingRegistryRoot {
      return .missing
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
    edition: Edition,
    allowCompleteRepair: Bool = false
  ) throws -> DataChannelUpdateTransaction {
    try prepareMutableDirectories()
    let receipt = try receiptForCatalog(catalog)
    guard let set = catalog.catalog.activationSet(for: edition) else {
      throw Failure.invalidActiveState
    }
    try validateDataChannelReceipt(
      receipt, artifacts: set.packs, allowCompleteRepair: allowCompleteRepair)
    let snapshot = try runtimeSnapshot(reconcilingStorage: false)
    switch set.updateSelection(
      installedPacks: snapshot.state.packs, allowCompleteRepair: allowCompleteRepair) {
    case .localAhead: throw Failure.staleDataChannel
    case .conflict: throw Failure.invalidActiveState
    case .current, .available: break
    }
    let transactionID = UUID()
    let directory = transactionsDirectory.appending(path: transactionID.uuidString, directoryHint: .isDirectory)
    let download = downloadsDirectory.appending(path: transactionID.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      try writeJSON(
        LanguageTransactionRecord(
          format: Self.transactionFormat,
          transactionID: transactionID,
          createdAt: Date().timeIntervalSince1970,
          catalog: receipt,
          edition: edition,
          artifacts: set.packs,
          baseRevision: snapshot.activeRevision,
          allowCompleteRepair: allowCompleteRepair ? true : nil,
          phase: .downloading,
          candidateRevision: nil),
        to: directory.appending(path: Self.languageTransactionMarkerName))
      try FileManager.default.createDirectory(at: download, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch {
      try? FileManager.default.removeItem(at: download)
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    return .init(transactionID: transactionID, downloadDirectory: download)
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

  func runtimeSnapshot(reconcilingStorage: Bool) throws -> RuntimeSnapshot {
    try prepareMutableDirectories()
    let requirement: RuntimePublicationRequirement =
      reconcilingStorage ? .committed : .committedOrPrepared
    let snapshot = try validatedRuntimeSnapshot(requirement: requirement)
    if reconcilingStorage {
      // Runtime truth is the validated immutable Active view. Reconciliation
      // is a retryable projection/GC side effect and cannot block that view.
      try? reconcileLanguageStorage(activeState: snapshot.state)
    }
    return snapshot
  }

  private enum RuntimePublicationRequirement { case committed, committedOrPrepared }

  private func validatedRuntimeSnapshot(
    requirement: RuntimePublicationRequirement
  ) throws -> RuntimeSnapshot {
    let activeDocument = try loadActiveStateDocument()
    let state = activeDocument.state
    if requirement == .committed, state.publication != .committed {
      throw Failure.invalidActiveState
    }
    let active = activeSharedDataDirectory.standardizedFileURL
    guard Self.isSecureOwnedDirectory(active),
      active.resolvingSymlinksInPath() == active
    else {
      throw Failure.unsafePath(active.path)
    }

    var manifests: [LinnetPackContract.Kind: LinnetPackContract.Manifest] = [:]
    for pack in state.packs {
      guard manifests[pack.kind] == nil else { throw Failure.invalidActiveState }
      manifests[pack.kind] = try verifiedInstalledManifest(for: pack).manifest
    }
    try verifyActiveProjection(state: state, manifests: manifests)
    return RuntimeSnapshot(
      sharedDataDirectory: active,
      userDataDirectory: userDataDirectory,
      prebuiltDataDirectory: active.appending(path: "build", directoryHint: .isDirectory),
      stagingDirectory: stagingDirectory,
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

  /// Catalog-selected download authentication and immutable pack staging.
  /// Full or differential transport must reconstruct the same manifest/files.
  func verifyAndStagePack(
    package: URL, artifact: LinnetDataChannel.Artifact,
    transfer: LinnetDataChannel.PackTransfer,
    allowCompleteRepair: Bool = false
  ) throws -> ActivePack {
    try prepareMutableDirectories()
    let resolvedPackage = package.resolvingSymlinksInPath().standardizedFileURL
    let resolvedDownloads = downloadsDirectory.resolvingSymlinksInPath().standardizedFileURL
    let downloadOwner = resolvedPackage.deletingLastPathComponent()
    guard downloadOwner == resolvedDownloads
      || downloadOwner.deletingLastPathComponent() == resolvedDownloads,
      Self.isSecureOwnedDirectory(downloadOwner) else {
      throw Failure.unsafePath(package.path)
    }
    let values = try resolvedPackage.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unsafePath(package.path) }
    switch transfer {
    case .complete:
      try LinnetDataChannel.verifyDownloadedArtifact(
        bytes: artifact.bytes, sha256: artifact.containerSHA256, at: resolvedPackage)
    case .delta(let delta, let base):
      guard artifact.deltas?.contains(delta) == true, Self.validPackIdentity(base),
        base.kind == artifact.kind, base.contentSHA256 == delta.baseContentSHA256 else {
        throw Failure.invalidActiveState
      }
      try LinnetDataChannel.verifyDownloadedArtifact(
        bytes: delta.bytes, sha256: delta.sha256, at: resolvedPackage)
    case .current, .requiresCompleteRepair:
      throw Failure.invalidActiveState
    }
    let kindRoot = packsDirectory.appending(path: artifact.kind.rawValue, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: kindRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard Self.isSecureOwnedDirectory(kindRoot) else { throw Failure.unsafePath(kindRoot.path) }
    let identity = Self.packIdentity(sequence: artifact.sequence, version: artifact.version)
    var final = kindRoot.appending(path: identity, directoryHint: .isDirectory)
    var separateRepairCopy = false
    if FileManager.default.fileExists(atPath: final.path) {
      let installed = try verifiedInstalledPack(at: final)
      if artifact.matches(installed) { return installed }
      guard allowCompleteRepair else { throw Failure.invalidActiveState }
      separateRepairCopy = true
    }

    let partial = kindRoot.appending(path: ".\(identity).partial-\(UUID().uuidString)", directoryHint: .isDirectory)
    do {
      let manifest: LinnetPackContract.Manifest, manifestData: Data
      switch transfer {
      case .delta(_, let base):
        let baseRoot = rootDirectory.appending(path: base.relativePath, directoryHint: .isDirectory)
        guard try verifiedInstalledPack(at: baseRoot) == base else { throw Failure.invalidActiveState }
        try LinnetDirectoryDelta.apply(
          base: baseRoot, delta: resolvedPackage, output: partial, verifyTreeIdentity: false)
        let staged = try verifiedInstalledManifest(at: partial)
        (manifest, manifestData) = (staged.manifest, staged.manifestData)
      case .complete:
        try FileManager.default.createDirectory(
          at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = try LinnetPackContract.verify(
          package: resolvedPackage, coreVersion: self.coreVersion, extractingTo: partial)
        (manifest, manifestData) = (staged.manifest, staged.manifestData)
        try manifestData.write(to: partial.appending(path: "manifest.json"), options: .withoutOverwriting)
      case .current, .requiresCompleteRepair:
        throw Failure.invalidActiveState
      }
      let active = Self.activePack(
        from: manifest, manifestSHA256: Self.sha256(manifestData),
        separateRepairCopy: separateRepairCopy)
      guard artifact.matches(active) else {
        throw LinnetPackContract.Failure.invalidManifest("catalog artifact identity")
      }
      final = rootDirectory.appending(path: active.relativePath, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: final.path) {
        guard try verifiedInstalledPack(at: final) == active else { throw Failure.invalidActiveState }
        try prepareOwnedTreeForRemoval(partial)
        try FileManager.default.removeItem(at: partial)
        return active
      }
      try makeImmutable(partial)
      try FileManager.default.moveItem(at: partial, to: final)
      return active
    } catch {
      try? prepareOwnedTreeForRemoval(partial)
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
    let targetState = try validatedTargetPacks(target, current: snapshot.state)

    let transactionID = update.transactionID
    let transaction = transactionsDirectory.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    let candidate = transaction.appending(path: "language-active", directoryHint: .isDirectory)
    var record = try validatedPreparationRecord(
      update: update,
      transaction: transaction,
      snapshot: snapshot,
      packs: targetState.packs,
      edition: targetState.edition
    )
    try FileManager.default.createDirectory(
      at: candidate,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      return try materializeActivationCandidate(
        candidate: candidate,
        transaction: transaction,
        snapshot: snapshot,
        packs: targetState.packs,
        edition: targetState.edition,
        record: &record
      )
    } catch {
      // The downloading record remains the single cleanup owner until the
      // prepared record is atomically published.
      try? FileManager.default.removeItem(at: candidate)
      throw error
    }
  }

  func validatedTargetPacks(
    _ target: [ActivePack],
    current state: ActiveState
  ) throws -> (packs: [ActivePack], edition: Edition) {
    guard Set(target.map(\.kind)).count == target.count else {
      throw Failure.invalidActiveState
    }
    let current = Dictionary(uniqueKeysWithValues: state.packs.map { ($0.kind, $0) })
    let requested = Dictionary(uniqueKeysWithValues: target.map { ($0.kind, $0) })
    for pack in target {
      if current[pack.kind] == nil {
        guard pack.kind == .extended else { throw Failure.invalidActiveState }
      }
    }
    for previous in state.packs where requested[previous.kind] == nil {
      guard previous.kind == .extended else { throw Failure.invalidActiveState }
    }
    let order: [LinnetPackContract.Kind: Int] = [
      .chinese: 0, .english: 1, .lts: 2, .extended: 3
    ]
    let packs = target.sorted { order[$0.kind, default: 99] < order[$1.kind, default: 99] }
    let edition: Edition = packs.contains(where: { $0.kind == .extended }) ? .full : .standard
    guard packsAreCompatible(packs, edition: edition) else {
      throw Failure.invalidActiveState
    }
    return (packs, edition)
  }

  func materializeActivationCandidate(
    candidate: URL,
    transaction: URL,
    snapshot: RuntimeSnapshot,
    packs: [ActivePack],
    edition: Edition,
    record: inout LanguageTransactionRecord
  ) throws -> ActivationCandidate {
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
    try Self.activeGrammarConfiguration
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
      transactionID: record.transactionID,
      acceptedCatalog: record.catalog,
      rollbackPacks: rollbackPacksAfterPublication(previous: snapshot.state, candidate: packs)
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
      transactionID: record.transactionID,
      directory: candidate,
      expectedActiveRevision: snapshot.activeRevision)
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
  func reconcileLanguageStorage(
    activeState: ActiveState,
    now: Date = Date()
  ) throws {
    var traversalBudget = Self.maximumGarbageCollectionEntries
    guard let entries = try boundedOwnedDirectoryEntries(
      at: transactionsDirectory, recursively: false, remaining: &traversalBudget)
    else { throw Failure.invalidActiveState }
    let transactionPlan = classifyTransactionCleanups(
      entries, activeState: activeState, now: now)
    let packCleanups = try supersededPackCleanups(
      active: activeState.packs, rollback: activeState.rollbackPacks,
      pending: transactionPlan.pendingPackPaths, now: now,
      remaining: &traversalBudget)
    let downloadCleanups = transactionPlan.language.map {
      downloadsDirectory.appending(path: $0.transactionID.uuidString, directoryHint: .isDirectory)
    }
    let allCleanupDirectories = transactionPlan.language.map(\.directory) + downloadCleanups
      + transactionPlan.scratch + packCleanups.map(\.directory)
    let preflightedTrees = try preflightCleanupTrees(
      allCleanupDirectories, remaining: &traversalBudget)
    let retirementMarkers = try languageRetirementMarkers(
      transactionPlan.language, preflightedTrees: preflightedTrees)
    let cleanupFailures = performLanguageCleanups(
      transactionPlan.language,
      preflightedTrees: preflightedTrees,
      retirementMarkers: retirementMarkers
    )
    for directory in transactionPlan.scratch { try? FileManager.default.removeItem(at: directory) }
    let protected = transactionPlan.pendingPackPaths.union(cleanupFailures)
    for cleanup in packCleanups where !protected.contains(cleanup.relativePath) {
      guard let tree = preflightedTrees[cleanup.directory.standardizedFileURL.path] else { continue }
      do {
        try prepareOwnedTreeForRemoval(cleanup.directory, entries: tree)
        try FileManager.default.removeItem(at: cleanup.directory)
      } catch { continue }
    }
  }

  func classifyTransactionCleanups(
    _ entries: [URL],
    activeState: ActiveState,
    now: Date
  ) -> (
    pendingPackPaths: Set<String>,
    language: [LanguageTransactionCleanup],
    scratch: [URL]
  ) {
    var pendingPackPaths = Set<String>()
    var language: [LanguageTransactionCleanup] = []
    var scratch: [URL] = []
    for entry in entries {
      if let record = validatedLanguageTransaction(at: entry, now: now) {
        let paths = record.artifacts.map(Self.packPath)
        let isLive = activeState.transactionID == record.transactionID
        if isLive, activeState.publication == .committed {
          language.append(.init(
            transactionID: record.transactionID, directory: entry,
            protectedPackPaths: paths, retiresCommittedTransaction: true))
        } else if now.timeIntervalSince1970 - record.createdAt >= Self.orphanSafetyAge,
          !isLive {
          language.append(.init(
            transactionID: record.transactionID, directory: entry,
            protectedPackPaths: paths, retiresCommittedTransaction: false))
        } else {
          pendingPackPaths.formUnion(paths)
        }
        continue
      }
      if let marker = validatedPersonalScratch(at: entry, now: now),
        now.timeIntervalSince1970 - marker.createdAt >= Self.orphanSafetyAge {
        scratch.append(entry)
      }
    }
    return (pendingPackPaths, language, scratch)
  }

  func validatedPersonalScratch(
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

  func validatedLanguageTransaction(
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

  func removeOwnedDownloadDirectory(transactionID: UUID) throws {
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
  func retireLanguageTransaction(
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

  func rollbackPacksAfterPublication(
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
      result[current.kind].map({ Self.sameImmutablePack($0, current) }) == true {
      result.removeValue(forKey: current.kind)
    }
    let order: [LinnetPackContract.Kind: Int] = [
      .chinese: 0, .english: 1, .lts: 2, .extended: 3
    ]
    return result.values.sorted { order[$0.kind, default: 99] < order[$1.kind, default: 99] }
  }

  func supersededPackCleanups(
    active: [ActivePack],
    rollback: [ActivePack],
    pending: Set<String>,
    now: Date,
    remaining: inout Int
  ) throws -> [PackCleanup] {
    let retained = Set((active + rollback).map(\.relativePath)).union(pending)
    var cleanups: [PackCleanup] = []
    for kind in [LinnetPackContract.Kind.chinese, .english, .lts, .extended] {
      let root = packsDirectory.appending(path: kind.rawValue, directoryHint: .isDirectory)
      guard let entries = try boundedOwnedDirectoryEntries(
        at: root, recursively: false, remaining: &remaining)
      else { continue }
      for entry in entries {
        let relative = "Data/Packs/\(kind.rawValue)/\(entry.lastPathComponent)"
        guard !retained.contains(relative),
          !pending.contains(where: { relative.hasPrefix($0 + "-") }),
          validatedPackDeletion(at: entry, kind: kind)
            || validatedPartialPackDeletion(at: entry, kind: kind, now: now)
        else {
          continue
        }
        cleanups.append(.init(directory: entry, relativePath: relative))
      }
    }
    return cleanups
  }

  func validatedPackDeletion(
    at directory: URL,
    kind: LinnetPackContract.Kind
  ) -> Bool {
    guard Self.isSecureOwnedDirectory(directory), contains(directory.resolvingSymlinksInPath()),
      let manifestData = try? readOwnedFile(directory.appending(path: "manifest.json")),
      let identity = try? JSONDecoder().decode(PackDeletionIdentity.self, from: manifestData),
      identity.kind == kind,
      identity.packID == kind.packID,
      Self.isSafeIdentifier(identity.version), identity.sequence > 0,
      Self.isSHA256(identity.contentSHA256),
      [Self.packIdentity(sequence: identity.sequence, version: identity.version),
       Self.packIdentity(sequence: identity.sequence, version: identity.version) + "-" + Self.sha256(manifestData)]
        .contains(directory.lastPathComponent)
    else { return false }
    return true
  }

  func validatedPartialPackDeletion(
    at directory: URL,
    kind: LinnetPackContract.Kind,
    now: Date
  ) -> Bool {
    let kindRoot = packsDirectory.appending(path: kind.rawValue, directoryHint: .isDirectory)
      .standardizedFileURL
    let name = directory.lastPathComponent
    guard directory.deletingLastPathComponent().standardizedFileURL == kindRoot,
      Self.isSecureOwnedDirectory(kindRoot), Self.isSecureOwnedDirectory(directory),
      contains(directory.resolvingSymlinksInPath()), name.first == ".",
      let marker = name.range(of: ".partial-", options: .backwards),
      marker.lowerBound > name.index(after: name.startIndex),
      UUID(uuidString: String(name[marker.upperBound...])) != nil,
      let identitySeparator = name[..<marker.lowerBound].firstIndex(of: "-")
    else { return false }
    let sequenceStart = name.index(after: name.startIndex)
    let sequence = name[sequenceStart..<identitySeparator]
    let version = name[name.index(after: identitySeparator)..<marker.lowerBound]
    guard UInt64(sequence) != nil, Self.isSafeIdentifier(String(version)),
      let modified = try? directory.resourceValues(
        forKeys: [.contentModificationDateKey]).contentModificationDate
    else { return false }
    return now.timeIntervalSince(modified) >= Self.orphanSafetyAge
  }

  /// Streams a Registry-owned directory under one reconciliation-wide budget.
  /// Callers finish every preflight before they execute the first deletion.
  func boundedOwnedDirectoryEntries(
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

  func readOwnedJSON<T: Decodable>(_ url: URL) -> T? {
    guard let data = try? readOwnedFile(url) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  /// Reads one user-writable Registry control file through the descriptor that
  /// was validated. Size and identity must remain stable for the whole read.
  func readOwnedFile(
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

  func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(value) + Data("\n".utf8)).write(to: url, options: .atomic)
  }

}
