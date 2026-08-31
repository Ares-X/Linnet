//
//  SettingsDataViews.swift
//  Data-page controls for downloads, backup history, and diagnostics.
//

import AppKit
import SwiftUI

extension DataTabView {
  var cloudSyncSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(
        "Sync learned words with iCloud Drive",
        isOn: Binding(
          get: { model.cloudSyncEnabled },
          set: { enabled in Task { await model.setCloudSyncEnabled(enabled) } })
      )
      .disabled(model.operationActive || model.cloudSyncPreparing)

      if model.cloudSyncPreparing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Sync learned words with iCloud Drive")
      } else if let location = model.cloudSyncLocation {
        LabeledContent("Location") {
          Text(verbatim: location.displayName)
        }
      } else if model.cloudSyncEnabled {
        Text("iCloud Drive is unavailable. Check iCloud Drive in System Settings.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Linnet always uses iCloud Drive/Linnet; no folder selection is required.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(
        // Keep the complete localization key intact for String Catalog lookup.
        // swiftlint:disable:next line_length
        "Rime incrementally merges learned Chinese and English words between your Macs. Linnet checks at most once per hour while it is running; the next activation catches up. It does not read or merge the user dictionary format itself."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)

      HStack {
        Button("Sync Learning Now") { model.synchronizeLearningNow() }
          .disabled(model.cloudSyncLocation == nil || model.operationActive || model.cloudSyncPreparing)
        Button("Upload Incremental Backup…") { pendingCloudBackupUpload = true }
          .disabled(model.cloudSyncLocation == nil || model.operationActive || model.cloudSyncPreparing)
        Button("Review Recovery Backup…") {
          Task {
            pendingPortableImport = await model.inspectCloudBackupArchive()
          }
        }
        .disabled(
          model.cloudSyncLocation == nil || !model.configuration.canPersist
            || model.operationActive || model.portableInspectionActive || model.cloudSyncPreparing)
      }
      Text(
        "Recovery backups also include personal words, disabled words, and Text Expander data. The first upload creates a baseline; later uploads are incremental and manual."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  var versionSection: some View {
    GroupBox("Version") {
      VStack(alignment: .leading, spacing: 8) {
        LabeledContent("Application") { Text(verbatim: model.productName) }
        LabeledContent("Version") {
          if let installed = updateChecker.installedIdentity {
            Text(verbatim: productIdentityDescription(installed))
          } else {
            Text("Unavailable").foregroundStyle(.secondary)
          }
        }
        if updateChecker.installedIdentity == nil {
          LabeledContent("Core status") { Text("Installation needs repair") }
          Text("Run the Complete installer to restore the installed Core identity.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        LabeledContent("Language data") { Text(languageDataEditionLabel) }
        if model.installedPacks.isEmpty {
          LabeledContent("Data status") { Text("Installation needs repair") }
          Text("Reinstall Linnet to restore the required local language data.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(orderedInstalledPacks, id: \.kind.rawValue) { pack in
            LabeledContent(packLabel(pack.kind)) {
              Text(verbatim: packReleaseDescription(
                version: pack.version,
                sequence: pack.sequence))
            }
          }
          Text(
            "Data release is the pack's increasing content sequence, not a Git revision. The version identifies the corresponding published content."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var coreUpdateSection: some View {
    GroupBox("Core update") {
      VStack(alignment: .leading, spacing: 10) {
        runtimeVersionRow
        updateCheckRow
        Divider()
        HStack(alignment: .center, spacing: 10) {
          Text(coreActivationActionHint)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button(coreActivationButtonTitle) { confirmCoreActivation() }
            .disabled(
              updateChecker.runtimeVersionState.activationIdentities == nil ||
                model.pendingChanges || model.operationActive)
            .accessibilityHint(
              "Switch away from Linnet before applying an installed Core update.")
        }
      }
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("settings.data.coreUpdate")
  }

  @ViewBuilder var runtimeVersionRow: some View {
    switch updateChecker.runtimeVersionState {
    case .checking(let installed):
      VStack(alignment: .leading, spacing: 4) {
        Label("Checking the running Core…", systemImage: "arrow.triangle.2.circlepath")
          .foregroundStyle(.secondary)
        coreIdentityRows(installed: installed, running: nil)
      }
    case .current(let identity):
      VStack(alignment: .leading, spacing: 4) {
        coreIdentityRows(installed: identity, running: identity)
      }
    case .restartRequired(let installed):
      VStack(alignment: .leading, spacing: 4) {
        Label("Installed Core will start after one normal login", systemImage: "info.circle")
          .foregroundStyle(.orange)
        coreIdentityRows(installed: installed, running: nil)
        Text(
          "This Core cannot verify every app released its old input connection, so this update cannot be applied now. After one normal macOS login or restart, later updates need no logout."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    case .pending(let installed, let running):
      VStack(alignment: .leading, spacing: 4) {
        Label("Installed Core update is ready", systemImage: "checkmark.circle")
          .foregroundStyle(.orange)
        coreIdentityRows(installed: installed, running: running)
        Text(
          "You can keep using the current Core, or apply the installed Core after switching away from Linnet. Other apps stay open and no logout is required."
        )
          .font(.caption2)
          .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    case .applying(let installed, let running):
      VStack(alignment: .leading, spacing: 4) {
        Label("Applying installed Core…", systemImage: "arrow.triangle.2.circlepath")
          .foregroundStyle(.secondary)
        coreIdentityRows(installed: installed, running: running)
        Text("Keep another input source selected until Settings closes.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    case .blocked(let installed, let running, let issue):
      VStack(alignment: .leading, spacing: 4) {
        Label("The installed Core is waiting", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        coreIdentityRows(installed: installed, running: running)
        Text(coreActivationInstruction(issue))
          .font(.caption2)
          .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    case .applied(let identity):
      VStack(alignment: .leading, spacing: 2) {
        Label("Installed Core is now running", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        coreIdentityRows(installed: identity, running: identity)
        Text("Settings will close so its own connection can reopen cleanly.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    case .unsupported(let installed, let running):
      VStack(alignment: .leading, spacing: 4) {
        Label("This running Core cannot apply the update safely", systemImage: "info.circle")
          .foregroundStyle(.orange)
        coreIdentityRows(installed: installed, running: running)
        Text(
          "Keep using the current Core. After the next normal macOS login or restart, future Core updates can use Apply Now without another logout."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    case .failed(let installed, let running):
      VStack(alignment: .leading, spacing: 4) {
        Label("The installed Core was not activated", systemImage: "xmark.circle")
          .foregroundStyle(.red)
        coreIdentityRows(installed: installed, running: running)
        Text("Core activation could not be verified. Check the runtime before trying again.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    case .unavailable(let installed):
      VStack(alignment: .leading, spacing: 4) {
        Label("Running Core identity is unavailable.", systemImage: "exclamationmark.circle")
        coreIdentityRows(installed: installed, running: nil)
        Group {
          if installed == nil {
            Text("Run the Complete installer to repair Linnet before checking for updates.")
          } else {
            Text(
              "Updates do not stop the current Core or its app connections. The installed Core will run after the next macOS login or restart."
            )
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    }
  }

  func productIdentityDescription(
    _ identity: LinnetSettingsContract.ProductIdentity
  ) -> String {
    "\(identity.version) (\(identity.build))"
  }

  @ViewBuilder func coreIdentityRows(
    installed: LinnetSettingsContract.ProductIdentity?,
    running: LinnetSettingsContract.ProductIdentity?
  ) -> some View {
    LabeledContent("Running") {
      if let running {
        Text(verbatim: productIdentityDescription(running))
      } else {
        Text("Unavailable").foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("settings.data.core.running")
    LabeledContent("Installed") {
      if let installed {
        Text(verbatim: productIdentityDescription(installed))
      } else {
        Text("Unavailable").foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("settings.data.core.installed")
    coreRevisionDetails(running: running, installed: installed)
  }

  @ViewBuilder func coreRevisionDetails(
    running: LinnetSettingsContract.ProductIdentity?,
    installed: LinnetSettingsContract.ProductIdentity?
  ) -> some View {
    DisclosureGroup("Advanced version details") {
      VStack(alignment: .leading, spacing: 4) {
        Text("Source revision")
          .font(.caption.weight(.medium))
        if let running {
          LabeledContent("Running") {
            Text(verbatim: running.revision)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
        if let installed {
          LabeledContent("Installed") {
            Text(verbatim: installed.revision)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
      }
      .padding(.top, 4)
    }
    .font(.caption)
  }

  var coreActivationButtonTitle: LocalizedStringKey {
    switch updateChecker.runtimeVersionState {
    case .blocked, .failed: "Try Apply Again…"
    default: "Apply Installed Update…"
    }
  }

  var coreActivationActionHint: LocalizedStringKey {
    switch updateChecker.runtimeVersionState {
    case .pending, .blocked, .failed:
      "Switch away from Linnet before applying the installed Core update."
    case .restartRequired, .unsupported:
      "Installed Core will run after the next normal login or restart."
    case .applying:
      "The installed Core update is being applied."
    default:
      "No installed Core update is waiting to be applied."
    }
  }

  func coreActivationInstruction(
    _ issue: LinnetSettingsContract.CoreActivationBlocker
  ) -> LocalizedStringKey {
    switch issue {
    case .inputSourceActive:
      "Use the macOS input menu to select another input source, then try again."
    case .inputSourceUnavailable:
      "The selected input source could not be read. Select another input source in the macOS input menu, then try again."
    case .compositionActive:
      "Finish or cancel the current composition, then try again."
    case .dataTransactionActive:
      "Wait for the current data operation to finish, then try again."
    case .applicationsStillRunning:
      "This older running Core cannot replace itself in this session. The installed update remains ready for the next normal login."
    case .unknownClient:
      "This older running Core cannot verify its inactive clients. The installed update remains ready for the next normal login."
    case .requesterUnavailable:
      "Settings could not establish the one safe activation requester. Reopen Settings and try again."
    }
  }

  func confirmCoreActivation() {
    guard !model.pendingChanges, !model.operationActive else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "Apply the installed Core now?")
    alert.informativeText = String(localized:
      "First use the macOS input menu to select another input source.")
      + " "
      + String(localized:
        "Your apps stay open. Settings closes after the new Core is verified.")
    let apply = alert.addButton(withTitle: String(localized: "Apply Now"))
    apply.keyEquivalent = "\r"
    let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
    cancel.keyEquivalent = "\u{1b}"
    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .alertFirstButtonReturn else { return }
      updateChecker.activateInstalledCore()
    }
    if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  @ViewBuilder var updateCheckRow: some View {
    Divider()
    HStack(alignment: .center, spacing: 10) {
      updateCheckLabel
      Spacer()
      if case .core = updateChecker.availability {
        Button("View Core Update") { updateChecker.openCoreUpdate() }
      }
      Button("Check Again") { updateChecker.check() }
        .disabled(updateChecker.active || updateChecker.activationInProgress)
    }
  }

  @ViewBuilder var updateCheckLabel: some View {
    if updateChecker.active {
      Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
        .foregroundStyle(.secondary)
    } else if updateChecker.failed {
      Label("Update check failed. Try again when you are online.", systemImage: "wifi.exclamationmark")
        .foregroundStyle(.orange)
    } else {
      switch updateChecker.availability {
      case .some(.current):
        Label("Linnet and language data are up to date.", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .some(.localDataAhead):
        Label("Installed language data is newer than this update channel. No downgrade will be downloaded.",
              systemImage: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
      case .some(.core(let core)):
        VStack(alignment: .leading, spacing: 2) {
          Label("Core update available", systemImage: "arrow.down.circle.fill")
            .foregroundStyle(.orange)
          LabeledContent("Current") {
            if let installed = updateChecker.installedIdentity {
              Text(verbatim: productIdentityDescription(installed))
            } else {
              Text("Unavailable").foregroundStyle(.secondary)
            }
          }
          .font(.caption.monospacedDigit())
          LabeledContent("Available") {
            Text(verbatim: "\(core.version) (\(core.build))")
          }
          .font(.caption.monospacedDigit())
          Text("The Core update does not require another logout. macOS may ask you to approve the unsigned package.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      case .some(.languageData(let updates)):
        VStack(alignment: .leading, spacing: 4) {
          Label(
            "Language-data updates are available. No logout is required.",
            systemImage: "arrow.down.circle.fill"
          )
          .foregroundStyle(Color.accentColor)
          ForEach(updates, id: \.kind.rawValue) { update in
            VStack(alignment: .leading, spacing: 1) {
              Text(packLabel(update.kind)).font(.caption.weight(.medium))
              Text(verbatim: updateDescription(update))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      case nil:
        if updateChecker.installedIdentity == nil {
          Label(
            "Update status is unavailable until the installation is repaired.",
            systemImage: "exclamationmark.circle"
          )
          .foregroundStyle(.orange)
        } else {
          Label("Update status is not available yet.", systemImage: "info.circle")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  var languageDataEditionLabel: LocalizedStringKey {
    switch model.dataEdition {
    case .some(.full): "Complete offline"
    case .some(.standard): "Recommended"
    case nil: "Unavailable"
    }
  }

  var orderedInstalledPacks: [LinnetDataRegistry.ActivePack] {
    let order: [LinnetPackContract.Kind] = [.chinese, .english, .lts, .extended]
    return model.installedPacks.sorted {
      (order.firstIndex(of: $0.kind) ?? order.count)
        < (order.firstIndex(of: $1.kind) ?? order.count)
    }
  }

  func packLabel(_ kind: LinnetPackContract.Kind) -> LocalizedStringKey {
    switch kind {
    case .chinese: "Chinese data"
    case .english: "English data"
    case .lts: "Chinese grammar model"
    case .extended: "Long-tail data"
    }
  }
  func updateDescription(_ update: LinnetDataChannel.LanguageDataUpdate) -> String {
    let installed = if let version = update.installedVersion,
      let sequence = update.installedSequence {
      packReleaseDescription(version: version, sequence: sequence)
    } else {
      String(localized: "Not installed")
    }
    return "\(String(localized: "Current")): \(installed) → "
      + "\(String(localized: "Available")): \(update.availableVersion) · "
      + "\(String(localized: "Data release")) \(update.availableSequence)"
  }
  func packReleaseDescription(version: String, sequence: UInt64) -> String {
    "\(version) · \(String(localized: "Data release")) \(sequence)"
  }

  var grammarModelSection: some View {
    GroupBox("Chinese sentence model") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: model.grammarModelStatus == .ltsActive
            ? "brain.head.profile.fill" : "brain.head.profile")
            .font(.title2)
            .foregroundStyle(model.grammarModelStatus == .ltsActive ? .green : .secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(model.grammarModelStatus.label)
              .font(.callout.weight(.medium))
            grammarModelDescription
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
        Divider()
        // Keep the complete localization key intact for String Catalog lookup.
        // swiftlint:disable:next line_length
        Text("The Wanxiang LTS grammar model (420 MB) is part of every recommended Linnet installation and improves long-sentence prediction. It is an input-method n-gram model, not a generative large language model. Data updates are fully verified before atomic activation.")
          .font(.caption2).foregroundStyle(.secondary)
      }.padding(8)
    }
  }

  @ViewBuilder var grammarModelDescription: some View {
    switch model.grammarModelStatus {
    case .ltsActive: Text("Better prediction for long Chinese sentences.")
    case .missing: Text("The recommended Chinese grammar model is not active.")
    case .checking: EmptyView()
    }
  }
}

extension DataTabView {
  var downloadSourceControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(
        "Download source",
        selection: Binding(
          get: { model.downloadSourceMode },
          set: { model.selectDownloadSourceMode($0) }
        )
      ) {
        Text("GitHub (Direct)").tag(LinnetSettingsDownloadSource.Mode.github)
        Text("GH-Proxy Public Mirror (Third-party)")
          .tag(LinnetSettingsDownloadSource.Mode.publicMirror)
        Text("Custom Mirror…").tag(LinnetSettingsDownloadSource.Mode.customMirror)
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("settings.data.downloadSource")
      .disabled(model.downloadSourceEditorDisabled)

      if model.downloadSourceMode == .publicMirror {
        Text(
          "GH-Proxy is an independent third-party service and is not operated by Linnet or GitHub."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Link(
          "Open GH-Proxy Service Information",
          destination: LinnetSettingsDownloadSource.publicMirrorInformationURL
        )
        .font(.caption)
        if model.downloadSourceFailure == .unavailablePublicMirror {
          Label(
            "This built-in mirror is unavailable. Choose another source before updating.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.red)
        }
      }

      if model.downloadSourceMode == .customMirror {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          TextField(
            "Custom mirror base URL",
            text: Binding(
              get: { model.downloadMirrorPrefix },
              set: { model.updateDownloadMirrorPrefix($0) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityHint(
            "Enter the HTTPS root address provided by a GHProxy-compatible service.")
          Button("Use Custom Mirror") { model.useDownloadMirror() }
            .disabled(!model.canUseDownloadMirror)
        }
        .disabled(model.downloadSourceEditorDisabled)

        if model.downloadSourceFailure != nil || !model.downloadMirrorIsValid {
          Label(
            "Enter a compatible HTTPS mirror root address.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.red)
        } else if model.downloadSourceNeedsSave {
          Text("Use Custom Mirror to make this address active before downloading.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Text("GitHub Direct is the default. Choose a mirror only when direct downloads are unreliable.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(
        // Keep the complete localization key intact for String Catalog lookup.
        // swiftlint:disable:next line_length
        "Mirrors are third-party services that can see your IP address, request time, and requested public file URLs. Linnet never sends them your dictionaries, learning data, credentials, or other personal data."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text(
        "The selected source is used only for future language-data downloads. Linnet never switches or falls back to another source automatically."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Text("Linnet verifies every downloaded release pack before activation.")
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  var longTailDescription: LocalizedStringKey {
    switch model.dataEdition {
    case .some(.full):
      "Names, places, medical, technical, professional, and deep-tail dictionaries are active."
    case .some(.standard):
      "Install the optional long-tail dictionaries for maximum offline coverage."
    case nil:
      "Repair the installation before managing language data."
    }
  }

  var languageDataUpdateDescription: LocalizedStringKey? {
    guard !model.languageDataUpdatesAvailable else { return nil }
    if !model.downloadSourceConfigured {
      return "Choose and save a valid download source before checking for updates."
    }
    return "Repair the installation before managing language data."
  }

  var legacyDataDescription: LocalizedStringKey {
    switch model.legacyImportState {
    case .unavailable: "Data services are unavailable."
    case .checking: "Checking detected legacy data…"
    case .none: "No compatible legacy data was found."
    case .compatible: "Compatible legacy data was verified."
    case .failed: "Detected legacy data could not be verified."
    }
  }

  var backupSection: some View {
    GroupBox("Recovery history") {
      VStack(alignment: .leading, spacing: 8) {
        Text("These recovery points are created before data-changing transactions; they are not automatic full backups.")
          .font(.caption).foregroundStyle(.secondary)
        Text("Full backup archives are created only when you choose a backup or export button.")
          .font(.caption2).foregroundStyle(.secondary)
        Picker("Retention", selection: $model.backupRetentionPolicy) {
          ForEach(LinnetSettingsContract.BackupRetentionPolicy.allCases, id: \.self) {
            Text(backupRetentionName($0)).tag($0)
          }
        }
        .accessibilityIdentifier("settings.data.retention")
        .disabled(model.operationActive)
        .onChange(of: model.backupRetentionPolicy) { _ in
          model.saveBackupRetentionPolicy()
        }
        Text(
          "Retention limits apply to verified backups. Existing incomplete or invalid records are not removed automatically."
        )
        .font(.caption).foregroundStyle(.secondary)
        Divider()
        switch model.backupHistory {
        case .unavailable:
          Label(
            SettingsPresentationStatus.backupsUnavailable.text(locale: locale),
            systemImage: "exclamationmark.triangle.fill"
          )
            .foregroundStyle(.red)
            .accessibilityLabel(
              SettingsPresentationStatus.backupsUnavailable.text(locale: locale))
        case .loading:
          Label("Loading backups…", systemImage: "hourglass")
            .foregroundStyle(.secondary)
        case .failed:
          Label(
            SettingsPresentationStatus.backupsUnavailable.text(locale: locale),
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.red)
        case .loaded(let records) where records.isEmpty:
          Text("No data-operation backups yet.")
            .foregroundStyle(.secondary)
        case .loaded:
          EmptyView()
        }
        ForEach(backupRecords, id: \.transactionDirectory.path) { record in
          HStack {
            Image(systemName: backupSymbol(record.state))
              .foregroundStyle(backupColor(record.state))
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(backupTitle(record.state).text(locale: locale))
                .font(.callout.weight(.medium))
              if let createdAt = record.createdAt {
                Text(verbatim: createdAt.formatted(date: .abbreviated, time: .standard))
                  .font(.caption).foregroundStyle(.secondary)
              } else {
                Text("No completion timestamp")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Button("Reveal") { model.reveal(record) }
            if case .verified = record.state {
              Button("Restore") { pendingRestore = record }
                .disabled(!model.canRestoreBackup || model.operationActive)
            } else if record.transactionID != nil {
              Button {
                pendingBackupRemoval = record
              } label: {
                Text(verbatim: SettingsBackupRemovalCopy.rowAction(locale: locale))
              }
              .disabled(model.operationActive)
            }
          }
          Divider()
        }
      }.padding(8)
    }
  }

  var backupRecords: [LinnetBackupStore.BackupRecord] {
    switch model.backupHistory {
    case .unavailable: []
    case .loading(let records), .loaded(let records), .failed(let records): records
    }
  }

  var diagnosticsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let diagnostics = model.diagnostics {
        Text(SettingsPresentationStatus.runtime(diagnostics.reachability).text(locale: locale))
          .font(.callout.weight(.medium))
        Text(diagnostics.redactedReport)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      } else {
        Text("Diagnostics have not been collected.").foregroundStyle(.secondary)
      }
      HStack {
        Button("Refresh") { model.refreshDiagnostics() }
          .disabled(model.operationActive)
        Button("Copy Report") { model.copyDiagnostics() }
          .disabled(model.diagnostics == nil)
        Button("Save…") { model.saveDiagnostics(locale: locale) }
          .disabled(model.diagnostics == nil)
        Spacer()
        Text(
          "Reports contain counts and versions, never words, learning rows, identity, or paths."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

}

private func backupTitle(_ state: LinnetBackupStore.BackupState) -> SettingsPresentationStatus {
  switch state {
  case .verified(let manifest): .backupVerified(backupOperation(manifest.operation))
  case .incomplete: .backupIncomplete
  case .corrupt: .backupInvalid
  }
}

private func backupOperation(_ operation: LinnetBackupStore.BackupOperation) -> SettingsOperationKind {
  switch operation {
  case .applyPersonalData: .apply
  case .importLegacy: .legacy
  case .importPortable: .portableImport
  case .restore: .restore
  case .clearLearning: .clearLearning
  }
}

private func backupRetentionName(_ policy: LinnetSettingsContract.BackupRetentionPolicy) -> LocalizedStringKey {
  switch policy {
  case .keepLatest10: "Keep latest 10 verified backups"
  case .keepLatest30: "Keep latest 30 verified backups"
  case .keepLatest100: "Keep latest 100 verified backups"
  }
}

private func backupSymbol(_ state: LinnetBackupStore.BackupState) -> String {
  switch state {
  case .verified: "checkmark.shield"
  case .incomplete: "clock.badge.exclamationmark"
  case .corrupt: "xmark.shield"
  }
}

private func backupColor(_ state: LinnetBackupStore.BackupState) -> Color {
  switch state {
  case .verified: .green
  case .incomplete: .orange
  case .corrupt: .red
  }
}
