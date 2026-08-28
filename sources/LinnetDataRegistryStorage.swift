import CryptoKit
import Darwin
import Foundation

extension LinnetDataRegistry {
  func receiptForCatalog(
    _ catalog: LinnetDataChannel.Verified
  ) throws -> DataChannelReceipt {
    guard catalog.catalog.sequence > 0, Self.isSHA256(catalog.digest) else {
      throw Failure.invalidActiveState
    }
    return .init(format: "io.github.ares-x.linnet.data-channel-receipt.v1",
      sequence: catalog.catalog.sequence, digest: catalog.digest)
  }

  func validateDataChannelReceipt(_ candidate: DataChannelReceipt?) throws {
    guard let candidate else { return }
    guard validDataChannelReceipt(candidate) else { throw Failure.invalidActiveState }
    guard let previous = try acceptedDataChannelReceipt() else { return }
    guard candidate.sequence > previous.sequence
      || (candidate.sequence == previous.sequence && candidate.digest == previous.digest)
    else { throw Failure.staleDataChannel }
  }

  func acceptedDataChannelReceipt() throws -> DataChannelReceipt? {
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

  func validDataChannelReceipt(_ receipt: DataChannelReceipt?) -> Bool {
    guard let receipt else { return true }
    return receipt.format == "io.github.ares-x.linnet.data-channel-receipt.v1"
      && receipt.sequence > 0 && Self.isSHA256(receipt.digest)
  }

  func loadActiveStateDocument() throws -> (state: ActiveState, data: Data) {
    try loadActiveStateDocument(at: activeSharedDataDirectory)
  }

  func loadActiveStateDocument(
    at directory: URL
  ) throws -> (state: ActiveState, data: Data) {
    try loadActiveStateDocument(atFile: directory.appending(path: "activation.json"))
  }

  func loadActiveStateDocument(
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

  func verifiedInstalledManifest(
    for pack: ActivePack
  ) throws -> VerifiedInstalledManifest {
    let directory = rootDirectory.appending(path: pack.relativePath, directoryHint: .isDirectory)
    let installed = try verifiedInstalledManifest(at: directory)
    guard Self.sha256(installed.manifestData) == pack.manifestSHA256,
      Self.activePack(from: installed.manifest, manifestSHA256: pack.manifestSHA256) == pack
    else { throw Failure.invalidActiveState }
    return installed
  }

  func verifiedInstalledManifest(
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

  func verifiedInstalledPack(at directory: URL) throws -> ActivePack {
    let installed = try verifiedInstalledManifest(at: directory)
    let manifestSHA256 = Self.sha256(installed.manifestData)
    let expectedPack = Self.activePack(
      from: installed.manifest, manifestSHA256: manifestSHA256)
    guard directory.standardizedFileURL == rootDirectory.appending(
      path: expectedPack.relativePath, directoryHint: .isDirectory).standardizedFileURL
    else { throw Failure.invalidActiveState }
    return expectedPack
  }

  func verifyActiveProjection(
    state: ActiveState,
    manifests: [LinnetPackContract.Kind: LinnetPackContract.Manifest]
  ) throws {
    let active = activeSharedDataDirectory.standardizedFileURL
    let expectedTargets = try activeProjectionTargets(state: state, manifests: manifests)
    let expectedDirectories = activeProjectionDirectories(for: expectedTargets.keys)
    let expectedEntries = Set(expectedTargets.keys)
      .union(["activation.json", "linnet_grammar_active.yaml"])
    try verifyActiveProjectionEntries(
      at: active,
      expectedTargets: expectedTargets,
      expectedEntries: expectedEntries,
      expectedDirectories: expectedDirectories
    )
    try verifyActiveGrammar(at: active)
  }

  func activeProjectionTargets(
    state: ActiveState,
    manifests: [LinnetPackContract.Kind: LinnetPackContract.Manifest]
  ) throws -> [String: URL] {
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
    let (selectorPack, selectorName) = try activeProjectionSelector(for: state)
    guard manifests[selectorPack.kind]?.files.contains(where: { $0.path == selectorName }) == true,
      expectedTargets.updateValue(
        rootDirectory.appending(path: selectorPack.relativePath)
          .appending(path: selectorName),
        forKey: "linnet_zh.dict.yaml") == nil
    else { throw Failure.invalidActiveState }

    for required in [
      "default.yaml", "squirrel.yaml", "linnet_zh.schema.yaml",
      "linnet_zh.dict.yaml", "linnet_en.schema.yaml",
      "wanxiang-lts-zh-hans.gram"
    ] where expectedTargets[required] == nil {
      throw Failure.incompleteActiveView(required)
    }
    return expectedTargets
  }

  func activeProjectionSelector(for state: ActiveState) throws -> (ActivePack, String) {
    guard let chinese = state.packs.first(where: { $0.kind == .chinese }) else {
      throw Failure.invalidActiveState
    }
    guard state.edition == .full else { return (chinese, "linnet_zh.dict.yaml") }
    guard let extended = state.packs.first(where: { $0.kind == .extended }) else {
      throw Failure.invalidActiveState
    }
    return (extended, "linnet_zh_full.dict.yaml")
  }

  func activeProjectionDirectories(
    for paths: Dictionary<String, URL>.Keys
  ) -> Set<String> {
    var expectedDirectories: Set<String> = ["build"]
    for path in paths {
      var components = path.split(separator: "/").map(String.init)
      _ = components.popLast()
      var prefix = ""
      for component in components {
        prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
        expectedDirectories.insert(prefix)
      }
    }
    return expectedDirectories
  }

  func verifyActiveProjectionEntries(
    at active: URL,
    expectedTargets: [String: URL],
    expectedEntries: Set<String>,
    expectedDirectories: Set<String>
  ) throws {
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
          relative == "activation.json" || relative == "linnet_grammar_active.yaml",
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
  }

  func verifyActiveGrammar(at active: URL) throws {
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

  func verifyInstalledInventory(
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
  func verifiedManifestFile(
    _ entry: LinnetPackContract.FileEntry,
    in directory: URL
  ) throws -> URL {
    try verifyCanonicalRoot()
    let resolved = try resolveManifestFile(entry, in: directory)
    let opened = try openManifestFile(
      resolved.file,
      expectedPath: resolved.expectedPath,
      expectedBytes: entry.bytes
    )
    defer { close(opened.descriptor) }
    let contents = try digestManifestFile(opened.descriptor, maximumBytes: entry.bytes)
    try validateStableManifestRead(
      opened.descriptor,
      before: opened.info,
      byteCount: contents.byteCount,
      digest: contents.digest,
      entry: entry
    )
    return resolved.file
  }

  func resolveManifestFile(
    _ entry: LinnetPackContract.FileEntry,
    in directory: URL
  ) throws -> (file: URL, expectedPath: String) {
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
    return (
      file,
      packRoot.appending(path: entry.path).standardizedFileURL.path
    )
  }

  func openManifestFile(
    _ file: URL,
    expectedPath: String,
    expectedBytes: UInt64
  ) throws -> (descriptor: Int32, info: stat) {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.invalidActiveState }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == getuid(),
      (before.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      before.st_size >= 0, before.st_size == off_t(expectedBytes)
    else {
      close(descriptor)
      throw Failure.invalidActiveState
    }

    var descriptorPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &descriptorPath) == 0,
      URL(fileURLWithPath: String(cString: descriptorPath))
        .resolvingSymlinksInPath().standardizedFileURL.path == expectedPath
    else {
      close(descriptor)
      throw Failure.invalidActiveState
    }
    return (descriptor, before)
  }

  func digestManifestFile(
    _ descriptor: Int32,
    maximumBytes: UInt64
  ) throws -> (byteCount: UInt64, digest: String) {
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
      guard total <= maximumBytes else { throw Failure.invalidActiveState }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    return (
      total,
      hasher.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }

  func validateStableManifestRead(
    _ descriptor: Int32,
    before: stat,
    byteCount: UInt64,
    digest: String,
    entry: LinnetPackContract.FileEntry
  ) throws {
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      byteCount == entry.bytes,
      digest == entry.sha256
    else { throw Failure.invalidActiveState }
  }

  static func activePack(
    from manifest: LinnetPackContract.Manifest,
    manifestSHA256: String
  ) -> ActivePack {
    let identity = packIdentity(sequence: manifest.sequence, version: manifest.version)
    return ActivePack(
      packID: manifest.packID,
      kind: manifest.kind,
      version: manifest.version,
      sequence: manifest.sequence,
      dataABI: manifest.dataABI,
      contentSHA256: manifest.contentSHA256,
      minCore: manifest.minCore,
      requirements: manifest.requires,
      relativePath: "Data/Packs/\(manifest.kind.rawValue)/\(identity)",
      manifestSHA256: manifestSHA256)
  }

  func makeImmutable(_ directory: URL) throws {
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

  func contains(_ url: URL) -> Bool {
    let root = rootDirectory.standardizedFileURL.path
    let candidate = url.standardizedFileURL.path
    return candidate == root || candidate.hasPrefix(root + "/")
  }

  func verifyCanonicalRoot() throws {
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

  func swapDirectories(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.path.withCString { lhsPath in
      rhs.path.withCString { rhsPath in
        renameatx_np(
          AT_FDCWD, lhsPath, AT_FDCWD, rhsPath,
          UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
        ) == 0
      }
    }
  }

  static func applicationSupportDirectory() throws -> URL {
    guard let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw Failure.applicationSupportUnavailable
    }
    return directory
  }

  static func openOrCreateCanonicalRoot(
    applicationSupportDirectory: URL,
    productName: String
  ) throws -> (url: URL, device: dev_t, inode: ino_t) {
    guard applicationSupportDirectory.isFileURL,
      applicationSupportDirectory.path.hasPrefix("/")
    else { throw Failure.unsafePath(applicationSupportDirectory.path) }
    let support = applicationSupportDirectory.standardizedFileURL
    _ = try ensureOwnedDirectory(support, withIntermediateDirectories: true)
    let resolvedSupport = support.resolvingSymlinksInPath().standardizedFileURL
    let root = resolvedSupport.appending(
      component: productName, directoryHint: .isDirectory).standardizedFileURL
    let rootInfo = try ensureOwnedDirectory(root, withIntermediateDirectories: false)
    return try openCanonicalRoot(root, expected: rootInfo)
  }

  static func ensureOwnedDirectory(
    _ directory: URL,
    withIntermediateDirectories: Bool
  ) throws -> stat {
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw Failure.unsafePath(directory.path) }
      do {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: withIntermediateDirectories,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw Failure.unsafePath(directory.path)
      }
      guard lstat(directory.path, &info) == 0 else {
        throw Failure.unsafePath(directory.path)
      }
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafePath(directory.path) }
    return info
  }

  static func openCanonicalRoot(
    _ root: URL,
    expected rootInfo: stat
  ) throws -> (url: URL, device: dev_t, inode: ino_t) {
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

  static func isSafeIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        .contains($0)
    }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func validPacks(_ packs: [ActivePack], edition: Edition) -> Bool {
    let requiredKinds: Set<LinnetPackContract.Kind> =
      edition == .full
      ? [.chinese, .english, .lts, .extended] : [.chinese, .english, .lts]
    guard Set(packs.map(\.kind)) == requiredKinds,
      Set(packs.map(\.packID)).count == packs.count
    else {
      return false
    }
    return packs.allSatisfy(validPackIdentity)
  }

  static func validPackIdentity(_ pack: ActivePack) -> Bool {
    let identity = packIdentity(sequence: pack.sequence, version: pack.version)
    return isSafeIdentifier(pack.packID)
      && pack.kind.packID == pack.packID
      && isSafeIdentifier(pack.version)
      && pack.sequence > 0
      && pack.dataABI > 0
      && isSHA256(pack.contentSHA256)
      && LinnetPackContract.supportsCore(required: pack.minCore, actual: pack.minCore)
      && pack.relativePath == "Data/Packs/\(pack.kind.rawValue)/\(identity)"
      && isSHA256(pack.manifestSHA256)
  }

  func validArtifacts(
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

  static func packPath(_ artifact: LinnetDataChannel.Artifact) -> String {
    "Data/Packs/\(artifact.kind.rawValue)/\(artifact.sequence)-\(artifact.version)"
  }

  /// Manifest encodings differ between the initial PKG and signed transport.
  /// Stable payload identity and compatibility metadata, not the envelope
  /// digest, own same-sequence idempotence.
  static func sameImmutablePack(_ lhs: ActivePack, _ rhs: ActivePack) -> Bool {
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

  func packsAreCompatible(_ packs: [ActivePack], edition: Edition) -> Bool {
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

  static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  static func packIdentity(sequence: UInt64, version: String) -> String {
    "\(sequence)-\(version)"
  }

  static func isSecureOwnedDirectory(_ directory: URL) -> Bool {
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid()
    else {
      return false
    }
    return (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
  }

  func preflightCleanupTrees(
    _ directories: [URL],
    remaining traversalBudget: inout Int
  ) throws -> [String: [URL]] {
    var result: [String: [URL]] = [:]
    for directory in directories {
      if let tree = try boundedOwnedDirectoryEntries(
        at: directory, recursively: true, remaining: &traversalBudget) {
        result[directory.standardizedFileURL.path] = tree
      }
    }
    return result
  }

  func languageRetirementMarkers(
    _ cleanups: [LanguageTransactionCleanup],
    preflightedTrees: [String: [URL]]
  ) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for cleanup in cleanups where cleanup.retiresCommittedTransaction {
      let key = cleanup.directory.standardizedFileURL.path
      let marker = cleanup.directory.appending(path: Self.languageTransactionMarkerName)
      guard preflightedTrees[key] != nil, let markerData = try? readOwnedFile(marker) else {
        throw Failure.invalidActiveState
      }
      result[key] = markerData
    }
    return result
  }

  func performLanguageCleanups(
    _ cleanups: [LanguageTransactionCleanup],
    preflightedTrees: [String: [URL]],
    retirementMarkers: [String: Data]
  ) -> Set<String> {
    var failures = Set<String>()
    for cleanup in cleanups {
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
        failures.formUnion(cleanup.protectedPackPaths)
      }
    }
    return failures
  }
}
