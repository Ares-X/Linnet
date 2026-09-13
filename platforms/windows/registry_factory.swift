import Foundation

extension LinnetDataRegistry {
  /// The installer owns this complete offline baseline. It is used only before
  /// the first activation; a Core upgrade never replaces a newer user data set.
  @discardableResult
  func installWindowsFactoryIfMissing() throws -> Bool {
    do {
      _ = try loadActiveStateDocument()
      return false
    } catch Failure.missingActiveState { }

    let factory = coreDataDirectory.appendingPathComponent("factory", isDirectory: true)
    let document = try Data(contentsOf: factory.appendingPathComponent("Runtime/Active/activation.json"))
    let state = try decodeActiveState(document)
    guard state.generation == 1, state.publication == .committed,
      state.transactionID == nil, state.acceptedCatalog == nil, state.rollbackPacks.isEmpty else {
      throw Failure.invalidActiveState
    }
    try prepareMutableDirectories()
    var manifests: [LinnetPackContract.Kind: LinnetPackContract.Manifest] = [:]
    for pack in state.packs {
      let final = rootDirectory.appending(path: pack.relativePath, directoryHint: .isDirectory)
      _ = try Self.ensureOwnedDirectory(final.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: final.path) {
        // A prior interrupted bootstrap may already have published this pack.
        guard try verifiedInstalledPack(at: final) == pack else { throw Failure.invalidActiveState }
      } else {
        let partial = final.deletingLastPathComponent().appendingPathComponent(
          ".\(final.lastPathComponent).partial-\(Foundation.UUID().uuidString)", isDirectory: true)
        _ = try Self.ensureOwnedDirectory(partial, withIntermediateDirectories: false)
        do {
          let verified = try LinnetPackContract.verify(
            package: factory.appendingPathComponent(pack.kind.releaseAssetName),
            coreVersion: coreVersion, extractingTo: partial)
          guard Self.activePack(from: verified.manifest,
            manifestSHA256: try LinnetPackContract.sha256(verified.manifestData)) == pack else {
            throw Failure.invalidActiveState
          }
          try LinnetWindowsDataFile.writeAtomically(verified.manifestData,
            to: partial.appendingPathComponent("manifest.json"))
          try publishVerifiedPack(pack, from: partial)
        } catch {
          try? removeOwnedTree(partial)
          throw error
        }
      }
      manifests[pack.kind] = try verifiedInstalledManifest(for: pack).manifest
    }

    _ = try Self.ensureOwnedDirectory(activeSharedDataDirectory, withIntermediateDirectories: true)
    let view = rootDirectory.appending(path: state.activeView, directoryHint: .isDirectory)
    _ = try Self.ensureOwnedDirectory(view.deletingLastPathComponent(), withIntermediateDirectories: true)
    // This exact factory generation is installer-owned, unpublished and has no
    // user files. Recreate its incomplete projection after an interrupted first
    // install; immutable packs and the flat learning directory are untouched.
    try removeOwnedTree(view)
    _ = try Self.ensureOwnedDirectory(view, withIntermediateDirectories: false)
    try LinnetWindowsDataFile.writeAtomically(document, to: view.appendingPathComponent("activation.json"))
    try materializeWindowsView(at: view, targets: activeProjectionTargets(state: state, manifests: manifests))
    try verifyActiveProjection(state: state, manifests: manifests)
    try LinnetWindowsDataFile.writeAtomically(document,
      to: activeSharedDataDirectory.appendingPathComponent("activation.json"))
    return true
  }
}
