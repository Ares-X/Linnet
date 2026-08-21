//
//  SettingsViews.swift
//  Tab views for the embedded Linnet Settings application. All views bind to
//  the shared SettingsModel. Panel-only appearance publishes live; page size,
//  candidate layouts, and other session-backed values wait for Apply Changes.
//

import AppKit
import SwiftUI

// MARK: - Appearance

struct AppearanceTabView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    LinnetSettingsPage(
      "Appearance",
      summary: "Choose a candidate-window theme and refine it before typing.",
      systemImage: "paintbrush.pointed"
    ) {
      LinnetSettingsTwoColumnLayout {
        appearanceControls
      } trailing: {
        appearancePreview
      }
      .disabled(!model.configuration.canPersist)
    }
    .onChange(of: model.configuration.documentDraft.appearance) { appearance in
      model.publishAppearance(appearance)
    }
  }

  private var appearanceControls: some View {
    GroupBox("Candidate window") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Candidate font size")
          Spacer()
          Text(fontPointLabel(model.configuration.documentDraft.appearance.fontPoint))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Slider(
          value: $model.configuration.documentDraft.appearance.fontPoint,
          in: LinnetSettingsDocument.Appearance.minimumFontPoint
            ... LinnetSettingsDocument.Appearance.maximumFontPoint,
          step: LinnetSettingsDocument.Appearance.fontPointStep
        )
        .accessibilityLabel("Candidate font size")
        .accessibilityValue(fontPointLabel(model.configuration.documentDraft.appearance.fontPoint))
        Text(
          "12–32 pt. The local visual preview updates immediately; the live candidate window follows the appearance setting."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Divider()

        Picker("Typeface", selection: $model.configuration.documentDraft.appearance.fontPreset) {
          ForEach(LinnetSettingsDocument.FontPreset.allCases, id: \.self) { preset in
            if preset == .system {
              Text("System Default").tag(preset)
            } else {
              Text(verbatim: preset.displayPair).tag(preset)
            }
          }
        }
        HStack(spacing: 10) {
          Text("双韵 Linnet")
            .font(Font(LinnetCandidatePresentation.platformFont(
              fontNames: model.configuration.documentDraft.appearance.fontPreset.fontFamilies,
              size: 17)))
          if model.configuration.documentDraft.appearance.fontPreset == .system {
            Text("Selected automatically by macOS")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text(verbatim: model.configuration.documentDraft.appearance.fontPreset.displayPair)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(
          "Candidates and IPA share the Latin face; Chinese candidates and definitions share the Chinese face. All presets use built-in macOS fonts."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Divider()

        Picker("Candidates per page", selection: $model.configuration.documentDraft.appearance.pageSize) {
          ForEach(LinnetSettingsDocument.Appearance.pageSizeOptions, id: \.self) { size in
            Text("\(size)").tag(size)
          }
        }
        .pickerStyle(.segmented)
        Text("Candidate count is applied with the schema after you press Apply Changes.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()

        Picker("Chinese candidates", selection: $model.configuration.documentDraft.appearance.chineseCandidateLayout) {
          Text("Horizontal").tag(LinnetSettingsDocument.CandidateLayout.horizontal)
          Text("Vertical").tag(LinnetSettingsDocument.CandidateLayout.vertical)
        }
        .pickerStyle(.segmented)
        Picker("English candidates", selection: $model.configuration.documentDraft.appearance.englishCandidateLayout) {
          Text("Horizontal").tag(LinnetSettingsDocument.CandidateLayout.horizontal)
          Text("Vertical").tag(LinnetSettingsDocument.CandidateLayout.vertical)
        }
        .pickerStyle(.segmented)

        Picker(
          "Candidate browsing",
          selection: $model.configuration.documentDraft.appearance.candidateBrowsingMode
        ) {
          Text("Scrolling only").tag(
            LinnetSettingsDocument.CandidateBrowsingMode.scrollingOnly)
          Text("Expandable").tag(
            LinnetSettingsDocument.CandidateBrowsingMode.expandable)
        }
        .pickerStyle(.segmented)
        Text(
          "Chinese and English keep independent horizontal or vertical layouts. Expandable browsing adds a candidate-window arrow that temporarily shows up to three pages; every new composition starts collapsed. These changes take effect after Apply Changes."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var appearancePreview: some View {
    VStack(alignment: .leading, spacing: 16) {
      LinnetSettingsThemeFamilyPicker(
        selection: $model.configuration.documentDraft.appearance.themeFamily,
        mode: $model.configuration.documentDraft.appearance.themeMode
      )
      LinnetSettingsAppearancePreviewView(appearance: model.configuration.documentDraft.appearance)
      Text(
        "The preview and candidate window use this theme. Settings keeps the native macOS appearance."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func fontPointLabel(_ value: Double) -> String {
    value == value.rounded()
      ? "\(Int(value)) pt"
      : String(format: "%.1f pt", value)
  }

}

// MARK: - Input

struct InputTabView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    LinnetSettingsPage(
      "Input",
      summary: "Configure input behavior. Choose your Chinese scheme and reverse-lookup preferences here.",
      systemImage: "keyboard"
    ) {
      VStack(alignment: .leading, spacing: 16) {
        if inputChangesPending {
          Label(
            "Input changes are pending. Choose Apply Changes before testing them.",
            systemImage: "clock.badge.exclamationmark"
          )
          .font(.callout.weight(.medium))
          .foregroundStyle(.orange)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        LinnetSettingsTwoColumnLayout {
          VStack(alignment: .leading, spacing: 16) {
            schemeSection
            learningSection
            modeSection
          }
        } trailing: {
          VStack(alignment: .leading, spacing: 16) {
            optionsSection
            reverseLookupSection
          }
        }
      }
    }
  }

  private var schemeSection: some View {
    GroupBox("Chinese scheme") {
      VStack(alignment: .leading, spacing: 10) {
        Picker(
          "Chinese scheme",
          selection: $model.configuration.documentDraft.input.chineseProfile
        ) {
          ForEach(LinnetSettingsContract.ChineseProfile.allCases, id: \.self) { profile in
            Text(chineseProfileName(profile)).tag(profile)
          }
        }
        .pickerStyle(.menu)
        Text(
          "The selected scheme is used for Chinese input and pinyin-to-English lookup in Smart English."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .padding(8)
    }
    .disabled(!model.configuration.canEdit)
  }

  private var reverseLookupSection: some View {
    GroupBox("Pinyin reverse lookup") {
      VStack(alignment: .leading, spacing: 10) {
        Picker(
          "Reverse lookup trigger",
          selection: $model.configuration.documentDraft.input.pinyinReverseTrigger
        ) {
          ForEach(LinnetSettingsDocument.PinyinReverseTrigger.allCases, id: \.self) {
            Text(pinyinReverseTriggerName($0)).tag($0)
          }
        }
        .pickerStyle(.menu)
        .accessibilityHint(
          Text("Type the selected key before the chosen scheme's code in Chinese or Smart English.")
        )

        Text(
          "Type the selected key before the chosen scheme's code in Chinese or Smart English."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        Text(
          "Smart English also recognizes the chosen scheme's letter-only codes automatically. Use the trigger for codes that contain punctuation."
        )
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Example")
            .font(.callout.weight(.medium))
          Text(verbatim: reverseLookupExample)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }
        Text("The example follows the selected Chinese scheme and trigger key.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(8)
    }
    .disabled(!model.configuration.canEdit)
  }

  private var learningSection: some View {
    GroupBox("Chinese learning strategy") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Learning strategy", selection: $model.configuration.documentDraft.input.chineseLearningPolicy) {
          ForEach(LinnetSettingsDocument.ChineseLearningPolicy.allCases, id: \.self) {
            Text(chineseLearningPolicyName($0)).tag($0)
          }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Chinese learning strategy")
        .accessibilityValue(
          Text(chineseLearningPolicyName(model.configuration.documentDraft.input.chineseLearningPolicy))
        )
        .accessibilityHint(
          Text(
            "Takes effect after Apply Changes. Switching strategies never deletes learning data."
          )
        )

        Text(chineseLearningPolicyDescription(model.configuration.documentDraft.input.chineseLearningPolicy))
          .font(.callout)
          .foregroundStyle(.secondary)

        if model.configuration.documentDraft.input.chineseLearningPolicy
          != model.configuration.documentBaseline?.input.chineseLearningPolicy
        {
          Text("Changes pending — use Apply Changes to activate this strategy.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(
            "Changing this setting never deletes learning data. Use Clear Learning in Data to remove it."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(8)
    }
    .disabled(!model.configuration.canEdit)
  }

  private var optionsSection: some View {
    GroupBox("Chinese options") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("Suggest emoji candidates", isOn: $model.configuration.documentDraft.input.emojiEnabled)
        Toggle(
          "Output traditional Chinese by default",
          isOn: $model.configuration.documentDraft.input.traditionalChinese
        )
        Toggle(
          "Use English punctuation by default",
          isOn: $model.configuration.documentDraft.input.asciiPunctuationDefault
        )
        DisclosureGroup("Advanced") {
          Toggle(
            "Prefer single characters in auxiliary-code lookup by default",
            isOn: $model.configuration.documentDraft.input.singleCharacterSearchDefault
          )
          .padding(.top, 6)
        }
        Text(
          "These options are applied from Settings to each new input session; no keyboard shortcut changes them."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding(8)
    }
    .disabled(!model.configuration.canEdit)
  }

  private var modeSection: some View {
    GroupBox("Mode switching") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Tap Shift to switch between Chinese and Smart English. Caps Lock remains the explicit raw ASCII mode.")
        Text("The menu-bar label comes from Rime: 双 or 中 for Chinese, A for raw ASCII, and En for Smart English.")
          .font(.callout).foregroundStyle(.secondary)
      }.padding(8)
    }
  }

  private func chineseLearningPolicyName(
    _ policy: LinnetSettingsDocument.ChineseLearningPolicy
  ) -> LocalizedStringKey {
    switch policy {
    case .enhanced: "Enhanced learning (Recommended)"
    case .standard: "Standard learning"
    case .disabled: "Turn off learning"
    }
  }

  private func chineseProfileName(
    _ profile: LinnetSettingsContract.ChineseProfile
  ) -> LocalizedStringKey {
    switch profile {
    case .natural: "Natural Code"
    case .fullPinyin: "Full Pinyin"
    case .flypy: "Flypy Double Pinyin"
    case .microsoft: "Microsoft Double Pinyin"
    case .sogou: "Sogou Double Pinyin"
    case .abc: "Intelligent ABC"
    case .ziguang: "Ziguang Double Pinyin"
    case .jiajia: "Jiajia Pinyin"
    }
  }

  private func pinyinReverseTriggerName(
    _ trigger: LinnetSettingsDocument.PinyinReverseTrigger
  ) -> LocalizedStringKey {
    switch trigger {
    case .semicolon: "Semicolon (;)"
    case .verticalBar: "Vertical bar (|)"
    }
  }

  private func chineseLearningPolicyDescription(
    _ policy: LinnetSettingsDocument.ChineseLearningPolicy
  ) -> LocalizedStringKey {
    switch policy {
    case .enhanced:
      "Uses Rime's native learning and adds Linnet's extra phrase reinforcement for unfamiliar character-by-character compositions."
    case .standard:
      "Uses only Rime's native learning. It still remembers selected candidates and may learn short phrases assembled from segments."
    case .disabled:
      "Stops reading and updating Chinese learning data. Existing data returns when learning is enabled again."
    }
  }

  private var inputChangesPending: Bool {
    guard let baseline = model.configuration.documentBaseline else { return false }
    return model.configuration.documentDraft.input != baseline.input
  }

  private var reverseLookupExample: String {
    let input = model.configuration.documentDraft.input
    return "\(input.pinyinReverseTrigger.prefix)\(input.chineseProfile.reverseLookupExampleCode) → algorithm"
  }

}

// MARK: - Dictionary

struct DictionaryTabView: View {
  @Environment(\.locale) private var locale
  @ObservedObject var model: SettingsModel

  var body: some View {
    LinnetSettingsPage(
      "Dictionary",
      summary: "Keep personal words, exclusions, and text expansions in one place.",
      systemImage: "text.book.closed"
    ) {
      VStack(alignment: .leading, spacing: 16) {
        if let message = model.personalValidationMessage(locale: locale) {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .accessibilityLabel(message)
        } else if model.personalValidationPending {
          Label("Checking personal dictionary…", systemImage: "hourglass")
            .foregroundStyle(.secondary)
        }
        GroupBox("Personal dictionary") {
          VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
              "Custom words", help: "Value and lowercase Rime code", add: model.addCustomWord)
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach($model.configuration.personalDraft.customWords) { $row in
                HStack {
                  TextField("Value", text: $row.value)
                  TextField("code", text: $row.code).frame(width: 170)
                  removeButton("Remove custom word") { model.removeCustomWord(id: row.id) }
                }
              }
            }
            Divider()
            sectionHeader(
              "Disabled English words", help: "Case-insensitive exact words",
              add: model.addDisabledWord
            )
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(Array(model.configuration.personalDraft.disabledWords.indices), id: \.self) { index in
                HStack {
                  TextField(
                    "word",
                    text: Binding(
                      get: { model.configuration.personalDraft.disabledWords[index] },
                      set: { model.configuration.personalDraft.disabledWords[index] = $0 }
                    )
                  )
                  removeButton("Remove disabled word") { model.removeDisabledWord(at: index) }
                }
              }
            }
            Divider()
            sectionHeader(
              "Text Expander", help: "Explicit triggers begin with x;", add: model.addExpansion)
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach($model.configuration.personalDraft.expansions) { $row in
                HStack {
                  TextField("Expansion", text: $row.value)
                  TextField("x;trigger", text: $row.trigger).frame(width: 170)
                  removeButton("Remove text expansion") { model.removeExpansion(id: row.id) }
                }
              }
            }
            Text("Apply Changes is revision-checked and creates an automatic backup.")
              .font(.callout).foregroundStyle(.secondary)
          }.padding(8)
        }
        .disabled(!model.configuration.canEdit)
      }
    }
  }

}

// MARK: - English

struct EnglishTabView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    LinnetSettingsPage(
      "English",
      summary: "Tune completion, pronunciation, translation, and correction together.",
      mark: .latinABC
    ) {
      LinnetSettingsTwoColumnLayout {
        GroupBox("Candidate suggestions") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle("Show IPA pronunciation", isOn: $model.configuration.documentDraft.english.showIPA)
            Toggle(
              "Show Chinese definitions",
              isOn: $model.configuration.documentDraft.english.showTranslation
            )
            Toggle(
              "Show Smart English context suggestions",
              isOn: $model.configuration.documentDraft.english.predictionEnabled
            )
            Toggle(
              "Suggest spelling corrections",
              isOn: $model.configuration.documentDraft.english.spellingCorrection
            )
            Text(
              "IPA and Chinese definitions can be hidden independently. Smart English suggestions and correction change candidate generation; all settings take effect after Apply Changes."
            )
            .font(.caption).foregroundStyle(.secondary)
          }.padding(8)
        }
        .disabled(!model.configuration.canEdit)
      } trailing: {
        GroupBox("Typing behavior") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(
              "Capitalize sentence starts",
              isOn: $model.configuration.documentDraft.english.sentenceCapitalization
            )
            Toggle(
              "Learn from English selections",
              isOn: $model.configuration.documentDraft.english.learnFromSelections
            )
            Toggle(
              "Add a trailing space when Space accepts a candidate",
              isOn: $model.configuration.documentDraft.english.spaceAddsTrailingSpace
            )
            Picker("Tab key", selection: $model.configuration.documentDraft.english.tabBehavior) {
              Text("Smart complete").tag(LinnetSettingsDocument.TabBehavior.smartComplete)
              Text("Navigate candidates").tag(LinnetSettingsDocument.TabBehavior.navigate)
              Text("Pass to application").tag(LinnetSettingsDocument.TabBehavior.pass)
            }
            Text(
              "Turning off learning stops reading and updating English learning data. Existing data returns when learning is enabled again; static context suggestions and spacing remain available."
            )
            .font(.caption).foregroundStyle(.secondary)
          }.padding(8)
        }
        .disabled(!model.configuration.canEdit)
      }
    }
  }
}

// MARK: - Data

struct DataTabView: View {
  @Environment(\.locale) private var locale
  @ObservedObject var model: SettingsModel
  @ObservedObject var updateChecker: LinnetSettingsUpdateChecker
  @Binding var pendingClear: Set<SettingsDataCoordinator.LearningDomain>?
  @Binding var pendingPortableImport: SettingsDataCoordinator.PortableImportCandidate?
  @Binding var pendingCloudBackupUpload: Bool
  @Binding var pendingRestore: LinnetBackupStore.BackupRecord?
  @Binding var pendingBackupRemoval: LinnetBackupStore.BackupRecord?
  @Binding var pendingLegacyImport: SettingsDataCoordinator.LegacyImportCandidate?

  var body: some View {
    LinnetSettingsPage(
      "Data",
      summary: "Update language data, sync or move personal data, and review backups and diagnostics.",
      systemImage: "internaldrive"
    ) {
      VStack(alignment: .leading, spacing: 16) {
        versionSection
        grammarModelSection
        dataManagementSection
        cloudSyncSection
        backupSection
        diagnosticsSection
      }
    }
  }

  private var cloudSyncSection: some View {
    GroupBox("iCloud Drive sync") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            if let location = model.cloudSyncLocation {
              Text(location.displayName).font(.callout.weight(.medium))
              Text(verbatim: location.learningDirectory.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            } else {
              Text("No sync folder selected").font(.callout.weight(.medium))
              Text("Choose a folder inside iCloud Drive to connect this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button {
            model.chooseCloudSyncFolder(locale: locale)
          } label: {
            Text(
              model.cloudSyncLocation == nil
                ? String(localized: "Choose Folder…")
                : String(localized: "Change Folder…")
            )
          }
          .disabled(model.operationActive)
        }

        Text(
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
          Spacer()
          Button("Disconnect") { model.disconnectCloudSyncFolder() }
            .disabled(model.cloudSyncLocation == nil || model.operationActive)
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

  private var versionSection: some View {
    GroupBox("Version") {
      VStack(alignment: .leading, spacing: 8) {
        LabeledContent("Application") { Text(verbatim: model.productName) }
        LabeledContent("Version") {
          Text(verbatim: "\(model.appVersion) (\(model.appBuild))")
        }
        LabeledContent("Language data") { Text(languageDataEditionLabel) }
        updateCheckRow
        if model.installedPacks.isEmpty {
          LabeledContent("Data status") { Text("Installation needs repair") }
          Text("Reinstall Linnet to restore the required local language data.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(orderedInstalledPacks, id: \.kind.rawValue) { pack in
            LabeledContent(packLabel(pack.kind)) {
              HStack(spacing: 4) {
                Text(verbatim: pack.version)
                Text("revision")
                Text(verbatim: String(pack.sequence))
              }
            }
          }
        }
      }
      .padding(8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var updateCheckRow: some View {
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

  @ViewBuilder private var updateCheckLabel: some View {
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
          Text(verbatim: core.version)
            .font(.caption.monospacedDigit())
          Text("The Core update does not require another logout. macOS may ask you to approve the unsigned package.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      case .some(.languageData):
        Label("A language-data update is available below. No logout is required.", systemImage: "arrow.down.circle.fill")
          .foregroundStyle(Color.accentColor)
      case nil:
        Label("Update status is not available yet.", systemImage: "info.circle")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var languageDataEditionLabel: LocalizedStringKey {
    switch model.dataEdition {
    case .some(.full): "Complete offline"
    case .some(.standard): "Recommended"
    case nil: "Unavailable"
    }
  }

  private var orderedInstalledPacks: [LinnetDataRegistry.ActivePack] {
    let order: [LinnetDataRegistry.PackKind] = [.chinese, .english, .lts, .extended]
    return model.installedPacks.sorted {
      (order.firstIndex(of: $0.kind) ?? order.count)
        < (order.firstIndex(of: $1.kind) ?? order.count)
    }
  }

  private func packLabel(_ kind: LinnetDataRegistry.PackKind) -> LocalizedStringKey {
    switch kind {
    case .chinese: "Chinese data"
    case .english: "English data"
    case .lts: "Chinese grammar model"
    case .extended: "Long-tail data"
    }
  }

  private var grammarModelSection: some View {
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
        Text("The Wanxiang LTS grammar model (420 MB) is part of every recommended Linnet installation and improves long-sentence prediction. It is an input-method n-gram model, not a generative large language model. Data updates are fully verified before atomic activation.")
          .font(.caption2).foregroundStyle(.secondary)
      }.padding(8)
    }
  }

  @ViewBuilder private var grammarModelDescription: some View {
    switch model.grammarModelStatus {
    case .ltsActive: Text("Better prediction for long Chinese sentences.")
    case .missing: Text("The recommended Chinese grammar model is not active.")
    case .checking: EmptyView()
    }
  }

  private var dataManagementSection: some View {
    GroupBox("Data management") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading) {
            Text("Language data").font(.callout.weight(.medium))
            Text("Update language data without reinstalling Linnet.")
              .font(.caption).foregroundStyle(.secondary)
            Text("Updates are built by Linnet from pinned upstream projects. Settings downloads only Linnet release packs, never raw upstream dictionaries or models.")
              .font(.caption2).foregroundStyle(.secondary)
            if let message = languageDataUpdateAvailabilityDescription {
              Text(message)
                .font(.caption2).foregroundStyle(.secondary)
            }
          }
          Spacer()
          if model.packDownloadActive {
            ProgressView(value: model.packDownloadProgress)
              .frame(width: 72)
              .accessibilityLabel("Language data download")
              .accessibilityValue(
                Text(
                  model.packDownloadProgress,
                  format: .percent.precision(.fractionLength(0))))
          }
          Button("Update Language Data") { model.updateLanguageData() }
            .disabled(
              !model.languageDataUpdatesAvailable
                || model.packDownloadActive || model.operationActive)
        }
        downloadSourceControls
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Long-tail dictionaries").font(.callout.weight(.medium))
            Text(longTailDescription)
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if model.languageDataUpdateTarget == .completeOffline {
            ProgressView(value: model.packDownloadProgress)
              .frame(width: 72)
              .accessibilityLabel("Long-tail data download")
              .accessibilityValue(
                Text(
                  model.packDownloadProgress,
                  format: .percent.precision(.fractionLength(0))))
          }
          if model.dataEdition == .standard {
            Button("Install Long-tail Data") {
              model.installCompleteOfflineData()
            }
            .disabled(
              !model.languageDataUpdatesAvailable
                || model.packDownloadActive || model.operationActive)
          }
        }
        Divider()
        HStack {
          VStack(alignment: .leading) {
            Text("Existing Rime / Hallelujah data").font(.callout.weight(.medium))
            Text(legacyDataDescription)
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Import Existing") {
            pendingLegacyImport = model.legacyImportCandidate
          }
            .disabled(
              !model.configuration.canPersist || !model.migrationAvailable
                || model.operationActive)
        }
        Divider()
        HStack {
          Text("Reset learning data").font(.callout.weight(.medium))
          Spacer()
          Menu("Clear Learning") {
            Button("Chinese…") { pendingClear = [.chinese] }
            Button("English…") { pendingClear = [.english] }
            Button("Chinese and English…") { pendingClear = [.chinese, .english] }
          }
          .accessibilityLabel("Clear Learning")
          .disabled(!model.dataServicesAvailable || model.operationActive)
        }
        Divider()
        Text("Data to export").font(.callout.weight(.medium))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading) {
          ForEach(LinnetBackupStore.Category.allCases, id: \.self) { category in
            Toggle(categoryName(category), isOn: model.categorySelected(category))
          }
        }
        HStack {
          Button("Export…") { model.choosePortableExport(locale: locale) }
            .disabled(
              !model.dataServicesAvailable || model.exportCategories.isEmpty
                || model.operationActive)
          Button("Import…") {
            guard let source = model.choosePortableImportSource(locale: locale) else { return }
            Task {
              pendingPortableImport = await model.inspectPortableImport(source)
            }
          }
            .disabled(
              !model.configuration.canPersist || model.operationActive
                || model.portableInspectionActive)
          Spacer()
          Button("Open Data Folder") { model.openDataFolder() }
            .disabled(!model.dataServicesAvailable)
        }
      }.padding(8)
    }
  }

  private var downloadSourceControls: some View {
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

  private var longTailDescription: LocalizedStringKey {
    switch model.dataEdition {
    case .some(.full):
      "Names, places, medical, technical, professional, and deep-tail dictionaries are active."
    case .some(.standard):
      "Install the optional long-tail dictionaries for maximum offline coverage."
    case nil:
      "Repair the installation before managing language data."
    }
  }

  private var languageDataUpdateAvailabilityDescription: LocalizedStringKey? {
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

  private var legacyDataDescription: LocalizedStringKey {
    switch model.legacyImportState {
    case .unavailable: "Data services are unavailable."
    case .checking: "Checking detected legacy data…"
    case .none: "No compatible legacy data was found."
    case .compatible: "Compatible legacy data was verified."
    case .failed: "Detected legacy data could not be verified."
    }
  }

  private var backupSection: some View {
    GroupBox("Automatic backups") {
      VStack(alignment: .leading, spacing: 8) {
        Picker("Retention", selection: $model.backupRetentionPolicy) {
          ForEach(LinnetSettingsContract.BackupRetentionPolicy.allCases, id: \.self) {
            Text(backupRetentionName($0)).tag($0)
          }
        }
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

  private var backupRecords: [LinnetBackupStore.BackupRecord] {
    switch model.backupHistory {
    case .unavailable: []
    case .loading(let records), .loaded(let records), .failed(let records): records
    }
  }

  private var diagnosticsSection: some View {
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

  private func runtimeStatus(
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

private func sectionHeader(
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

private func removeButton(
  _ label: LocalizedStringKey,
  action: @escaping () -> Void
) -> some View {
  Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
    .buttonStyle(.borderless)
    .accessibilityLabel(Text(label))
    .help(Text(label))
}

private func categoryName(_ category: LinnetBackupStore.Category) -> LocalizedStringKey {
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
