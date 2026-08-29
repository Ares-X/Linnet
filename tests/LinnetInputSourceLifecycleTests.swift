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
    let matchingSource = LinnetInputSourceRegistration.Source(
      identifier: identifier, bundleIdentifier: identifier)
    guard LinnetInputSourceRegistration.classify([], identifier: identifier) == .missing else {
      fatalError("zero matching sources did not classify as missing")
    }
    let registered = LinnetInputSourceRegistration.classify(
      [matchingSource], identifier: identifier)
    guard registered == .registered,
      registered.wireValue == "registered:bundle-match:path-unknown"
    else { fatalError("one matching source lost its typed identity/path evidence") }
    guard LinnetInputSourceRegistration.classify(
      [matchingSource, matchingSource], identifier: identifier) == .duplicate(count: 2)
    else { fatalError("duplicate sources were accepted") }
    guard LinnetInputSourceRegistration.classify([
      .init(identifier: identifier, bundleIdentifier: "invalid.example")
    ], identifier: identifier) == .conflictingIdentity else {
      fatalError("a conflicting registered bundle identity was accepted")
    }
    guard LinnetInputSourceRegistration.classify([
      .init(identifier: identifier, bundleIdentifier: nil)
    ], identifier: identifier) == .unknownBundleIdentifier else {
      fatalError("missing bundle identity was presented as verified")
    }
    guard LinnetInputSourceRegistration.classify([
      .init(identifier: "unrelated.example", bundleIdentifier: identifier)
    ], identifier: identifier) == .conflictingIdentity else {
      fatalError("a stale source ID sharing Linnet's bundle identity was ignored")
    }
    guard LinnetInputSourceRegistration.classify([
      matchingSource,
      .init(identifier: "stale.example", bundleIdentifier: identifier)
    ], identifier: identifier) == .conflictingIdentity else {
      fatalError("a valid source masked a conflicting bundle residue")
    }
    guard LinnetInputSourceRegistration.classify([
      .init(identifier: "unrelated.example", bundleIdentifier: "unrelated.example")
    ], identifier: identifier) == .missing else {
      fatalError("an unrelated input source became Linnet registration evidence")
    }
    print("LinnetInputSourceLifecycleTests: PASS")
  }
}
