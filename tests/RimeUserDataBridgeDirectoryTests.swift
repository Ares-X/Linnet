import Darwin
import Foundation

@main
struct RimeUserDataBridgeDirectoryTests {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "RimeUserDataBridgeDirectoryTests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try makeDirectory(root)
    let bridge = RimeUserDataBridge()
    let product = "LinnetDirectoryTests"

    let empty = root.appending(path: "empty", directoryHint: .isDirectory)
    try makeDirectory(empty)
    let preparedEmpty = try bridge.prepareLegacyDirectory(
      empty, shared: root, product: product)
    guard preparedEmpty.recognizedDictionaryCount == 0 else {
      fail("empty legacy directory reported importable dictionaries")
    }
    try RimeUserDataBridge.validatePreparedUserDirectory(preparedEmpty)

    let legal = root.appending(path: "legal", directoryHint: .isDirectory)
    try makeDirectory(legal)
    try seedDictionary("rime_ice", row: "你好\tni hao\t7", directory: legal, root: root)
    try seedDictionary("melt_eng", row: "hello\thello\t6", directory: legal, root: root)
    let preparedLegal = try bridge.prepareLegacyDirectory(
      legal, shared: root, product: product)
    guard preparedLegal.recognizedDictionaryCount == 2 else {
      fail("logical Rime dictionaries were not recognized through Levers")
    }
    try RimeUserDataBridge.validatePreparedUserDirectory(preparedLegal)

    let overflow = root.appending(path: "overflow", directoryHint: .isDirectory)
    try makeDirectory(overflow)
    for index in 0...LinnetBackupStore.maximumLiveDirectoryEntries {
      FileManager.default.createFile(
        atPath: overflow.appending(path: "entry-\(index)").path,
        contents: Data())
    }
    expectFailure {
      _ = try bridge.prepareLegacyDirectory(overflow, shared: root, product: product)
    }

    let linked = root.appending(path: "linked", directoryHint: .isDirectory)
    try makeDirectory(linked)
    try FileManager.default.createSymbolicLink(
      at: linked.appending(path: "rime_ice.userdb"),
      withDestinationURL: legal.appending(path: "rime_ice.userdb"))
    expectFailure {
      _ = try bridge.prepareLegacyDirectory(linked, shared: root, product: product)
    }

    let replaced = root.appending(path: "replaced", directoryHint: .isDirectory)
    try makeDirectory(replaced)
    let preparedReplaced = try bridge.prepareLegacyDirectory(
      replaced, shared: root, product: product)
    try FileManager.default.removeItem(at: replaced)
    try makeDirectory(replaced)
    expectFailure {
      try RimeUserDataBridge.validatePreparedUserDirectory(preparedReplaced)
    }
    print("RimeUserDataBridgeDirectoryTests: PASS")
  }

  private static func seedDictionary(
    _ name: String,
    row: String,
    directory: URL,
    root: URL
  ) throws {
    let source = root.appending(path: "seed-\(name).txt")
    try "# Rime user dictionary export\n\(row)\n".write(
      to: source,
      atomically: true,
      encoding: .utf8
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "bin/rime_dict_manager")
    process.arguments = ["--import", name, source.path]
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      fail("could not seed logical Rime dictionary \(name)")
    }
  }

  private static func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  private static func expectFailure(_ body: () throws -> Void) {
    do {
      try body()
      fail("unsafe user-dictionary directory was accepted")
    } catch is RimeUserDataBridge.Failure {
      return
    } catch {
      fail("unexpected failure: \(error)")
    }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
      Data("RimeUserDataBridgeDirectoryTests: FAIL: \(message)\n".utf8))
    _Exit(EXIT_FAILURE)
  }
}
