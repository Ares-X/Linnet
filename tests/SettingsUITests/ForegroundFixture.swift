import AppKit

@main
@MainActor
final class ForegroundFixture: NSObject {
  private let result = NSTextField(labelWithString: "Ready")
  private var candidateNumber = 0

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
    let add = NSButton(title: "Add Candidate Word", target: fixture, action: #selector(addCustomWord))
    add.frame = NSRect(x: 40, y: 130, width: 200, height: 40)
    fixture.result.frame = NSRect(x: 40, y: 80, width: 400, height: 30)
    window.contentView?.addSubview(button)
    window.contentView?.addSubview(add)
    window.contentView?.addSubview(fixture.result)
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    withExtendedLifetime(fixture) { application.run() }
  }

  @MainActor
  @objc private func openSettings() {
    openSettings(customWord: nil)
  }

  @objc private func addCustomWord() {
    candidateNumber += 1
    openSettings(customWord: "Candidate \(candidateNumber)")
  }

  private func openSettings(customWord: String?) {
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
    let completion: (NSRunningApplication?, Error?) -> Void = { [self] opened, error in
      let succeeded = opened != nil && error == nil
      Task { @MainActor in
        result.stringValue = succeeded ? "Settings open delivered" : "Settings open failed"
      }
    }
    if let customWord {
      var components = URLComponents()
      components.scheme = "linnet-settings"
      components.host = "custom-word"
      components.queryItems = [.init(name: "value", value: customWord)]
      guard let url = components.url else { return }
      NSWorkspace.shared.open(
        [url], withApplicationAt: settingsURL, configuration: configuration,
        completionHandler: completion)
    } else {
      NSWorkspace.shared.openApplication(
        at: settingsURL, configuration: configuration, completionHandler: completion)
    }
  }
}
