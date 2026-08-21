import AppKit
import SwiftUI

@MainActor
final class SettingsApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var model: SettingsModel?
  var interfaceLocale = Locale.autoupdatingCurrent

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

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
          minHeight: 660,
          idealHeight: 800)
    }
    .defaultSize(width: LinnetSettingsLayoutMetrics.defaultWindowWidth, height: 800)
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
