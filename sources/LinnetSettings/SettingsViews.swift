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
        .accessibilityIdentifier("settings.appearance.fontSize")
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
        .accessibilityIdentifier("settings.appearance.typeface")
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
        .accessibilityIdentifier("settings.appearance.pageSize")
        Text("Candidate count is applied with the schema after you press Apply Changes.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()

        Picker("Chinese candidates", selection: $model.configuration.documentDraft.appearance.chineseCandidateLayout) {
          Text("Horizontal").tag(LinnetSettingsDocument.CandidateLayout.horizontal)
          Text("Vertical").tag(LinnetSettingsDocument.CandidateLayout.vertical)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings.appearance.chineseLayout")
        Picker("English candidates", selection: $model.configuration.documentDraft.appearance.englishCandidateLayout) {
          Text("Horizontal").tag(LinnetSettingsDocument.CandidateLayout.horizontal)
          Text("Vertical").tag(LinnetSettingsDocument.CandidateLayout.vertical)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings.appearance.englishLayout")

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
        .accessibilityIdentifier("settings.appearance.browsing")
        Text(
          // Keep the complete localization key intact for String Catalog lookup.
          // swiftlint:disable:next line_length
          "Chinese and English keep independent horizontal or vertical layouts. Expandable browsing starts compact, then pressing [ or ] (or - or =) to switch candidate pages expands up to three pages automatically. Every new composition starts collapsed. These changes take effect after Apply Changes."
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
      summary: "Configure Chinese and Smart English behavior in one place.",
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
        GroupBox("Smart English") {
          LinnetSettingsTwoColumnLayout {
            englishCandidateSuggestions
          } trailing: {
            englishTypingBehavior
          }
          .padding(8)
        }
        .disabled(!model.configuration.canEdit)
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
          "The selected scheme is used for Chinese input and prefixed pinyin-to-English lookup in Chinese mode."
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
          Text("Type the selected key before the chosen scheme's code in Chinese mode.")
        )

        Text(
          "Type the selected key before the chosen scheme's code in Chinese mode."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        Text(
          "Smart English recognizes the selected full- or double-pinyin scheme automatically; semicolon and other punctuation go directly to the current app."
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
          != model.configuration.documentBaseline?.input.chineseLearningPolicy {
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
        Toggle(
          "Prefer single characters in auxiliary-code lookup by default",
          isOn: $model.configuration.documentDraft.input.singleCharacterSearchDefault
        )
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

  private var englishCandidateSuggestions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Candidate suggestions").font(.headline)
      Toggle("Show IPA pronunciation", isOn: $model.configuration.documentDraft.english.showIPA)
      Toggle(
        "Show Chinese definitions",
        isOn: $model.configuration.documentDraft.english.showTranslation
      )
      Toggle(
        "Show Smart English context suggestions",
        isOn: $model.configuration.documentDraft.english.predictionEnabled
      )
      Text(
        "IPA, Chinese definitions, and context suggestions can be hidden. English correction and fuzzy matching are always available. Changes take effect after Apply Changes."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var englishTypingBehavior: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Typing behavior").font(.headline)
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
      .font(.caption)
      .foregroundStyle(.secondary)
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
    return model.configuration.documentDraft.input != baseline.input ||
      model.configuration.documentDraft.english != baseline.english
  }

  private var reverseLookupExample: String {
    let input = model.configuration.documentDraft.input
    return "\(input.pinyinReverseTrigger.prefix)\(input.chineseProfile.representativeInputCode) → algorithm"
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
              let rows = model.configuration.personalDraft.customWords
              ForEach(
                rows.indices.lazy.map { ($0, rows[$0].id) }, id: \.1
              ) { index, _ in
                let row = rows[index]
                let rowBinding = model.customWordBinding(row, at: index)
                HStack {
                  TextField("Value", text: rowBinding.value)
                  TextField("code", text: rowBinding.code).frame(width: 170)
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
              let rows = model.configuration.personalDraft.disabledWords
              ForEach(
                rows.indices.lazy.map { ($0, rows[$0].identifier) }, id: \.1
              ) { index, _ in
                let row = rows[index]
                let rowBinding = model.disabledWordBinding(row, at: index)
                HStack {
                  TextField("word", text: rowBinding.value)
                  removeButton("Remove disabled word") {
                    model.removeDisabledWord(id: row.identifier)
                  }
                }
              }
            }
            Divider()
            sectionHeader(
              "Text Expander", help: "Explicit triggers begin with x;", add: model.addExpansion)
            LazyVStack(alignment: .leading, spacing: 8) {
              let rows = model.configuration.personalDraft.expansions
              ForEach(
                rows.indices.lazy.map { ($0, rows[$0].id) }, id: \.1
              ) { index, _ in
                let row = rows[index]
                let rowBinding = model.expansionBinding(row, at: index)
                HStack {
                  TextField("Expansion", text: rowBinding.value)
                  TextField("x;trigger", text: rowBinding.trigger).frame(width: 170)
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

// MARK: - Data

struct DataTabView: View {
  @Environment(\.locale) var locale
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
      "Data & Updates",
      summary: "Review updates, sync or move personal data, and manage recovery.",
      systemImage: "arrow.triangle.2.circlepath"
    ) {
      VStack(alignment: .leading, spacing: 16) {
        versionSection
        coreUpdateSection
        languageDataSection
        grammarModelSection
        GroupBox {
          DisclosureGroup("iCloud Drive sync") {
            cloudSyncSection
              .padding(.top, 8)
          }
          .accessibilityIdentifier("settings.data.cloudDisclosure")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        GroupBox {
          DisclosureGroup("Manual recovery & transfer") {
            VStack(alignment: .leading, spacing: 16) {
              personalDataSection
              backupSection
            }
            .padding(.top, 8)
          }
          .accessibilityIdentifier("settings.data.manualDisclosure")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        GroupBox {
          DisclosureGroup("Diagnostics") {
            diagnosticsSection
              .padding(.top, 8)
          }
          .accessibilityIdentifier("settings.data.diagnosticsDisclosure")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var languageDataSection: some View {
    GroupBox("Language data updates") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading) {
            Text("Language data").font(.callout.weight(.medium))
            Text("Update language data without reinstalling Linnet.")
              .font(.caption).foregroundStyle(.secondary)
            Text("Updates are built by Linnet from pinned upstream projects. Settings downloads only Linnet release packs, never raw upstream dictionaries or models.")
              .font(.caption2).foregroundStyle(.secondary)
            if let message = languageDataUpdateDescription {
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
      }.padding(8)
    }
  }

  private var personalDataSection: some View {
    VStack(alignment: .leading, spacing: 12) {
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
    }
  }

}

// MARK: - Shared Settings controls

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

extension DataTabView {
  var updateChannelPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker("Update channel", selection: Binding(
        get: { updateChecker.updateChannel },
        set: { updateChecker.setUpdateChannel($0) }
      )) {
        Text("Stable").tag(LinnetSettingsUpdateChecker.UpdateChannel.stable)
        Text("Preview").tag(LinnetSettingsUpdateChecker.UpdateChannel.preview)
      }
      .pickerStyle(.segmented)
      .disabled(
        updateChecker.active || updateChecker.activationInProgress
          || updateChecker.coreDownloadInProgress)
      if updateChecker.updateChannel == .preview {
        Text(
          "Preview receives release candidates before they become the latest stable version.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}
