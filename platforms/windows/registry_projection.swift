import Foundation
import WinSDK

extension LinnetDataRegistry {
  func windowsCoreFiles() throws -> [String: URL] {
    let files = try FileManager.default.contentsOfDirectory(at: coreDataDirectory,
      includingPropertiesForKeys: [.isRegularFileKey])
    var result: [String: URL] = [:]
    for file in files {
      let name = file.lastPathComponent
      if name == "weasel.yaml" || (name.hasPrefix("linnet_windows_") && name.hasSuffix(".yaml")) {
        result[name] = file
      }
    }
    guard result["weasel.yaml"] != nil, result["linnet_windows_default.yaml"] != nil else {
      throw Failure.incompleteActiveView("Core input policies")
    }
    return result
  }

  /// Derived Core configuration is refreshed during native maintenance, just
  /// like Rime's compiled configuration. Pack files themselves never change.
  func windowsProjectedConfiguration(
    _ name: String, source: URL, targets: [String: URL]
  ) throws -> Data? {
    if source.deletingLastPathComponent().standardizedFileURL == coreDataDirectory.standardizedFileURL {
      return try Data(contentsOf: source)
    }
    guard let stem = WindowsInputPolicy.schemaStem(name),
      targets["linnet_windows_" + stem + ".yaml"] != nil else { return nil }
    return try Data(WindowsInputPolicy.applying(
      to: String(contentsOf: source, encoding: .utf8), stem: stem).utf8)
  }

  func materializeWindowsView(at directory: URL, targets: [String: URL]) throws {
    _ = try Self.ensureOwnedDirectory(directory.appendingPathComponent("build", isDirectory: true),
      withIntermediateDirectories: false)
    let lease = try LinnetWindowsDataFile(directory, access: .directory)
    defer { withExtendedLifetime(lease) {} }
    for (name, source) in targets.sorted(by: { $0.key < $1.key }) {
      let parents = try LinnetWindowsDataFile.prepareParents(path: name, beneath: directory)
      defer { withExtendedLifetime(parents) {} }
      let target = directory.appendingPathComponent(name)
      if let data = try windowsProjectedConfiguration(name, source: source, targets: targets) {
        try LinnetWindowsDataFile.writeAtomically(data, to: target)
      } else {
        // Packs and views share the Registry volume. Hard links avoid another
        // full dictionary/grammar copy and need no symlink/developer privilege.
        try (Array(target.path.utf16) + [0]).withUnsafeBufferPointer { destination in
          try (Array(source.path.utf16) + [0]).withUnsafeBufferPointer { origin in
            guard CreateHardLinkW(destination.baseAddress, origin.baseAddress, nil) else {
              throw NSError(domain: "Windows.Win32", code: Int(GetLastError()),
                userInfo: [NSLocalizedDescriptionKey: "Cannot project language-data file: \(name)"])
            }
          }
        }
      }
    }
    try LinnetWindowsDataFile.writeAtomically(Self.activeGrammarConfiguration,
      to: directory.appendingPathComponent("linnet_grammar_active.yaml"))
  }

  func refreshWindowsCoreProjection() throws {
    let state = try loadActiveStateDocument().state
    var manifests: [LinnetPackContract.Kind: LinnetPackContract.Manifest] = [:]
    for pack in state.packs { manifests[pack.kind] = try verifiedInstalledManifest(for: pack).manifest }
    let targets = try activeProjectionTargets(state: state, manifests: manifests)
    let directory = rootDirectory.appendingPathComponent(state.activeView, isDirectory: true)
    var configurations: [String: Data] = ["linnet_grammar_active.yaml": Self.activeGrammarConfiguration]
    for (name, source) in targets {
      guard let data = try windowsProjectedConfiguration(name, source: source, targets: targets) else { continue }
      configurations[name] = data
    }
    for (name, data) in configurations {
      let target = directory.appendingPathComponent(name)
      do {
        if try readOwnedFile(target) == data { continue }
      } catch OwnedFileReadFailure.missing { }
      try LinnetWindowsDataFile.writeAtomically(data, to: target)
    }
  }

  func verifyWindowsActiveProjection(at directory: URL, expectedTargets: [String: URL],
    expectedEntries: Set<String>, expectedDirectories: Set<String>) throws {
    guard let entries = try ownedDirectoryEntries(at: directory, recursively: true) else {
      throw Failure.invalidActiveState
    }
    var files = Set<String>(), directories = Set<String>()
    let prefix = directory.standardizedFileURL.path + "/"
    for entry in entries {
      guard entry.path.hasPrefix(prefix) else { throw Failure.invalidActiveState }
      let name = String(entry.path.dropFirst(prefix.count))
      let file = try LinnetWindowsDataFile(entry, access: .metadata)
      if file.isDirectory { directories.insert(name); continue }
      files.insert(name)
      if name == "activation.json" || name == "linnet_grammar_active.yaml" { continue }
      guard let source = expectedTargets[name] else { throw Failure.invalidActiveState }
      if let data = try windowsProjectedConfiguration(name, source: source, targets: expectedTargets) {
        guard try readOwnedFile(entry) == data else { throw Failure.invalidActiveState }
      } else {
        let original = try LinnetWindowsDataFile(source, access: .metadata)
        guard file.identity == original.identity else { throw Failure.invalidActiveState }
      }
    }
    guard files == expectedEntries, directories == expectedDirectories else { throw Failure.invalidActiveState }
    let view = try loadActiveStateDocument(at: directory).state
    guard directory == rootDirectory.appending(path: view.activeView, directoryHint: .isDirectory) else {
      throw Failure.invalidActiveState
    }
  }

  /// Called under the existing native maintenance/exclusion owner. Until the
  /// final file rename, the previous committed ActiveState remains authoritative.
  func publishWindowsActivation(_ candidate: ActivationCandidate) throws {
    let current = try loadActiveStateDocument()
    guard current.state.publication == .committed,
      candidate.expectedActiveRevision == ActiveRevision(generation: current.state.generation,
        stateSHA256: try LinnetPackContract.sha256(current.data)) else { throw Failure.invalidActiveState }
    let transaction = transactionsDirectory.appendingPathComponent(candidate.transactionID.uuidString, isDirectory: true)
    guard candidate.directory == transaction.appending(path: "language-active", directoryHint: .isDirectory),
      let record = validatedLanguageTransaction(at: transaction, now: Date()), record.phase == .prepared else {
      throw Failure.invalidActiveState
    }
    let proposed = try loadActiveStateDocument(at: candidate.directory)
    guard proposed.state.publication == .prepared, proposed.state.transactionID == candidate.transactionID,
      proposed.state.activeView == Self.generationViewPath(candidate.transactionID),
      record.candidateRevision == ActiveRevision(generation: proposed.state.generation,
        stateSHA256: try LinnetPackContract.sha256(proposed.data)) else { throw Failure.invalidActiveState }
    _ = try Self.ensureOwnedDirectory(rootDirectory.appending(path: "Runtime/Views", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let view = rootDirectory.appending(path: proposed.state.activeView, directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: candidate.directory, to: view)
    // Same rollback location as macOS; Windows only needs the previous state,
    // because the old generation view was not moved or overwritten.
    _ = try Self.ensureOwnedDirectory(candidate.directory, withIntermediateDirectories: false)
    try LinnetWindowsDataFile.writeAtomically(current.data,
      to: candidate.directory.appendingPathComponent("activation.json"))
    try LinnetWindowsDataFile.writeAtomically(proposed.data,
      to: activeSharedDataDirectory.appendingPathComponent("activation.json"))
  }

  func retireWindowsViews(active: ActiveState, now: Date) throws {
    guard active.publication == .committed else { return }
    let root = rootDirectory.appending(path: "Runtime/Views", directoryHint: .isDirectory)
    guard let entries = try ownedDirectoryEntries(at: root, recursively: false) else { return }
    for entry in entries {
      guard let identifier = Foundation.UUID(uuidString: entry.lastPathComponent),
        let state = try? loadActiveStateDocument(at: entry).state,
        state.activeView == Self.generationViewPath(identifier), state.activeView != active.activeView,
        entry.standardizedFileURL == rootDirectory.appending(path: state.activeView, directoryHint: .isDirectory)
      else { continue }
      if state.generation >= active.generation {
        guard let changed = try entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
          now.timeIntervalSince(changed) >= Self.orphanSafetyAge else { continue }
      }
      try removeOwnedTree(entry)
    }
  }
}
