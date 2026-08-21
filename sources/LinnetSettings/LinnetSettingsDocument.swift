//
//  LinnetSettingsDocument.swift
//  Typed, versioned settings document edited by the graphical Settings UI and
//  rendered into Rime YAML projections only at deploy time. The document is
//  the only Layer-1 surface the Settings application writes to; everything
//  else is derived by LinnetSettingsProjectionRenderer.
//

import CryptoKit
import Darwin
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
      pinyinReverseTrigger: .semicolon
    )

    init(
      chineseProfile: LinnetSettingsContract.ChineseProfile = .fullPinyin,
      emojiEnabled: Bool,
      traditionalChinese: Bool,
      asciiPunctuationDefault: Bool,
      singleCharacterSearchDefault: Bool = false,
      chineseLearningPolicy: ChineseLearningPolicy = .enhanced,
      pinyinReverseTrigger: PinyinReverseTrigger = .semicolon
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

/// Owns the JSON codec, first-run adoption, and atomic publication primitive
/// for the settings document. Settings writes only transaction candidates;
/// Host is the sole owner that exchanges one with the live document.
enum LinnetSettingsDocumentStore {
  static let fileName = "linnet_settings.json"
  static let maximumDocumentBytes = 1024 * 1024
  private static let chineseProfileSchemaVersion = 8
  private static let rimeUserConfigFile = "user.yaml"

  struct Snapshot: Equatable, Sendable {
    let document: LinnetSettingsDocument
    let revision: String
  }

  enum Failure: LocalizedError, Equatable, Sendable {
    case unsafePath(String)
    case malformedDocument
    case documentTooLarge
    case newerSchemaVersion(Int)

    var errorDescription: String? {
      switch self {
      case .unsafePath(let path): "Unsafe settings document path: \(path)"
      case .malformedDocument: "The settings document could not be read."
      case .documentTooLarge: "The settings document is too large."
      case .newerSchemaVersion(let version):
        "The settings document was created by a newer version (schema \(version))."
      }
    }
  }

  /// Loads the document. A missing file builds the default document and
  /// adopts legacy English interaction values and the last recognized Rime
  /// Chinese profile so an upgraded install keeps its behavior. Malformed
  /// JSON and newer schema versions fail closed without touching the file.
  static func snapshot(from directory: URL) throws -> Snapshot {
    let url = directory.appending(path: fileName)
    let stored: StoredDocumentBytes?
    do {
      stored = try boundedDataIfPresent(url)
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.malformedDocument
    }
    guard let stored else {
      let adopted = try adoptLegacy(from: directory)
      return Snapshot(
        document: adopted,
        revision: revision(presence: "absent", data: try encoded(adopted)))
    }
    var document: LinnetSettingsDocument
    do {
      document = try JSONDecoder().decode(LinnetSettingsDocument.self, from: stored.data)
    } catch {
      throw Failure.malformedDocument
    }
    guard document.schemaVersion <= LinnetSettingsDocument.currentSchemaVersion else {
      throw Failure.newerSchemaVersion(document.schemaVersion)
    }
    if shouldAdoptLegacyChineseProfile(from: stored.data),
      let profile = legacyChineseProfile(from: directory) {
      document.input.chineseProfile = profile
    }
    return Snapshot(document: document, revision: stored.revision)
  }

  static func load(from directory: URL) throws -> LinnetSettingsDocument {
    try snapshot(from: directory).document
  }

  static func defaultSnapshot() throws -> Snapshot {
    let document = LinnetSettingsDocument.default
    return Snapshot(
      document: document,
      revision: revision(presence: "absent", data: try encoded(document)))
  }

  static func write(_ document: LinnetSettingsDocument, to directory: URL) throws {
    try requireDirectory(directory)
    let data = try encoded(document)
    do {
      try data.write(to: directory.appending(path: fileName), options: .atomic)
    } catch {
      throw Failure.unsafePath(fileName)
    }
  }

  /// Atomically exchanges the candidate and live document on the same volume.
  /// It is deliberately involutive: after a successful exchange the candidate
  /// holds the previous live document, so the identical operation is rollback.
  /// Exactly one side may be absent, which covers first-run publication and
  /// restoring that physical absence without a journal or sentinel file.
  static func exchangeCandidateDocument(
    candidateDirectory: URL,
    liveDirectory: URL
  ) throws {
    let candidateDirectoryDescriptor = try ownedDirectoryDescriptor(candidateDirectory)
    defer { close(candidateDirectoryDescriptor) }
    let liveDirectoryDescriptor = try ownedDirectoryDescriptor(liveDirectory)
    defer { close(liveDirectoryDescriptor) }
    var candidateDirectoryInfo = stat()
    var liveDirectoryInfo = stat()
    guard fstat(candidateDirectoryDescriptor, &candidateDirectoryInfo) == 0,
      fstat(liveDirectoryDescriptor, &liveDirectoryInfo) == 0,
      candidateDirectoryInfo.st_dev == liveDirectoryInfo.st_dev
    else { throw Failure.unsafePath(fileName) }
    let candidate = candidateDirectory.appending(path: fileName)
    let live = liveDirectory.appending(path: fileName)
    let candidatePresent = try boundedDataIfPresent(candidate) != nil
    let livePresent = try boundedDataIfPresent(live) != nil
    guard candidatePresent || livePresent else { return }

    let result: Int32
    if candidatePresent && livePresent {
      result = fileName.withCString { candidateName in
        fileName.withCString { liveName in
          renameatx_np(
            candidateDirectoryDescriptor,
            candidateName,
            liveDirectoryDescriptor,
            liveName,
            UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
          )
        }
      }
    } else {
      let source = candidatePresent ? candidate : live
      let sourceDirectoryDescriptor = candidatePresent
        ? candidateDirectoryDescriptor : liveDirectoryDescriptor
      let destinationDirectoryDescriptor = candidatePresent
        ? liveDirectoryDescriptor : candidateDirectoryDescriptor
      result = source.lastPathComponent.withCString { sourceName in
        fileName.withCString { destinationName in
          renameatx_np(
            sourceDirectoryDescriptor,
            sourceName,
            destinationDirectoryDescriptor,
            destinationName,
            UInt32(RENAME_NOFOLLOW_ANY)
          )
        }
      }
    }
    guard result == 0 else { throw Failure.unsafePath(fileName) }
  }

  private static func encoded(_ document: LinnetSettingsDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(document.normalized())
    } catch {
      throw Failure.malformedDocument
    }
    guard data.count <= maximumDocumentBytes else { throw Failure.documentTooLarge }
    return data
  }

  /// One-time adoption moves legacy English interaction values and the last
  /// recognized Rime Chinese profile into the document. Best effort; missing,
  /// malformed, or unknown legacy values yield the explicit defaults.
  static func adoptLegacy(from directory: URL) throws -> LinnetSettingsDocument {
    var document = LinnetSettingsDocument.default
    let userSettings = directory.appending(
      path: LinnetPersonalDataStore.legacyUserSettingsFile)
    if FileManager.default.fileExists(atPath: userSettings.path),
      let legacy = try? LinnetPersonalDataStore.readLegacyUserSettings(userSettings) {
      document.english.sentenceCapitalization = legacy.sentenceCapitalization
      document.english.tabBehavior =
        LinnetSettingsDocument.TabBehavior(rawValue: legacy.tabBehavior) ?? .smartComplete
    }
    if let profile = legacyChineseProfile(from: directory) {
      document.input.chineseProfile = profile
    }
    return document
  }

  private struct StoredShape: Decodable {
    struct InputShape: Decodable {
      let chineseProfile: String?
    }

    let schemaVersion: Int?
    let input: InputShape?
  }

  private static func shouldAdoptLegacyChineseProfile(from data: Data) -> Bool {
    guard let shape = try? JSONDecoder().decode(StoredShape.self, from: data),
      let version = shape.schemaVersion,
      version < chineseProfileSchemaVersion
    else {
      return false
    }
    return shape.input?.chineseProfile == nil
  }

  /// Reads the previous Rime owner only at document adoption. A recognized
  /// profile is written into the typed document on the next Apply; unknown,
  /// duplicate, or malformed values never become a steady-state fallback.
  private static func legacyChineseProfile(
    from directory: URL
  ) -> LinnetSettingsContract.ChineseProfile? {
    let url = directory.appending(path: rimeUserConfigFile)
    guard let stored = try? boundedDataIfPresent(url),
      let contents = String(data: stored.data, encoding: .utf8)
    else {
      return nil
    }
    var insideVar = false
    var selected: LinnetSettingsContract.ChineseProfile?
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      if line == "var:" {
        insideVar = true
        continue
      }
      if !line.hasPrefix(" ") {
        insideVar = false
      }
      guard insideVar,
        line.hasPrefix("  previously_selected_schema: ")
      else {
        continue
      }
      let value = String(line.dropFirst("  previously_selected_schema: ".count))
        .trimmingCharacters(in: .whitespaces)
      guard selected == nil,
        let profile = LinnetSettingsContract.ChineseProfile(schemaID: value)
      else {
        return nil
      }
      selected = profile
    }
    return selected
  }

  private static func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.unsafePath(url.path)
    }
  }

  /// Pins a user-owned directory for a subsequent relative-name mutation so
  /// system-level symlinks in an otherwise valid absolute prefix do not become
  /// part of the document publication decision.
  private static func ownedDirectoryDescriptor(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.unsafePath(url.path) }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      close(descriptor)
      throw Failure.unsafePath(url.path)
    }
    return descriptor
  }

  private struct StoredDocumentBytes {
    let data: Data
    let revision: String
  }

  private static func boundedDataIfPresent(_ url: URL) throws -> StoredDocumentBytes? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 && errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw Failure.unsafePath(url.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else {
      throw Failure.unsafePath(url.lastPathComponent)
    }
    guard info.st_size >= 0, info.st_size <= maximumDocumentBytes else {
      throw Failure.documentTooLarge
    }
    var data = Data()
    var hasher = revisionHasher(presence: "present")
    data.reserveCapacity(Int(info.st_size))
    while true {
      let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
      if chunk.isEmpty { break }
      guard data.count <= maximumDocumentBytes - chunk.count else {
        throw Failure.documentTooLarge
      }
      data.append(chunk)
      hasher.update(data: chunk)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      info.st_dev == after.st_dev, info.st_ino == after.st_ino,
      info.st_size == after.st_size,
      info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      data.count == Int(info.st_size)
    else { throw Failure.unsafePath(url.lastPathComponent) }
    return StoredDocumentBytes(data: data, revision: hex(hasher.finalize()))
  }

  private static func revision(presence: String, data: Data) -> String {
    var hasher = revisionHasher(presence: presence)
    hasher.update(data: data)
    return hex(hasher.finalize())
  }

  private static func revisionHasher(presence: String) -> SHA256 {
    var hasher = SHA256()
    hasher.update(data: Data("io.github.ares-x.linnet.settings-document.v1\0".utf8))
    hasher.update(data: Data(presence.utf8))
    hasher.update(data: Data([0]))
    return hasher
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
