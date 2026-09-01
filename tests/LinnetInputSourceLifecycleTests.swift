import Carbon
import Foundation

enum SquirrelApp {
  static let bundleIdentifier = "io.github.ares-x.inputmethod.Linnet"
  static let appDir = URL(fileURLWithPath: "/tmp/Linnet.app", isDirectory: true)
}

@main
struct LinnetInputSourceLifecycleTests {
  private static func source(
    identifier: String?,
    bundleIdentifier: String?,
    category: String? = kTISCategoryKeyboardInputSource as String,
    isEnableCapable: Bool? = true,
    isSelectCapable: Bool? = true,
    isEnabled: Bool? = true,
    isSelected: Bool? = false
  ) -> LinnetInputSourceRegistration.Source {
    .init(
      identifier: identifier,
      bundleIdentifier: bundleIdentifier,
      category: category,
      type: kTISTypeKeyboardInputMethodWithoutModes as String,
      isEnableCapable: isEnableCapable,
      isSelectCapable: isSelectCapable,
      isEnabled: isEnabled,
      isSelected: isSelected)
  }

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
    let matchingSource = source(identifier: identifier, bundleIdentifier: identifier)
    guard LinnetInputSourceRegistration.classify([], identifier: identifier) == .missing else {
      fatalError("zero matching sources did not classify as missing")
    }
    let enabledObservation = LinnetInputSourceRegistration.classify(
      [matchingSource], identifier: identifier)
    guard enabledObservation == .enabledObservation,
      enabledObservation.wireValue ==
        "registered:enabled-observation:selectable:path-unknown"
    else { fatalError("one enabled source was not retained as an observation") }
    let disabledSource = source(
      identifier: identifier,
      bundleIdentifier: identifier,
      isEnabled: false)
    let enablementRequired = LinnetInputSourceRegistration.classify(
      [disabledSource], identifier: identifier)
    guard enablementRequired == .enablementRequired,
      enablementRequired.wireValue == "registered:enablement-required:path-unknown"
    else { fatalError("a registered source lost its user-enablement requirement") }
    let selectedSource = source(
      identifier: identifier,
      bundleIdentifier: identifier,
      isSelected: true)
    guard LinnetInputSourceRegistration.classify(
      [selectedSource], identifier: identifier) == .selectedObservation
    else { fatalError("the current Linnet source was not retained as an observation") }
    guard LinnetInputSourceRegistration.classify([
      source(identifier: identifier, bundleIdentifier: identifier, category: "invalid")
    ], identifier: identifier) == .conflictingKind else {
      fatalError("a non-keyboard source kind was presented as Linnet")
    }
    guard LinnetInputSourceRegistration.classify([
      source(identifier: identifier, bundleIdentifier: identifier, isSelectCapable: false)
    ], identifier: identifier) == .unavailableCapabilities else {
      fatalError("an unselectable source was presented as available")
    }
    guard LinnetInputSourceRegistration.classify([
      source(identifier: identifier, bundleIdentifier: identifier, isEnabled: nil)
    ], identifier: identifier) == .unknownAvailability else {
      fatalError("missing TIS availability properties were accepted")
    }
    guard LinnetInputSourceRegistration.classify(
      [matchingSource, matchingSource], identifier: identifier) == .duplicate(count: 2)
    else { fatalError("duplicate sources were accepted") }
    guard LinnetInputSourceRegistration.classify([
      source(identifier: identifier, bundleIdentifier: "invalid.example")
    ], identifier: identifier) == .conflictingIdentity else {
      fatalError("a conflicting registered bundle identity was accepted")
    }
    guard LinnetInputSourceRegistration.classify([
      source(identifier: identifier, bundleIdentifier: nil)
    ], identifier: identifier) == .unknownBundleIdentifier else {
      fatalError("missing bundle identity was presented as verified")
    }
    guard LinnetInputSourceRegistration.classify([
      source(identifier: "unrelated.example", bundleIdentifier: identifier)
    ], identifier: identifier) == .conflictingIdentity else {
      fatalError("a stale source ID sharing Linnet's bundle identity was ignored")
    }
    guard LinnetInputSourceRegistration.classify([
      matchingSource,
      source(identifier: "stale.example", bundleIdentifier: identifier)
    ], identifier: identifier) == .conflictingIdentity else {
      fatalError("a valid source masked a conflicting bundle residue")
    }
    guard LinnetInputSourceRegistration.classify([
      source(identifier: "unrelated.example", bundleIdentifier: "unrelated.example")
    ], identifier: identifier) == .missing else {
      fatalError("an unrelated input source became Linnet registration evidence")
    }
    print("LinnetInputSourceLifecycleTests: PASS")
  }
}
