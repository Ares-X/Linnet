import AppKit
import Carbon
import Foundation

@main
struct MacOSKeyCodesTests {
  private struct ExpectedModifierEvent {
    let keycode: UInt32
    let modifiers: UInt32
  }

  static func main() throws {
    verifyModifierTransitionState()
    verifyComposingKeypadEquivalents()
    verifyNativeTextEvents()
    try verifyNativeKeyboardComposition()
    for (physical, character) in [
      (kVK_ANSI_2, Character("é")),
      (kVK_ANSI_A, Character("ä")),
      (kVK_ANSI_E, Character("e\u{0301}")),
    ] {
      require(SquirrelKeycode.osxKeycodeToRime(
        keycode: UInt16(physical), keychar: character, shift: false, caps: false)
          == UInt32(XK_VoidSymbol),
        "a non-ASCII character was reinterpreted as a QWERTY key")
    }
    require(SquirrelKeycode.osxKeycodeToRime(
      keycode: UInt16(kVK_ANSI_2), keychar: "2", shift: false, caps: false) == UInt32(XK_2),
      "an ASCII digit lost its actual character")
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

  private static func verifyNativeTextEvents() {
    func input(
      _ characters: String, ignoring: String,
      key: Int = kVK_ANSI_E, modifiers: NSEvent.ModifierFlags = []
    ) -> (keycode: UInt32, nativeText: Bool) {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: ignoring,
        isARepeat: false, keyCode: UInt16(key))!
      return SquirrelKeycode.osxKeyEventToRime(event)
    }

    for text in ["é", "e\u{0301}", "eé", "^x"] {
      let result = input(text, ignoring: "e")
      require(result.keycode == UInt32(XK_VoidSymbol) && result.nativeText,
        "a native text payload was reduced to its unmodified ASCII letter")
    }
    let optionText = input("∫", ignoring: "b", key: kVK_ANSI_B, modifiers: [.option])
    require(optionText.keycode == UInt32(XK_b) && optionText.nativeText,
      "an Option binding lost Rime priority or its unhandled native text")
    let deadKey = input("", ignoring: "e", modifiers: [.option])
    require(deadKey.keycode == UInt32(XK_e) && !deadKey.nativeText,
      "an empty dead-key prefix was mistaken for a completed text character")
    let imkDeadKey = input("´", ignoring: "´", modifiers: [.option])
    require(imkDeadKey.keycode == UInt32(XK_e) && imkDeadKey.nativeText,
      "IMK's spacing-accent dead-key payload hid the Option-e Rime binding")
    let emptyKey = input("", ignoring: "")
    require(emptyKey.keycode == UInt32(XK_VoidSymbol) && !emptyKey.nativeText,
      "an empty native payload inferred the server's separate dead-key fact")
    for modifiers: NSEvent.ModifierFlags in [[.command], [.control]] {
      let shortcut = input("é", ignoring: "e", modifiers: modifiers)
      require(shortcut.keycode == UInt32(XK_e) && !shortcut.nativeText,
        "a Command or Control shortcut was treated as native text")
    }
    let punctuation = input("!", ignoring: "1", key: kVK_ANSI_1, modifiers: [.shift])
    require(punctuation.keycode == UInt32(XK_exclam) && !punctuation.nativeText,
      "shifted ASCII punctuation lost its actual character")
    let arrow = input("\u{F702}", ignoring: "\u{F702}", key: kVK_LeftArrow)
    require(arrow.keycode == UInt32(XK_Left) && !arrow.nativeText,
      "a physical cursor key was treated as native Unicode text")
  }

  private static func verifyNativeKeyboardComposition() throws {
    // Loading ABC's installed Unicode layout is read-only; neither the active
    // input source nor the user's keyboard preferences are changed.
    let composer = try SquirrelNativeKeyboardComposer(keyboardLayoutName: "com.apple.keylayout.ABC")
    func key(
      _ code: Int, modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false
    ) throws -> String {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "",
        isARepeat: isARepeat, keyCode: UInt16(code))!
      return try composer.translate(event)
    }
    func acutePrefix() throws {
      let output = try key(kVK_ANSI_E, modifiers: [.option])
      require(output.isEmpty && composer.isComposing, "ABC Option-e did not begin a native dead key")
    }

    require(!composer.isComposing, "a new composer inherited a pending dead key")
    try acutePrefix()
    let preview = try composer.preview()
    require(preview == "´" && composer.isComposing, "preview consumed the native acute state")
    let prefixRepeat = try key(kVK_ANSI_E, modifiers: [.option], isARepeat: true)
    require(prefixRepeat.isEmpty && composer.isComposing,
      "autorepeating ABC's Option-e prefix emitted a spacing accent")
    let accented = try key(kVK_ANSI_E)
    require(accented == "é" && !composer.isComposing,
      "ABC Option-e followed by e did not produce é: \(accented.debugDescription), composing=\(composer.isComposing)")
    let accentedRepeat = try key(kVK_ANSI_E, isARepeat: true)
    require(accentedRepeat == "é" && !composer.isComposing,
      "autorepeating a completed native accent lost the platform's repeat metadata")
    let following = try key(kVK_ANSI_E)
    require(following == "e" && !composer.isComposing,
      "a new e keydown reused the completed accent's autorepeat metadata")

    try acutePrefix()
    let spacing = try key(kVK_Space)
    require(spacing == "´" && !composer.isComposing, "ABC Space did not finish a spacing acute accent")

    try acutePrefix()
    let unsupported = try key(kVK_ANSI_X)
    require(unsupported == "´x" && !composer.isComposing,
      "ABC's unsupported acute combination lost part of its multi-character output")

    try acutePrefix()
    let repeated = try key(kVK_ANSI_E, modifiers: [.option])
    require(repeated == "´" && composer.isComposing,
      "ABC's repeated dead key did not emit the old accent and begin the next one")
    let afterRepeated = try key(kVK_ANSI_E)
    require(afterRepeated == "é" && !composer.isComposing,
      "ABC's repeated accent did not retain the next composition")

    try acutePrefix()
    let uppercase = try key(kVK_ANSI_E, modifiers: [.shift])
    require(uppercase == "É" && !composer.isComposing, "native composition lost Shift")

    try acutePrefix()
    let caps = try key(kVK_ANSI_E, modifiers: [.capsLock])
    require(caps == "É" && !composer.isComposing, "native composition lost Caps Lock")

    try acutePrefix()
    let shiftedCaps = try key(kVK_ANSI_E, modifiers: [.capsLock, .shift])
    require(shiftedCaps == "É" && !composer.isComposing,
      "native composition did not preserve ABC's Shift plus Caps Lock behavior: \(shiftedCaps.debugDescription)")

    try acutePrefix()
    let flushed = try composer.finish()
    require(flushed == "´" && !composer.isComposing, "finishing discarded the pending spacing accent")
    let finishedAgain = try composer.finish()
    require(finishedAgain.isEmpty, "finishing an idle composer inserted a Space")

    try acutePrefix()
    composer.reset()
    let ordinary = try key(kVK_ANSI_E)
    require(ordinary == "e" && !composer.isComposing, "reset left native accent state in the next client")

    do {
      _ = try SquirrelNativeKeyboardComposer(keyboardLayoutName: "invalid.test.keyboard-layout")
      require(false, "a missing explicitly configured layout silently used another layout")
    } catch SquirrelNativeKeyboardComposer.TranslationError.keyboardLayoutUnavailable(let identifier) {
      require(identifier == "invalid.test.keyboard-layout", "a missing-layout error lost its identifier")
    }
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
