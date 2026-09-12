import Foundation

// Build-time projection of the existing product choices, not a Windows copy
// of the input policies. The native dialog consumes the rendered Rime values.
enum WindowsSettingsCatalog {
  typealias Document = LinnetSettingsDocument
  struct Choice: Encodable {
    let id: String
    let label: String
    let projections: [String: String]
  }
  struct Option: Encodable {
    let id: String
    let label: String
    let group: String
    let defaultIndex: Int
    let choices: [Choice]
  }

  static func write(to directory: URL) throws {
    var options: [Option] = []
    func choice(_ id: String, _ label: String, _ update: (inout Document) -> Void) -> Choice {
      var document = Document.default
      update(&document)
      var projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
      if document.appearance.fontPoint != Document.default.appearance.fontPoint {
        for (key, value) in detailWidths(fontPoint: document.appearance.fontPoint).sorted(by: { $0.key < $1.key }) {
          projections["squirrel.custom.yaml", default: "patch:\n"] += "  \"style/\(key)\": \(value)\n"
        }
      }
      return Choice(id: id, label: label, projections: projections)
    }
    func add<T: Equatable & Encodable>(
      _ id: String, _ label: String, _ group: String, _ values: [T], _ selected: T,
      label valueLabel: (T) -> String, update: (inout Document, T) -> Void
    ) {
      options.append(Option(id: id, label: label, group: group,
        defaultIndex: values.firstIndex(of: selected)!, choices: values.map { value in
          let encoded = try! JSONEncoder().encode(value)
          let raw = try! JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed)
          let id = (raw as? String) ?? (raw as! NSNumber).stringValue
          return choice(id, valueLabel(value)) { update(&$0, value) }
        }))
    }
    func toggle(_ id: String, _ label: String, _ group: String,
                _ path: WritableKeyPath<Document, Bool>) {
      add(id, label, group, [false, true], Document.default[keyPath: path],
          label: { $0 ? "开启 / On" : "关闭 / Off" }) { $0[keyPath: path] = $1 }
    }
    add("profile", "中文方案 / Chinese profile", "输入 / Input",
        LinnetSettingsContract.ChineseProfile.allCases, Document.default.input.chineseProfile,
        label: { $0.schemaID }) { $0.input.chineseProfile = $1 }
    toggle("emoji", "Emoji", "输入 / Input", \.input.emojiEnabled)
    toggle("traditional", "繁体中文 / Traditional Chinese", "输入 / Input", \.input.traditionalChinese)
    toggle("ascii_punctuation", "英文标点 / ASCII punctuation", "输入 / Input", \.input.asciiPunctuationDefault)
    toggle("single_character", "单字优先 / Single character first", "输入 / Input", \.input.singleCharacterSearchDefault)
    add("chinese_learning", "中文学习 / Chinese learning", "输入 / Input",
        Document.ChineseLearningPolicy.allCases, Document.default.input.chineseLearningPolicy,
        label: { $0.rawValue }) { $0.input.chineseLearningPolicy = $1 }
    add("reverse_trigger", "反查前缀 / Reverse lookup prefix", "输入 / Input",
        Document.PinyinReverseTrigger.allCases, Document.default.input.pinyinReverseTrigger,
        label: { $0.prefix }) { $0.input.pinyinReverseTrigger = $1 }
    for pair in Document.FuzzyPinyinPair.allCases {
      add("fuzzy_" + pair.rawValue, pair.label, "模糊音 / Fuzzy pinyin", [false, true], false,
          label: { $0 ? "开启 / On" : "关闭 / Off" }) {
        $0.input.fuzzyPinyin = $1 ? [pair] : []
      }
    }
    toggle("sentence_capitalization", "句首大写 / Sentence capitals", "英文 / English", \.english.sentenceCapitalization)
    toggle("ipa", "音标 / IPA", "英文 / English", \.english.showIPA)
    toggle("translation", "中文释义 / Chinese definitions", "英文 / English", \.english.showTranslation)
    toggle("prediction", "英文预测 / Prediction", "英文 / English", \.english.predictionEnabled)
    toggle("english_learning", "学习选词 / Learn selections", "英文 / English", \.english.learnFromSelections)
    toggle("trailing_space", "空格选词后加空格 / Trailing space", "英文 / English", \.english.spaceAddsTrailingSpace)
    add("tab", "Tab 行为 / Tab behavior", "英文 / English", Document.TabBehavior.allCases,
        Document.default.english.tabBehavior, label: { $0.rawValue }) { $0.english.tabBehavior = $1 }
    add("page_size", "每页候选 / Candidates per page", "外观 / Appearance", Document.Appearance.pageSizeOptions,
        Document.default.appearance.pageSize, label: String.init) { $0.appearance.pageSize = $1 }
    add("font_point", "字号 / Font size", "外观 / Appearance",
        Array(Int(Document.Appearance.minimumFontPoint)...Int(Document.Appearance.maximumFontPoint)),
        Int(Document.default.appearance.fontPoint), label: String.init) { $0.appearance.fontPoint = Double($1) }
    for (id, label, path) in [
      ("chinese_layout", "中文排列 / Chinese layout", \Document.appearance.chineseCandidateLayout),
      ("english_layout", "英文排列 / English layout", \Document.appearance.englishCandidateLayout)
    ] {
      add(id, label, "外观 / Appearance", Document.CandidateLayout.allCases,
          Document.default[keyPath: path], label: { $0.rawValue }) { $0[keyPath: path] = $1 }
    }
    add("browsing", "候选展开 / Candidate expansion", "外观 / Appearance",
        Document.CandidateBrowsingMode.allCases, Document.default.appearance.candidateBrowsingMode,
        label: { $0.rawValue }) { $0.appearance.candidateBrowsingMode = $1 }
    add("grid_columns", "展开列数 / Expanded columns", "外观 / Appearance",
        Array(LinnetSettingsContract.horizontalExpandedGridRange), Document.default.appearance.expandedHorizontalCount,
        label: String.init) { $0.appearance.expandedHorizontalCount = $1 }
    add("grid_rows", "展开行数 / Expanded rows", "外观 / Appearance",
        Array(LinnetSettingsContract.horizontalExpandedGridRange), Document.default.appearance.expandedHorizontalRows,
        label: String.init) { $0.appearance.expandedHorizontalRows = $1 }
    add("vertical_count", "纵向展开候选 / Expanded vertical count", "外观 / Appearance",
        Array(LinnetSettingsContract.expandedCandidateCountRange), Document.default.appearance.expandedVerticalCount,
        label: String.init) { $0.appearance.expandedVerticalCount = $1 }
    var themes: [Choice] = []
    for family in Document.ThemeFamily.allCases {
      for mode in Document.ThemeMode.allCases {
        themes.append(choice(family.rawValue + "/" + mode.rawValue, family.rawValue + " / " + mode.rawValue) {
          $0.appearance.themeFamily = family
          $0.appearance.themeMode = mode
        })
      }
    }
    options.append(Option(id: "theme", label: "主题与明暗 / Theme and appearance",
      group: "外观 / Appearance", defaultIndex: 0, choices: themes))
    let appearance = Document.default.appearance
    var defaults: [String: Any] = [
      "font_point": appearance.fontPoint,
      "label_font_point": Document.Appearance.labelFontPoint(for: appearance.fontPoint),
      "comment_font_point": Document.Appearance.commentFontPoint(for: appearance.fontPoint),
      "linnet_candidate_expansion_allowed": appearance.candidateBrowsingMode == .expandable,
      "linnet_expanded_horizontal_count": appearance.expandedHorizontalCount,
      "linnet_expanded_horizontal_rows": appearance.expandedHorizontalRows,
      "linnet_expanded_vertical_count": appearance.expandedVerticalCount,
      "color_scheme": appearance.themeFamily.schemeIdentifier(isDark: false),
      "color_scheme_dark": appearance.themeFamily.schemeIdentifier(isDark: true)
    ]
    for (key, value) in detailWidths(fontPoint: appearance.fontPoint) { defaults[key] = value }
    let encodedOptions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options))
    let data = try JSONSerialization.data(withJSONObject: ["options": encodedOptions, "defaults": defaults])
    try data.write(to: directory.appendingPathComponent("settings-catalog.json"))
    let design = """
    // Generated from the shared candidate presentation owner. Do not edit.
    #pragma once
    namespace linnet_design {
    constexpr int expanded_candidate_count = \(LinnetCandidatePresentation.maximumExpandedCandidateCount);
    constexpr int footer_detail_lines = \(LinnetCandidatePresentation.maximumFooterDetailLineCount);
    }
    """
    try (design + "\n").write(to: directory.appendingPathComponent("linnet_candidate_design.h"),
                              atomically: true, encoding: .utf8)
  }

  private static func detailWidths(fontPoint: Double) -> [String: Int] {
    let horizontal = LinnetCandidatePresentation.candidateDetailGeometry(
      forLinearLayout: true, candidateFontPoint: fontPoint)
    let vertical = LinnetCandidatePresentation.candidateDetailGeometry(
      forLinearLayout: false, candidateFontPoint: fontPoint)
    return [
      "linnet_detail_candidate_width": Int(vertical.candidateColumnMaximumWidth!),
      "linnet_detail_sidecar_width": Int(vertical.detailColumnMaximumWidth!),
      "linnet_detail_footer_width": Int(horizontal.detailColumnMaximumWidth!)
    ]
  }
}
