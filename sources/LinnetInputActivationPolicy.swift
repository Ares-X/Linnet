import Foundation

/// Pure projections applied once when InputMethodKit activates a text client.
/// Runtime state remains owned by Rime and the active controller.
enum LinnetInputActivationPolicy {
  private static let appleKeyboardPrefix = "com.apple.keylayout."

  static func keyboardLayoutName(configured: String?) -> String? {
    guard let configured, !configured.isEmpty, configured != "last" else {
      return nil
    }
    if configured == "default" {
      return "\(appleKeyboardPrefix)ABC"
    }
    if configured.hasPrefix(appleKeyboardPrefix) {
      return configured
    }
    return "\(appleKeyboardPrefix)\(configured)"
  }

  static func shouldCommitCompositionForClick(
    characterIndex: Int,
    markedRange: NSRange,
    spatiallyInsideMarkedRange: Bool? = nil
  ) -> Bool {
    if let spatiallyInsideMarkedRange {
      return !spatiallyInsideMarkedRange
    }
    let (markedUpperBound, rangeOverflow) = markedRange.location
      .addingReportingOverflow(markedRange.length)
    guard characterIndex >= 0,
      characterIndex != NSNotFound,
      markedRange.location >= 0,
      markedRange.location != NSNotFound,
      markedRange.length > 0,
      !rangeOverflow,
      markedUpperBound > markedRange.location
    else { return true }
    return characterIndex < markedRange.location ||
      characterIndex >= markedUpperBound
  }
}
