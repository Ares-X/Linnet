import AppKit

@main
enum ForegroundFixture {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 480, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Settings UI foreground fixture"
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    application.run()
  }
}
