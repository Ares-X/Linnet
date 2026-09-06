import AppKit
import Foundation
import SwiftUI

private final class SettingsLayoutFrameRecorder {
  var frames = [String: CGRect]()
}

private struct SettingsLayoutFramePreference: PreferenceKey {
  static var defaultValue = [String: CGRect]()

  static func reduce(
    value: inout [String: CGRect],
    nextValue: () -> [String: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

private struct SettingsLayoutProbe: View {
  let recorder: SettingsLayoutFrameRecorder

  var body: some View {
    LinnetSettingsTwoColumnLayout {
      cell("leading")
    } trailing: {
      cell("trailing")
    }
    .coordinateSpace(name: "settings-layout-probe")
    .onPreferenceChange(SettingsLayoutFramePreference.self) { frames in
      recorder.frames = frames
    }
  }

  private func cell(_ name: String) -> some View {
    Color.clear
      .frame(height: 40)
      .background {
        GeometryReader { proxy in
          Color.clear.preference(
            key: SettingsLayoutFramePreference.self,
            value: [name: proxy.frame(in: .named("settings-layout-probe"))])
        }
      }
  }
}

@main
struct LinnetSettingsPageLayoutTests {
  static func main() {
    require(
      LinnetSettingsLayoutMetrics.minimumWindowWidth == 760,
      "the Settings minimum width is not the compact 760-point contract")
    require(
      LinnetSettingsLayoutMetrics.defaultWindowWidth == 960,
      "the Settings default width is not the 960-point product contract")
    require(
      LinnetSettingsLayoutMetrics.defaultWindowWidth
        >= LinnetSettingsLayoutMetrics.minimumWindowWidth,
      "the Settings default width is smaller than its supported minimum")
    require(
      LinnetSettingsLayoutMetrics.minimumWindowHeight == 520,
      "the Settings minimum height is not the compact 520-point contract")
    require(
      LinnetSettingsLayoutMetrics.defaultWindowHeight == 640,
      "the Settings default height is not the 640-point product contract")

    let requiredContentWidth =
      2 * LinnetSettingsLayoutMetrics.minimumColumnWidth
      + LinnetSettingsLayoutMetrics.columnSpacing
      + 2 * LinnetSettingsLayoutMetrics.pageHorizontalInset
    require(
      requiredContentWidth > LinnetSettingsLayoutMetrics.minimumWindowWidth,
      "the compact Settings width no longer exercises the stacked layout")
    require(
      requiredContentWidth <= LinnetSettingsLayoutMetrics.defaultWindowWidth,
      "the default Settings width cannot contain both canonical columns")

    let wide = layoutFrames(
      width: LinnetSettingsLayoutMetrics.defaultWindowWidth
        - 2 * LinnetSettingsLayoutMetrics.pageHorizontalInset)
    guard let wideLeading = wide["leading"], let wideTrailing = wide["trailing"] else {
      fail("the wide Settings layout did not publish both columns")
    }
    require(
      abs(wideLeading.minY - wideTrailing.minY) < 0.5 &&
        wideLeading.maxX <= wideTrailing.minX,
      "the default Settings width did not render two peer columns")

    let compact = layoutFrames(
      width: LinnetSettingsLayoutMetrics.minimumWindowWidth
        - 2 * LinnetSettingsLayoutMetrics.pageHorizontalInset)
    guard let compactLeading = compact["leading"],
      let compactTrailing = compact["trailing"]
    else { fail("the compact Settings layout did not publish both groups") }
    require(
      compactLeading.maxY <= compactTrailing.minY,
      "the minimum Settings width did not stack its two groups")

    print("LinnetSettingsPageLayoutTests: PASS")
  }

  @MainActor
  private static func layoutFrames(width: CGFloat) -> [String: CGRect] {
    let recorder = SettingsLayoutFrameRecorder()
    let hostingView = NSHostingView(
      rootView: SettingsLayoutProbe(recorder: recorder).frame(width: width))
    hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
    hostingView.layoutSubtreeIfNeeded()
    for _ in 0..<20 where recorder.frames.count < 2 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      hostingView.layoutSubtreeIfNeeded()
    }
    return recorder.frames
  }

  private static func fail(_ message: String) -> Never {
    fputs("LinnetSettingsPageLayoutTests: FAIL: \(message)\n", stderr)
    exit(1)
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
