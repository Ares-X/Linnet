import AppKit
import Carbon
import Foundation

@main
struct MacOSKeyCodesTests {
  private struct ExpectedModifierEvent {
    let keycode: UInt32
    let modifiers: UInt32
  }

  static func main() {
    verifyModifierTransitionState()
    verifyComposingKeypadEquivalents()
    verifyInputDispatchAuthority()
    verifyPerControllerClientOwnership()
    verifyModifierEpochLifecycle()
    verifyDelayedCallbackSessionOwnership()
    require(
      SquirrelKeycode.osxKeycodeToRime(
        keycode: UInt16(kVK_LeftArrow), keychar: nil, shift: false, caps: false)
        == UInt32(XK_Left),
      "a physical arrow with no characters was dropped"
    )
    require(
      SquirrelKeycode.osxKeycodeToRime(
        keycode: UInt16(kVK_UpArrow), keychar: nil, shift: false, caps: false)
        == UInt32(XK_Up),
      "a second physical arrow with no characters was dropped"
    )
    require(
      SquirrelKeycode.osxKeycodeToRime(
        keycode: UInt16(kVK_ANSI_A), keychar: nil, shift: false, caps: false)
        == UInt32(XK_VoidSymbol),
      "a characterless letter event was inferred from the physical QWERTY position"
    )
    require(
      SquirrelKeycode.osxKeycodeToRime(
        keycode: UInt16(kVK_ANSI_A), keychar: "a", shift: false, caps: false)
        == UInt32(XK_a),
      "an ordinary printable key stopped using its actual characters"
    )
    require(
      SquirrelKeycode.osxKeycodeToRime(
        keycode: UInt16(kVK_ANSI_KeypadEnter), keychar: nil, shift: false, caps: false)
        == UInt32(XK_Return),
      "keypad Enter did not share the ordinary Return contract"
    )
    print("MacOSKeyCodesTests: PASS")
  }
}

private extension MacOSKeyCodesTests {
  private static func verifyPerControllerClientOwnership() {
    let controller = controllerSource()
    let delegate = readSource("sources/SquirrelApplicationDelegate.swift")
    let presentation = readSource("sources/SquirrelApplicationPresentation.swift")
    let handle = section(
      in: controller,
      startingAt: "override func handle(",
      endingAt: "private func dispatchReadyEvent("
    )
    let activation = section(
      in: controller,
      startingAt: "override func activateServer",
      endingAt: "override init!"
    )
    let deactivation = section(
      in: controller,
      startingAt: "override func deactivateServer",
      endingAt: "override func hidePalettes()"
    )
    let candidatePublication = section(
      in: controller,
      startingAt: "private func showPanel(",
      endingAt: "\n}"
    )

    require(
      !controller.contains("LinnetInputActivationRegistry")
        && !delegate.contains("inputActivationRegistry")
        && !presentation.contains("beginInputActivation(")
        && !presentation.contains("finishInputActivation("),
      "a process-global registry still competes with InputMethodKit controller ownership"
    )
    require(
      activation.contains("activeClient = activatingClient")
        && !activation.contains("guard let activationToken")
        && !activation.contains("beginInputActivation("),
      "a native App activation can still be rejected by a process-global owner"
    )
    require(
      handle.contains("activeClient = senderClient")
        && controller.contains("guard let updateClient = activeClient")
        && deactivation.contains("activeClient = nil")
        && !controller.contains("client ===")
        && !controller.contains("=== expectedClient")
        && !controller.contains("=== targetClient")
        && !controller.contains("=== senderClient")
        && !controller.contains("=== activatingClient")
        && !controller.contains("=== deactivatingClient"),
      "an InputMethodKit proxy address still decides whether accepted input is published"
    )
    let eventBinding = candidatePublication.range(of: "panel.bind(controller: self)")?.lowerBound
    let publicationGuard = candidatePublication.range(
      of: "panel.inputController === self")?.lowerBound
    require(
      eventBinding != nil && publicationGuard != nil
        && eventBinding! < publicationGuard!,
      "candidate publication still depends on activateServer being replayed after a Host update"
    )
  }

  private static func verifyModifierTransitionState() {
    verifySingleShiftTransport(
      physicalKeycode: UInt16(kVK_Shift), rimeKeycode: UInt32(XK_Shift_L), name: "left")
    verifySingleShiftTransport(
      physicalKeycode: UInt16(kVK_RightShift), rimeKeycode: UInt32(XK_Shift_R), name: "right")
    verifyOverlappingShiftReleaseOrders()
    verifyCapsLockTransitions()
    verifyAmbiguousFlagsChangedFailsClosed()
    verifyAmbiguousSnapshotPreservesArmedShift()
    verifyActivationHeldShiftSuppressesOppositeTap()
    verifyActivationResetDropsUntrackedRelease()
  }

  private static func verifySingleShiftTransport(
    physicalKeycode: UInt16,
    rimeKeycode: UInt32,
    name: String
  ) {
    var tap = SquirrelModifierTransitionState(hardwareFlags: [])
    requireEvents(
      tap.transitions(keyCode: physicalKeycode, modifiers: [.shift]),
      [ExpectedModifierEvent(keycode: rimeKeycode, modifiers: kShiftMask.rawValue)],
      "\(name) Shift down was not transported exactly once"
    )
    requireEvents(
      tap.transitions(keyCode: physicalKeycode, modifiers: []),
      [ExpectedModifierEvent(keycode: rimeKeycode, modifiers: kReleaseMask.rawValue)],
      "\(name) Shift up was not transported exactly once"
    )

    // Duration and chord classification belong downstream. The transition owner
    // transports the same physical pair and ignores duplicate flags snapshots.
    var heldOrChorded = SquirrelModifierTransitionState(hardwareFlags: [])
    requireEvents(
      heldOrChorded.transitions(keyCode: physicalKeycode, modifiers: [.shift]),
      [ExpectedModifierEvent(keycode: rimeKeycode, modifiers: kShiftMask.rawValue)],
      "\(name) held/chorded Shift down was lost"
    )
    requireEvents(
      heldOrChorded.transitions(keyCode: physicalKeycode, modifiers: [.shift]),
      [],
      "a repeated physical \(name) Shift down snapshot was misclassified as release"
    )
    requireEvents(
      heldOrChorded.transitions(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift]),
      [],
      "an unchanged non-modifier flags snapshot duplicated \(name) Shift down"
    )
    requireEvents(
      heldOrChorded.transitions(keyCode: physicalKeycode, modifiers: []),
      [ExpectedModifierEvent(keycode: rimeKeycode, modifiers: kReleaseMask.rawValue)],
      "\(name) held/chorded Shift up was lost"
    )
  }

  private static func verifyOverlappingShiftReleaseOrders() {
    verifyOverlappingShifts(
      releases: [
        (UInt16(kVK_Shift), UInt32(XK_Shift_L)),
        (UInt16(kVK_RightShift), UInt32(XK_Shift_R))
      ],
      name: "left-then-right"
    )
    verifyOverlappingShifts(
      releases: [
        (UInt16(kVK_RightShift), UInt32(XK_Shift_R)),
        (UInt16(kVK_Shift), UInt32(XK_Shift_L))
      ],
      name: "right-then-left"
    )
  }

  private static func verifyOverlappingShifts(
    releases: [(physical: UInt16, rime: UInt32)],
    name: String
  ) {
    var state = SquirrelModifierTransitionState(hardwareFlags: [])
    var actual = state.transitions(keyCode: UInt16(kVK_Shift), modifiers: [.shift])
    actual += state.transitions(keyCode: UInt16(kVK_RightShift), modifiers: [.shift])
    actual += state.transitions(keyCode: releases[0].physical, modifiers: [.shift])
    actual += state.transitions(keyCode: releases[1].physical, modifiers: [])

    requireEvents(
      actual,
      [
        ExpectedModifierEvent(keycode: UInt32(XK_Shift_L), modifiers: kShiftMask.rawValue),
        ExpectedModifierEvent(keycode: UInt32(XK_Shift_R), modifiers: kShiftMask.rawValue),
        ExpectedModifierEvent(
          keycode: releases[0].rime,
          modifiers: kShiftMask.rawValue | kReleaseMask.rawValue),
        ExpectedModifierEvent(keycode: releases[1].rime, modifiers: kReleaseMask.rawValue)
      ],
      "overlapping Shift \(name) collapsed side identity or degraded to one tap"
    )
  }

  private static func verifyCapsLockTransitions() {
    var state = SquirrelModifierTransitionState(hardwareFlags: [])
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_CapsLock), modifiers: [.capsLock]),
      [ExpectedModifierEvent(keycode: UInt32(XK_Caps_Lock), modifiers: 0)],
      "Caps Lock on did not expose the pre-toggle modifier state"
    )
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_CapsLock), modifiers: [.capsLock]),
      [],
      "an unchanged Caps Lock snapshot emitted a duplicate toggle"
    )
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_CapsLock), modifiers: []),
      [ExpectedModifierEvent(keycode: UInt32(XK_Caps_Lock), modifiers: kLockMask.rawValue)],
      "Caps Lock off did not expose the pre-toggle modifier state"
    )
  }

  private static func verifyAmbiguousFlagsChangedFailsClosed() {
    var state = SquirrelModifierTransitionState(hardwareFlags: [])
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .control]),
      [],
      "an ambiguous non-modifier flags event fabricated duplicate modifier transitions"
    )
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_Shift), modifiers: [.control]),
      [],
      "an ambiguous event fabricated an unmatched Shift release"
    )
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_Control), modifiers: []),
      [],
      "an ambiguous event fabricated an unmatched Control release"
    )
  }

  private static func verifyAmbiguousSnapshotPreservesArmedShift() {
    for shift in [
      (name: "left", physical: UInt16(kVK_Shift), rime: UInt32(XK_Shift_L)),
      (name: "right", physical: UInt16(kVK_RightShift), rime: UInt32(XK_Shift_R))
    ] {
      var state = SquirrelModifierTransitionState(hardwareFlags: [])
      requireEvents(
        state.transitions(keyCode: shift.physical, modifiers: [.shift]),
        [ExpectedModifierEvent(keycode: shift.rime, modifiers: kShiftMask.rawValue)],
        "\(shift.name) Shift was not armed before an ambiguous snapshot"
      )
      requireEvents(
        state.transitions(
          keyCode: UInt16(kVK_ANSI_A),
          modifiers: [.shift, .control, .option]),
        [],
        "an ambiguous multi-flag snapshot fabricated modifier transitions"
      )
      requireEvents(
        state.transitions(keyCode: shift.physical, modifiers: [.control, .option]),
        [ExpectedModifierEvent(
          keycode: shift.rime,
          modifiers: kControlMask.rawValue | kAltMask.rawValue | kReleaseMask.rawValue
        )],
        "an ambiguous multi-flag snapshot forgot the armed \(shift.name) Shift release"
      )
    }
  }

  private static func verifyActivationHeldShiftSuppressesOppositeTap() {
    for scenario in [
      (
        heldName: "left",
        heldPhysical: UInt16(kVK_Shift),
        tappedName: "right",
        tappedPhysical: UInt16(kVK_RightShift),
        tappedRime: UInt32(XK_Shift_R)
      ),
      (
        heldName: "right",
        heldPhysical: UInt16(kVK_RightShift),
        tappedName: "left",
        tappedPhysical: UInt16(kVK_Shift),
        tappedRime: UInt32(XK_Shift_L)
      )
    ] {
      var state = SquirrelModifierTransitionState(hardwareFlags: [.maskShift])
      requireEvents(
        state.transitions(keyCode: scenario.tappedPhysical, modifiers: [.shift]),
        [],
        "activation-held \(scenario.heldName) Shift leaked the opposite down"
      )
      requireEvents(
        state.transitions(keyCode: scenario.tappedPhysical, modifiers: [.shift]),
        [],
        "activation-held \(scenario.heldName) Shift leaked the opposite up"
      )
      requireEvents(
        state.transitions(keyCode: scenario.heldPhysical, modifiers: []),
        [],
        "activation-held \(scenario.heldName) Shift leaked its epoch-ending release"
      )
      requireEvents(
        state.transitions(keyCode: scenario.tappedPhysical, modifiers: [.shift]),
        [ExpectedModifierEvent(
          keycode: scenario.tappedRime,
          modifiers: kShiftMask.rawValue
        )],
        "\(scenario.tappedName) Shift remained suppressed after aggregate Shift cleared"
      )
      requireEvents(
        state.transitions(keyCode: scenario.tappedPhysical, modifiers: []),
        [ExpectedModifierEvent(
          keycode: scenario.tappedRime,
          modifiers: kReleaseMask.rawValue
        )],
        "\(scenario.tappedName) Shift release was lost after aggregate Shift cleared"
      )
    }
  }

  private static func verifyActivationResetDropsUntrackedRelease() {
    var state = SquirrelModifierTransitionState(hardwareFlags: [])
    _ = state.transitions(keyCode: UInt16(kVK_Shift), modifiers: [.shift])
    state.reset(from: [.maskShift, .maskControl, .maskAlternate, .maskCommand,
                       .maskSecondaryFn])
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_Shift), modifiers: []),
      [],
      "activation reset leaked an untracked Shift release into the new epoch"
    )

    state.reset(from: [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
                       .maskCommand, .maskSecondaryFn])
    requireEvents(
      state.transitions(keyCode: UInt16(kVK_CapsLock), modifiers: []),
      [ExpectedModifierEvent(keycode: UInt32(XK_Caps_Lock), modifiers: kLockMask.rawValue)],
      "activation reset did not retain the persistent Caps Lock baseline"
    )
  }

  private static func verifyComposingKeypadEquivalents() {
    let mappings: [(keypad: UInt32, composing: UInt32)] = [
      (UInt32(XK_KP_0), UInt32(XK_0)),
      (UInt32(XK_KP_1), UInt32(XK_1)),
      (UInt32(XK_KP_2), UInt32(XK_2)),
      (UInt32(XK_KP_3), UInt32(XK_3)),
      (UInt32(XK_KP_4), UInt32(XK_4)),
      (UInt32(XK_KP_5), UInt32(XK_5)),
      (UInt32(XK_KP_6), UInt32(XK_6)),
      (UInt32(XK_KP_7), UInt32(XK_7)),
      (UInt32(XK_KP_8), UInt32(XK_8)),
      (UInt32(XK_KP_9), UInt32(XK_9)),
      (UInt32(XK_KP_Decimal), UInt32(XK_period)),
      (UInt32(XK_KP_Equal), UInt32(XK_equal)),
      (UInt32(XK_KP_Add), UInt32(XK_plus)),
      (UInt32(XK_KP_Subtract), UInt32(XK_minus)),
      (UInt32(XK_KP_Multiply), UInt32(XK_asterisk)),
      (UInt32(XK_KP_Divide), UInt32(XK_slash))
    ]
    for mapping in mappings {
      require(
        SquirrelKeycode.composingKeypadEquivalent(mapping.keypad) == mapping.composing,
        "keypad keys no longer share their composing ASCII contract"
      )
    }
    require(
      SquirrelKeycode.composingKeypadEquivalent(UInt32(XK_Return)) == nil,
      "a non-keypad key acquired a composing-only alias"
    )
  }
}

private extension MacOSKeyCodesTests {
  private static func verifyInputDispatchAuthority() {
    let controller = controllerSource()
    let processKey = section(
      in: controller,
      startingAt: "func processKey(",
      endingAt: "private func synchronizeCandidateLayoutOptions()"
    )
    let effectiveKeycode = section(
      in: controller,
      startingAt: "private func effectiveRimeKeycode(for keycode:",
      endingAt: "private func enterVimCommandModeIfNeeded("
    )
    let keypadLookup = effectiveKeycode.range(
      of: "SquirrelKeycode.composingKeypadEquivalent(keycode)")
    let pendingLookup = effectiveKeycode.range(of: "hasPendingRimeInput")
    require(
      keypadLookup != nil && pendingLookup != nil
        && keypadLookup!.lowerBound < pendingLookup!.lowerBound
        && occurrences(
          of: "SquirrelKeycode.composingKeypadEquivalent(keycode)",
          in: effectiveKeycode) == 1
        && occurrences(of: "hasPendingRimeInput", in: effectiveKeycode) == 1
        && occurrences(
          of: "effectiveRimeKeycode(for: rimeKeycode)",
          in: processKey) == 1,
      "ordinary processKey hot path queries pending Rime input before proving a keypad key"
    )
    require(
      !controller.contains("printablePaging"),
      "the controller retained printable paging ownership"
    )
  }

  private static func verifyModifierEpochLifecycle() {
    let controller = controllerSource()
    let host = readSource("sources/SquirrelApplicationDelegate.swift")
    let keycodes = readSource("sources/MacOSKeyCodes.swift")
    let flagsChanged = section(
      in: controller,
      startingAt: "case .flagsChanged:",
      endingAt: "case .keyDown:"
    )
    let readyDispatch = section(
      in: controller,
      startingAt: "private func dispatchReadyEvent(",
      endingAt: "override func recognizedEvents("
    )
    let reset = section(
      in: controller,
      startingAt: "func resetModifierEpoch()",
      endingAt: "var hasPendingRimeInput"
    )
    let readiness = section(
      in: controller,
      startingAt: "func ensureReadySession(",
      endingAt: "func updateAppOptions()"
    )
    let activation = section(
      in: controller,
      startingAt: "override func activateServer",
      endingAt: "override init!"
    )
    let invalidation = section(
      in: host,
      startingAt: "private func invalidateRimeSessions()",
      endingAt: "func shutdownRime()"
    )
    let shutdown = section(
      in: host,
      startingAt: "func shutdownRime()",
      endingAt: "fileprivate func workspaceWillPowerOff"
    )
    let reopen = section(
      in: host,
      startingAt: "private func reopenRimeInput()",
      endingAt: "private func startStaleSessionCleaner()"
    )
    let createSession = section(
      in: controller,
      startingAt: "func createSession(",
      endingAt: "func sessionIsCurrent()"
    )
    let modeBaseline = section(
      in: controller,
      startingAt: "func synchronizeRecoveredInputMode(",
      endingAt: "func applyInputModeIdentity("
    )
    let modeOwner = section(
      in: controller,
      startingAt: "func applyInputModeIdentity(",
      endingAt: "var hasPendingRimeInput"
    )
    let activeCommit = section(
      in: controller,
      startingAt: "func commitActiveComposition(",
      endingAt: "func rimeUpdate("
    )

    require(
      occurrences(of: "resetModifierEpoch()", in: controller) == 2,
      "modifier epoch reset is not defined once and consumed once by activation"
    )
    require(
      occurrences(of: "isRimeInputSuspended = false", in: host) == 2
        && occurrences(of: "inputController.resetModifierEpoch()", in: host) == 1,
      "runtime input admission regained a second ungated reopen path"
    )
    let rebase = reopen.range(of: "inputController.resetModifierEpoch()")?.lowerBound
    let reopenGate = reopen.range(of: "isRimeInputSuspended = false")?.lowerBound
    require(
      rebase != nil && reopenGate != nil && rebase! < reopenGate!,
      "runtime resume can expose a stale modifier baseline to the next event"
    )
    require(
      reset.contains(".reset(")
        && reset.contains("from: CGEventSource.flagsState(.combinedSessionState)"),
      "modifier epoch owner no longer resets the typed transition state from hardware"
    )
    require(
      activation.contains("ensureReadySession(for: activatingClient)")
        && activation.contains("resetModifierEpoch()")
        && !activation.contains("SquirrelModifierTransitionState"),
      "activation no longer establishes the modifier epoch before user events"
    )
    require(
      readiness.contains("if recoveredSession")
        && readiness.contains("synchronizeRecoveredInputMode(")
        && !readiness.contains("resetModifierEpoch()")
        && !readiness.contains("CGEventSource.flagsState")
        && !readiness.contains("set_option(session, \"ascii_mode\"")
        && !readiness.contains("set_property(session,"),
      "session recovery regained physical modifier or input-mode ownership"
    )
    require(
      !readyDispatch.contains("set_option(session, \"ascii_mode\"")
        && !readyDispatch.contains("set_property(session,"),
      "ready-event ingress regained a second Caps or ASCII state owner"
    )
    require(
      !createSession.contains("inputModeIdentity = nil")
        && modeBaseline.contains("rimeAPI.get_status(")
        && modeBaseline.contains("announcesTransition: false")
        && !modeBaseline.contains("panel.updateStatus(")
        && modeOwner.contains("loadSettings(for:")
        && modeOwner.contains("inlinePreedit")
        && modeOwner.contains("panel.updateStatus("),
      "session recovery does not establish a silent pre-event input-mode baseline"
    )
    require(
      readiness.contains("if recoveredSession {")
        && readiness.contains("clearChord()")
        && activeCommit.contains("clearChord()"),
      "a session replacement or active composition exit retained delayed chord state"
    )
    require(
      !controller.contains("lastModifiers")
        && !controller.contains("symmetricDifference")
        && !controller.contains("inferModifierKeycode"),
      "the controller retained a second untyped modifier transition owner"
    )
    require(
      occurrences(of: "SquirrelModifierTransitionState", in: controller) == 1
        && flagsChanged.contains(".transitions("),
      "the controller does not consume the unique typed modifier transition owner"
    )
    require(
      !keycodes.contains("activationModifierBaseline")
        && !keycodes.contains("inferModifierKeycode"),
      "retired modifier inference helpers remain as competing truth paths"
    )
    let availabilityGuard =
      activation.range(of: "guard NSApp.squirrelAppDelegate.canAcceptRimeInput")?.lowerBound
    let modifierReset = activation.range(of: "resetModifierEpoch()")?.lowerBound
    let readinessCall =
      activation.range(of: "ensureReadySession(for: activatingClient)")?.lowerBound
    require(
      modifierReset != nil && availabilityGuard != nil && readinessCall != nil
        && modifierReset! < availabilityGuard! && availabilityGuard! < readinessCall!,
      "a suspended activation can defer its modifier baseline until the first event"
    )

    let commit = invalidation.range(of: "commitCurrentComposition()")?.lowerBound
    let suspend = invalidation.range(of: "isRimeInputSuspended = true")?.lowerBound
    let cleanup = invalidation.range(of: "rimeAPI.cleanup_all_sessions()")?.lowerBound
    require(
      commit != nil && suspend != nil && cleanup != nil
        && commit! < suspend! && suspend! < cleanup!,
      "runtime invalidation does not commit, suspend, then clean up"
    )
    let shutdownInvalidation = shutdown.range(of: "invalidateRimeSessions()")?.lowerBound
    let closeConfiguration = shutdownInvalidation.flatMap {
      shutdown.range(of: "config?.close()", range: $0..<shutdown.endIndex)?.lowerBound
    }
    require(
      shutdownInvalidation != nil && closeConfiguration != nil &&
        shutdownInvalidation! < closeConfiguration!,
      "shutdown closes configuration before a committing client can finish reentry"
    )
  }

  private static func verifyDelayedCallbackSessionOwnership() {
    let controller = controllerSource()
    let presentation = readSource("sources/SquirrelApplicationPresentation.swift")
    let chordTimer = section(
      in: controller,
      startingAt: "func onChordTimer(",
      endingAt: "func updateChord("
    )
    let chordSchedule = section(
      in: controller,
      startingAt: "func updateChord(",
      endingAt: "func clearChord()"
    )
    let status = section(
      in: presentation,
      startingAt: "func updateStatusIcon(session:",
      endingAt: "func inputSourceDidActivate("
    )
    let message = section(
      in: presentation,
      startingAt: "func showStatusMessage(",
      endingAt: "func updateStatusIcon(session:"
    )
    let leaseValidation = section(
      in: controller,
      startingAt: "func ownsCurrentSession(",
      endingAt: "private func handleCompositionMouseDown("
    )

    require(
      chordTimer.contains("sessionLease: LinnetRimeSessionLease")
        && chordSchedule.contains("sessionLease: sessionLease")
        && !chordTimer.contains("sessionID")
        && !chordSchedule.contains("let sessionID = session"),
      "a delayed chord callback still authorizes a recycled raw session identifier"
    )
    require(
      status.contains("let sessionLease = controller.currentSessionLease(")
        && status.contains("matching: session)")
        && status.contains("ownsCurrentSession(")
        && status.contains("panel?.inputController === controller")
        && status.contains("sessionLease")
        && message.contains("controller.currentSessionLease(")
        && message.contains("matching: session)"),
      "status callbacks do not retain and revalidate the exact session lease"
    )
    let availability = leaseValidation.range(of: "canAcceptRimeInput")?.lowerBound
    let sessionLookup = leaseValidation.range(of: "expectedLease.isCurrent")?.lowerBound
    require(
      availability != nil && sessionLookup != nil && availability! < sessionLookup!,
      "an async lease revalidation can query a suspended or finalized runtime"
    )
  }

  private static func readSource(_ path: String) -> String {
    do {
      return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
      FileHandle.standardError.write(
        Data("MacOSKeyCodesTests: FAIL: could not read \(path): \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func controllerSource() -> String {
    readSource("sources/SquirrelInputController.swift") +
      readSource("sources/SquirrelInputController+RimeSession.swift")
  }

  private static func section(
    in source: String,
    startingAt start: String,
    endingAt end: String
  ) -> String {
    guard let startRange = source.range(of: start),
      let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
    else {
      FileHandle.standardError.write(
        Data("MacOSKeyCodesTests: FAIL: missing source section \(start)\n".utf8))
      exit(EXIT_FAILURE)
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }

  private static func occurrences(of needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
  }

  private static func requireEvents(
    _ actual: [SquirrelModifierTransitionState.Event],
    _ expected: [ExpectedModifierEvent],
    _ message: String
  ) {
    require(actual.count == expected.count, "\(message): event count")
    for (index, pair) in zip(actual, expected).enumerated() {
      require(pair.0.keycode == pair.1.keycode, "\(message): event \(index) keycode")
      require(pair.0.modifiers == pair.1.modifiers, "\(message): event \(index) modifiers")
    }
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    guard condition() else {
      FileHandle.standardError.write(Data("MacOSKeyCodesTests: FAIL: \(message)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
