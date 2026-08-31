import Darwin
import Foundation

@main
struct LinnetCloudSyncLocationTests {
  static func main() {
    do {
      try withTemporaryDirectory { root in
        try testProductLocation(root: root)
        try testUnavailableAndUnsafeCloudRootsAreRejected(root: root)
      }
      print("LinnetCloudSyncLocationTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testProductLocation(root: URL) throws {
    let library = root.appending(component: "Product", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
    let cloudDocuments = try makeCloudDocuments(in: library)
    let location = try LinnetCloudSyncLocation.productLocation(libraryDirectory: library)
    let learningDirectory = try location.prepareLearningDirectory()
    let expectedFolder = cloudDocuments.appending(component: "Linnet", directoryHint: .isDirectory)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard location.folder.standardizedFileURL
        == expectedFolder,
      learningDirectory.lastPathComponent == "Linnet-Rime-Sync",
      learningDirectory.hasDirectoryPath,
      location.displayName == "iCloud Drive/Linnet"
    else {
      print("actual=\(location.folder.absoluteString)")
      print("expected=\(expectedFolder.absoluteString)")
      print("learning=\(learningDirectory.absoluteString), directory=\(learningDirectory.hasDirectoryPath)")
      fail("the product-owned iCloud Drive location was not derived deterministically")
    }
  }

  private static func testUnavailableAndUnsafeCloudRootsAreRejected(root: URL) throws {
    let unavailableLibrary = root.appending(
      component: "Unavailable", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: unavailableLibrary, withIntermediateDirectories: false)
    expectFailure("a missing iCloud Drive root was accepted") {
      _ = try LinnetCloudSyncLocation.productLocation(
        libraryDirectory: unavailableLibrary)
    }

    let unsafeLibrary = root.appending(component: "Unsafe", directoryHint: .isDirectory)
    let target = root.appending(component: "CloudTarget", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unsafeLibrary, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let mobileDocuments = unsafeLibrary.appending(
      component: "Mobile Documents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mobileDocuments, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: mobileDocuments.appending(
        component: "com~apple~CloudDocs", directoryHint: .isDirectory),
      withDestinationURL: target)
    expectFailure("a symlink was accepted as the iCloud Drive root") {
      _ = try LinnetCloudSyncLocation.productLocation(libraryDirectory: unsafeLibrary)
    }

    let safeLibrary = root.appending(component: "Safe", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: safeLibrary, withIntermediateDirectories: false)
    _ = try makeCloudDocuments(in: safeLibrary)
    let location = try LinnetCloudSyncLocation.productLocation(libraryDirectory: safeLibrary)
    try FileManager.default.createSymbolicLink(
      at: location.learningDirectory,
      withDestinationURL: root)
    expectFailure("a symlink was accepted as Rime's learning sync directory") {
      _ = try location.prepareLearningDirectory()
    }
  }

  private static func makeCloudDocuments(in library: URL) throws -> URL {
    let directory = library
      .appending(component: "Mobile Documents", directoryHint: .isDirectory)
      .appending(component: "com~apple~CloudDocs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = LinnetTestScratch.directory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
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
