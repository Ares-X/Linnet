import SwiftUI

/// Projects the Core download lifecycle into the Settings card. The checker
/// remains the state/action owner; this extension owns only its presentation.
extension DataTabView {
  func pendingCoreTitle(
    installed: LinnetSettingsContract.ProductIdentity,
    running: LinnetSettingsContract.ProductIdentity
  ) -> LocalizedStringKey {
    installed.version == running.version && installed.build == running.build
      ? "Installed Core revision differs from the running Core"
      : "Installed Core update is ready"
  }

  func pendingCoreDetail(
    installed: LinnetSettingsContract.ProductIdentity,
    running: LinnetSettingsContract.ProductIdentity
  ) -> LocalizedStringKey {
    installed.version == running.version && installed.build == running.build
      ? "The version and build are the same, but the installed source revision differs. You can keep using the running Core or apply the installed revision after switching away from Linnet."
      : "You can keep using the current Core, or apply the installed Core after switching away from Linnet. Other apps stay open and no logout is required."
  }

  @ViewBuilder func coreDownloadControls(_ core: LinnetDataChannel.Core) -> some View {
    Group {
      switch updateChecker.coreDownloadState {
      case .downloading(let downloadingCore, let progress) where downloadingCore == core:
        VStack(alignment: .trailing, spacing: 4) {
          ProgressView(value: progress)
            .frame(width: 120)
            .accessibilityLabel("Downloading Core update")
            .accessibilityValue(Text(verbatim: "\(Int(progress * 100))%"))
          Button("Cancel") { updateChecker.cancelCoreDownload() }
        }
      case .installerPackage(let readyCore, _) where readyCore == core:
        Button("Open Legacy Installer…") { updateChecker.showDownloadedCoreUpdate() }
      case .ready(let readyCore, _) where readyCore == core:
        Button("Apply Update…") { confirmDownloadedCoreActivation() }
          .disabled(model.pendingChanges || model.operationActive)
      case .blocked(let readyCore, _, _) where readyCore == core:
        Button("Try Apply Again…") { confirmDownloadedCoreActivation() }
          .disabled(model.pendingChanges || model.operationActive)
      case .applying(let applyingCore, _) where applyingCore == core:
        ProgressView().controlSize(.small)
      case .failed(let failedCore) where failedCore == core:
        Button("Try Download Again") { updateChecker.downloadCoreUpdate(core) }
      case .recoveryRequired:
        EmptyView()
      default:
        Button("Download Core Update") { updateChecker.downloadCoreUpdate(core) }
      }
    }
    .accessibilityIdentifier("settings.data.core.downloadAction")
  }

  func coreDownloadStatusTitle(_ core: LinnetDataChannel.Core) -> LocalizedStringKey {
    switch updateChecker.coreDownloadState {
    case .downloading(let downloadingCore, _) where downloadingCore == core:
      "Downloading Core update…"
    case .installerPackage(let readyCore, _) where readyCore == core:
      "Legacy Core package downloaded and verified"
    case .ready(let readyCore, _) where readyCore == core:
      "Core update downloaded and verified"
    case .blocked(let readyCore, _, _) where readyCore == core:
      "Core update is waiting"
    case .applying(let applyingCore, _) where applyingCore == core:
      "Applying Core update…"
    case .applied:
      "Core update applied"
    case .recoveryRequired(let failedCore) where failedCore == core:
      "Core update needs repair"
    case .failed(let failedCore) where failedCore == core:
      "Core download failed"
    default:
      "Core update available"
    }
  }

  func coreDownloadStatusImage(_ core: LinnetDataChannel.Core) -> String {
    switch updateChecker.coreDownloadState {
    case .downloading(let downloadingCore, _) where downloadingCore == core:
      "arrow.down.circle"
    case .installerPackage(let readyCore, _) where readyCore == core:
      "checkmark.circle.fill"
    case .ready(let readyCore, _) where readyCore == core:
      "checkmark.circle.fill"
    case .blocked(let readyCore, _, _) where readyCore == core:
      "exclamationmark.triangle.fill"
    case .applying(let applyingCore, _) where applyingCore == core:
      "arrow.triangle.2.circlepath"
    case .applied:
      "checkmark.circle.fill"
    case .recoveryRequired(let failedCore) where failedCore == core:
      "exclamationmark.octagon.fill"
    case .failed(let failedCore) where failedCore == core:
      "exclamationmark.triangle.fill"
    default:
      "arrow.down.circle.fill"
    }
  }

  func coreDownloadStatusColor(_ core: LinnetDataChannel.Core) -> Color {
    switch updateChecker.coreDownloadState {
    case .installerPackage(let readyCore, _) where readyCore == core:
      .green
    case .ready(let readyCore, _) where readyCore == core:
      .green
    case .applied:
      .green
    case .blocked(let readyCore, _, _) where readyCore == core:
      .orange
    case .applying(let applyingCore, _) where applyingCore == core:
      .accentColor
    case .recoveryRequired(let failedCore) where failedCore == core:
      .red
    case .failed(let failedCore) where failedCore == core:
      .red
    case .downloading(let downloadingCore, _) where downloadingCore == core:
      .accentColor
    default:
      .orange
    }
  }

  func coreDownloadStatusDetail(_ core: LinnetDataChannel.Core) -> LocalizedStringKey {
    switch updateChecker.coreDownloadState {
    case .downloading(let downloadingCore, _) where downloadingCore == core:
      "Settings is downloading the update and will verify its exact bytes."
    case .installerPackage(let readyCore, _) where readyCore == core:
      "This transitional update still uses macOS Installer. Open it only if you need to update from an older Core."
    case .ready(let readyCore, _) where readyCore == core:
      "Switch to another input source, then apply the verified update here. Apps stay open; no Installer, password, logout, or restart is required."
    case .blocked(let readyCore, _, let issue) where readyCore == core:
      coreActivationInstruction(issue)
    case .applying(let applyingCore, _) where applyingCore == core:
      "Keep another input source selected while Settings starts and verifies the new Core."
    case .applied:
      "The new Core is running. Settings will close and reopen cleanly the next time you choose it."
    case .recoveryRequired(let failedCore) where failedCore == core:
      "The update could not be verified or rolled back automatically. Run Linnet.pkg once to repair the installation."
    case .failed(let failedCore) where failedCore == core:
      "The update was not downloaded, extracted, or verified. The installed Core was not changed."
    default:
      "Download and verify the Core update here. Applying it does not use Installer and does not require a password or logout."
    }
  }

  func confirmDownloadedCoreActivation() {
    guard !model.pendingChanges, !model.operationActive else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "Apply the downloaded Core update now?")
    alert.informativeText = String(localized:
      "First use the macOS input menu to select another input source.")
      + " "
      + String(localized:
        "Your apps stay open. No Installer, password, logout, or restart is required.")
    let apply = alert.addButton(withTitle: String(localized: "Apply Now"))
    apply.keyEquivalent = "\r"
    let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
    cancel.keyEquivalent = "\u{1b}"
    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .alertFirstButtonReturn else { return }
      updateChecker.applyDownloadedCoreUpdate()
    }
    if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }
}
