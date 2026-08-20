import AppKit
import Carbon
import Foundation

@main
struct MacOSKeyCodesTests {
  static func main() {
    for (name, hardwareFlag) in [
      ("Shift", CGEventFlags.maskShift),
      ("Control", .maskControl),
      ("Option", .maskAlternate),
      ("Command", .maskCommand),
      ("Fn", .maskSecondaryFn),
    ] {
      require(
        SquirrelKeycode.activationModifierBaseline(from: hardwareFlag).isEmpty,
        "activation retained stale \(name) state from the previous input epoch"
      )
    }
    require(
      SquirrelKeycode.activationModifierBaseline(from: .maskAlphaShift) == [.capsLock],
      "activation did not seed persistent Caps Lock hardware state"
    )
    require(
      SquirrelKeycode.activationModifierBaseline(
        from: [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand,
               .maskSecondaryFn]
      ) == [.capsLock],
      "activation baseline retained transient modifiers alongside Caps Lock"
    )
    verifyModifierEpochLifecycle()
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

  private static func verifyModifierEpochLifecycle() {
    let controller = readSource("sources/SquirrelInputController.swift")
    let host = readSource("sources/SquirrelApplicationDelegate.swift")
    let reset = section(
      in: controller,
      startingAt: "func resetModifierEpoch()",
      endingAt: "override func activateServer"
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

    require(
      occurrences(of: "resetModifierEpoch()", in: controller) == 2,
      "modifier epoch reset is not owned once and consumed once by activation"
    )
    require(
      occurrences(of: "inputController.resetModifierEpoch()", in: host) == 1,
      "runtime invalidation does not consume the controller modifier epoch owner exactly once"
    )
    require(
      reset.contains("lastModifiers = SquirrelKeycode.activationModifierBaseline(")
        && reset.contains("CGEventSource.flagsState(.combinedSessionState)"),
      "modifier epoch owner no longer preserves only the live Caps Lock baseline"
    )
    require(
      activation.contains("resetModifierEpoch()") && !activation.contains("lastModifiers ="),
      "activation retained a competing inline modifier baseline"
    )
    let activationReset = activation.range(of: "resetModifierEpoch()")?.lowerBound
    let availabilityGuard =
      activation.range(of: "guard NSApp.squirrelAppDelegate.canAcceptRimeInput")?.lowerBound
    require(
      activationReset != nil && availabilityGuard != nil
        && activationReset! < availabilityGuard!,
      "an activation during runtime suspension can retain the prior modifier epoch"
    )

    let commit = invalidation.range(of: "commitComposition")?.lowerBound
    let epoch = invalidation.range(of: "inputController.resetModifierEpoch()")?.lowerBound
    let suspend = invalidation.range(of: "isRimeInputSuspended = true")?.lowerBound
    let cleanup = invalidation.range(of: "rimeAPI.cleanup_all_sessions()")?.lowerBound
    require(
      commit != nil && epoch != nil && suspend != nil && cleanup != nil
        && commit! < epoch! && epoch! < suspend! && suspend! < cleanup!,
      "runtime invalidation does not commit, reset the modifier epoch, suspend, then clean up"
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
