import Foundation

@main
struct LinnetSettingsPageLayoutTests {
  static func main() {
    require(
      LinnetSettingsLayoutMetrics.minimumWindowWidth == 960,
      "the Settings minimum width no longer guarantees the two-column layout")
    require(
      LinnetSettingsLayoutMetrics.defaultWindowWidth == 1040,
      "the Settings default width no longer presents the preview on the right")
    require(
      LinnetSettingsLayoutMetrics.defaultWindowWidth
        >= LinnetSettingsLayoutMetrics.minimumWindowWidth,
      "the Settings default width is smaller than its supported minimum")

    let requiredContentWidth =
      2 * LinnetSettingsLayoutMetrics.minimumColumnWidth
      + LinnetSettingsLayoutMetrics.columnSpacing
      + 2 * LinnetSettingsLayoutMetrics.pageHorizontalInset
    require(
      requiredContentWidth <= LinnetSettingsLayoutMetrics.minimumWindowWidth,
      "the minimum Settings window cannot contain both canonical columns")
    require(
      LinnetSettingsLayoutMetrics.minimumWindowWidth - requiredContentWidth >= 80,
      "the two-column contract leaves too little room for native window chrome")

    print("LinnetSettingsPageLayoutTests: PASS")
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    guard condition() else {
      fputs("LinnetSettingsPageLayoutTests: FAIL: \(message)\n", stderr)
      exit(1)
    }
  }
}
