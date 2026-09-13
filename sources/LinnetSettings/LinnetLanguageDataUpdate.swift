import Foundation

/// One online language-data operation for the macOS and Windows Settings
/// consumers. Each frontend owns its mutation lease and native activation;
/// catalog identity, selection and filesystem transactions stay in the Registry.
enum LinnetLanguageDataUpdate {
  enum Phase: Sendable { case downloading, verifying, activating }

  static func run(
    registry: LinnetDataRegistry,
    transport: LinnetSettingsDownloadTransport,
    catalogURL: URL,
    edition: LinnetDataRegistry.Edition? = nil,
    allowCompleteRepair: Bool = false,
    progress: @escaping @Sendable (Phase, Double) async -> Void,
    diagnostic: @escaping @Sendable (String) -> Void,
    activate: @escaping @Sendable (LinnetDataRegistry.ActivationCandidate) async throws -> Void
  ) async throws {
    try registry.prepareMutableDirectories()
    try Task.checkCancellation()
    await progress(.downloading, 0)
    let catalogData = try await transport.downloadCatalog(at: catalogURL)
    try Task.checkCancellation()
    await progress(.verifying, 0)
    let catalog = try registry.verifyDataChannel(catalogData)
    let snapshot = try registry.runtimeSnapshot()
    let requestedEdition = edition ?? snapshot.state.edition
    guard let selected = catalog.catalog.activationSet(for: requestedEdition) else {
      throw LinnetDataRegistry.Failure.invalidActiveState
    }
    let update = try registry.beginDataChannelUpdate(
      accepting: catalog, edition: requestedEdition, allowCompleteRepair: allowCompleteRepair)
    defer { try? registry.cancelDataChannelUpdate(transactionID: update.transactionID) }
    var targetPacks: [LinnetDataRegistry.ActivePack] = []
    for artifact in selected.packs {
      try Task.checkCancellation()
      let installed = snapshot.state.packs.first { $0.kind == artifact.kind }
      var transfer = artifact.transfer(from: installed, allowCompleteRepair: allowCompleteRepair)
      if case .current(let pack) = transfer {
        targetPacks.append(pack)
        continue
      }
      while true {
        let url: URL, bytes: UInt64
        if case .delta(let delta, _) = transfer {
          (url, bytes) = (delta.url, delta.bytes)
        } else {
          (url, bytes) = (artifact.url, artifact.bytes)
        }
        let package = update.downloadDirectory.appending(path: url.lastPathComponent)
        let completed = Double(targetPacks.count) / Double(selected.packs.count)
        do {
          await progress(.downloading, completed)
          try await transport.downloadArtifact(from: url, expectedBytes: bytes, to: package)
          try Task.checkCancellation()
          await progress(.verifying, completed)
          let staged = try registry.verifyAndStagePack(
            package: package, artifact: artifact, transfer: transfer,
            allowCompleteRepair: allowCompleteRepair)
          targetPacks.append(staged)
          break
        } catch {
          try Task.checkCancellation()
          guard case .delta = transfer else { throw error }
          diagnostic("Language-data delta failed; downloading complete pack: \(error.localizedDescription)")
          transfer = .complete
        }
      }
      await progress(.verifying, Double(targetPacks.count) / Double(selected.packs.count))
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
    let candidate = try registry.prepareDataChannelUpdate(update, target: targetPacks)
    await progress(.activating, 1)
    try Task.checkCancellation()
    try await activate(candidate)
  }
}
