import AppKit

@main
@MainActor
final class ForegroundFixture: NSObject {
  private let result = NSTextField(labelWithString: "Ready")

  @MainActor
  static func main() {
    let application = NSApplication.shared
    let fixture = ForegroundFixture()
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 480, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Settings UI foreground fixture"
    let button = NSButton(title: "Open Settings", target: fixture, action: #selector(openSettings))
    button.frame = NSRect(x: 40, y: 180, width: 200, height: 40)
    fixture.result.frame = NSRect(x: 40, y: 130, width: 400, height: 30)
    window.contentView?.addSubview(button)
    window.contentView?.addSubview(fixture.result)
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    withExtendedLifetime(fixture) { application.run() }
  }

  @MainActor
  @objc private func openSettings() {
    // XCTest operates this normal UI; only the unsandboxed fixture owns the
    // Host-like open. Sandboxed NSWorkspace discards both arguments and HOME.
    let settingsURL = Bundle.main.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("Linnet.app/Contents/Applications/Settings.app")
    let isolatedHome = "/private/tmp/linnet-settings-ui-uat-active-\(getuid())"
    guard Bundle(url: settingsURL)?.bundleIdentifier ==
      "io.github.ares-x.inputmethod.Linnet.settings-ui-uat.settings",
      FileManager.default.fileExists(
        atPath: isolatedHome + "/.linnet-settings-ui-uat-fixture")
    else {
      result.stringValue = "Invalid isolated Settings fixture"
      return
    }
    result.stringValue = "Opening Settings"
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.allowsRunningApplicationSubstitution = false
    configuration.environment = ["HOME": isolatedHome, "CFFIXED_USER_HOME": isolatedHome]
    configuration.arguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    NSWorkspace.shared.openApplication(at: settingsURL, configuration: configuration) { [self] opened, error in
      let succeeded = opened != nil && error == nil
      Task { @MainActor in
        result.stringValue = succeeded ? "Settings open delivered" : "Settings open failed"
      }
    }
  }
}
