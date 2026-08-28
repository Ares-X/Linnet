import AppKit
import SwiftUI

private enum SettingsInterfaceLanguage: String, CaseIterable {
  static let defaultsKey = "Linnet.Settings.InterfaceLanguage"

  case system
  case english
  case simplifiedChinese

  var locale: Locale {
    switch self {
    case .system: .autoupdatingCurrent
    case .english: Locale(identifier: "en")
    case .simplifiedChinese: Locale(identifier: "zh-Hans")
    }
  }
}

private extension SettingsPresentationSeverity {
  var footerColor: Color {
    switch self {
    case .informational: .secondary
    case .success: .green
    case .progress: .accentColor
    case .warning: .orange
    case .error: .red
    }
  }
}

struct SettingsRootView: View {
  @StateObject private var model = SettingsModel()
  @AppStorage(SettingsInterfaceLanguage.defaultsKey)
  private var interfaceLanguageRawValue = SettingsInterfaceLanguage.system.rawValue
  @State private var pendingClear: Set<SettingsDataCoordinator.LearningDomain>?
  @State private var pendingPortableImport: SettingsDataCoordinator.PortableImportCandidate?
  @State private var pendingRestore: LinnetBackupStore.BackupRecord?
  @State private var pendingBackupRemoval: LinnetBackupStore.BackupRecord?
  @State private var pendingLegacyImport: SettingsDataCoordinator.LegacyImportCandidate?
  @State private var pendingCloudBackupUpload = false

  var body: some View {
    VStack(spacing: 0) {
      conflictNotice
      tabs
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
    .task {
      await model.prepareInitialState()
      model.refreshBackups()
      model.refreshLegacyImportCandidate()
      if model.diagnostics == nil { model.refreshDiagnostics() }
    }
    .confirmationDialog(
      "Upload a full recovery backup?",
      isPresented: $pendingCloudBackupUpload,
      titleVisibility: .visible
    ) {
      Button("Upload and Replace", role: .destructive) { model.uploadCloudBackupArchive() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This replaces iCloud Drive/Linnet/Linnet-Full-Backup.linnet-data. Local data is not changed."
      )
    }
    .confirmationDialog(
      "Import existing Rime / Hallelujah data?",
      isPresented: presented($pendingLegacyImport),
      titleVisibility: .visible
    ) {
      Button("Import Existing", role: .destructive) {
        if let pendingLegacyImport { model.importExistingData(pendingLegacyImport) }
        pendingLegacyImport = nil
      }
      Button("Cancel", role: .cancel) { pendingLegacyImport = nil }
    } message: {
      if let pendingLegacyImport {
        Text(verbatim: model.legacyImportSummary(
          pendingLegacyImport, locale: interfaceLanguage.locale))
      }
    }
    .confirmationDialog(
      "Clear selected learning data?",
      isPresented: presented($pendingClear),
      titleVisibility: .visible
    ) {
      Button("Clear Learning", role: .destructive) {
        if let pendingClear { model.clearLearning(pendingClear) }
        pendingClear = nil
      }
      Button("Cancel", role: .cancel) { pendingClear = nil }
    } message: {
      Text(
        "Personal words, disabled words, Text Expander, and English interaction settings are preserved. An automatic backup is created first."
      )
    }
    .confirmationDialog(
      "Replace categories from this portable archive?",
      isPresented: presented($pendingPortableImport),
      titleVisibility: .visible
    ) {
      Button("Import and Replace", role: .destructive) {
        if let pendingPortableImport { model.importPortable(pendingPortableImport) }
        pendingPortableImport = nil
      }
      Button("Cancel", role: .cancel) { pendingPortableImport = nil }
    } message: {
      if let pendingPortableImport {
        Text(verbatim: model.portableImportSummary(
          pendingPortableImport, locale: interfaceLanguage.locale))
      }
    }
    .confirmationDialog(
      "Restore this verified backup?",
      isPresented: presented($pendingRestore),
      titleVisibility: .visible
    ) {
      Button("Restore Backup", role: .destructive) {
        if let pendingRestore { model.restore(pendingRestore) }
        pendingRestore = nil
      }
      Button("Cancel", role: .cancel) { pendingRestore = nil }
    } message: {
      Text("The verified backup replaces current data. The current state is backed up first.")
    }
    .confirmationDialog(
      SettingsBackupRemovalCopy.title(locale: interfaceLanguage.locale),
      isPresented: presented($pendingBackupRemoval),
      titleVisibility: .visible
    ) {
      Button(
        SettingsBackupRemovalCopy.confirmAction(locale: interfaceLanguage.locale),
        role: .destructive
      ) {
        if let pendingBackupRemoval { model.removeBackupRecord(pendingBackupRemoval) }
        pendingBackupRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingBackupRemoval = nil }
    } message: {
      Text(verbatim: SettingsBackupRemovalCopy.message(locale: interfaceLanguage.locale))
    }
    .background(SettingsWindowCloseGuard(model: model, locale: interfaceLanguage.locale))
    .onAppear { registerApplicationDelegate() }
    .onChange(of: interfaceLanguageRawValue) { _ in registerApplicationDelegate() }
    .environment(\.locale, interfaceLanguage.locale)
  }

  @ViewBuilder private var conflictNotice: some View {
    if model.configuration.hasExternalConflict {
      GroupBox("Settings data changed elsewhere") {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Your unsaved drafts were preserved. Reload the current settings data, or keep your drafts and review them before applying."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          HStack {
            Button("Reload Current Data") { model.reloadExternalChanges() }
            Button("Keep My Drafts") { model.keepPendingDrafts() }
          }
        }
        .padding(8)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  private var tabs: some View {
    TabView {
      AppearanceTabView(model: model)
        .tabItem { Label("Appearance", systemImage: "paintbrush.pointed") }
      InputTabView(model: model)
        .tabItem { Label("Chinese Input", systemImage: "keyboard") }
      EnglishTabView(model: model)
        .tabItem {
          Label {
            Text("Smart English")
          } icon: {
            LinnetSettingsPageMarkView(mark: .latinABC, context: .tab)
              .font(.system(size: 10, weight: .bold))
          }
        }
      DictionaryTabView(model: model)
        .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
      DataTabView(
        model: model,
        updateChecker: model.updateChecker,
        pendingClear: $pendingClear,
        pendingPortableImport: $pendingPortableImport,
        pendingCloudBackupUpload: $pendingCloudBackupUpload,
        pendingRestore: $pendingRestore,
        pendingBackupRemoval: $pendingBackupRemoval,
        pendingLegacyImport: $pendingLegacyImport
      )
      .tabItem { Label("Data", systemImage: "internaldrive") }
    }
  }

  private var interfaceLanguage: SettingsInterfaceLanguage {
    SettingsInterfaceLanguage(rawValue: interfaceLanguageRawValue) ?? .system
  }

  private func registerApplicationDelegate() {
    guard let delegate = NSApp.delegate as? SettingsApplicationDelegate else { return }
    delegate.model = model
    delegate.interfaceLocale = interfaceLanguage.locale
  }

  private func presented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
    Binding(
      get: { value.wrappedValue != nil },
      set: { if !$0 { value.wrappedValue = nil } }
    )
  }

  private var interfaceLanguageBinding: Binding<SettingsInterfaceLanguage> {
    Binding(
      get: { interfaceLanguage },
      set: { interfaceLanguageRawValue = $0.rawValue }
    )
  }

  private var footer: some View {
    let presentation = model.displayedStatus.presentation(locale: interfaceLanguage.locale)
    return HStack(spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: presentation.systemImage)
          .accessibilityHidden(true)
        Text(verbatim: presentation.text)
          .font(.callout)
          .lineLimit(2)
          .help(presentation.text)
      }
      .foregroundStyle(presentation.severity.footerColor)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
      .accessibilityAddTraits(.updatesFrequently)
      Spacer()
      if let active = model.activeOperation {
        ProgressView().controlSize(.small)
        Text(
          SettingsPresentationStatus.operationProgress(active.kind, active.phase)
            .text(locale: interfaceLanguage.locale)
        )
        .font(.callout)
        Button("Cancel") { model.cancelActiveOperation() }
          .disabled(!active.cancellable)
      } else if model.packDownloadCancellable {
        ProgressView(value: model.packDownloadProgress)
          .frame(width: 80)
          .accessibilityLabel("Language data download")
          .accessibilityValue(
            Text(model.packDownloadProgress, format: .percent.precision(.fractionLength(0))))
        Button("Cancel Download") { model.cancelLanguagePackDownload() }
      }
      Picker(selection: interfaceLanguageBinding) {
        Text("Follow System").tag(SettingsInterfaceLanguage.system)
        Text(verbatim: "English").tag(SettingsInterfaceLanguage.english)
        Text(verbatim: "简体中文").tag(SettingsInterfaceLanguage.simplifiedChinese)
      } label: {
        Label("Language", systemImage: "globe")
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("settings.interfaceLanguage")
      .fixedSize()
      Button("Apply Changes") { model.applyConfiguration() }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canApplyChanges)
        .help(
          "Theme, font, and appearance mode save and apply to the candidate window live. Candidate count, candidate layouts, Input, English, and personal data require Apply Changes."
        )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }
}
