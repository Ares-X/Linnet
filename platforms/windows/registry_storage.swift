import Foundation
import WinSDK

// Only native filesystem operations live here. ActiveState, pack compatibility,
// catalog acceptance and transaction classification remain in the shared owner.
extension LinnetDataRegistry {
  static func openOrCreateCanonicalRoot(
    applicationSupportDirectory: URL, productName: String
  ) throws -> (url: URL, device: VolumeID, inode: FileID) {
    let root = applicationSupportDirectory.appendingPathComponent(productName, isDirectory: true)
    let opened = try LinnetWindowsDataFile.ensureDirectory(root, intermediates: false)
    return (try opened.canonicalURL, opened.identity.volume, opened.identity.file)
  }

  static func openExistingCanonicalRoot(
    applicationSupportDirectory: URL, productName: String
  ) throws -> (url: URL, device: VolumeID, inode: FileID) {
    let root = applicationSupportDirectory.appendingPathComponent(productName, isDirectory: true)
    guard let opened = try LinnetWindowsDataFile.existing(root, access: .directory) else {
      throw Failure.missingRegistryRoot
    }
    return (try opened.canonicalURL, opened.identity.volume, opened.identity.file)
  }

  static func ensureOwnedDirectory(
    _ directory: URL, withIntermediateDirectories: Bool
  ) throws -> BY_HANDLE_FILE_INFORMATION {
    try LinnetWindowsDataFile.ensureDirectory(directory, intermediates: withIntermediateDirectories).information
  }

  static func existingOwnedDirectory(_ directory: URL) throws -> BY_HANDLE_FILE_INFORMATION {
    guard let opened = try LinnetWindowsDataFile.existing(directory, access: .directory) else {
      throw Failure.missingRegistryRoot
    }
    return opened.information
  }

  static func isSecureOwnedDirectory(_ directory: URL) -> Bool {
    (try? LinnetWindowsDataFile(directory, access: .directory)) != nil
  }

  func verifyCanonicalRoot() throws {
    let root = try LinnetWindowsDataFile(rootDirectory, access: .directory)
    guard root.identity.volume == rootDevice, root.identity.file == rootInode,
      try root.canonicalURL == rootDirectory else { throw Failure.unsafePath(rootDirectory.path) }
  }

  func validateInstalledRootLayout() throws -> Bool {
    var found = false
    for name in ["Data", "Runtime", "Build", "Downloads", "State", "Backups", "Transactions"] {
      let directory = rootDirectory.appendingPathComponent(name, isDirectory: true)
      guard let opened = try LinnetWindowsDataFile.existing(directory, access: .directory) else { continue }
      guard opened.identity.volume == rootDevice else { throw Failure.unsafePath(directory.path) }
      if ["Data", "Runtime", "Build", "Downloads"].contains(name) { found = true }
    }
    return found
  }

  func ownedDirectoryEntries(at directory: URL, recursively: Bool) throws -> [URL]? {
    try verifyCanonicalRoot()
    guard let lease = try LinnetWindowsDataFile.existing(directory, access: .directory) else { return nil }
    defer { withExtendedLifetime(lease) {} }
    guard try contains(lease.canonicalURL) else { throw Failure.unsafePath(directory.path) }
    var failed = false
    guard let enumerator = FileManager.default.enumerator(at: directory,
      includingPropertiesForKeys: nil,
      options: recursively ? [] : [.skipsSubdirectoryDescendants],
      errorHandler: { _, _ in failed = true; return false }) else {
      throw Failure.invalidActiveState
    }
    var entries: [URL] = []
    for case let entry as URL in enumerator {
      // Inspect before requesting the next entry, so a junction cannot be
      // traversed as another Registry subtree by the platform enumerator.
      let opened = try LinnetWindowsDataFile(entry, access: .metadata)
      guard try contains(opened.canonicalURL) else { throw Failure.unsafePath(entry.path) }
      entries.append(entry)
    }
    guard !failed else { throw Failure.invalidActiveState }
    return entries
  }

  func readOwnedFile(_ url: URL) throws -> Data {
    try verifyCanonicalRoot()
    guard let file = try LinnetWindowsDataFile.existing(url, access: .read) else {
      throw OwnedFileReadFailure.missing
    }
    guard try contains(file.canonicalURL), file.byteCount <= UInt64(Int.max) else {
      throw OwnedFileReadFailure.invalid
    }
    var data = Data()
    // The read HANDLE denies write/delete sharing for its entire lifetime.
    while true {
      let chunk = try file.read(upToCount: 65_536)
      if chunk.isEmpty { break }
      data.append(chunk)
      guard UInt64(data.count) <= file.byteCount else { throw OwnedFileReadFailure.invalid }
    }
    guard UInt64(data.count) == file.byteCount else { throw OwnedFileReadFailure.invalid }
    return data
  }

  func verifiedManifestFile(_ entry: LinnetPackContract.FileEntry, in directory: URL) throws -> URL {
    try verifyCanonicalRoot()
    let rootLease = try LinnetWindowsDataFile(directory, access: .directory)
    guard try contains(rootLease.canonicalURL) else { throw Failure.invalidActiveState }
    var parents = [rootLease]
    var path = directory
    for component in entry.path.split(separator: "/").dropLast() {
      path.appendPathComponent(String(component), isDirectory: true)
      parents.append(try LinnetWindowsDataFile(path, access: .directory))
    }
    defer { withExtendedLifetime(parents) {} }
    let url = directory.appendingPathComponent(entry.path)
    let file = try LinnetWindowsDataFile(url, access: .read)
    guard file.byteCount == entry.bytes, try contains(file.canonicalURL) else {
      throw Failure.invalidActiveState
    }
    var hasher = try LinnetPackContract.Hasher()
    var total: UInt64 = 0
    while true {
      let chunk = try file.read(upToCount: 65_536)
      if chunk.isEmpty { break }
      total += UInt64(chunk.count)
      guard total <= entry.bytes else { throw Failure.invalidActiveState }
      try hasher.update(data: chunk)
    }
    guard total == entry.bytes, try hasher.finalize() == entry.sha256 else {
      throw Failure.invalidActiveState
    }
    return url
  }

  func makeImmutable(_ directory: URL) throws {
    guard let entries = try ownedDirectoryEntries(at: directory, recursively: true) else {
      throw Failure.invalidActiveState
    }
    for entry in entries {
      let file = try LinnetWindowsDataFile(entry, access: .metadata)
      if !file.isDirectory { try LinnetWindowsDataFile.makeReadOnly(entry) }
    }
  }

  func removeOwnedTree(_ directory: URL, entries supplied: [URL]? = nil) throws {
    guard directory.standardizedFileURL != rootDirectory, contains(directory) else {
      throw Failure.unsafePath(directory.path)
    }
    guard let item = try LinnetWindowsDataFile.existing(directory, access: .remove) else { return }
    if !item.isDirectory { try item.remove(); return }
    try item.close()
    guard let entries = try supplied ?? ownedDirectoryEntries(at: directory, recursively: true) else { return }
    // Descendants precede parents. Native unlink preserves readonly attributes
    // on any immutable pack linked into another active view.
    for entry in entries.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
      if let file = try LinnetWindowsDataFile.existing(entry, access: .remove) { try file.remove() }
    }
    if let root = try LinnetWindowsDataFile.existing(directory, access: .remove) { try root.remove() }
  }

  func retireLanguageTransaction(at directory: URL, markerData: Data, entries: [URL]) throws {
    let markerURL = directory.appendingPathComponent(Self.languageTransactionMarkerName)
    for entry in entries where entry != markerURL { try removeOwnedTree(entry) }
    if let marker = try LinnetWindowsDataFile.existing(markerURL, access: .remove) { try marker.remove() }
    do {
      if let root = try LinnetWindowsDataFile.existing(directory, access: .remove) { try root.remove() }
    } catch {
      try LinnetWindowsDataFile.writeAtomically(markerData, to: markerURL)
      throw error
    }
  }
}
