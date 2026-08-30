import AppKit

@main
enum ForegroundFixture {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    if CommandLine.arguments.dropFirst().first == "--open-settings" {
      // Unlike sandboxed XCTRunner, this existing fixture can supply a launch
      // environment through NSWorkspace, just as the real input-method Host can.
      let arguments = CommandLine.arguments
      guard arguments.count == 4,
        Bundle(path: arguments[2])?.bundleIdentifier ==
          "io.github.ares-x.inputmethod.Linnet.settings-ui-uat.settings",
        FileManager.default.fileExists(
          atPath: arguments[3] + "/.linnet-settings-ui-uat-fixture")
      else { exit(2) }
      application.setActivationPolicy(.prohibited)
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.addsToRecentItems = false
      configuration.allowsRunningApplicationSubstitution = false
      configuration.environment = [
        "HOME": arguments[3], "CFFIXED_USER_HOME": arguments[3],
      ]
      configuration.arguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
      NSWorkspace.shared.openApplication(
        at: URL(fileURLWithPath: arguments[2]), configuration: configuration
      ) { opened, error in
        exit(opened != nil && error == nil ? 0 : 1)
      }
      application.run()
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 480, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Settings UI foreground fixture"
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    application.run()
  }
}
