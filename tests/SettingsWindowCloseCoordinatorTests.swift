import AppKit

@MainActor
final class SettingsModel {
  var pendingChanges = false
  var operationActive = false
  var canApplyChanges = true

  func applyConfiguration(completion: (@MainActor (Bool) -> Void)? = nil) {
    completion?(false)
  }

  func discardPendingChanges() {
    pendingChanges = false
  }
}

@MainActor
private final class TrackingWindow: NSWindow {
  private(set) var closeCount = 0

  override func close() {
    closeCount += 1
  }
}

@main
struct SettingsWindowCloseCoordinatorTests {
  @MainActor
  static func main() {
    _ = NSApplication.shared
    let model = SettingsModel()
    let coordinator = SettingsWindowCloseCoordinator()
    coordinator.model = model
    let window = TrackingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    coordinator.attach(to: window)

    model.pendingChanges = true
    coordinator.updateDocumentEditedState()
    coordinator.completeApply(accepted: false, for: window)
    guard window.closeCount == 0, window.isDocumentEdited, model.pendingChanges else {
      fail("a rejected Apply closed the window or discarded its draft")
    }

    model.pendingChanges = false
    coordinator.completeApply(accepted: true, for: window)
    guard window.closeCount == 1, !window.isDocumentEdited, !model.pendingChanges else {
      fail("an accepted Apply did not clear document state and close exactly once")
    }

    print("SettingsWindowCloseCoordinatorTests: PASS")
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}
