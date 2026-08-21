import Darwin
import Foundation

@main
struct LinnetCloudSyncLocationTests {
  static func main() {
    do {
      try withTemporaryDirectory { root in
        try testFolderBookmarkRoundTrip(root: root)
        try testNonDirectoryAndSymlinkAreRejected(root: root)
        try testCorruptBookmarkIsRejected()
      }
      print("LinnetCloudSyncLocationTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testFolderBookmarkRoundTrip(root: URL) throws {
    let folder = root.appending(component: "iCloud Drive", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

    let selected = try LinnetCloudSyncLocation.select(folder: folder)
    let restored = try LinnetCloudSyncLocation.resolve(bookmark: selected.bookmark)
    let learningDirectory = try restored.prepareLearningDirectory()
    guard restored.folder.standardizedFileURL == folder.resolvingSymlinksInPath(),
      learningDirectory.lastPathComponent == "Linnet-Rime-Sync",
      learningDirectory.hasDirectoryPath,
      restored.displayName == "iCloud Drive"
    else {
      fail("the selected sync folder did not survive its bookmark round trip")
    }
  }

  private static func testNonDirectoryAndSymlinkAreRejected(root: URL) throws {
    let file = root.appending(component: "not-a-folder", directoryHint: .notDirectory)
    try Data("x".utf8).write(to: file)
    expectFailure("a regular file was accepted as a sync folder") {
      _ = try LinnetCloudSyncLocation.select(folder: file)
    }

    let target = root.appending(component: "target", directoryHint: .isDirectory)
    let link = root.appending(component: "linked-folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    expectFailure("a symlink was accepted as the durable sync folder owner") {
      _ = try LinnetCloudSyncLocation.select(folder: link)
    }

    let selected = try LinnetCloudSyncLocation.select(folder: target)
    try FileManager.default.createSymbolicLink(
      at: selected.learningDirectory,
      withDestinationURL: root)
    expectFailure("a symlink was accepted as Rime's learning sync directory") {
      _ = try selected.prepareLearningDirectory()
    }
  }

  private static func testCorruptBookmarkIsRejected() throws {
    expectFailure("corrupt bookmark bytes resolved to a sync folder") {
      _ = try LinnetCloudSyncLocation.resolve(bookmark: Data("not-a-bookmark".utf8))
    }
  }

  private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    var template = Array("/tmp/linnet-cloud-sync.XXXXXX".utf8CString)
    guard let path = mkdtemp(&template) else { throw POSIXError(.EIO) }
    let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  private static func expectFailure(_ message: String, _ body: () throws -> Void) {
    do {
      try body()
      fail(message)
    } catch {}
  }
}

private func fail(_ message: String) -> Never {
  fputs("LinnetCloudSyncLocationTests: \(message)\n", stderr)
  exit(1)
}
