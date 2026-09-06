import Darwin
import Foundation

extension LinnetPackTests {
  static func directoryDeltaRoundTrip() throws {
    try applicationPublicationPreservesDirectoryIdentity()
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
    precondition(chmod(base.appending(path: "nested").path, 0o755) == 0)
    try expectDeltaFailure {
      try LinnetDirectoryDelta.apply(base: base, delta: delta, output: restored)
    }
    precondition(!fileManager.fileExists(atPath: restored.path))
    precondition(chmod(base.appending(path: "nested").path, 0o555) == 0)
    try LinnetDirectoryDelta.apply(base: base, delta: delta, output: restored)
    let restoredDigest = try LinnetDirectoryDelta.digest(restored)
    let baseAfter = try LinnetDirectoryDelta.digest(base)
    precondition(restoredDigest == targetDigest && baseAfter == originalDigest)
    let targetState = try LinnetDirectoryDelta.state(base: restored, delta: delta)
    precondition(targetState == .target)
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

  private static func applicationPublicationPreservesDirectoryIdentity() throws {
    let root = LinnetTestScratch.directory.appending(path: "app-delta-\(UUID().uuidString)")
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }
    let installed = root.appending(path: "Installed.app", directoryHint: .isDirectory)
    let candidate = root.appending(path: "Candidate.app", directoryHint: .isDirectory)
    let staged = root.appending(path: "Staged.app", directoryHint: .isDirectory)
    for (app, contents) in [(installed, "old"), (candidate, "new")] {
      try manager.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: app.appending(path: "Contents/payload"))
    }
    let delta = root.appending(path: "core.linnetdelta")
    try LinnetDirectoryDelta.build(base: installed, target: candidate, output: delta)
    try LinnetDirectoryDelta.apply(base: installed, delta: delta, output: staged)
    var before = stat()
    precondition(lstat(installed.path, &before) == 0)
    let bookmark = try installed.bookmarkData(options: .minimalBookmark)
    let baseDigest = try LinnetDirectoryDelta.digest(installed)
    let targetDigest = try LinnetDirectoryDelta.digest(candidate)
    let finderMetadata = installed.appending(path: ".DS_Store")
    try Data("local Finder view".utf8).write(to: finderMetadata)
    let digestWithFinderMetadata = try LinnetDirectoryDelta.digest(installed)
    precondition(digestWithFinderMetadata == baseDigest,
      "Finder metadata changed the published payload identity")
    for expectedContents in ["new", "old"] {
      if expectedContents == "new" {
        try LinnetDirectoryDelta.exchangeApp(installed: installed, staged: staged, delta: delta)
      } else {
        try LinnetDirectoryDelta.exchangeApp(installed: installed, staged: staged,
          baseSHA256: baseDigest, targetSHA256: targetDigest)
      }
      let payload = try Data(contentsOf: installed.appending(path: "Contents/payload"))
      precondition(payload == Data(expectedContents.utf8), "App publication did not exchange exact contents")
      let keptMetadata = try Data(contentsOf: finderMetadata)
      precondition(keptMetadata == Data("local Finder view".utf8),
        "update or rollback moved the registered folder's Finder metadata")
      var after = stat()
      precondition(lstat(installed.path, &after) == 0)
      guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
        LinnetTestFailure.fail("Core publication replaced the registered App directory identity")
      }
      var stale = false
      let resolved = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
        bookmarkDataIsStale: &stale)
      guard resolved.standardizedFileURL == installed.standardizedFileURL else {
        LinnetTestFailure.fail("Core publication moved the existing App bookmark into staging")
      }
    }
    let completePayload = root.appending(path: "Linnet.payload", directoryHint: .isDirectory)
    try manager.copyItem(at: candidate, to: completePayload)
    try LinnetDirectoryDelta.exchangeApp(installed: installed, staged: completePayload,
      baseSHA256: baseDigest, targetSHA256: targetDigest)
    let completeContents = try Data(contentsOf: installed.appending(path: "Contents/payload"))
    precondition(completeContents == Data("new".utf8),
      "opaque Complete payload did not publish its exact contents")
    try LinnetDirectoryDelta.exchangeApp(installed: installed, staged: completePayload,
      baseSHA256: baseDigest, targetSHA256: targetDigest)
    let unexpected = installed.appending(path: "outside-Contents")
    try Data("invalid App layout".utf8).write(to: unexpected)
    let invalidDigest = try LinnetDirectoryDelta.digest(installed)
    try expectDeltaFailure {
      try LinnetDirectoryDelta.exchangeApp(installed: installed, staged: staged,
        baseSHA256: invalidDigest, targetSHA256: targetDigest)
    }
    let afterRejection = try LinnetDirectoryDelta.digest(installed)
    precondition(afterRejection == invalidDigest, "rejected App layout was mutated")
    print("Core publication: stable App inode and bookmark across update/rollback")
  }

  private static func expectDeltaFailure(_ operation: () throws -> Void) throws {
    do {
      try operation()
      preconditionFailure("invalid delta was accepted")
    } catch is LinnetDirectoryDelta.Failure { }
  }
}
