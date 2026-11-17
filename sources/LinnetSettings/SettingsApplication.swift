import AppKit
import SwiftUI

@MainActor
final class SettingsApplicationDelegate: NSObject, NSApplicationDelegate {
  let model = SettingsModel()
  var interfaceLocale = Locale.autoupdatingCurrent
  private var settingsWindowPresentationPending = false
  private var terminationPending = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let application = notification.object as? NSApplication else { return }
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(refreshSyncStatus),
      name: LinnetSettingsContract.cloudSyncStatusChanged, object: nil,
      suspensionBehavior: .deliverImmediately)
    requestSettingsWindowPresentation(in: application)
  }

  func applicationDidBecomeActive(_ notification: Notification) { refreshSyncStatus() }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard let value = LinnetSettingsContract.customWordValue(from: url) else { continue }
      model.editCustomWord(value: value)
      requestSettingsWindowPresentation(in: application)
    }
  }

  @objc private func refreshSyncStatus() {
    model.cloudSyncStatus = LinnetSettingsContract.cloudSyncStatus()
  }
  func applicationDidUpdate(_ notification: Notification) {
    guard let application = notification.object as? NSApplication else { return }
    presentSettingsWindowIfReady(in: application)
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows _: Bool
  ) -> Bool {
    requestSettingsWindowPresentation(in: sender)
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationPending { return .terminateLater }
    if model.operationActive {
      NSSound.beep()
      return .terminateCancel
    }
    guard model.pendingChanges else {
      finishTermination(in: sender)
      return .terminateLater
    }
    if sender.windows.contains(where: { $0.attachedSheet != nil }) {
      return .terminateCancel
    }
    SettingsPendingChangesPrompt.present(
      for: sender.keyWindow ?? sender.windows.first(where: \.isVisible),
      canApply: model.canApplyChanges,
      locale: interfaceLocale
    ) { [model] choice in
      switch choice {
      case .apply:
        model.applyConfiguration { accepted in
          if accepted { self.finishTermination(in: sender) }
          else { sender.reply(toApplicationShouldTerminate: false) }
        }
      case .discard:
        model.discardPendingChanges()
        self.finishTermination(in: sender)
      case .cancel:
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }

  private func finishTermination(in application: NSApplication) {
    terminationPending = true
    Task {
      await model.updateChecker.endSession()
      application.reply(toApplicationShouldTerminate: true)
    }
  }

  func requestSettingsWindowPresentation(in application: NSApplication) {
    settingsWindowPresentationPending = true
    presentSettingsWindowIfReady(in: application)
  }

  private func presentSettingsWindowIfReady(in application: NSApplication) {
    guard settingsWindowPresentationPending,
          let window = application.windows.first(where: { $0.canBecomeKey })
    else { return }

    settingsWindowPresentationPending = false
    window.collectionBehavior.insert(.moveToActiveSpace)
    application.activate(ignoringOtherApps: true)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
  }
}

@main
struct LinnetSettingsApp: App {
  @NSApplicationDelegateAdaptor(SettingsApplicationDelegate.self)
  private var applicationDelegate

  var body: some Scene {
    Window("Linnet", id: "settings") {
      SettingsRootView(model: applicationDelegate.model, applicationDelegate: applicationDelegate)
        .frame(
          minWidth: LinnetSettingsLayoutMetrics.minimumWindowWidth,
          idealWidth: LinnetSettingsLayoutMetrics.defaultWindowWidth,
          minHeight: LinnetSettingsLayoutMetrics.minimumWindowHeight,
          idealHeight: LinnetSettingsLayoutMetrics.defaultWindowHeight)
    }
    .defaultSize(
      width: LinnetSettingsLayoutMetrics.defaultWindowWidth,
      height: LinnetSettingsLayoutMetrics.defaultWindowHeight)
    .windowResizability(.contentMinSize)
  }
}
