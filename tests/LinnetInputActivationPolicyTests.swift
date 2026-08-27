import Foundation

@main
struct LinnetInputActivationPolicyTests {
  static func main() {
    require(
      LinnetInputActivationPolicy.keyboardLayoutName(configured: nil) == nil,
      "an absent layout stopped preserving the previously selected keyboard")
    require(
      LinnetInputActivationPolicy.keyboardLayoutName(configured: "") == nil,
      "an empty layout stopped preserving the previously selected keyboard")
    require(
      LinnetInputActivationPolicy.keyboardLayoutName(configured: "last") == nil,
      "the last-layout policy unexpectedly overrode the keyboard")
    require(
      LinnetInputActivationPolicy.keyboardLayoutName(configured: "default") ==
        "com.apple.keylayout.ABC",
      "the default layout no longer resolves to Apple's ABC keyboard")
    require(
      LinnetInputActivationPolicy.keyboardLayoutName(configured: "Dvorak") ==
        "com.apple.keylayout.Dvorak",
      "a short Apple layout identifier was not canonicalized")
    require(
      LinnetInputActivationPolicy.keyboardLayoutName(
        configured: "com.apple.keylayout.Colemak") ==
        "com.apple.keylayout.Colemak",
      "a canonical Apple layout identifier was changed")

    let markedRange = NSRange(location: 8, length: 4)
    require(
      LinnetInputActivationPolicy.shouldCommitCompositionForClick(
        characterIndex: 7, markedRange: markedRange),
      "a click before marked text did not end composition")
    require(
      LinnetInputActivationPolicy.shouldCommitCompositionForClick(
        characterIndex: 12, markedRange: markedRange),
      "a click at the marked-range upper boundary did not end composition")
    for insideIndex in 8..<12 {
      require(
        !LinnetInputActivationPolicy.shouldCommitCompositionForClick(
          characterIndex: insideIndex,
          markedRange: markedRange),
        "a click inside marked text unexpectedly ended composition")
    }
    require(
      !LinnetInputActivationPolicy.shouldCommitCompositionForClick(
        characterIndex: NSNotFound,
        markedRange: markedRange,
        spatiallyInsideMarkedRange: true),
      "a raw mouse hit inside marked text was replaced by nearest-index inference")
    require(
      LinnetInputActivationPolicy.shouldCommitCompositionForClick(
        characterIndex: 9,
        markedRange: markedRange,
        spatiallyInsideMarkedRange: false),
      "a raw mouse hit outside marked text was trapped by a nearest inside index")
    for outsideOrUnmarked in [
      (NSNotFound, markedRange),
      (7, NSRange(location: NSNotFound, length: 0)),
      (7, NSRange(location: 8, length: 0)),
      (-1, NSRange(location: -2, length: 3)),
      (Int.max - 1, NSRange(location: Int.max - 1, length: 4)),
      (7, NSRange(location: 8, length: -1)),
    ] {
      require(
        LinnetInputActivationPolicy.shouldCommitCompositionForClick(
          characterIndex: outsideOrUnmarked.0,
          markedRange: outsideOrUnmarked.1),
        "an unmarked or unresolved host click failed to retire passive UI")
    }
    print("LinnetInputActivationPolicyTests: PASS")
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    guard condition() else {
      FileHandle.standardError.write(
        Data("LinnetInputActivationPolicyTests: FAIL: \(message)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
