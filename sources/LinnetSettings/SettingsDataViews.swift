//
//  SettingsDataViews.swift
//  Data-page controls for downloads, backup history, and diagnostics.
//

import AppKit
import SwiftUI

extension DataTabView {
  var cloudSyncSection: some View {
    GroupBox("iCloud Drive sync") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle(
          "Sync learned words with iCloud Drive",
          isOn: Binding(
            get: { model.cloudSyncEnabled },
            set: { model.setCloudSyncEnabled($0) })
        )
        .disabled(model.operationActive)

        if let location = model.cloudSyncLocation {
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
            .disabled(model.cloudSyncLocation == nil || model.operationActive)
          Button("Upload Full Backup…") { pendingCloudBackupUpload = true }
            .disabled(model.cloudSyncLocation == nil || model.operationActive)
          Button("Review Full Backup…") {
            Task {
              pendingPortableImport = await model.inspectCloudBackupArchive()
            }
          }
          .disabled(
            model.cloudSyncLocation == nil || !model.configuration.canPersist
              || model.operationActive || model.portableInspectionActive)
        }
        Text(
          "The full backup also includes personal words, disabled words, and Text Expander data. It is a manual recovery archive, not a second learning-sync engine."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var versionSection: some View {
    GroupBox("Version") {
      VStack(alignment: .leading, spacing: 8) {
        LabeledContent("Application") { Text(verbatim: model.productName) }
        LabeledContent("Version") {
          Text(verbatim: "\(model.appVersion) (\(model.appBuild))")
        }
        LabeledContent("Language data") { Text(languageDataEditionLabel) }
        runtimeVersionRow
        updateCheckRow
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

  @ViewBuilder var runtimeVersionRow: some View {
    switch updateChecker.runtimeVersionState {
    case .checking:
      LabeledContent("Running Core") { Text("Checking…") }
        .foregroundStyle(.secondary)
    case .current(let identity):
      LabeledContent("Running Core") {
        Text(verbatim: productIdentityDescription(identity))
      }
    case .pending(let installed, let running):
      VStack(alignment: .leading, spacing: 4) {
        Label("Installed Core update is ready", systemImage: "checkmark.circle")
          .foregroundStyle(.orange)
        LabeledContent("Running") {
          Text(verbatim: productIdentityDescription(running))
        }
        LabeledContent("Installed") {
          Text(verbatim: productIdentityDescription(installed))
        }
        Text(
          "The current Core keeps its existing app connections. The installed Core will run the next time macOS starts Linnet. You do not need to close apps or log out."
        )
          .font(.caption2)
          .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    case .unavailable:
      VStack(alignment: .leading, spacing: 4) {
        Label("Running Core identity is unavailable.", systemImage: "exclamationmark.circle")
        Text(
          "Updates do not stop the current Core or its app connections. The installed Core will run on the next normal Linnet start."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        Button("Check Runtime Again") { updateChecker.refreshRuntime() }
      }
    }
  }

  func productIdentityDescription(
    _ identity: LinnetSettingsContract.ProductIdentity
  ) -> String {
    "\(identity.version) (\(identity.build)) · \(identity.revision.prefix(8))"
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
        .disabled(updateChecker.active)
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
      case .some(.core(let core)):
        VStack(alignment: .leading, spacing: 2) {
          Label("Core update available", systemImage: "arrow.down.circle.fill")
            .foregroundStyle(.orange)
          LabeledContent("Current") {
            Text(verbatim: "\(model.appVersion) (\(model.appBuild))")
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
              Text(updatePackLabel(update.kind)).font(.caption.weight(.medium))
              Text(verbatim: updateDescription(update))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      case nil:
        Label("Update status is not available yet.", systemImage: "info.circle")
          .foregroundStyle(.secondary)
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
    let order: [LinnetDataRegistry.PackKind] = [.chinese, .english, .lts, .extended]
    return model.installedPacks.sorted {
      (order.firstIndex(of: $0.kind) ?? order.count)
        < (order.firstIndex(of: $1.kind) ?? order.count)
    }
  }

  func packLabel(_ kind: LinnetDataRegistry.PackKind) -> LocalizedStringKey {
    switch kind {
    case .chinese: "Chinese data"
    case .english: "English data"
    case .lts: "Chinese grammar model"
    case .extended: "Long-tail data"
    }
  }

  func updatePackLabel(_ kind: LinnetPackContract.Kind) -> LocalizedStringKey {
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
    if model.dataChannelService == .published && !model.downloadSourceConfigured {
      return "Choose and save a valid download source before checking for updates."
    }
    return switch model.dataChannelService {
    case .unpublished:
      "Online language-data updates are not available for this version yet."
    case .published:
      "Repair the installation before managing language data."
    }
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
    GroupBox("Automatic backups") {
      VStack(alignment: .leading, spacing: 8) {
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
    GroupBox("Diagnostics") {
      VStack(alignment: .leading, spacing: 10) {
        if let diagnostics = model.diagnostics {
          Text(runtimeStatus(diagnostics.reachability).text(locale: locale))
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
      }.padding(8)
    }
  }

  func runtimeStatus(
    _ reachability: SettingsDataCoordinator.Diagnostics.Reachability
  ) -> SettingsPresentationStatus {
    switch reachability {
    case .running: .runtime(.running)
    case .paused: .runtime(.paused)
    case .degraded: .runtime(.degraded)
    case .unreachable: .runtime(.unreachable)
    }
  }
}

// MARK: - Shared helpers

func sectionHeader(
  _ title: LocalizedStringKey,
  help: LocalizedStringKey,
  add: @escaping () -> Void
) -> some View {
  HStack {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.callout.weight(.medium))
      Text(help).font(.caption).foregroundStyle(.secondary)
    }
    Spacer()
    Button(action: add) { Image(systemName: "plus") }
      .accessibilityLabel(Text("Add") + Text(" ") + Text(title))
      .help(Text("Add") + Text(" ") + Text(title))
  }
}

func removeButton(
  _ label: LocalizedStringKey,
  action: @escaping () -> Void
) -> some View {
  Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
    .buttonStyle(.borderless)
    .accessibilityLabel(Text(label))
    .help(Text(label))
}

func categoryName(_ category: LinnetBackupStore.Category) -> LocalizedStringKey {
  switch category {
  case .customWords: "Custom words"
  case .disabledWords: "Disabled words"
  case .textExpander: "Text Expander"
  case .chineseLearning: "Chinese learning"
  case .englishLearning: "English learning"
  }
}

private func backupTitle(
  _ state: LinnetBackupStore.BackupState
) -> SettingsPresentationStatus {
  switch state {
  case .verified(let manifest): .backupVerified(backupOperation(manifest.operation))
  case .incomplete: .backupIncomplete
  case .corrupt: .backupInvalid
  }
}

private func backupOperation(
  _ operation: LinnetBackupStore.BackupOperation
) -> SettingsOperationKind {
  switch operation {
  case .applyPersonalData: .apply
  case .importLegacy: .legacy
  case .importPortable: .portableImport
  case .restore: .restore
  case .clearLearning: .clearLearning
  }
}

private func backupRetentionName(
  _ policy: LinnetSettingsContract.BackupRetentionPolicy
) -> LocalizedStringKey {
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
