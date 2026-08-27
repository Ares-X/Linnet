import Foundation

enum SquirrelApp {
  static let bundleIdentifier = "io.github.ares-x.inputmethod.Linnet"
  static let appDir = URL(fileURLWithPath: "/tmp/Linnet.app", isDirectory: true)
}

@main
struct LinnetInputSourceLifecycleTests {
  static func main() {
    let identifier = SquirrelApp.bundleIdentifier
    let home = URL(fileURLWithPath: "/Users/linnet-fixture", isDirectory: true)
    let installed = home.appending(
      path: "Library/Input Methods/Linnet.app", directoryHint: .isDirectory)
    let cachedBuild = home.appending(
      path: "Library/Caches/build/Debug/Linnet.app", directoryHint: .isDirectory)
    guard SquirrelInstaller.hostMayStartRuntime(
      bundleURL: installed, homeDirectory: home)
    else { fatalError("the canonical installed Host was rejected") }
    guard !SquirrelInstaller.hostMayStartRuntime(
      bundleURL: cachedBuild, homeDirectory: home)
    else { fatalError("a cached development Host could access the production runtime") }
    do {
      guard try SquirrelInstaller.registrationRequired(
        inputSourceCount: 0, identifier: identifier)
      else { fatalError("missing source was not registered") }
      guard try !SquirrelInstaller.registrationRequired(
        inputSourceCount: 1, identifier: identifier)
      else { fatalError("existing source was re-registered") }
      _ = try SquirrelInstaller.registrationRequired(
        inputSourceCount: 2, identifier: identifier)
      fatalError("duplicate sources were accepted")
    } catch SquirrelInstaller.Failure.inputSourceCountMismatch(
      let actualIdentifier, let count
    ) {
      guard actualIdentifier == identifier, count == 2 else {
        fatalError("duplicate-source failure lost its identity")
      }
    } catch {
      fatalError("unexpected registration failure: \(error)")
    }
    print("LinnetInputSourceLifecycleTests: PASS")
  }
}
