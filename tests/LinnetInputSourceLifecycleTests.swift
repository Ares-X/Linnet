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

private func expectRegistrationRequirement(
  _ expected: Bool,
  inputSourceCount: Int,
  intent: SquirrelInstaller.RegistrationIntent,
  _ label: String
) {
  do {
    let actual = try SquirrelInstaller.registrationRequired(
      inputSourceCount: inputSourceCount,
      intent: intent,
      identifier: SquirrelApp.bundleIdentifier)
    guard actual == expected else {
      fputs("LinnetInputSourceLifecycleTests: \(label); got \(actual)\n", stderr)
      exit(1)
    }
  } catch {
    fputs("LinnetInputSourceLifecycleTests: \(label); unexpected \(error)\n", stderr)
    exit(1)
  }
}

private func expectDuplicateRegistrationRejected() {
  do {
    _ = try SquirrelInstaller.registrationRequired(
      inputSourceCount: 2,
      intent: .ensurePresent,
      identifier: SquirrelApp.bundleIdentifier)
    fputs("LinnetInputSourceLifecycleTests: duplicate registration was accepted\n", stderr)
    exit(1)
  } catch SquirrelInstaller.Failure.inputSourceCountMismatch(let identifier, let count) {
    guard identifier == SquirrelApp.bundleIdentifier, count == 2 else {
      fputs("LinnetInputSourceLifecycleTests: wrong duplicate registration failure\n", stderr)
      exit(1)
    }
  } catch {
    fputs("LinnetInputSourceLifecycleTests: wrong duplicate registration error\n", stderr)
    exit(1)
  }
}

private func expectRegistrationStateRejected(
  inputSourceCount: Int,
  intent: SquirrelInstaller.RegistrationIntent,
  _ label: String
) {
  do {
    _ = try SquirrelInstaller.registrationRequired(
      inputSourceCount: inputSourceCount,
      intent: intent,
      identifier: SquirrelApp.bundleIdentifier)
    fputs("LinnetInputSourceLifecycleTests: \(label) was accepted\n", stderr)
    exit(1)
  } catch SquirrelInstaller.Failure.registrationStateMismatch(
    let identifier, let actualIntent, let count
  ) {
    guard identifier == SquirrelApp.bundleIdentifier,
      actualIntent == intent, count == inputSourceCount
    else {
      fputs("LinnetInputSourceLifecycleTests: wrong registration-state failure\n", stderr)
      exit(1)
    }
  } catch {
    fputs("LinnetInputSourceLifecycleTests: \(label); wrong \(error)\n", stderr)
    exit(1)
  }
}

private func expectCoreUpdatePlanMatrix() {
  typealias Transition = CoreIdentityTransition
  typealias Registration = SquirrelInstaller.RegistrationIntent
  typealias Enable = SquirrelInstaller.CoreUpdateEnableIntent

  let rows: [(Transition, PriorEnablement, Registration?, Enable?, String)] = [
    (.sameCommunityCMSLeaf, .enabled, .preservePresent, .preserve,
      "re-enabled an unchanged community CMS identity"),
    (.sameCommunityCMSLeaf, .disabled, .preservePresent, .preserve,
      "enabled an unchanged source that the user disabled"),
    (.sameCommunityCMSLeaf, .unregistered, .preserveAbsent, .preserve,
      "registered an unchanged identity that the user had removed"),
    (.legacyCommunityAdhocToCMS, .enabled, .preservePresent, .reassert,
      "did not reassert a previously enabled source across the ad-hoc to CMS transition"),
    (.legacyCommunityAdhocToCMS, .disabled, .preservePresent, .preserve,
      "enabled a transitioned source that the user disabled"),
    (.legacyCommunityAdhocToCMS, .unregistered, .preserveAbsent, .preserve,
      "registered a transitioned identity that the user had removed"),
    (.missingAppInstall, .enabled, nil, nil,
      "accepted a missing App with stale enabled registration"),
    (.missingAppInstall, .disabled, nil, nil,
      "accepted a missing App with stale disabled registration"),
    (.missingAppInstall, .unregistered, .ensurePresent, .preserve,
      "enabled a repaired source without prior user intent"),
  ]

  var registrationCount = 0
  var reassertionCount = 0
  for (transition, priorEnablement, expectedRegistration, expectedEnable, label) in rows {
    let actual = SquirrelInstaller.coreUpdatePlan(
      identityTransition: transition,
      priorEnablement: priorEnablement,
      wasCurrent: priorEnablement == .enabled)
    guard actual?.registrationIntent == expectedRegistration,
      actual?.enableIntent == expectedEnable
    else {
      fputs(
        "LinnetInputSourceLifecycleTests: \(label); got \(String(describing: actual))\n",
        stderr)
      exit(1)
    }
    if actual?.registrationIntent == .ensurePresent { registrationCount += 1 }
    if actual?.enableIntent == .reassert {
      reassertionCount += 1
    }
  }

  guard registrationCount == 1 else {
    fputs(
      "LinnetInputSourceLifecycleTests: Core update has \(registrationCount) registration paths\n",
      stderr)
    exit(1)
  }
  // The pre-update observation owns user intent. A post-replacement TIS cache
  // may still report enabled, so this single reassert intent must reach the one
  // enable mutation owner instead of being suppressed by cached state.
  guard reassertionCount == 1 else {
    fputs(
      "LinnetInputSourceLifecycleTests: Core update has \(reassertionCount) enable reassertion paths\n",
      stderr)
    exit(1)
  }

  guard SquirrelInstaller.coreUpdatePlan(
    identityTransition: .sameCommunityCMSLeaf,
    priorEnablement: .unregistered,
    wasCurrent: true) == nil
  else {
    fputs(
      "LinnetInputSourceLifecycleTests: accepted an unregistered current input source\n",
      stderr)
    exit(1)
  }
}

private func expectCoreUpdateRawValueClosure() {
  typealias Transition = CoreIdentityTransition
  let transitionValues = [
    "legacy-community-adhoc-to-cms", "missing-app-install", "same-community-cms-leaf",
  ]
  let priorValues = ["disabled", "enabled", "unregistered"]
  let parsedTransitions = transitionValues.compactMap(Transition.init(rawValue:))
  let parsedPrior = priorValues.compactMap(PriorEnablement.init(rawValue:))
  guard parsedTransitions.map(\.rawValue).sorted() == transitionValues.sorted(),
    parsedPrior.map(\.rawValue).sorted() == priorValues.sorted(),
    Transition(rawValue: "unknown-transition") == nil,
    PriorEnablement(rawValue: "unknown-enablement") == nil
  else {
    fputs("LinnetInputSourceLifecycleTests: typed Core wire values are not closed\n", stderr)
    exit(1)
  }
}

@main
struct LinnetInputSourceLifecycleTests {
  static func main() {
    let fallback = "com.apple.keylayout.ABC"
    let unicodeHex = "com.apple.keylayout.UnicodeHexInput"
    let hallelujah = "github.dongyuwei.inputmethod.hallelujahInputMethod"
    expectRegistrationRequirement(true, inputSourceCount: 0, intent: .ensurePresent,
      "did not register a genuinely missing input source")
    // After a missing App payload is restored, macOS may already enumerate it
    // before the explicit registration boundary runs. Ensure-present is
    // intentionally idempotent for that legal post-payload state.
    expectRegistrationRequirement(false, inputSourceCount: 1, intent: .ensurePresent,
      "re-registered an input source already discovered after payload activation")
    expectRegistrationRequirement(false, inputSourceCount: 1, intent: .preservePresent,
      "re-registered a preserved input source")
    expectRegistrationRequirement(false, inputSourceCount: 0, intent: .preserveAbsent,
      "registered a source whose absent state must be preserved")
    expectRegistrationStateRejected(inputSourceCount: 0, intent: .preservePresent,
      "a registered source disappeared during Core replacement")
    expectRegistrationStateRejected(inputSourceCount: 1, intent: .preserveAbsent,
      "an unregistered source appeared during Core replacement")
    expectDuplicateRegistrationRejected()
    expectCoreUpdateRawValueClosure()
    expectCoreUpdatePlanMatrix()
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
