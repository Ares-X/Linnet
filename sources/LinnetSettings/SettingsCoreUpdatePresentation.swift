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
      case .ready(let readyCore, _) where readyCore == core:
        Button("Show in Finder") { updateChecker.showDownloadedCoreUpdate() }
      case .failed(let failedCore) where failedCore == core:
        Button("Try Download Again") { updateChecker.downloadCoreUpdate(core) }
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
    case .ready(let readyCore, _) where readyCore == core:
      "Core package downloaded and verified"
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
    case .ready(let readyCore, _) where readyCore == core:
      "checkmark.circle.fill"
    case .failed(let failedCore) where failedCore == core:
      "exclamationmark.triangle.fill"
    default:
      "arrow.down.circle.fill"
    }
  }

  func coreDownloadStatusColor(_ core: LinnetDataChannel.Core) -> Color {
    switch updateChecker.coreDownloadState {
    case .ready(let readyCore, _) where readyCore == core:
      .green
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
      "Settings is downloading the package and will verify its size and SHA-256."
    case .ready(let readyCore, _) where readyCore == core:
      "The verified package is ready in Finder. Open it and follow the macOS installer prompts."
    case .failed(let failedCore) where failedCore == core:
      "The package was not downloaded or did not pass verification. Check your connection and try again."
    default:
      "Download and verify the Core package here. No logout is required; macOS may ask you to approve the unsigned installer."
    }
  }
}
