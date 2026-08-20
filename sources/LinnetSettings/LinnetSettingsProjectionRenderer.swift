//
//  LinnetSettingsProjectionRenderer.swift
//  Deterministic projection of the settings document onto the Rime YAML
//  files librime and Squirrel read at deploy time. User choices that match the
//  bundled defaults are omitted, while Core-owned input policies are emitted
//  on every reconciliation.
//

import Darwin
import Foundation

enum LinnetSettingsProjectionRenderer {
  static let squirrelCustomFile = "squirrel.custom.yaml"
  static let defaultCustomFile = "default.custom.yaml"
  static let englishCustomFile = "linnet_en.custom.yaml"

  /// All eight Chinese profiles include linnet_zh.schema.yaml's switches
  /// list (`__include: linnet_zh.schema.yaml:/`), so the indices are stable:
  /// 0 ascii_mode, 1 ascii_punct, 2 traditionalization, 3 emoji (reset 1),
  /// 4 single-character-first auxiliary-code search.
  static let asciiPunctuationSwitchIndex = 1
  static let traditionalizationSwitchIndex = 2
  static let emojiSwitchIndex = 3
  static let singleCharacterSearchSwitchIndex = 4
  static let englishPredictionSwitchIndex = 1
  private static let maximumProjectionBytes = 1024 * 1024
  private static let codeTokenRecognizerPattern =
    "^(?:(?:www[.]|https?:|ftp[.:]|mailto:|file:).*|(?:[a-z]+[A-Z]|[A-Z][a-z]+[A-Z]|[A-Z]{2,}[a-z]|v[0-9]+|[A-Z][A-Za-z]*[0-9]|[A-Z]{2,}[._/@:+-])[0-9A-Za-z._/@:+?&=%#~-]*)$"

  static var chineseCustomFiles: [String] {
    LinnetSettingsContract.ChineseProfile.allCases.map { "\($0.schemaID).custom.yaml" }
  }

  static var ownedFiles: Set<String> {
    Set([squirrelCustomFile, defaultCustomFile, englishCustomFile]).union(chineseCustomFiles)
  }

  /// Renders user deviations plus the Core-owned input policy projection.
  static func renderProjections(document: LinnetSettingsDocument) -> [String: String] {
    var projections: [String: String] = [:]
    if let squirrel = renderSquirrelCustom(document.appearance) {
      projections[squirrelCustomFile] = squirrel
    }
    projections[defaultCustomFile] = renderDefaultCustom(
      pageSize: document.appearance.pageSize,
      chineseProfile: document.input.chineseProfile
    )
    for schemaID in LinnetSettingsContract.ChineseProfile.allCases.map(\.schemaID) {
      if let schemaCustom = renderChineseSchemaCustom(
        appearance: document.appearance,
        input: document.input,
        english: document.english
      ) {
        projections["\(schemaID).custom.yaml"] = schemaCustom
      }
    }
    if let englishCustom = renderEnglishSchemaCustom(
      appearance: document.appearance,
      input: document.input,
      english: document.english
    ) {
      projections[englishCustomFile] = englishCustom
    }
    return projections
  }

  /// Reconciles rebuildable projection caches with the canonical document.
  /// Identical bytes are never rewritten, so appearance Apply changes only the
  /// files whose owner facts actually moved.
  @discardableResult
  static func reconcile(
    document: LinnetSettingsDocument,
    to directory: URL
  ) throws -> Set<String> {
    try requireDirectory(directory)
    let rendered = renderProjections(document: document)
    var changed: Set<String> = []
    for name in ownedFiles.sorted() {
      let url = directory.appending(path: name)
      if let contents = rendered[name] {
        let data = Data(contents.utf8)
        guard data.count <= maximumProjectionBytes else { throw Failure.unsafeFile(name) }
        if try existingData(at: url, name: name) == data { continue }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        changed.insert(name)
      } else if try existingData(at: url, name: name) != nil {
        try FileManager.default.removeItem(at: url)
        changed.insert(name)
      }
    }
    return changed
  }

  enum Failure: LocalizedError, Equatable, Sendable {
    case unsafeFile(String)

    var errorDescription: String? {
      switch self {
      case .unsafeFile(let name): "Unsafe settings projection file: \(name)"
      }
    }
  }

  private static func requireDirectory(_ directory: URL) throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafeFile(directory.lastPathComponent) }
  }

  private static func existingData(at url: URL, name: String) throws -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 && errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw Failure.unsafeFile(name) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_size >= 0,
      info.st_size <= maximumProjectionBytes
    else { throw Failure.unsafeFile(name) }
    let data = try handle.readToEnd() ?? Data()
    guard data.count == Int(info.st_size) else { throw Failure.unsafeFile(name) }
    return data
  }

  // MARK: - Per-file renderers

  private static func renderSquirrelCustom(
    _ appearance: LinnetSettingsDocument.Appearance
  ) -> String? {
    var entries: [(String, String)] = []
    if appearance.fontPoint != LinnetSettingsDocument.Appearance.defaultFontPoint {
      entries.append(("style/font_point", formatNumber(appearance.fontPoint)))
      entries.append((
        "style/label_font_point",
        formatNumber(LinnetSettingsDocument.Appearance.labelFontPoint(for: appearance.fontPoint))
      ))
      entries.append((
        "style/comment_font_point",
        formatNumber(LinnetSettingsDocument.Appearance.commentFontPoint(for: appearance.fontPoint))
      ))
    }
    let schemes = colorSchemes(for: appearance.themeFamily, mode: appearance.themeMode)
    let defaults = (
      light: LinnetSettingsDocument.ThemeFamily.defaultValue.schemeIdentifier(isDark: false),
      dark: LinnetSettingsDocument.ThemeFamily.defaultValue.schemeIdentifier(isDark: true)
    )
    if schemes.light != defaults.light || schemes.dark != defaults.dark {
      entries.append(("style/color_scheme", quoted(schemes.light)))
      entries.append(("style/color_scheme_dark", quoted(schemes.dark)))
    }
    if appearance.themeMode != .system {
      entries.append((
        "style/linnet_material_appearance",
        quoted(appearance.themeMode.rawValue)
      ))
    }
    if let fontFace = appearance.fontPreset.projectedFontFace {
      entries.append(("style/font_face", quoted(fontFace)))
    }
    if appearance.candidateBrowsingMode == .scrollingOnly {
      entries.append(("style/linnet_candidate_expansion_allowed", "false"))
    }
    guard !entries.isEmpty else { return nil }
    return renderPatch(entries)
  }

  private static func colorSchemes(
    for family: LinnetSettingsDocument.ThemeFamily,
    mode: LinnetSettingsDocument.ThemeMode
  ) -> (light: String, dark: String) {
    let light = family.schemeIdentifier(isDark: false)
    let dark = family.schemeIdentifier(isDark: true)
    switch mode {
    case .system: return (light, dark)
    case .light: return (light, light)
    case .dark: return (dark, dark)
    }
  }

  private static func renderDefaultCustom(
    pageSize: Int,
    chineseProfile: LinnetSettingsContract.ChineseProfile
  ) -> String {
    // Core-only updates do not replace the language pack. Reconciliation runs
    // before every Rime start, so this projection is the installed-product
    // owner for policies that must override an older Active pack immediately.
    var entries = [
      ("ascii_composer/switch_key/Caps_Lock", "commit_text"),
      ("linnet/recognizer_patterns/zz_code_token", quoted(codeTokenRecognizerPattern)),
    ]
    if pageSize != LinnetSettingsDocument.Appearance.defaultPageSize {
      entries.append(("menu/page_size", String(pageSize)))
    }
    if let selectedIndex = LinnetSettingsContract.ChineseProfile.allCases.firstIndex(
      of: chineseProfile), selectedIndex != 0
    {
      // switcher/fix_schema_list_order makes the first list entry authoritative
      // for every fresh session. Swap, rather than remove, so the standard Rime
      // schema switcher and runtime-health list retain all shipped profiles.
      entries.append(("schema_list/@0/schema", quoted(chineseProfile.schemaID)))
      entries.append(("schema_list/@\(selectedIndex)/schema", quoted(
        LinnetSettingsContract.ChineseProfile.fullPinyin.schemaID
      )))
    }
    return renderPatch(entries)
  }

  private static func renderChineseSchemaCustom(
    appearance: LinnetSettingsDocument.Appearance,
    input: LinnetSettingsDocument.Input,
    english: LinnetSettingsDocument.English
  ) -> String? {
    var entries: [(String, String)] = []
    appendCandidateLayout(
      appearance.chineseCandidateLayout,
      defaultLayout: .horizontal,
      to: &entries
    )
    if input.asciiPunctuationDefault {
      entries.append(("switches/@\(asciiPunctuationSwitchIndex)/reset", "1"))
    }
    if input.traditionalChinese {
      entries.append(("switches/@\(traditionalizationSwitchIndex)/reset", "1"))
    }
    if !input.emojiEnabled {
      entries.append(("switches/@\(emojiSwitchIndex)/reset", "0"))
    }
    if input.singleCharacterSearchDefault {
      entries.append(("switches/@\(singleCharacterSearchSwitchIndex)/reset", "1"))
    }
    appendPinyinReverseTrigger(input.pinyinReverseTrigger, to: &entries)
    appendChineseLearningPolicy(input.chineseLearningPolicy, to: &entries)
    appendEnglishMetadataOptions(english, to: &entries)
    appendEnglishLearningOptions(english, includeUserDictionary: false, to: &entries)
    guard !entries.isEmpty else { return nil }
    return renderPatch(entries)
  }

  /// The document enum is the single user-facing owner of this pair. Rime's
  /// standard affix segmentor requires both fields to move atomically.
  private static func appendPinyinReverseTrigger(
    _ trigger: LinnetSettingsDocument.PinyinReverseTrigger,
    to entries: inout [(String, String)]
  ) {
    guard trigger != .semicolon else { return }
    entries.append((
      "recognizer/patterns/linnet_pinyin",
      quoted(trigger.recognizerPattern)
    ))
    entries.append(("linnet_pinyin/prefix", quoted(trigger.prefix)))
  }

  private static func renderEnglishSchemaCustom(
    appearance: LinnetSettingsDocument.Appearance,
    input: LinnetSettingsDocument.Input,
    english: LinnetSettingsDocument.English
  ) -> String? {
    var entries: [(String, String)] = []
    appendCandidateLayout(
      appearance.englishCandidateLayout,
      defaultLayout: .horizontal,
      to: &entries
    )
    appendPinyinReverseTrigger(input.pinyinReverseTrigger, to: &entries)
    if input.chineseProfile != .fullPinyin {
      entries.append(("linnet_pinyin/prism", quoted(input.chineseProfile.schemaID)))
      entries.append((
        "linnet_mode_switch/chinese_schema", quoted(input.chineseProfile.schemaID)
      ))
    }
    appendEnglishMetadataOptions(english, to: &entries)
    if !english.predictionEnabled {
      entries.append(("switches/@\(englishPredictionSwitchIndex)/reset", "0"))
    }
    if !english.spellingCorrection {
      entries.append(("linnet_english_interaction/spelling_correction", "false"))
    }
    appendEnglishLearningOptions(english, includeUserDictionary: true, to: &entries)
    guard !entries.isEmpty else { return nil }
    return renderPatch(entries)
  }

  private static func appendEnglishMetadataOptions(
    _ english: LinnetSettingsDocument.English,
    to entries: inout [(String, String)]
  ) {
    // These two fields are always explicit so a retired personal-data patch
    // cannot override the typed document even when its values equal defaults.
    entries.append((
      "linnet_english_interaction/sentence_capitalization",
      english.sentenceCapitalization ? "true" : "false"
    ))
    entries.append((
      "linnet_english_interaction/tab_behavior",
      quoted(english.tabBehavior.rawValue)
    ))
    if !english.showIPA {
      entries.append(("linnet_english_interaction/show_ipa", "false"))
    }
    if !english.showTranslation {
      entries.append(("linnet_english_interaction/show_translation", "false"))
    }
  }

  private static func appendEnglishLearningOptions(
    _ english: LinnetSettingsDocument.English,
    includeUserDictionary: Bool,
    to entries: inout [(String, String)]
  ) {
    guard !english.learnFromSelections else { return }
    if includeUserDictionary {
      entries.append(("translator/enable_user_dict", "false"))
    }
    entries.append(("linnet_english_interaction/learning_enabled", "false"))
  }

  /// The bundled schema owns the enhanced default. Settings emits only the
  /// deviations, identically for every Chinese profile.
  private static func appendChineseLearningPolicy(
    _ policy: LinnetSettingsDocument.ChineseLearningPolicy,
    to entries: inout [(String, String)]
  ) {
    switch policy {
    case .enhanced:
      break
    case .standard:
      entries.append(("auto_phrase/enable", "false"))
    case .disabled:
      entries.append(("translator/enable_user_dict", "false"))
      entries.append(("auto_phrase/enable", "false"))
    }
  }

  /// Candidate layout is schema-specific: Chinese and English may project
  /// different list directions while sharing the same theme and typography.
  private static func appendCandidateLayout(
    _ layout: LinnetSettingsDocument.CandidateLayout,
    defaultLayout: LinnetSettingsDocument.CandidateLayout,
    to entries: inout [(String, String)]
  ) {
    guard layout != defaultLayout else { return }
    switch layout {
    case .horizontal:
      entries.append(("style/candidate_list_layout", quoted("linear")))
      entries.append(("style/text_orientation", quoted("horizontal")))
    case .vertical:
      entries.append(("style/candidate_list_layout", quoted("stacked")))
      entries.append(("style/text_orientation", quoted("horizontal")))
    }
  }

  // MARK: - YAML emission

  private static func renderPatch(_ entries: [(String, String)]) -> String {
    let lines = entries.map { "  \"\($0.0)\": \($0.1)" }
    return "patch:\n" + lines.joined(separator: "\n") + "\n"
  }

  private static func quoted(_ value: String) -> String {
    "\"\(value)\""
  }

  private static func formatNumber(_ value: Double) -> String {
    String(format: "%g", value)
  }
}
