import CryptoKit
import Darwin
import Foundation

/// One on-disk delta boundary shared by Core packages and immutable language
/// packs. rsync owns the difference algorithm; reconstruction only touches an
/// APFS clone. Neither a failed delta nor clone failure permits a full copy.
enum LinnetDirectoryDelta {
  enum Failure: LocalizedError {
    case invalid(String)
    case filesystem(String, Int32)

    var errorDescription: String? {
      switch self {
      case .invalid(let detail): "Invalid Linnet delta: \(detail)."
      case .filesystem(let action, let code): "Linnet delta \(action) failed (errno \(code))."
      }
    }
  }

  enum BaseState: String { case base, target }

  private struct Header: Codable {
    let baseSHA256: String
    let targetSHA256: String
    let batchBytes: UInt64
    let batchSHA256: String
  }

  private struct Entry: Codable {
    let path: String
    let type: String
    let mode: UInt16
    let content: String
  }

  private static let magic = Data("LNDELTA1".utf8)
  private static let maximumBytes: UInt64 = 2_147_483_648
  private static let rsyncOptions = [
    "-rlp", "--checksum", "--no-whole-file", "--delete", "--protocol=29"
  ]

  static func digest(_ root: URL) throws -> String {
    try sha(encode(entries(root)))
  }

  static func build(base: URL, target: URL, output: URL) throws {
    let baseDigest = try digest(base)
    let targetDigest = try digest(target)
    let work = try scratch(beside: output)
    defer { try? FileManager.default.removeItem(at: work) }
    let batch = work.appending(path: "payload.batch")
    try rsync(["--only-write-batch=\(batch.path)", target.path + "/", base.path + "/"])
    guard try digest(base) == baseDigest, try digest(target) == targetDigest else {
      throw Failure.invalid("source changed during generation")
    }
    let source = try openRead(batch)
    defer { try? source.close() }
    let batchBytes = try source.seekToEnd()
    try source.seek(toOffset: 0)
    let batchSHA = try transfer(source, count: batchBytes, to: nil)
    let header = try encode(Header(
      baseSHA256: baseDigest, targetSHA256: targetDigest,
      batchBytes: batchBytes, batchSHA256: batchSHA))
    let destination = try createFile(output)
    var complete = false
    defer {
      try? destination.close()
      if !complete { try? FileManager.default.removeItem(at: output) }
    }
    try destination.write(contentsOf: magic)
    var length = UInt32(header.count).bigEndian
    try withUnsafeBytes(of: &length) { try destination.write(contentsOf: Data($0)) }
    try destination.write(contentsOf: header)
    try source.seek(toOffset: 0)
    _ = try transfer(source, count: batchBytes, to: destination)
    try destination.synchronize()
    complete = true
  }

  static func state(base: URL, delta: URL) throws -> BaseState {
    let header = try read(delta, extracting: nil)
    let actual = try digest(base)
    if actual == header.targetSHA256 { return .target }
    guard actual == header.baseSHA256 else { throw Failure.invalid("installed baseline does not match") }
    return .base
  }

  static func apply(base: URL, delta: URL, output: URL) throws {
    let work = try scratch(beside: output)
    defer { try? FileManager.default.removeItem(at: work) }
    let batch = work.appending(path: "payload.batch")
    let header = try read(delta, extracting: batch)
    guard try digest(base) == header.baseSHA256 else {
      throw Failure.invalid("installed baseline does not match")
    }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      try clone(base, to: output)
      try rsync(["--read-batch=\(batch.path)", output.path + "/"])
      guard try digest(output) == header.targetSHA256, try digest(base) == header.baseSHA256 else {
        throw Failure.invalid("reconstructed target or original baseline differs")
      }
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
  }

  /// The same exact pair supports install and rollback; arbitrary or modified
  /// trees cannot be exchanged. The installer still owns CMS/runtime checks.
  static func exchangeApp(installed: URL, staged: URL, delta: URL) throws {
    let header = try read(delta, extracting: nil)
    try exchangeApp(installed: installed, staged: staged,
      baseSHA256: header.baseSHA256, targetSHA256: header.targetSHA256)
  }

  /// Complete repair has verified full target bytes rather than a delta. Both
  /// transports publish and roll back through this single exact-pair boundary.
  static func exchangeApp(installed: URL, staged: URL, baseSHA256: String, targetSHA256: String) throws {
    let first = try digest(installed), second = try digest(staged)
    guard (first == baseSHA256 && second == targetSHA256)
      || (first == targetSHA256 && second == baseSHA256) else {
      throw Failure.invalid("exchange pair")
    }
    // LaunchServices/InputMethodKit can retain references to the registered
    // App directory. Exchange its complete Contents, never the App inode: the
    // old registered object must not move to staging and then get deleted.
    for app in [installed, staged] {
      guard app.pathExtension == "app",
        try FileManager.default.contentsOfDirectory(atPath: app.path) == ["Contents"] else {
        throw Failure.invalid("App publication layout")
      }
      try requireDirectory(app.appending(path: "Contents"))
    }
    let installedContents = installed.appending(path: "Contents")
    let stagedContents = staged.appending(path: "Contents")
    guard renameatx_np(
      AT_FDCWD, installedContents.path, AT_FDCWD, stagedContents.path,
      UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)) == 0 else {
      throw Failure.filesystem("atomic exchange", errno)
    }
  }

  private static func entries(_ root: URL) throws -> [Entry] {
    try requireDirectory(root)
    // Foundation enumerates resolved paths (notably /var -> /private/var).
    // The prefix and enumerated entries must use the same filesystem identity.
    guard let resolvedRoot = realpath(root.path, nil) else { throw Failure.filesystem("resolve inventory root", errno) }
    defer { free(resolvedRoot) }
    let canonicalRoot = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
    let prefix = canonicalRoot.path + "/"
    let fileManager = FileManager.default
    var enumerationError: Error?
    guard let iterator = fileManager.enumerator(
      at: canonicalRoot, includingPropertiesForKeys: nil, errorHandler: { _, error in
        enumerationError = error
        return false
      }) else {
      throw Failure.invalid("directory inventory")
    }
    var result: [Entry] = []
    var total: UInt64 = 0
    for case let url as URL in iterator {
      try Task.checkCancellation()
      guard url.path.hasPrefix(prefix) else { throw Failure.invalid("inventory root") }
      let path = String(url.path.dropFirst(prefix.count))
      var info = stat()
      guard result.count < 32_768, path.utf8.count <= 1024,
        lstat(url.path, &info) == 0, info.st_uid == getuid(),
        info.st_mode & 0o6000 == 0 else { throw Failure.invalid("entry \(path)") }
      let type: String, content: String
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        type = "directory"; content = ""
      case S_IFLNK:
        type = "symlink"
        content = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        let resolved = url.deletingLastPathComponent().appending(path: content)
          .resolvingSymlinksInPath().standardizedFileURL.path
        guard !content.hasPrefix("/"), resolved.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
          throw Failure.invalid("escaping link \(path)")
        }
      case S_IFREG:
        guard info.st_size >= 0, UInt64(info.st_size) <= maximumBytes - total else {
          throw Failure.invalid("tree size")
        }
        total += UInt64(info.st_size)
        let handle = try openRead(url)
        defer { try? handle.close() }
        type = "file"; content = try transfer(handle, count: UInt64(info.st_size), to: nil)
      default: throw Failure.invalid("file type \(path)")
      }
      result.append(.init(path: path, type: type, mode: UInt16(info.st_mode & 0o7777), content: content))
    }
    if let enumerationError { throw enumerationError }
    return result.sorted { $0.path < $1.path }
  }

  private static func clone(_ base: URL, to output: URL) throws {
    let fileManager = FileManager.default
    for entry in try entries(base) {
      try Task.checkCancellation()
      let source = base.appending(path: entry.path), destination = output.appending(path: entry.path)
      switch entry.type {
      case "directory":
        try fileManager.createDirectory(
          at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      case "symlink":
        try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: entry.content)
      default:
        let handle = try openRead(source)
        defer { try? handle.close() }
        guard fclonefileat(handle.fileDescriptor, AT_FDCWD, destination.path, 0) == 0 else {
          throw Failure.filesystem("APFS clone", errno)
        }
        // Keep immutable file modes. rsync replaces changed files through its
        // temporary-file path; unchanged clones retain their original blocks.
      }
    }
  }

  private static func read(_ delta: URL, extracting batch: URL?) throws -> Header {
    let handle = try openRead(delta)
    defer { try? handle.close() }
    guard try handle.read(upToCount: magic.count) == magic,
      let lengthData = try handle.read(upToCount: 4), lengthData.count == 4 else {
      throw Failure.invalid("framing")
    }
    let length = lengthData.reduce(0) { ($0 << 8) | Int($1) }
    guard (1...1024).contains(length), let data = try handle.read(upToCount: length),
      data.count == length, let header = try? JSONDecoder().decode(Header.self, from: data),
      try encode(header) == data, header.batchBytes > 0, header.batchBytes <= maximumBytes,
      [header.baseSHA256, header.targetSHA256, header.batchSHA256].allSatisfy({ value in
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      }) else { throw Failure.invalid("header") }
    let destination = try batch.map(createFile)
    defer { try? destination?.close() }
    guard try transfer(handle, count: header.batchBytes, to: destination) == header.batchSHA256 else {
      throw Failure.invalid("batch hash")
    }
    try destination?.synchronize()
    return header
  }

  private static func transfer(_ input: FileHandle, count: UInt64, to output: FileHandle?) throws -> String {
    guard count <= maximumBytes else { throw Failure.invalid("payload size") }
    var remaining = count, hasher = SHA256()
    while remaining > 0 {
      try Task.checkCancellation()
      guard let chunk = try input.read(upToCount: Int(min(1_048_576, remaining))), !chunk.isEmpty else {
        throw Failure.invalid("truncated payload")
      }
      hasher.update(data: chunk)
      try output?.write(contentsOf: chunk)
      remaining -= UInt64(chunk.count)
    }
    guard try input.read(upToCount: 1)?.isEmpty != false else { throw Failure.invalid("trailing bytes") }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func openRead(_ url: URL) throws -> FileHandle {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Failure.filesystem("read", errno) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      close(descriptor)
      throw Failure.invalid("regular file")
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private static func createFile(_ url: URL) throws -> FileHandle {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw Failure.filesystem("create", errno) }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private static func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
      throw Failure.invalid("owned directory")
    }
  }

  private static func scratch(beside output: URL) throws -> URL {
    let parent = output.deletingLastPathComponent()
    try requireDirectory(parent)
    let directory = parent.appending(path: ".linnet-delta-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }

  private static func rsync(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
    process.arguments = rsyncOptions + arguments
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    try Task.checkCancellation()
    try process.run()
    let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000_000
    while completion.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
      if Task.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadline {
        process.terminate()
        process.waitUntilExit()
        try Task.checkCancellation()
        throw Failure.invalid("rsync deadline")
      }
    }
    guard process.terminationStatus == 0 else { throw Failure.invalid("rsync batch reconstruction") }
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
