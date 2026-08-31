import Darwin
import Foundation

extension LinnetPackTests {
  static func directoryDeltaRoundTrip() throws {
    let root = LinnetTestScratch.directory.appending(path: "directory-delta-\(UUID().uuidString)")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: root) }
    let base = root.appending(path: "base", directoryHint: .isDirectory)
    let target = root.appending(path: "target", directoryHint: .isDirectory)
    let restored = root.appending(path: "restored", directoryHint: .isDirectory)
    for directory in [base, target] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let original = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 251) })
    var changed = original
    changed.replaceSubrange(32_768..<32_832, with: Data(repeating: 254, count: 64))
    try original.write(to: base.appending(path: "dictionary.bin"))
    try changed.write(to: target.appending(path: "dictionary.bin"))
    for directory in [base, target] {
      try Data("same".utf8).write(to: directory.appending(path: "unchanged.txt"))
      try fileManager.createSymbolicLink(
        atPath: directory.appending(path: "relative-link").path,
        withDestinationPath: "unchanged.txt")
    }
    try Data("delete".utf8).write(to: base.appending(path: "removed.txt"))
    try Data("add".utf8).write(to: target.appending(path: "added.txt"))
    for directory in [base, target] {
      let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
      try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)
      try Data("read-only".utf8).write(to: nested.appending(path: "stable.txt"))
      for path in ["dictionary.bin", "unchanged.txt", "nested/stable.txt"] {
        precondition(chmod(directory.appending(path: path).path, 0o444) == 0)
      }
      precondition(chmod(nested.path, 0o555) == 0)
    }
    let delta = root.appending(path: "update.linnetdelta")
    let originalDigest = try LinnetDirectoryDelta.digest(base)
    let targetDigest = try LinnetDirectoryDelta.digest(target)
    let alias = root.appending(path: "alias", directoryHint: .isDirectory)
    try fileManager.createSymbolicLink(at: alias, withDestinationURL: root)
    let aliasedDigest = try LinnetDirectoryDelta.digest(alias.appending(path: "base", directoryHint: .isDirectory))
    precondition(aliasedDigest == originalDigest, "parent path aliases must not enter the relative inventory")
    try LinnetDirectoryDelta.build(base: base, target: target, output: delta)
    let deltaBytes = try delta.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    precondition(deltaBytes < original.count / 10, "delta must not contain the full file")
    let baseState = try LinnetDirectoryDelta.state(base: base, delta: delta)
    precondition(baseState == .base)
    try LinnetDirectoryDelta.apply(base: base, delta: delta, output: restored)
    let restoredDigest = try LinnetDirectoryDelta.digest(restored)
    let baseAfter = try LinnetDirectoryDelta.digest(base)
    precondition(restoredDigest == targetDigest && baseAfter == originalDigest)
    let targetState = try LinnetDirectoryDelta.state(base: restored, delta: delta)
    precondition(targetState == .target)
    try LinnetDirectoryDelta.exchange(installed: base, staged: restored, delta: delta)
    let installedDigest = try LinnetDirectoryDelta.digest(base)
    precondition(installedDigest == targetDigest)
    try LinnetDirectoryDelta.exchange(installed: base, staged: restored, delta: delta)
    let rolledBackDigest = try LinnetDirectoryDelta.digest(base)
    precondition(rolledBackDigest == originalDigest)
    let modifiedClone = restored.appending(path: "unchanged.txt")
    precondition(chmod(modifiedClone.path, 0o644) == 0)
    try changed.write(to: modifiedClone)
    let isolatedBaseDigest = try LinnetDirectoryDelta.digest(base)
    precondition(isolatedBaseDigest == originalDigest, "COW must not mutate original blocks")
    try expectDeltaFailure {
      _ = try LinnetDirectoryDelta.state(base: restored, delta: delta)
    }
    let corrupt = root.appending(path: "corrupt.linnetdelta")
    var bytes = try Data(contentsOf: delta)
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: corrupt)
    let rejected = root.appending(path: "rejected", directoryHint: .isDirectory)
    try expectDeltaFailure {
      try LinnetDirectoryDelta.apply(base: base, delta: corrupt, output: rejected)
    }
    precondition(!fileManager.fileExists(atPath: rejected.path))
    print("Directory delta: PASS (\(deltaBytes) bytes / \(original.count), exact modes/add/delete/link/COW/rollback/corruption)")
  }

  private static func expectDeltaFailure(_ operation: () throws -> Void) throws {
    do {
      try operation()
      preconditionFailure("invalid delta was accepted")
    } catch is LinnetDirectoryDelta.Failure { }
  }
}
