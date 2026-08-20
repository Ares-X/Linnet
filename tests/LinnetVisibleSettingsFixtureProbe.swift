import Darwin
import Foundation

@main
struct LinnetVisibleSettingsFixtureProbe {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 4 else { throw Failure.usage }

      let settingsURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
        .standardizedFileURL
      let expectedHome = URL(fileURLWithPath: arguments[1], isDirectory: true)
      let expectedSettingsIdentifier = arguments[2]
      let expectedHostIdentifier = arguments[3]
      let expectedRoot = expectedHome.appendingPathComponent(
        "Library/Application Support/Linnet", isDirectory: true)
      guard let settings = Bundle(url: settingsURL),
        settings.bundleIdentifier == expectedSettingsIdentifier,
        let settingsExecutable = settings.executableURL,
        FileManager.default.isExecutableFile(atPath: settingsExecutable.path),
        let host = LinnetSettingsContract.hostBundle(startingAt: settings),
        host.bundleIdentifier == expectedHostIdentifier,
        host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Linnet",
        host.bundleURL.standardizedFileURL
          == settingsURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL,
        let registry = LinnetSettingsContract.dataRegistry(startingAt: settings)
      else { throw Failure.invalidBundle }

      guard sameFile(registry.rootDirectory, expectedRoot)
      else {
        throw Failure.escapedFixedHome(
          actual: registry.rootDirectory.path, expected: expectedRoot.path)
      }

      let snapshot = try registry.runtimeSnapshot()
      guard sameFile(snapshot.rootDirectory, expectedRoot),
        sameFile(
          registry.userDataDirectory,
          expectedRoot.appendingPathComponent("UserData", isDirectory: true)),
        sameFile(
          snapshot.sharedDataDirectory,
          expectedRoot.appendingPathComponent("Runtime/Active", isDirectory: true)),
        snapshot.state.edition == .full,
        snapshot.state.packs.map(\.kind) == [.chinese, .english, .lts, .extended],
        snapshot.state.packs.allSatisfy({ !$0.version.isEmpty && $0.sequence > 0 }),
        snapshot.activeRevision.generation > 0,
        snapshot.activeRevision.stateSHA256.count == 64
      else { throw Failure.invalidSnapshot }

      print("Visible Settings fixed-home fixture: PASS")
      print("host=\(host.bundleURL.path)")
      print("settings=\(settingsURL.path)")
      print("runtime=\(snapshot.sharedDataDirectory.path)")
      print("edition=\(snapshot.state.edition.rawValue)")
      let packs = snapshot.state.packs.map {
        "\($0.kind.rawValue):\($0.version)#\($0.sequence)"
      }.joined(separator: ",")
      print("packs=\(packs)")
    } catch {
      FileHandle.standardError.write(
        Data("Visible Settings fixture probe failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private enum Failure: Error {
    case usage
    case invalidBundle
    case escapedFixedHome(actual: String, expected: String)
    case invalidSnapshot
  }

  private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    var left = stat()
    var right = stat()
    return lstat(lhs.path, &left) == 0
      && lstat(rhs.path, &right) == 0
      && left.st_dev == right.st_dev && left.st_ino == right.st_ino
  }
}
