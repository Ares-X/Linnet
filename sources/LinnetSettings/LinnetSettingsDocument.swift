//
//  LinnetSettingsDocument.swift
//  Typed, versioned settings document edited by the graphical Settings UI and
//  rendered into Rime YAML projections only at deploy time. The document is
//  the only Layer-1 surface the Settings application writes to; everything
//  else is derived by LinnetSettingsProjectionRenderer.
//

import Foundation

/// Canonical settings document (schema v11). Every default below matches the
/// bundled distribution defaults, so a fresh install renders an identical
/// configuration without emitting any projection file.
struct LinnetSettingsDocument: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 11

  var schemaVersion: Int
  var appearance: Appearance
  var input: Input
  var english: English

  init(
    schemaVersion: Int = currentSchemaVersion,
    appearance: Appearance,
    input: Input,
    english: English
  ) {
    self.schemaVersion = schemaVersion
    self.appearance = appearance
    self.input = input
    self.english = english
  }
}

extension LinnetSettingsDocument {
  enum ThemeMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
  }

  enum ThemeFamily: String, Codable, CaseIterable, Sendable {
    case paperLedger = "paper_ledger"
    case moonJade = "moon_jade"
    case sidecarSlate = "sidecar_slate"
    case clayTiles = "clay_tiles"
    case mistJade = "mist_jade"
    case nativeGlass = "native_glass"
    case inkCinnabar = "ink_cinnabar"

    static let defaultValue = ThemeFamily.paperLedger

    func schemeIdentifier(isDark: Bool) -> String {
      let prefix: String
      switch self {
      case .paperLedger: prefix = "linnet_paper"
      case .moonJade: prefix = "linnet_moon_jade"
      case .sidecarSlate: prefix = "linnet_sidecar"
      case .clayTiles: prefix = "linnet_clay"
      case .mistJade: prefix = "linnet_mist_jade"
      case .nativeGlass: prefix = "linnet_glass"
      case .inkCinnabar: prefix = "linnet_ink_cinnabar"
      }
      return "\(prefix)_\(isDark ? "dark" : "light")"
    }
  }

  enum FontPreset: String, Codable, CaseIterable, Sendable {
    case system
    case humanist
    case swiss
    case editorial
    case book

    /// Canonical font cascade used by both the live candidate window and the
    /// Settings preview. The first family owns Latin glyphs; the second owns
    /// Chinese glyphs and any fallback absent from the first family.
    var fontFamilies: [String] {
      switch self {
      case .system: []
      case .humanist: ["Avenir Next", "Hiragino Sans GB"]
      case .swiss: ["Helvetica Neue", "Heiti SC"]
      case .editorial: ["Iowan Old Style", "Songti SC"]
      case .book: ["Charter", "Songti SC"]
      }
    }

    var displayPair: String {
      self == .system ? "SF Pro + PingFang SC" : fontFamilies.joined(separator: " + ")
    }

    var projectedFontFace: String? {
      fontFamilies.isEmpty ? nil : fontFamilies.joined(separator: ", ")
    }
  }

  enum CandidateLayout: String, Codable, CaseIterable, Sendable {
    case horizontal
    case vertical
  }

  /// Controls whether the candidate window offers its native-like disclosure
  /// control. The current expanded/collapsed state is transient panel state;
  /// it is deliberately not persisted in this document.
  enum CandidateBrowsingMode: String, Codable, CaseIterable, Sendable {
    case scrollingOnly = "scrolling_only"
    case expandable
  }

  enum TabBehavior: String, Codable, CaseIterable, Sendable {
    case pass
    case navigate
    case smartComplete = "smart_complete"
  }

  /// One product-level choice owns the two Rime learning switches. Keeping
  /// invalid combinations out of the document avoids a second UI-side policy.
  enum ChineseLearningPolicy: String, Codable, CaseIterable, Sendable {
    case enhanced
    case standard
    case disabled
  }

  /// One finite product choice owns both Rime projections required by the
  /// standard affix segmentor. Keeping the literal and regular expression
  /// together prevents a custom trigger from reaching the recognizer without
  /// also reaching the prefix stripper.
  enum PinyinReverseTrigger: String, Codable, CaseIterable, Sendable {
    case semicolon
    case verticalBar = "vertical_bar"

    var prefix: String {
      switch self {
      case .semicolon: ";"
      case .verticalBar: "|"
      }
    }

    var recognizerPattern: String {
      switch self {
      case .semicolon: "^;[a-z;']*$"
      case .verticalBar: "^[|][a-z;']*$"
      }
    }
  }

  struct Appearance: Codable, Equatable, Sendable {
    static let defaultFontPoint = 16.0
    static let minimumFontPoint = 12.0
    static let maximumFontPoint = 32.0
    static let fontPointStep = 1.0
    static let defaultPageSize = 9
    static let pageSizeOptions = [3, 5, 7, 9]

    var fontPoint: Double
    var themeFamily: ThemeFamily
    var themeMode: ThemeMode
    var fontPreset: FontPreset
    var chineseCandidateLayout: CandidateLayout
    var englishCandidateLayout: CandidateLayout
    var candidateBrowsingMode: CandidateBrowsingMode
    var pageSize: Int

    static let `default` = Appearance(
      fontPoint: defaultFontPoint,
      themeMode: .system,
      chineseCandidateLayout: .horizontal,
      englishCandidateLayout: .horizontal,
      pageSize: defaultPageSize,
      candidateBrowsingMode: .expandable,
      themeFamily: ThemeFamily.defaultValue,
      fontPreset: .system
    )

    init(
      fontPoint: Double,
      themeMode: ThemeMode,
      chineseCandidateLayout: CandidateLayout,
      englishCandidateLayout: CandidateLayout,
      pageSize: Int,
      candidateBrowsingMode: CandidateBrowsingMode = .expandable,
      themeFamily: ThemeFamily = ThemeFamily.defaultValue,
      fontPreset: FontPreset = .system
    ) {
      self.fontPoint = fontPoint
      self.themeFamily = themeFamily
      self.themeMode = themeMode
      self.fontPreset = fontPreset
      self.chineseCandidateLayout = chineseCandidateLayout
      self.englishCandidateLayout = englishCandidateLayout
      self.candidateBrowsingMode = candidateBrowsingMode
      self.pageSize = pageSize
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      fontPoint =
        Self.clampFontPoint(
          try container.decodeIfPresent(Double.self, forKey: .fontPoint) ?? Self.defaultFontPoint)
      let familyValue = try container.decodeIfPresent(String.self, forKey: .themeFamily)
      if let familyValue {
        guard let family = ThemeFamily(rawValue: familyValue) else {
          throw DecodingError.dataCorruptedError(
            forKey: .themeFamily,
            in: container,
            debugDescription: "Unknown Linnet theme family.")
        }
        themeFamily = family
      } else {
        themeFamily = ThemeFamily.defaultValue
      }
      let modeValue = try container.decodeIfPresent(String.self, forKey: .themeMode)
      themeMode = modeValue.flatMap(ThemeMode.init(rawValue:)) ?? .system
      let fontValue = try container.decodeIfPresent(String.self, forKey: .fontPreset)
      fontPreset = fontValue.flatMap(FontPreset.init(rawValue:)) ?? .system
      let chineseLayoutValue = try container.decodeIfPresent(
        String.self, forKey: .chineseCandidateLayout)
      let englishLayoutValue = try container.decodeIfPresent(
        String.self, forKey: .englishCandidateLayout)
      let hadLegacyExpandedLayout =
        chineseLayoutValue == "expanded" || englishLayoutValue == "expanded"

      if chineseLayoutValue == "expanded" {
        chineseCandidateLayout = .horizontal
      } else if let chineseLayoutValue {
        guard let layout = CandidateLayout(rawValue: chineseLayoutValue) else {
          throw DecodingError.dataCorruptedError(
            forKey: .chineseCandidateLayout,
            in: container,
            debugDescription: "Unknown Chinese candidate layout.")
        }
        chineseCandidateLayout = layout
      } else {
        chineseCandidateLayout = .horizontal
      }
      if englishLayoutValue == "expanded" {
        englishCandidateLayout = .horizontal
      } else if let englishLayoutValue {
        guard let layout = CandidateLayout(rawValue: englishLayoutValue) else {
          throw DecodingError.dataCorruptedError(
            forKey: .englishCandidateLayout,
            in: container,
            debugDescription: "Unknown English candidate layout.")
        }
        englishCandidateLayout = layout
      } else {
        englishCandidateLayout = .horizontal
      }

      if let browsingValue = try container.decodeIfPresent(
        String.self, forKey: .candidateBrowsingMode) {
        guard let mode = CandidateBrowsingMode(rawValue: browsingValue) else {
          throw DecodingError.dataCorruptedError(
            forKey: .candidateBrowsingMode,
            in: container,
            debugDescription: "Unknown candidate browsing mode.")
        }
        candidateBrowsingMode = mode
      } else {
        // v9 briefly encoded `expanded` as a third layout. Preserve only its
        // user intent (offer disclosure), while older horizontal/vertical
        // documents keep their prior scrolling-only behavior.
        candidateBrowsingMode = hadLegacyExpandedLayout ? .expandable : .scrollingOnly
      }
      let decodedPageSize =
        try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? Self.defaultPageSize
      pageSize = Self.pageSizeOptions.contains(decodedPageSize) ? decodedPageSize : Self.defaultPageSize
    }

    static func clampFontPoint(_ value: Double) -> Double {
      min(maximumFontPoint, max(minimumFontPoint, value))
    }

    static func labelFontPoint(for candidateFontPoint: Double) -> Double {
      max(10, clampFontPoint(candidateFontPoint) * 0.625)
    }

    static func commentFontPoint(for candidateFontPoint: Double) -> Double {
      max(12, clampFontPoint(candidateFontPoint) * 0.75)
    }

    /// Projects an appearance request onto the subset the Host can reload
    /// without rebuilding its active Rime sessions. The Settings model uses
    /// this to avoid claiming a draft is live; the mutation coordinator uses
    /// the same owner to enforce the boundary for direct callers.
    func livePanelProjection(over baseline: Appearance) -> Appearance {
      var result = self
      result.pageSize = baseline.pageSize
      result.chineseCandidateLayout = baseline.chineseCandidateLayout
      result.englishCandidateLayout = baseline.englishCandidateLayout
      result.candidateBrowsingMode = baseline.candidateBrowsingMode
      return result
    }
  }

  struct Input: Codable, Equatable, Sendable {
    var chineseProfile: LinnetSettingsContract.ChineseProfile
    var emojiEnabled: Bool
    var traditionalChinese: Bool
    var asciiPunctuationDefault: Bool
    var singleCharacterSearchDefault: Bool
    var chineseLearningPolicy: ChineseLearningPolicy
    var pinyinReverseTrigger: PinyinReverseTrigger

    static let `default` = Input(
      chineseProfile: .fullPinyin,
      emojiEnabled: true,
      traditionalChinese: false,
      asciiPunctuationDefault: false,
      singleCharacterSearchDefault: false,
      chineseLearningPolicy: .enhanced,
      pinyinReverseTrigger: .verticalBar
    )

    init(
      chineseProfile: LinnetSettingsContract.ChineseProfile = .fullPinyin,
      emojiEnabled: Bool,
      traditionalChinese: Bool,
      asciiPunctuationDefault: Bool,
      singleCharacterSearchDefault: Bool = false,
      chineseLearningPolicy: ChineseLearningPolicy = .enhanced,
      pinyinReverseTrigger: PinyinReverseTrigger
    ) {
      self.chineseProfile = chineseProfile
      self.emojiEnabled = emojiEnabled
      self.traditionalChinese = traditionalChinese
      self.asciiPunctuationDefault = asciiPunctuationDefault
      self.singleCharacterSearchDefault = singleCharacterSearchDefault
      self.chineseLearningPolicy = chineseLearningPolicy
      self.pinyinReverseTrigger = pinyinReverseTrigger
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if container.contains(.chineseProfile) {
        chineseProfile = try container.decode(
          LinnetSettingsContract.ChineseProfile.self,
          forKey: .chineseProfile
        )
      } else {
        chineseProfile = Input.default.chineseProfile
      }
      emojiEnabled =
        try container.decodeIfPresent(Bool.self, forKey: .emojiEnabled)
        ?? Input.default.emojiEnabled
      traditionalChinese =
        try container.decodeIfPresent(Bool.self, forKey: .traditionalChinese)
        ?? Input.default.traditionalChinese
      asciiPunctuationDefault =
        try container.decodeIfPresent(Bool.self, forKey: .asciiPunctuationDefault)
        ?? Input.default.asciiPunctuationDefault
      singleCharacterSearchDefault =
        try container.decodeIfPresent(Bool.self, forKey: .singleCharacterSearchDefault)
        ?? Input.default.singleCharacterSearchDefault
      if container.contains(.chineseLearningPolicy) {
        let learningValue = try? container.decode(
          String.self, forKey: .chineseLearningPolicy)
        chineseLearningPolicy =
          learningValue.flatMap(ChineseLearningPolicy.init(rawValue:))
          ?? .disabled
      } else {
        chineseLearningPolicy = Input.default.chineseLearningPolicy
      }
      if container.contains(.pinyinReverseTrigger) {
        let triggerValue = try? container.decode(
          String.self, forKey: .pinyinReverseTrigger)
        pinyinReverseTrigger =
          triggerValue.flatMap(PinyinReverseTrigger.init(rawValue:))
          ?? Input.default.pinyinReverseTrigger
      } else {
        pinyinReverseTrigger = Input.default.pinyinReverseTrigger
      }
    }
  }

  struct English: Codable, Equatable, Sendable {
    var sentenceCapitalization: Bool
    var tabBehavior: TabBehavior
    var showIPA: Bool
    var showTranslation: Bool
    var predictionEnabled: Bool
    var spellingCorrection: Bool
    var learnFromSelections: Bool
    var spaceAddsTrailingSpace: Bool

    static let `default` = English(
      sentenceCapitalization: false,
      tabBehavior: .smartComplete,
      showIPA: true,
      showTranslation: true,
      predictionEnabled: true,
      spellingCorrection: true,
      learnFromSelections: true,
      spaceAddsTrailingSpace: true
    )

    init(
      sentenceCapitalization: Bool,
      tabBehavior: TabBehavior,
      showIPA: Bool = true,
      showTranslation: Bool = true,
      predictionEnabled: Bool = true,
      spellingCorrection: Bool = true,
      learnFromSelections: Bool = true,
      spaceAddsTrailingSpace: Bool = true
    ) {
      self.sentenceCapitalization = sentenceCapitalization
      self.tabBehavior = tabBehavior
      self.showIPA = showIPA
      self.showTranslation = showTranslation
      self.predictionEnabled = predictionEnabled
      self.spellingCorrection = spellingCorrection
      self.learnFromSelections = learnFromSelections
      self.spaceAddsTrailingSpace = spaceAddsTrailingSpace
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      sentenceCapitalization =
        try container.decodeIfPresent(Bool.self, forKey: .sentenceCapitalization)
        ?? English.default.sentenceCapitalization
      let behaviorValue = try container.decodeIfPresent(String.self, forKey: .tabBehavior)
      tabBehavior = behaviorValue.flatMap(TabBehavior.init(rawValue:)) ?? .smartComplete
      showIPA = try container.decodeIfPresent(Bool.self, forKey: .showIPA) ?? true
      showTranslation = try container.decodeIfPresent(Bool.self, forKey: .showTranslation) ?? true
      predictionEnabled =
        try container.decodeIfPresent(Bool.self, forKey: .predictionEnabled) ?? true
      spellingCorrection =
        try container.decodeIfPresent(Bool.self, forKey: .spellingCorrection) ?? true
      learnFromSelections =
        try container.decodeIfPresent(Bool.self, forKey: .learnFromSelections) ?? true
      spaceAddsTrailingSpace =
        try container.decodeIfPresent(Bool.self, forKey: .spaceAddsTrailingSpace) ?? true
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedSchemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    schemaVersion = storedSchemaVersion
    appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .default
    input = try container.decodeIfPresent(Input.self, forKey: .input) ?? .default
    english = try container.decodeIfPresent(English.self, forKey: .english) ?? .default
    // v4 changes two shipped defaults. Older documents necessarily stored the
    // previous values without recording whether they were explicit, so adopt
    // the new product defaults once; users can still opt back into either value.
    if storedSchemaVersion < 4 {
      if appearance.englishCandidateLayout == .vertical {
        appearance.englishCandidateLayout = .horizontal
      }
      if appearance.pageSize == 5 {
        appearance.pageSize = Appearance.defaultPageSize
      }
    }
    if storedSchemaVersion < Self.currentSchemaVersion {
      schemaVersion = Self.currentSchemaVersion
    }
  }

  static let `default` = LinnetSettingsDocument(
    appearance: .default,
    input: .default,
    english: .default
  )

  /// Clamps values into their bounded contract ranges and pins the schema
  /// version, so nothing the renderer emits can produce invalid Rime.
  func normalized() -> LinnetSettingsDocument {
    var result = self
    result.schemaVersion = Self.currentSchemaVersion
    result.appearance.fontPoint = Self.Appearance.clampFontPoint(appearance.fontPoint)
    if !Self.Appearance.pageSizeOptions.contains(result.appearance.pageSize) {
      result.appearance.pageSize = Self.Appearance.defaultPageSize
    }
    return result
  }
}
