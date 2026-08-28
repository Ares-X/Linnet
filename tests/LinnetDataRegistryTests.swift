import Foundation

@_silgen_name("__read_nocancel")
private func linnetTestSystemRead(
  _ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int
) -> Int

private final class RegistryOwnedReadFaults: @unchecked Sendable {
  enum Action {
    case grow
    case shrink
    case swap(replacement: String)
  }

  private struct Fault {
    let target: String
    let action: Action
    var remainingMatches: Int
  }

  private let lock = NSLock()
  private var fault: Fault?
  private var didFire = false
  private var didMutate = false

  func configure(target: URL, action: Action, onMatch: Int = 1) {
    lock.lock()
    fault = Fault(target: target.path, action: action, remainingMatches: onMatch)
    didFire = false
    didMutate = false
    lock.unlock()
  }

  func reset() {
    lock.lock()
    fault = nil
    didFire = false
    didMutate = false
    lock.unlock()
  }

  var outcome: (fired: Bool, mutated: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (didFire, didMutate)
  }

  func afterRead(descriptor: Int32) {
    var pathBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &pathBytes) == 0 else { return }
    let path = String(cString: pathBytes)

    lock.lock()
    guard var pending = fault, pending.target == path else {
      lock.unlock()
      return
    }
    pending.remainingMatches -= 1
    guard pending.remainingMatches == 0 else {
      fault = pending
      lock.unlock()
      return
    }
    fault = nil
    didFire = true
    lock.unlock()

    let changed: Bool
    switch pending.action {
    case .grow:
      let writer = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
      if writer >= 0 {
        var byte: UInt8 = 0x20
        changed = lseek(writer, 0, SEEK_END) >= 0
          && Darwin.write(writer, &byte, 1) == 1
        close(writer)
      } else {
        changed = false
      }
    case .shrink:
      let writer = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
      var info = stat()
      if writer >= 0, fstat(writer, &info) == 0 {
        changed = ftruncate(writer, max(0, info.st_size / 2)) == 0
        close(writer)
      } else {
        if writer >= 0 { close(writer) }
        changed = false
      }
    case .swap(let replacement):
      changed = rename(replacement, path) == 0
    }

    lock.lock()
    didMutate = changed
    lock.unlock()
  }
}

private let registryOwnedReadFaults = RegistryOwnedReadFaults()

@_cdecl("read")
func linnetRegistryTestRead(
  _ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int
) -> Int {
  let result = linnetTestSystemRead(descriptor, buffer, count)
  if result > 0 { registryOwnedReadFaults.afterRead(descriptor: descriptor) }
  return result
}

private final class ConcurrentErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var errors: [Error] = []

  func append(_ error: Error) {
    lock.lock()
    errors.append(error)
    lock.unlock()
  }

  var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return errors.isEmpty
  }

  var first: String {
    lock.lock()
    defer { lock.unlock() }
    return errors.first.map(String.init(describing:)) ?? "none"
  }
}

@main
struct LinnetDataRegistryTests {
  static func main() {
    let fixtureSigning: FixtureSigningOwner
    do {
      fixtureSigning = try FixtureSigningOwner()
    } catch {
      LinnetTestFailure.fail("fixture signing owner: \(error)")
    }
    run("valid snapshot", fixtureSigning, validSnapshotUsesOneCanonicalRoot)
    run("descriptor-canonical temporary root", fixtureSigning,
      descriptorCanonicalTemporaryRootSupportsAtomicSwap)
    run("canonical root symlink", fixtureSigning, canonicalRootSymlinkFailsClosed)
    run("replaced canonical root", fixtureSigning, replacedCanonicalRootFailsClosed)
    run("installed manifest", fixtureSigning, missingInstalledManifestFailsClosed)
    run("runtime payload integrity", fixtureSigning, modifiedInstalledPayloadFailsClosed)
    run("exact Active projection", fixtureSigning, undeclaredActiveEntryFailsClosed)
    run("legacy active schema", fixtureSigning, legacyActiveSchemaFailsClosed)
    run("missing state", fixtureSigning, missingStateFailsClosed)
    run("bounded active metadata", fixtureSigning, oversizedActiveMetadataFailsClosed)
    run("symlink active metadata", fixtureSigning, symlinkActiveMetadataFailsClosed)
    run("growing active metadata", fixtureSigning, growingActiveMetadataFailsClosed)
    run("shrinking active metadata", fixtureSigning, shrinkingActiveMetadataFailsClosed)
    run("swapped active metadata", fixtureSigning, swappedActiveMetadataFailsClosed)
    run("bounded owned markers", fixtureSigning, unsafeOwnedMarkersArePreserved)
    run("growing retirement marker", fixtureSigning, growingRetirementMarkerIsPreserved)
    run("escaping active entry", fixtureSigning, escapingActiveEntryFailsClosed)
    run("grammar state", fixtureSigning, inconsistentGrammarStateFailsClosed)
    run("Core downgrade", fixtureSigning, currentCoreDowngradeFailsClosed)
    run("same sequence idempotence", fixtureSigning, sameContentSameSequenceIsIdempotent)
    run("exhaustive installed inventory", fixtureSigning, undeclaredPackEntryFailsClosed)
    run("incompatible replacement", fixtureSigning, incompatibleReplacementFailsClosed)
    run("cross-kind CAS", fixtureSigning, crossKindCandidatesCarryCASAndCleanOwnedPaths)
    run("full activation", fixtureSigning, replacementBuildsOneFullActivation)
    run("durable transaction pack protection", fixtureSigning, durableTransactionProtectsPlannedPacks)
    run("single durable transaction", fixtureSigning, singleDurableTransactionOwnsCancel)
    run("failed prepare cleanup owner", fixtureSigning, failedPreparationRetainsTransactionCleanupOwner)
    run("prepared crash recovery", fixtureSigning, preparedDataChannelCrashRestoresPreviousActive)
    run("committed receipt recovery", fixtureSigning, dataChannelReceiptFollowsPublication)
    run("generation retention", fixtureSigning, threeGenerationsRetainCurrentAndOneRollback)
    run("scoped reconciliation", fixtureSigning, reconciliationIsScopedAndIdempotent)
    run("bounded transaction root GC", fixtureSigning, oversizedTransactionRootDeletesNothing)
    run("bounded transaction target GC", fixtureSigning, oversizedTransactionTargetDeletesNothing)
    run("bounded pack root GC", fixtureSigning, oversizedPackRootDeletesNothing)
    run("personal scratch GC", fixtureSigning, personalScratchGCIsTypedAndScoped)
    run("concurrent reconciliation", fixtureSigning, concurrentReconciliationNeverBlocksSnapshot)
    run("best-effort superseded cleanup", fixtureSigning, supersededCleanupContinuesAfterEntryFailure)
    print("LinnetDataRegistryTests: PASS")
  }

  private static func run(
    _ name: String,
    _ fixtureSigning: FixtureSigningOwner,
    _ test: (FixtureSigningOwner) throws -> Void
  ) {
    do {
      try test(fixtureSigning)
    } catch {
      LinnetTestFailure.fail("\(name): \(error)")
    }
  }

  private static func singleDurableTransactionOwnsCancel(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let verified = LinnetDataChannel.Verified(
        catalog: dataChannelCatalog(for: try fixturePacks(fixtureSigning), sequence: 2),
        digest: String(repeating: "6", count: 64))
      let update = try registry.beginDataChannelUpdate(
        accepting: verified, edition: .standard)
      let transaction = registry.transactionsDirectory.appending(
        path: update.transactionID.uuidString, directoryHint: .isDirectory)
      require(FileManager.default.fileExists(
        atPath: transaction.appending(
          path: LinnetDataRegistry.languageTransactionMarkerName).path),
        "canonical transaction marker missing")
      require(!FileManager.default.fileExists(
        atPath: transaction.appending(path: ".linnet-data-channel-pending.json").path),
        "second pending marker exists")
      try registry.cancelDataChannelUpdate(transactionID: update.transactionID)
      require(!FileManager.default.fileExists(atPath: transaction.path),
        "canonical cancellation retained transaction")
    }
  }

  private static func threeGenerationsRetainCurrentAndOneRollback(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let second = try replacementPack(
        .lts, version: "2026.08.2", sequence: 2, registry: registry,
        fixtureSigning: fixtureSigning)
      try publish(second, registry: registry)
      let third = try replacementPack(
        .lts, version: "2026.08.3", sequence: 3, registry: registry,
        fixtureSigning: fixtureSigning)
      try publish(third, registry: registry)

      let ltsRoot = registry.packsDirectory.appending(path: "lts", directoryHint: .isDirectory)
      let retained = try FileManager.default.contentsOfDirectory(atPath: ltsRoot.path).sorted()
      require(retained == ["2-2026.08.2", "3-2026.08.3"], "current plus rollback pack")
      let snapshot = try registry.runtimeSnapshot()
      require(snapshot.state.packs.first(where: { $0.kind == .lts }) == third, "current LTS")
      let retainedAfterSecondGC = try FileManager.default.contentsOfDirectory(
        atPath: ltsRoot.path).sorted()
      require(retainedAfterSecondGC == retained, "repeated GC is idempotent")
    }
  }

  private static func reconciliationIsScopedAndIdempotent(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try FileManager.default.createDirectory(
        at: registry.userDataDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: registry.backupsDirectory, withIntermediateDirectories: true)
      let userSentinel = registry.userDataDirectory.appending(path: "gc-sentinel")
      let backupSentinel = registry.backupsDirectory.appending(path: "gc-sentinel")
      try Data("user".utf8).write(to: userSentinel)
      try Data("backup".utf8).write(to: backupSentinel)

      let orphan = try prepareReplacing(
        replacementPack(
          .english, version: "2026.08.2", sequence: 2, registry: registry,
          fixtureSigning: fixtureSigning),
        registry: registry)
      let marker = orphan.directory.deletingLastPathComponent()
        .appending(path: ".linnet-language-transaction.json")
      guard var markerDocument = try JSONSerialization.jsonObject(
        with: Data(contentsOf: marker)) as? [String: Any]
      else { LinnetTestFailure.fail("transaction marker is not an object") }
      markerDocument["created_at"] = 1
      try JSONSerialization.data(withJSONObject: markerDocument, options: [.sortedKeys])
        .write(to: marker, options: .atomic)

      let unknown = registry.transactionsDirectory.appending(path: "foreign-settings-transaction")
      try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
      let unmarked = registry.transactionsDirectory.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: true)
      let outside = registry.rootDirectory.appending(path: "outside-transaction")
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let forged = registry.transactionsDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createSymbolicLink(at: forged, withDestinationURL: outside)
      let ltsRoot = registry.packsDirectory.appending(path: "lts", directoryHint: .isDirectory)
      let unknownPack = ltsRoot.appending(path: "unknown-pack-directory")
      try FileManager.default.createDirectory(at: unknownPack, withIntermediateDirectories: true)
      let outsidePack = registry.rootDirectory.appending(path: "outside-pack")
      try FileManager.default.createDirectory(at: outsidePack, withIntermediateDirectories: true)
      let forgedPack = ltsRoot.appending(path: "99-forged-pack")
      try FileManager.default.createSymbolicLink(at: forgedPack, withDestinationURL: outsidePack)

      _ = try registry.runtimeSnapshot()
      _ = try registry.runtimeSnapshot()

      require(!FileManager.default.fileExists(atPath: marker.deletingLastPathComponent().path),
        "expired marked orphan removed")
      require(FileManager.default.fileExists(atPath: unknown.path), "unknown transaction preserved")
      require(FileManager.default.fileExists(atPath: unmarked.path), "unmarked UUID preserved")
      require(FileManager.default.fileExists(atPath: forged.path), "transaction symlink preserved")
      require(FileManager.default.fileExists(atPath: outside.path), "symlink target preserved")
      require(FileManager.default.fileExists(atPath: unknownPack.path), "unknown pack preserved")
      require(FileManager.default.fileExists(atPath: forgedPack.path), "pack symlink preserved")
      require(FileManager.default.fileExists(atPath: outsidePack.path), "pack symlink target preserved")
      require(FileManager.default.fileExists(atPath: userSentinel.path), "UserData preserved")
      require(FileManager.default.fileExists(atPath: backupSentinel.path), "Backups preserved")
    }
  }

  private static func sameContentSameSequenceIsIdempotent(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let current = try fixturePacks(fixtureSigning).first!
      let replacement = LinnetDataRegistry.ActivePack(
        packID: current.packID,
        kind: current.kind,
        version: current.version,
        sequence: current.sequence,
        dataABI: current.dataABI,
        contentSHA256: current.contentSHA256,
        minCore: current.minCore,
        requirements: current.requirements,
        relativePath: current.relativePath,
        manifestSHA256: current.manifestSHA256)
      let activation = try prepareReplacing(replacement, registry: registry)
      try registry.cancelDataChannelUpdate(transactionID: activation.transactionID)
    }
  }

  private static func undeclaredPackEntryFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let currentEnglish = try fixturePacks(fixtureSigning).first(where: { $0.kind == .english })!
      let undeclared = registry.rootDirectory.appending(
        path: currentEnglish.relativePath).appending(path: "undeclared.plugin.yaml")
      try Data("must-not-project".utf8).write(to: undeclared)
      let replacement = try replacementPack(
        .lts, version: "2026.08.inventory", sequence: 2, registry: registry,
        fixtureSigning: fixtureSigning)
      requireFailure(.invalidActiveState) {
        _ = try prepareReplacing(replacement, registry: registry)
      }
    }
  }

  private static func oversizedTransactionRootDeletesNothing(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try registry.prepareMutableDirectories()
      let expired = UUID()
      try registry.beginPersonalScratch(
        transactionID: expired, createdAt: Date(timeIntervalSince1970: 1))
      let removable = try replacementPack(
        .lts, version: "2026.08.transaction-root", sequence: 9, registry: registry,
        fixtureSigning: fixtureSigning)
      for index in 0..<LinnetPackContract.maximumFiles {
        let path = registry.transactionsDirectory.appending(path: "foreign-\(index)").path
        require(FileManager.default.createFile(atPath: path, contents: Data()),
          "transaction overflow fixture")
      }

      let snapshot = try registry.runtimeSnapshot()
      require(snapshot.state.generation == 1, "GC limit blocked healthy Active")
      require(FileManager.default.fileExists(
        atPath: registry.transactionsDirectory.appending(path: expired.uuidString).path),
        "oversized transaction root deleted an owned entry")
      require(FileManager.default.fileExists(
        atPath: registry.rootDirectory.appending(path: removable.relativePath).path),
        "oversized transaction root allowed a later pack deletion")
    }
  }

  private static func oversizedTransactionTargetDeletesNothing(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try registry.prepareMutableDirectories()
      let expired = UUID()
      try registry.beginPersonalScratch(
        transactionID: expired, createdAt: Date(timeIntervalSince1970: 1))
      let expiredDirectory = registry.transactionsDirectory.appending(path: expired.uuidString)
      for index in 0...LinnetPackContract.maximumFiles {
        let path = expiredDirectory.appending(path: "payload-\(index)").path
        require(FileManager.default.createFile(atPath: path, contents: Data()),
          "transaction target overflow fixture")
      }
      let removable = try replacementPack(
        .lts, version: "2026.08.transaction-target", sequence: 9, registry: registry,
        fixtureSigning: fixtureSigning)

      let snapshot = try registry.runtimeSnapshot()
      require(snapshot.state.generation == 1, "target limit blocked healthy Active")
      require(FileManager.default.fileExists(atPath: expiredDirectory.path),
        "oversized transaction target was deleted")
      require(FileManager.default.fileExists(
        atPath: registry.rootDirectory.appending(path: removable.relativePath).path),
        "oversized transaction target allowed a later pack deletion")
    }
  }

  private static func oversizedPackRootDeletesNothing(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try registry.prepareMutableDirectories()
      let expired = UUID()
      try registry.beginPersonalScratch(
        transactionID: expired, createdAt: Date(timeIntervalSince1970: 1))
      let removable = try replacementPack(
        .lts, version: "2026.08.pack-root", sequence: 9, registry: registry,
        fixtureSigning: fixtureSigning)
      let ltsRoot = registry.packsDirectory.appending(path: "lts", directoryHint: .isDirectory)
      for index in 0..<LinnetPackContract.maximumFiles {
        let path = ltsRoot.appending(path: "foreign-\(index)").path
        require(FileManager.default.createFile(atPath: path, contents: Data()),
          "pack overflow fixture")
      }

      let snapshot = try registry.runtimeSnapshot()
      require(snapshot.state.generation == 1, "pack limit blocked healthy Active")
      require(FileManager.default.fileExists(
        atPath: registry.transactionsDirectory.appending(path: expired.uuidString).path),
        "oversized pack root allowed an earlier transaction deletion")
      require(FileManager.default.fileExists(
        atPath: registry.rootDirectory.appending(path: removable.relativePath).path),
        "oversized pack root deleted a candidate")
    }
  }

  private static func currentCoreDowngradeFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      var packs = try fixturePacks(fixtureSigning)
      let current = packs.removeFirst()
      packs.insert(
        .init(
          packID: current.packID,
          kind: current.kind,
          version: current.version,
          sequence: current.sequence,
          dataABI: current.dataABI,
          contentSHA256: current.contentSHA256,
          minCore: "2.0.0",
          requirements: current.requirements,
          relativePath: current.relativePath,
          manifestSHA256: current.manifestSHA256),
        at: 0)
      try writeState(
        .init(
          format: LinnetDataRegistry.stateFormat,
          edition: .standard,
          generation: 1,
          activeView: "Runtime/Active",
          packs: packs),
        to: registry.activeSharedDataDirectory.appending(path: "activation.json"))
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func validSnapshotUsesOneCanonicalRoot(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let snapshot = try registry.runtimeSnapshot()
      require(samePath(snapshot.sharedDataDirectory, registry.activeSharedDataDirectory), "shared")
      require(
        samePath(snapshot.userDataDirectory, registry.rootDirectory.appending(path: "UserData")),
        "user"
      )
      require(
        samePath(
          snapshot.prebuiltDataDirectory,
          snapshot.sharedDataDirectory.appending(path: "build")
        ),
        "prebuilt"
      )
      require(
        samePath(snapshot.stagingDirectory, registry.rootDirectory.appending(path: "Build")),
        "staging"
      )
      require(
        samePath(
          snapshot.transactionsDirectory,
          registry.rootDirectory.appending(path: "Transactions")
        ),
        "transactions"
      )
      require(
        samePath(snapshot.backupsDirectory, registry.rootDirectory.appending(path: "Backups")),
        "backups"
      )
    }
  }

  private static func canonicalRootSymlinkFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    let base = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Caches/LinnetRootBoundary-\(UUID().uuidString)", directoryHint: .isDirectory)
    let outside = base.appending(path: "outside", directoryHint: .isDirectory)
    let support = base.appending(path: "support", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: support.appending(path: "Linnet", directoryHint: .isDirectory),
      withDestinationURL: outside)
    requireFailure(.unsafePath(support.appending(path: "Linnet").path)) {
      _ = try LinnetDataRegistry(
        productName: "Linnet", coreVersion: "1.0.0",
        applicationSupportDirectory: support)
    }
    require(
      FileManager.default.fileExists(atPath: outside.path),
      "root validation touched symlink target")
  }

  private static func descriptorCanonicalTemporaryRootSupportsAtomicSwap(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    let support = FileManager.default.temporaryDirectory.appending(
      path: "LinnetDescriptorRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: support) }
    let registry = try LinnetDataRegistry(
      productName: "Linnet", coreVersion: "1.0.0",
      applicationSupportDirectory: support)
    let descriptor = open(
      registry.rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    require(descriptor >= 0, "canonical temporary root cannot be opened")
    defer { close(descriptor) }
    var descriptorPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    require(
      fcntl(descriptor, F_GETPATH, &descriptorPath) == 0 &&
        String(cString: descriptorPath) == registry.rootDirectory.path,
      "Registry did not preserve the descriptor-canonical root path")

    let live = registry.userDataDirectory
    let candidate = registry.transactionsDirectory.appending(
      path: "candidate", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try Data("live".utf8).write(to: live.appending(path: "sentinel"))
    try Data("candidate".utf8).write(to: candidate.appending(path: "sentinel"))
    try exchangeDirectories(live, candidate)
    let liveSentinel = try Data(contentsOf: live.appending(path: "sentinel"))
    require(
      liveSentinel == Data("candidate".utf8),
      "descriptor-canonical root did not support an atomic no-follow exchange")
  }

  private static func replacedCanonicalRootFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let root = registry.rootDirectory
      let saved = root.deletingLastPathComponent().appending(
        path: "Linnet-saved-(UUID().uuidString)", directoryHint: .isDirectory)
      let outside = root.deletingLastPathComponent().appending(
        path: "Linnet-outside-(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
      try FileManager.default.moveItem(at: root, to: saved)
      try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
      defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.moveItem(at: saved, to: root)
        try? FileManager.default.removeItem(at: outside)
      }
      try Data("sentinel".utf8).write(to: outside.appending(path: "sentinel"))
      requireFailure(.unsafePath(root.path)) { _ = try registry.runtimeSnapshot() }
      require(
        FileManager.default.fileExists(atPath: outside.appending(path: "sentinel").path),
        "runtime traversed the replaced root")
    }
  }

  private static func missingInstalledManifestFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let pack = try fixturePacks(fixtureSigning).first!
      try FileManager.default.removeItem(
        at: registry.rootDirectory.appending(path: pack.relativePath)
          .appending(path: "manifest.json"))
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func modifiedInstalledPayloadFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let pack = try fixturePacks(fixtureSigning).first!
      let file = registry.rootDirectory.appending(path: pack.relativePath)
        .appending(path: "default.yaml")
      try Data("tampered".utf8).write(to: file)
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func undeclaredActiveEntryFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try Data("undeclared".utf8).write(
        to: registry.activeSharedDataDirectory.appending(path: "undeclared.yaml"))
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func missingStateFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try FileManager.default.removeItem(
        at: registry.activeSharedDataDirectory.appending(path: "activation.json"))
      requireFailure(.missingActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func oversizedActiveMetadataFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let activation = registry.activeSharedDataDirectory.appending(path: "activation.json")
      let handle = try FileHandle(forWritingTo: activation)
      try handle.truncate(atOffset: 1_048_577)
      try handle.close()
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func symlinkActiveMetadataFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let activation = registry.activeSharedDataDirectory.appending(path: "activation.json")
      let alternate = registry.activeSharedDataDirectory.appending(path: "alternate-activation.json")
      try Data(contentsOf: activation).write(to: alternate)
      try FileManager.default.removeItem(at: activation)
      try FileManager.default.createSymbolicLink(at: activation, withDestinationURL: alternate)
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func growingActiveMetadataFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let activation = registry.activeSharedDataDirectory.appending(path: "activation.json")
      registryOwnedReadFaults.configure(target: activation, action: .grow)
      defer { registryOwnedReadFaults.reset() }
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
      let outcome = registryOwnedReadFaults.outcome
      require(outcome.fired && outcome.mutated, "active growth fixture did not fire")
    }
  }

  private static func shrinkingActiveMetadataFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let activation = registry.activeSharedDataDirectory.appending(path: "activation.json")
      registryOwnedReadFaults.configure(target: activation, action: .shrink)
      defer { registryOwnedReadFaults.reset() }
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
      let outcome = registryOwnedReadFaults.outcome
      require(outcome.fired && outcome.mutated, "active shrink fixture did not fire")
    }
  }

  private static func swappedActiveMetadataFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let activation = registry.activeSharedDataDirectory.appending(path: "activation.json")
      let replacement = registry.activeSharedDataDirectory.appending(path: "replacement-activation.json")
      try Data("not-json".utf8).write(to: replacement)
      registryOwnedReadFaults.configure(
        target: activation, action: .swap(replacement: replacement.path))
      defer { registryOwnedReadFaults.reset() }
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
      let outcome = registryOwnedReadFaults.outcome
      require(outcome.fired && outcome.mutated, "active swap fixture did not fire")
    }
  }

  private static func unsafeOwnedMarkersArePreserved(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try registry.prepareMutableDirectories()
      let oversized = UUID()
      try registry.beginPersonalScratch(
        transactionID: oversized, createdAt: Date(timeIntervalSince1970: 1))
      let oversizedDirectory = registry.transactionsDirectory.appending(path: oversized.uuidString)
      let oversizedMarker = oversizedDirectory.appending(
        path: LinnetDataRegistry.personalScratchMarkerName)
      let handle = try FileHandle(forWritingTo: oversizedMarker)
      try handle.truncate(atOffset: 1_048_577)
      try handle.close()

      let linked = UUID()
      try registry.beginPersonalScratch(
        transactionID: linked, createdAt: Date(timeIntervalSince1970: 1))
      let linkedDirectory = registry.transactionsDirectory.appending(path: linked.uuidString)
      let linkedMarker = linkedDirectory.appending(
        path: LinnetDataRegistry.personalScratchMarkerName)
      let linkedTarget = registry.rootDirectory.appending(path: "linked-marker-target.json")
      try Data(contentsOf: linkedMarker).write(to: linkedTarget)
      try FileManager.default.removeItem(at: linkedMarker)
      try FileManager.default.createSymbolicLink(at: linkedMarker, withDestinationURL: linkedTarget)

      _ = try registry.runtimeSnapshot()
      require(FileManager.default.fileExists(atPath: oversizedDirectory.path),
        "oversized marker was treated as owned")
      require(FileManager.default.fileExists(atPath: linkedDirectory.path),
        "symlink marker was treated as owned")
    }
  }

  private static func growingRetirementMarkerIsPreserved(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let replacement = try replacementPack(
        .english, version: "2026.08.retire", sequence: 2, registry: registry,
        fixtureSigning: fixtureSigning)
      let activation = try prepareReplacing(replacement, registry: registry)
      let transaction = activation.directory.deletingLastPathComponent()
      let marker = transaction.appending(
        path: LinnetDataRegistry.languageTransactionMarkerName)
      try exchangeDirectories(registry.activeSharedDataDirectory, activation.directory)
      registryOwnedReadFaults.configure(target: marker, action: .grow, onMatch: 3)
      defer { registryOwnedReadFaults.reset() }

      try registry.commitDataChannelUpdate(transactionID: activation.transactionID)
      let outcome = registryOwnedReadFaults.outcome
      require(outcome.fired && outcome.mutated, "retirement growth fixture did not fire")
      require(FileManager.default.fileExists(atPath: transaction.path),
        "mutating retirement marker lost its recovery owner")
      let snapshot = try registry.tentativeRuntimeSnapshot()
      require(snapshot.state.publication == .committed,
        "retirement marker failure changed publication truth")
    }
  }

  private static func legacyActiveSchemaFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let activation = registry.activeSharedDataDirectory.appending(path: "activation.json")
      guard var document = try JSONSerialization.jsonObject(
        with: Data(contentsOf: activation)) as? [String: Any]
      else { LinnetTestFailure.fail("fixture activation is not an object") }
      document.removeValue(forKey: "publication")
      try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        .write(to: activation, options: .atomic)
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func escapingActiveEntryFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let schema = registry.activeSharedDataDirectory.appending(path: "linnet_en.schema.yaml")
      try FileManager.default.removeItem(at: schema)
      try FileManager.default.createSymbolicLink(
        at: schema,
        withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
      )
      requireFailure(.invalidActiveState) {
        _ = try registry.runtimeSnapshot()
      }
    }
  }

  private static func inconsistentGrammarStateFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let invalid = LinnetDataRegistry.ActiveState(
        format: LinnetDataRegistry.stateFormat,
        edition: .full,
        generation: 1,
        activeView: "Runtime/Active",
        packs: try fixturePacks(fixtureSigning)
      )
      try writeState(
        invalid,
        to: registry.activeSharedDataDirectory.appending(path: "activation.json")
      )
      requireFailure(.invalidActiveState) { _ = try registry.runtimeSnapshot() }
    }
  }

  private static func replacementBuildsOneFullActivation(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      _ = try registry.runtimeSnapshot()
      let version = "2026.08.1"
      let fixture = try fixturePack(
        .extended, version: version, sequence: 2,
        files: [
          "dicts/yixue.dict.yaml": Data("fixture-extended-data".utf8),
          "linnet_zh_full.dict.yaml": Data("full-selector".utf8),
        ],
        fixtureSigning: fixtureSigning)
      let packRoot = registry.packsDirectory.appending(
        path: "extended/2-\(version)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: packRoot, withIntermediateDirectories: true)
      try writeFixturePack(fixture, to: packRoot)
      let activation = try prepareReplacing(fixture.pack, registry: registry)
      let old = activation.directory.deletingLastPathComponent().appending(path: "old-active")
      try FileManager.default.moveItem(at: registry.activeSharedDataDirectory, to: old)
      try FileManager.default.moveItem(at: activation.directory, to: registry.activeSharedDataDirectory)
      try FileManager.default.moveItem(at: old, to: activation.directory)
      try registry.commitDataChannelUpdate(transactionID: activation.transactionID)
      let snapshot = try registry.runtimeSnapshot()
      require(snapshot.state.edition == .full, "full edition")
      require(snapshot.state.packs.last == fixture.pack, "Extended pack")
      require(
        FileManager.default.fileExists(
          atPath: snapshot.sharedDataDirectory.appending(path: "dicts/yixue.dict.yaml").path),
        "Extended dictionary"
      )
    }
  }

  private static func dataChannelReceiptFollowsPublication(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let active = try fixturePacks(fixtureSigning)
      let catalog = dataChannelCatalog(for: active, sequence: 9)
      let acceptedDigest = String(repeating: "a", count: 64)
      let verified = LinnetDataChannel.Verified(
        catalog: catalog, digest: acceptedDigest)
      let update = try registry.beginDataChannelUpdate(accepting: verified, edition: .standard)
      let activation = try registry.prepareDataChannelUpdate(update, target: active)
      let transactionDirectory = registry.transactionsDirectory.appending(
        path: activation.transactionID.uuidString, directoryHint: .isDirectory)
      let marker = transactionDirectory.appending(
        path: LinnetDataRegistry.languageTransactionMarkerName)
      require(FileManager.default.fileExists(atPath: marker.path), "prepared marker")
      let prepared = try JSONDecoder().decode(
        LinnetDataRegistry.ActiveState.self,
        from: Data(contentsOf: activation.directory.appending(path: "activation.json")))
      require(prepared.publication == .prepared, "candidate publication")
      require(prepared.acceptedCatalog?.sequence == 9, "candidate catalog receipt")
      let old = activation.directory.deletingLastPathComponent().appending(path: "old-active")
      try FileManager.default.moveItem(at: registry.activeSharedDataDirectory, to: old)
      try FileManager.default.moveItem(at: activation.directory, to: registry.activeSharedDataDirectory)
      let downloadBlocker = update.downloadDirectory.appending(path: "cleanup-blocker")
      try Data("download".utf8).write(to: downloadBlocker)
      guard chflags(downloadBlocker.path, UInt32(UF_IMMUTABLE)) == 0 else {
        LinnetTestFailure.fail("could not block committed download cleanup")
      }
      try registry.commitDataChannelUpdate(transactionID: activation.transactionID)
      let healthy = try registry.runtimeSnapshot()
      require(healthy.state.publication == .committed, "commit publication")
      require(healthy.state.acceptedCatalog?.sequence == 9, "committed catalog receipt")
      require(healthy.state.acceptedCatalog?.digest == acceptedDigest,
        "committed catalog digest")
      require(healthy.state.rollbackPacks.isEmpty, "unchanged activation created rollback packs")
      require(FileManager.default.fileExists(atPath: marker.path),
        "cleanup failure removed its transaction owner")
      let stateDirectory = registry.activeSharedDataDirectory
      require(!FileManager.default.fileExists(
        atPath: stateDirectory.appending(path: "data-channel.json").path),
        "receipt side file returned")
      require(!FileManager.default.fileExists(
        atPath: stateDirectory.appending(path: "rollback.json").path),
        "rollback side file returned")

      let repeated = try registry.beginDataChannelUpdate(
        accepting: verified, edition: .standard)
      require(FileManager.default.fileExists(atPath: repeated.downloadDirectory.path),
        "same-sequence matching catalog digest is idempotent")
      try registry.cancelDataChannelUpdate(transactionID: repeated.transactionID)
      require(!FileManager.default.fileExists(atPath: repeated.downloadDirectory.path),
        "idempotent catalog cancellation retained its download directory")
      let transactionsBeforeDivergence = Set(
        try FileManager.default.contentsOfDirectory(atPath: registry.transactionsDirectory.path))
      let downloadsBeforeDivergence = Set(
        try FileManager.default.contentsOfDirectory(atPath: registry.downloadsDirectory.path))
      let divergent = LinnetDataChannel.Verified(
        catalog: catalog, digest: String(repeating: "b", count: 64))
      requireFailure(.staleDataChannel) {
        _ = try registry.beginDataChannelUpdate(accepting: divergent, edition: .standard)
      }
      let transactionsAfterDivergence = Set(
        try FileManager.default.contentsOfDirectory(atPath: registry.transactionsDirectory.path))
      let downloadsAfterDivergence = Set(
        try FileManager.default.contentsOfDirectory(atPath: registry.downloadsDirectory.path))
      require(
        transactionsAfterDivergence == transactionsBeforeDivergence,
        "same-sequence divergent catalog created a transaction")
      require(
        downloadsAfterDivergence == downloadsBeforeDivergence,
        "same-sequence divergent catalog created a download directory")

      let replay = LinnetDataChannel.Verified(
        catalog: dataChannelCatalog(for: active, sequence: 8),
        digest: String(repeating: "c", count: 64))
      requireFailure(.staleDataChannel) {
        _ = try registry.beginDataChannelUpdate(accepting: replay, edition: .standard)
      }
      _ = chflags(downloadBlocker.path, 0)
      _ = try registry.runtimeSnapshot()
      require(!FileManager.default.fileExists(atPath: transactionDirectory.path),
        "committed transaction was not reconciled")
    }
  }

  private static func personalScratchGCIsTypedAndScoped(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try registry.prepareMutableDirectories()
      let old = UUID()
      let fresh = UUID()
      let foreign = UUID()
      try registry.beginPersonalScratch(
        transactionID: old, createdAt: Date(timeIntervalSince1970: 1))
      try registry.beginPersonalScratch(transactionID: fresh)
      let freshMarker = registry.transactionsDirectory.appending(
        path: fresh.uuidString).appending(path: LinnetDataRegistry.personalScratchMarkerName)
      var markerInfo = stat()
      require(lstat(freshMarker.path, &markerInfo) == 0
        && (markerInfo.st_mode & S_IFMT) == S_IFREG,
        "personal scratch marker is not a regular file")
      let markerDocument = try JSONSerialization.jsonObject(
        with: Data(contentsOf: freshMarker)) as? [String: Any]
      require(markerDocument?["format"] as? String
        == "io.github.ares-x.linnet.personal-scratch.v1",
        "personal scratch marker format")
      require(markerDocument?["transaction_id"] as? String == fresh.uuidString,
        "personal scratch marker transaction identity")
      require(markerDocument?["created_at"] as? Double != nil,
        "personal scratch marker timestamp")
      try FileManager.default.createDirectory(
        at: registry.transactionsDirectory.appending(
          path: foreign.uuidString, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: registry.userDataDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: registry.backupsDirectory, withIntermediateDirectories: true)
      let userSentinel = registry.userDataDirectory.appending(path: "personal-gc-sentinel")
      let backupSentinel = registry.backupsDirectory.appending(path: "personal-gc-sentinel")
      try Data("user".utf8).write(to: userSentinel)
      try Data("backup".utf8).write(to: backupSentinel)

      _ = try registry.runtimeSnapshot()

      require(!FileManager.default.fileExists(
        atPath: registry.transactionsDirectory.appending(path: old.uuidString).path),
        "verified expired personal scratch was not reaped")
      require(FileManager.default.fileExists(
        atPath: registry.transactionsDirectory.appending(path: fresh.uuidString).path),
        "fresh personal scratch was reaped")
      require(FileManager.default.fileExists(
        atPath: registry.transactionsDirectory.appending(path: foreign.uuidString).path),
        "foreign UUID transaction was reaped")
      require(FileManager.default.fileExists(atPath: userSentinel.path), "UserData was traversed")
      require(FileManager.default.fileExists(atPath: backupSentinel.path), "Backups was traversed")
    }
  }

  private static func concurrentReconciliationNeverBlocksSnapshot(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let replacement = try replacementPack(
        .english, version: "2026.08.concurrent", sequence: 2, registry: registry,
        fixtureSigning: fixtureSigning)
      let activation = try prepareReplacing(replacement, registry: registry)
      try exchangeDirectories(registry.activeSharedDataDirectory, activation.directory)
      let downloadBlocker = registry.downloadsDirectory.appending(
        path: activation.transactionID.uuidString).appending(path: "cleanup-blocker")
      try Data("blocked".utf8).write(to: downloadBlocker)
      guard chflags(downloadBlocker.path, UInt32(UF_IMMUTABLE)) == 0 else {
        LinnetTestFailure.fail("could not block concurrent cleanup fixture")
      }
      try registry.commitDataChannelUpdate(transactionID: activation.transactionID)
      _ = chflags(downloadBlocker.path, 0)
      let transaction = registry.transactionsDirectory.appending(
        path: activation.transactionID.uuidString, directoryHint: .isDirectory)
      for index in 0..<128 {
        try Data(repeating: UInt8(index), count: 4_096).write(
          to: transaction.appending(path: "cleanup-\(index)"))
      }
      let second = try LinnetDataRegistry(
        productName: registry.rootDirectory.lastPathComponent,
        coreVersion: "1.0.0",
        applicationSupportDirectory: registry.rootDirectory.deletingLastPathComponent())
      let errors = ConcurrentErrors()
      DispatchQueue.concurrentPerform(iterations: 24) { index in
        do {
          _ = try (index.isMultiple(of: 2) ? registry : second).runtimeSnapshot()
        } catch {
          errors.append(error)
        }
      }
      require(errors.isEmpty, "concurrent Registry reconcile blocked a snapshot: \(errors.first)")
      _ = try registry.runtimeSnapshot()
      require(!FileManager.default.fileExists(atPath: transaction.path),
        "concurrent reconciliation never completed committed cleanup")
      let reconciledSnapshot = try registry.runtimeSnapshot()
      require(reconciledSnapshot.state.acceptedCatalog?.sequence == 2,
        "concurrent reconciliation lost the committed receipt")
    }
  }

  private static func supersededCleanupContinuesAfterEntryFailure(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let blocked = try replacementPack(
        .english, version: "2026.08.blocked", sequence: 7, registry: registry,
        fixtureSigning: fixtureSigning)
      let removable = try replacementPack(
        .english, version: "2026.08.removable", sequence: 8, registry: registry,
        fixtureSigning: fixtureSigning)
      let blockedRoot = registry.rootDirectory.appending(path: blocked.relativePath)
      let immutable = blockedRoot.appending(path: "manifest.json")
      guard chflags(immutable.path, UInt32(UF_IMMUTABLE)) == 0 else {
        LinnetTestFailure.fail("could not make cleanup fixture immutable")
      }
      defer {
        _ = chflags(immutable.path, 0)
        try? FileManager.default.removeItem(at: blockedRoot)
      }

      _ = try registry.runtimeSnapshot()

      require(FileManager.default.fileExists(atPath: blockedRoot.path),
        "failed deletion did not preserve its entry")
      require(!FileManager.default.fileExists(
        atPath: registry.rootDirectory.appending(path: removable.relativePath).path),
        "one failed deletion blocked a later superseded pack")
    }
  }

  private static func preparedDataChannelCrashRestoresPreviousActive(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      var checkpoint = "create replacement"
      do {
      let replacement = try replacementPack(
        .english, version: "2026.08.2", sequence: 2, registry: registry,
        fixtureSigning: fixtureSigning)
      checkpoint = "prepare candidate"
      let activation = try prepareReplacing(replacement, registry: registry)
      checkpoint = "read previous state"
      let previousState = try registry.runtimeSnapshot().state
      checkpoint = "simulate active swap"
      try exchangeDirectories(registry.activeSharedDataDirectory, activation.directory)

      checkpoint = "read tentative state"
      let tentative = try registry.tentativeRuntimeSnapshot()
      require(tentative.state != previousState, "tentative candidate was not visible")
      try registry.cancelDataChannelUpdate(transactionID: activation.transactionID)
      require(FileManager.default.fileExists(
        atPath: activation.directory.deletingLastPathComponent().path),
        "cancel removed a prepared transaction that is still the live Active view")
      checkpoint = "recover prepared state"
      let recovered = try registry.recoverPreparedLanguageActivation()
      require(recovered,
        "prepared crash recovery did not restore previous Active")
      let restored = try registry.runtimeSnapshot().state
      require(restored == previousState,
        "prepared crash recovery changed previous Active")
      } catch {
        throw NSError(
          domain: "LinnetDataRegistryTests.preparedRecovery",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "\(checkpoint): \(error)"])
      }
    }
  }

  private static func durableTransactionProtectsPlannedPacks(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let planned = try replacementPack(
        .english, version: "2026.08.9", sequence: 9, registry: registry,
        fixtureSigning: fixtureSigning)
      var target = try fixturePacks(fixtureSigning)
      target.removeAll { $0.kind == .english }
      target.append(planned)
      let verified = LinnetDataChannel.Verified(
        catalog: dataChannelCatalog(for: target, sequence: 9),
        digest: String(repeating: "c", count: 64))
      let transaction = try registry.beginDataChannelUpdate(accepting: verified, edition: .standard)
      let transactionMarker = registry.transactionsDirectory.appending(
        path: transaction.transactionID.uuidString).appending(
          path: LinnetDataRegistry.languageTransactionMarkerName)
      require(!FileManager.default.fileExists(
        atPath: transactionMarker.deletingLastPathComponent().appending(
          path: ".linnet-data-channel-pending.json").path),
        "second pending marker exists")
      try Data("owned-download".utf8).write(
        to: transaction.downloadDirectory.appending(path: "partial.linnetpack"))
      let foreignDownload = registry.downloadsDirectory.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: foreignDownload, withIntermediateDirectories: false)
      try FileManager.default.createDirectory(
        at: registry.userDataDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: registry.backupsDirectory, withIntermediateDirectories: true)
      let userSentinel = registry.userDataDirectory.appending(path: "transaction-gc-sentinel")
      let backupSentinel = registry.backupsDirectory.appending(path: "transaction-gc-sentinel")
      try Data("user".utf8).write(to: userSentinel)
      try Data("backup".utf8).write(to: backupSentinel)
      _ = try registry.runtimeSnapshot()
      require(
        FileManager.default.fileExists(atPath: registry.rootDirectory.appending(path: planned.relativePath).path),
        "live transaction pack survives GC")
      require(FileManager.default.fileExists(atPath: transaction.downloadDirectory.path),
        "live transaction download directory was collected")

      guard var markerDocument = try JSONSerialization.jsonObject(
        with: Data(contentsOf: transactionMarker)) as? [String: Any]
      else { LinnetTestFailure.fail("transaction marker is not an object") }
      markerDocument["created_at"] = 1
      try JSONSerialization.data(withJSONObject: markerDocument, options: [.sortedKeys])
        .write(to: transactionMarker, options: .atomic)
      _ = try registry.runtimeSnapshot()
      require(!FileManager.default.fileExists(
        atPath: registry.transactionsDirectory.appending(
          path: transaction.transactionID.uuidString).path),
        "expired transaction was preserved")
      require(!FileManager.default.fileExists(atPath: transaction.downloadDirectory.path),
        "expired owned download directory was preserved")
      require(!FileManager.default.fileExists(
        atPath: registry.rootDirectory.appending(path: planned.relativePath).path),
        "expired transaction kept an unreferenced pack protected")
      require(FileManager.default.fileExists(atPath: foreignDownload.path),
        "foreign download directory was deleted")
      require(FileManager.default.fileExists(atPath: userSentinel.path), "UserData was changed")
      require(FileManager.default.fileExists(atPath: backupSentinel.path), "Backups were changed")
    }
  }

  private static func incompatibleReplacementFailsClosed(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      let current = try fixturePacks(fixtureSigning).first!
      requireFailure(.invalidActiveState) {
        _ = try prepareReplacing(
          .init(
            packID: current.packID,
            kind: current.kind,
            version: "same-sequence-different-pack",
            sequence: current.sequence,
            dataABI: current.dataABI,
            contentSHA256: String(repeating: "d", count: 64),
            minCore: current.minCore,
            requirements: current.requirements,
            relativePath: "Data/Packs/chinese/1-same-sequence-different-pack",
            manifestSHA256: String(repeating: "d", count: 64)), registry: registry)
      }
      requireFailure(.invalidActiveState) {
        _ = try prepareReplacing(
          .init(
            packID: LinnetPackContract.Kind.lts.packID,
            kind: .lts,
            version: "incompatible-abi",
            sequence: 2,
            dataABI: 2,
            contentSHA256: String(repeating: "e", count: 64),
            minCore: "1.0.0",
            requirements: [.init(kind: .chinese, dataABI: 2)],
            relativePath: "Data/Packs/lts/2-incompatible-abi",
            manifestSHA256: String(repeating: "e", count: 64)), registry: registry)
      }
    }
  }

  private static func failedPreparationRetainsTransactionCleanupOwner(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      var target = try fixturePacks(fixtureSigning)
      let current = target.removeFirst()
      target.insert(.init(
        packID: current.packID, kind: current.kind, version: "conflict",
        sequence: current.sequence, dataABI: current.dataABI,
        contentSHA256: String(repeating: "9", count: 64), minCore: current.minCore,
        requirements: current.requirements,
        relativePath: "Data/Packs/chinese/1-conflict",
        manifestSHA256: String(repeating: "8", count: 64)), at: 0)
      let verified = LinnetDataChannel.Verified(
        catalog: dataChannelCatalog(for: target, sequence: 2),
        digest: String(repeating: "7", count: 64))
      let update = try registry.beginDataChannelUpdate(
        accepting: verified, edition: .standard)
      requireFailure(.invalidActiveState) {
        _ = try registry.prepareDataChannelUpdate(update, target: target)
      }
      let transaction = registry.transactionsDirectory.appending(
        path: update.transactionID.uuidString)
      require(FileManager.default.fileExists(atPath: transaction.path),
        "failed prepare discarded its transaction cleanup owner")
      require(FileManager.default.fileExists(atPath: update.downloadDirectory.path),
        "failed prepare orphaned its Registry-owned download directory")
      try registry.cancelDataChannelUpdate(transactionID: update.transactionID)
      require(!FileManager.default.fileExists(atPath: transaction.path),
        "cancel preserved the failed transaction")
      require(!FileManager.default.fileExists(atPath: update.downloadDirectory.path),
        "cancel preserved the failed download directory")
    }
  }

  private static func crossKindCandidatesCarryCASAndCleanOwnedPaths(
    _ fixtureSigning: FixtureSigningOwner
  ) throws {
    try withFixture(fixtureSigning) { registry in
      try FileManager.default.createDirectory(
        at: registry.userDataDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: registry.backupsDirectory, withIntermediateDirectories: true)
      let userSentinel = registry.userDataDirectory.appending(path: "sentinel")
      let backupSentinel = registry.backupsDirectory.appending(path: "sentinel")
      try Data("user".utf8).write(to: userSentinel)
      try Data("backup".utf8).write(to: backupSentinel)

      let chinese = try replacementPack(
        .chinese, version: "2026.08.2", registry: registry,
        fixtureSigning: fixtureSigning)
      let english = try replacementPack(
        .english, version: "2026.08.2", registry: registry,
        fixtureSigning: fixtureSigning)
      let first = try prepareReplacing(chinese, registry: registry)
      let stale = try prepareReplacing(english, registry: registry)
      require(first.expectedActiveRevision == stale.expectedActiveRevision, "same base revision")
      let old = first.directory.deletingLastPathComponent().appending(path: "old-active")
      try FileManager.default.moveItem(at: registry.activeSharedDataDirectory, to: old)
      try FileManager.default.moveItem(at: first.directory, to: registry.activeSharedDataDirectory)
      try registry.commitDataChannelUpdate(transactionID: first.transactionID)
      let live = try registry.activeRevision()
      require(live.generation == first.expectedActiveRevision.generation + 1, "new generation")
      require(live != stale.expectedActiveRevision, "stale candidate")
      let staleDownload = registry.downloadsDirectory.appending(
        path: stale.transactionID.uuidString, directoryHint: .isDirectory)
      require(FileManager.default.fileExists(atPath: staleDownload.path), "stale download owner")
      try registry.cancelDataChannelUpdate(transactionID: stale.transactionID)
      require(!FileManager.default.fileExists(atPath: stale.directory.path), "stale transaction")
      require(!FileManager.default.fileExists(atPath: staleDownload.path), "stale download cleanup")
      require(FileManager.default.fileExists(atPath: userSentinel.path), "UserData preserved")
      require(FileManager.default.fileExists(atPath: backupSentinel.path), "Backups preserved")
      require(
        !FileManager.default.fileExists(atPath: stale.directory.path),
        "unpublished candidate remains non-authoritative")
    }
  }

  private static func replacementPack(
    _ kind: LinnetPackContract.Kind,
    version: String,
    sequence: UInt64 = 2,
    registry: LinnetDataRegistry,
    fixtureSigning: FixtureSigningOwner
  ) throws -> LinnetDataRegistry.ActivePack {
    let files = Dictionary(uniqueKeysWithValues: fixtureFileNames(kind).map {
      ($0, Data(version.utf8))
    })
    let fixture = try fixturePack(
      kind, version: version, sequence: sequence, files: files,
      fixtureSigning: fixtureSigning)
    let root = registry.packsDirectory.appending(
      path: "\(kind.rawValue)/\(sequence)-\(version)", directoryHint: .isDirectory)
    try writeFixturePack(fixture, to: root)
    return fixture.pack
  }

  private static func prepareReplacing(
    _ replacement: LinnetDataRegistry.ActivePack,
    registry: LinnetDataRegistry
  ) throws -> LinnetDataRegistry.ActivationCandidate {
    let activeData = try Data(contentsOf: registry.activeSharedDataDirectory.appending(path: "activation.json"))
    var target = try JSONDecoder().decode(LinnetDataRegistry.ActiveState.self, from: activeData).packs
    target.removeAll { $0.kind == replacement.kind }
    target.append(replacement)
    let sequence = target.map(\.sequence).max() ?? 1
    let catalog = LinnetDataChannel.Verified(
      catalog: dataChannelCatalog(for: target, sequence: sequence),
      digest: String(repeating: String(format: "%x", sequence % 16), count: 64))
    let edition: LinnetDataRegistry.Edition = target.contains { $0.kind == .extended }
      ? .full : .standard
    let update = try registry.beginDataChannelUpdate(accepting: catalog, edition: edition)
    return try registry.prepareDataChannelUpdate(update, target: target)
  }

  private static func publish(
    _ pack: LinnetDataRegistry.ActivePack,
    registry: LinnetDataRegistry
  ) throws {
    let activation = try prepareReplacing(pack, registry: registry)
    let old = activation.directory.deletingLastPathComponent().appending(path: "old-active")
    try FileManager.default.moveItem(at: registry.activeSharedDataDirectory, to: old)
    try FileManager.default.moveItem(at: activation.directory, to: registry.activeSharedDataDirectory)
    try registry.commitDataChannelUpdate(transactionID: activation.transactionID)
  }

  private static func withFixture(
    _ fixtureSigning: FixtureSigningOwner,
    _ body: (LinnetDataRegistry) throws -> Void
  ) throws {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "LinnetDataRegistryTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let registry = try LinnetDataRegistry(
      productName: "Linnet",
      coreVersion: "1.0.0",
      applicationSupportDirectory: base
    )
    let active = registry.activeSharedDataDirectory
    try FileManager.default.createDirectory(
      at: active.appending(path: "build", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    let fixtures = try [LinnetPackContract.Kind.chinese, .english, .lts].map { kind in
      try fixturePack(
        kind, version: "2026.08.1", sequence: 1,
        files: Dictionary(uniqueKeysWithValues: fixtureFileNames(kind).map {
          ($0, Data($0.utf8))
        }),
        fixtureSigning: fixtureSigning)
    }
    let packs = fixtures.map(\.pack)
    for fixture in fixtures {
      let root = registry.rootDirectory.appending(
        path: fixture.pack.relativePath, directoryHint: .isDirectory)
      try writeFixturePack(fixture, to: root)
      for path in fixture.files.keys.sorted()
      where path != "linnet_zh.dict.yaml" && path != "linnet_zh_full.dict.yaml" {
        let projected = active.appending(path: path)
        try FileManager.default.createDirectory(
          at: projected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
          at: projected, withDestinationURL: root.appending(path: path))
      }
    }
    let chinese = fixtures.first { $0.pack.kind == .chinese }!
    try FileManager.default.createSymbolicLink(
      at: active.appending(path: "linnet_zh.dict.yaml"),
      withDestinationURL: registry.rootDirectory.appending(path: chinese.pack.relativePath)
        .appending(path: "linnet_zh.dict.yaml"))
    try Data("grammar:\n  language: wanxiang-lts-zh-hans\n".utf8).write(
      to: active.appending(path: "linnet_grammar_active.yaml"))
    try writeState(
      .init(
        format: LinnetDataRegistry.stateFormat,
        edition: .standard,
        generation: 1,
        activeView: "Runtime/Active",
        packs: packs
      ),
      to: active.appending(path: "activation.json")
    )
    try body(registry)
  }

  private static func exchangeDirectories(_ lhs: URL, _ rhs: URL) throws {
    let result = lhs.path.withCString { lhsPath in
      rhs.path.withCString { rhsPath in
        renameatx_np(
          AT_FDCWD, lhsPath, AT_FDCWD, rhsPath,
          UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY))
      }
    }
    guard result == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }
  }

  private struct FixturePack {
    let pack: LinnetDataRegistry.ActivePack
    let manifestData: Data
    let files: [String: Data]
  }

  private struct FixtureSigningOwner {
    init() throws {}
  }

  private static func fixturePacks(
    _ fixtureSigning: FixtureSigningOwner
  ) throws -> [LinnetDataRegistry.ActivePack] {
    try [LinnetPackContract.Kind.chinese, .english, .lts].map { kind in
      try fixturePack(
        kind, version: "2026.08.1", sequence: 1,
        files: Dictionary(uniqueKeysWithValues: fixtureFileNames(kind).map {
          ($0, Data($0.utf8))
        }),
        fixtureSigning: fixtureSigning).pack
    }
  }

  private static func fixtureFileNames(_ kind: LinnetPackContract.Kind) -> [String] {
    switch kind {
    case .chinese:
      ["default.yaml", "linnet_zh.dict.yaml", "linnet_zh.schema.yaml", "squirrel.yaml"]
    case .english:
      ["linnet_en.schema.yaml"]
    case .lts:
      ["wanxiang-lts-zh-hans.gram"]
    case .extended:
      ["dicts/yixue.dict.yaml", "linnet_zh_full.dict.yaml"]
    }
  }

  private static func fixturePack(
    _ kind: LinnetPackContract.Kind,
    version: String,
    sequence: UInt64,
    files: [String: Data],
    fixtureSigning _: FixtureSigningOwner
  ) throws -> FixturePack {
    let marker: Character = switch kind {
    case .chinese: "d"
    case .english: "e"
    case .lts: "f"
    case .extended: "9"
    }
    let requirements: [LinnetPackContract.Requirement] =
      kind == .lts || kind == .extended ? [.init(kind: .chinese, dataABI: 1)] : []
    let entries = files.keys.sorted().map {
      LinnetPackContract.FileEntry(
        path: $0, bytes: UInt64(files[$0]!.count),
        sha256: LinnetPackContract.sha256(files[$0]!))
    }
    let contentSHA256 = String(repeating: marker, count: 64)
    let manifest = LinnetPackContract.Manifest(
      format: LinnetPackContract.manifestFormat,
      product: LinnetPackContract.productIdentifier,
      packID: kind.packID,
      kind: kind,
      version: version,
      sequence: sequence,
      dataABI: 1,
      minCore: "1.0.0",
      contentSHA256: contentSHA256,
      requires: requirements,
      files: entries)
    let manifestData = try LinnetPackContract.canonicalManifestData(manifest)
    let pack = LinnetDataRegistry.ActivePack(
      packID: manifest.packID,
      kind: kind,
      version: version,
      sequence: sequence,
      dataABI: 1,
      contentSHA256: contentSHA256,
      minCore: manifest.minCore,
      requirements: requirements,
      relativePath: "Data/Packs/\(kind.rawValue)/\(sequence)-\(version)",
      manifestSHA256: LinnetPackContract.sha256(manifestData))
    return .init(pack: pack, manifestData: manifestData, files: files)
  }

  private static func writeFixturePack(_ fixture: FixturePack, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (path, data) in fixture.files {
      let file = directory.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file)
    }
    try fixture.manifestData.write(
      to: directory.appending(path: "manifest.json"), options: .atomic)
  }

  private static func dataChannelCatalog(
    for packs: [LinnetDataRegistry.ActivePack], sequence: UInt64
  ) -> LinnetDataChannel.Catalog {
    let artifacts = packs.map { pack in
      LinnetDataChannel.Artifact(
        kind: pack.kind,
        version: pack.version, sequence: pack.sequence, dataABI: pack.dataABI,
        minCore: pack.minCore, contentSHA256: pack.contentSHA256, bytes: 1,
        containerSHA256: String(repeating: "b", count: 64),
        url: URL(string: "https://github.com/Ares-X/Linnet/releases/download/data-\(sequence)/\(pack.kind.releaseAssetName)")!)
    }
    let edition: LinnetDataRegistry.Edition = packs.contains { $0.kind == .extended }
      ? .full : .standard
    return .init(
      format: LinnetDataChannel.format, sequence: sequence,
      core: .init(
        version: "0.1.0", build: 1, revision: String(repeating: "a", count: 40),
        bytes: 1, sha256: String(repeating: "b", count: 64),
        packageURL: URL(
          string:
            "https://github.com/Ares-X/Linnet/releases/download/core-v0.1.0/Linnet-0.1.0-arm64-Core-community-beta.pkg")!,
        releaseURL: URL(string: "https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.0")!),
      activationSets: [.init(edition: edition, packs: artifacts)])
  }

  private static func writeState(
    _ state: LinnetDataRegistry.ActiveState,
    to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(state).write(to: url, options: .atomic)
  }

  private static func requireFailure(
    _ expected: LinnetDataRegistry.Failure,
    operation: () throws -> Void
  ) {
    do {
      try operation()
      LinnetTestFailure.fail("expected \(expected)")
    } catch let actual as LinnetDataRegistry.Failure {
      require(actual == expected, "failure \(actual) != \(expected)")
    } catch {
      LinnetTestFailure.fail("unexpected error: \(error)")
    }
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String = "") {
    guard condition() else { LinnetTestFailure.fail("assertion failed: \(message)") }
  }

  private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
  }
}
