import Foundation

enum SquirrelApp {
  static let bundleIdentifier = "io.github.ares-x.inputmethod.Linnet"
  static let appDir = URL(fileURLWithPath: "/tmp/Linnet.app", isDirectory: true)
}

private func expectDesired(
  _ expected: String,
  wasCurrent: Bool,
  fallback: String,
  currentBefore: String,
  currentAfter: String,
  _ label: String
) {
  let actual = SquirrelInstaller.desiredInputSourceAfterCoreUpdate(
    wasCurrent: wasCurrent,
    postQuiescenceInputSourceID: fallback,
    currentBeforeQuiescence: currentBefore,
    currentAfterQuiescence: currentAfter,
    targetInputSourceID: SquirrelApp.bundleIdentifier)
  guard actual == expected else {
    fputs("LinnetInputSourceLifecycleTests: \(label); got \(actual)\n", stderr)
    exit(1)
  }
}

private func expectRestore(
  _ expected: String?,
  desired: String,
  beforeRegister: String,
  afterRegister: String,
  _ label: String
) {
  let actual = SquirrelInstaller.inputSourceToRestoreAfterRegistration(
    desiredInputSourceID: desired,
    preRegistrationInputSourceID: beforeRegister,
    postRegistrationInputSourceID: afterRegister,
    targetInputSourceID: SquirrelApp.bundleIdentifier)
  guard actual == expected else {
    fputs("LinnetInputSourceLifecycleTests: \(label); got \(actual ?? "nil")\n", stderr)
    exit(1)
  }
}

@main
struct LinnetInputSourceLifecycleTests {
  static func main() {
    let fallback = "com.apple.keylayout.ABC"
    let unicodeHex = "com.apple.keylayout.UnicodeHexInput"
    let hallelujah = "github.dongyuwei.inputmethod.hallelujahInputMethod"
    expectDesired(SquirrelApp.bundleIdentifier,
      wasCurrent: true, fallback: fallback,
      currentBefore: fallback, currentAfter: fallback,
      "lost a previously selected Linnet after its expected quiescence fallback")
    expectDesired(SquirrelApp.bundleIdentifier,
      wasCurrent: true, fallback: fallback,
      currentBefore: SquirrelApp.bundleIdentifier, currentAfter: fallback,
      "lost an already restored Linnet")
    expectDesired(hallelujah,
      wasCurrent: true, fallback: fallback,
      currentBefore: hallelujah, currentAfter: hallelujah,
      "overrode a newer non-Linnet selection")
    expectDesired(hallelujah,
      wasCurrent: true, fallback: fallback,
      currentBefore: fallback, currentAfter: hallelujah,
      "overrode a non-Linnet selection made during Host quiescence")
    expectDesired(hallelujah,
      wasCurrent: false, fallback: fallback,
      currentBefore: SquirrelApp.bundleIdentifier, currentAfter: hallelujah,
      "overrode a non-Linnet selection made while quitting a newly selected Linnet")
    expectDesired(unicodeHex,
      wasCurrent: false, fallback: fallback,
      currentBefore: unicodeHex, currentAfter: unicodeHex,
      "selected Linnet when it was never current")
    expectDesired(fallback,
      wasCurrent: false, fallback: fallback,
      currentBefore: fallback, currentAfter: fallback,
      "restored Linnet from a matching fallback without prior selection")
    expectDesired(SquirrelApp.bundleIdentifier,
      wasCurrent: false, fallback: fallback,
      currentBefore: SquirrelApp.bundleIdentifier, currentAfter: fallback,
      "lost Linnet selected by the user during the Core update")
    expectDesired(hallelujah,
      wasCurrent: false, fallback: fallback,
      currentBefore: unicodeHex, currentAfter: hallelujah,
      "overrode a source selected during Host quiescence")

    expectRestore(unicodeHex, desired: unicodeHex,
      beforeRegister: unicodeHex, afterRegister: SquirrelApp.bundleIdentifier,
      "did not undo a registration-induced target selection")
    expectRestore(nil, desired: unicodeHex,
      beforeRegister: unicodeHex, afterRegister: unicodeHex,
      "selected an already-current non-target source")
    expectRestore(nil, desired: unicodeHex,
      beforeRegister: unicodeHex, afterRegister: hallelujah,
      "overrode a new non-target selection made during registration")
    expectRestore(nil, desired: SquirrelApp.bundleIdentifier,
      beforeRegister: fallback, afterRegister: hallelujah,
      "overrode a new non-target selection while restoring Linnet")
    expectRestore(nil, desired: SquirrelApp.bundleIdentifier,
      beforeRegister: SquirrelApp.bundleIdentifier, afterRegister: hallelujah,
      "reclaimed Linnet after the user selected another source")
    expectRestore(SquirrelApp.bundleIdentifier,
      desired: SquirrelApp.bundleIdentifier,
      beforeRegister: fallback, afterRegister: fallback,
      "did not restore a previously current Linnet after registration")
    expectRestore(nil, desired: SquirrelApp.bundleIdentifier,
      beforeRegister: fallback, afterRegister: SquirrelApp.bundleIdentifier,
      "reselected an already-current Linnet")
    print("LinnetInputSourceLifecycleTests: PASS")
  }
}
