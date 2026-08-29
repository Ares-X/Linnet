import AppKit
import SwiftUI

@MainActor
final class SettingsApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var model: SettingsModel?
  var interfaceLocale = Locale.autoupdatingCurrent

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard let application = notification.object as? NSApplication else { return }
    presentSettingsWindow(in: application)
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows _: Bool
  ) -> Bool {
    presentSettingsWindow(in: sender)
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    if model.operationActive {
      NSSound.beep()
      return .terminateCancel
    }
    guard model.pendingChanges else { return .terminateNow }
    if sender.windows.contains(where: { $0.attachedSheet != nil }) {
      return .terminateCancel
    }
    SettingsPendingChangesPrompt.present(
      for: sender.keyWindow ?? sender.windows.first(where: \.isVisible),
      canApply: model.canApplyChanges,
      locale: interfaceLocale
    ) { choice in
      switch choice {
      case .apply:
        model.applyConfiguration { accepted in
          sender.reply(toApplicationShouldTerminate: accepted)
        }
      case .discard:
        model.discardPendingChanges()
        sender.reply(toApplicationShouldTerminate: true)
      case .cancel:
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }

  private func presentSettingsWindow(in application: NSApplication) {
    guard let window = application.windows.first(where: { $0.canBecomeKey }) else { return }
    application.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}

@main
struct LinnetSettingsApp: App {
  @NSApplicationDelegateAdaptor(SettingsApplicationDelegate.self)
  private var applicationDelegate

  var body: some Scene {
    WindowGroup {
      SettingsRootView()
        .frame(
          minWidth: LinnetSettingsLayoutMetrics.minimumWindowWidth,
          idealWidth: LinnetSettingsLayoutMetrics.defaultWindowWidth,
          minHeight: LinnetSettingsLayoutMetrics.windowHeight)
    }
    .defaultSize(
      width: LinnetSettingsLayoutMetrics.defaultWindowWidth,
      height: LinnetSettingsLayoutMetrics.windowHeight)
    .windowResizability(.contentMinSize)
    .commands { CommandGroup(replacing: .newItem) {} }
  }
}

struct SettingsActiveOperation: Equatable {
  let kind: SettingsOperationKind
  var phase: SettingsOperationPhase
  var cancellationAvailable: Bool
  var cancellationRequested: Bool

  var cancellable: Bool { cancellationAvailable && !cancellationRequested }
}

enum SettingsLegacyImportState {
  case unavailable
  case checking
  case none
  case compatible(SettingsDataCoordinator.LegacyImportCandidate)
  case failed
}

enum SettingsLanguageDataUpdateTarget: Equatable {
  case currentEdition
  case completeOffline

  var presentationPack: SettingsPresentationPack {
    self == .completeOffline ? .longTailDictionaries : .languageData
  }
}
