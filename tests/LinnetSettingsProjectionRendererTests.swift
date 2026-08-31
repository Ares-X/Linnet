import AppKit
import Darwin
import Foundation

@main
struct LinnetSettingsProjectionRendererTests {
  static func main() {
    let directory = LinnetTestScratch.directory.appending(
      path: "LinnetSettingsProjectionRendererTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      testDefaultInteractionProjection()
      testThemeFamilyAndAppearanceMapping()
      testFontPresetProjection()
      testCandidateLayoutMapping()
      testLightweightAppearanceProjection()
      testFontPointProjection()
      testPageSizeProjection()
      testSwitchProjections()
      testPinyinReverseTriggerProjection()
      testChineseProfileProjectionAndCodec()
      testChineseLearningPolicyProjection()
      testEnglishExperienceProjections()
      testEnglishLearningProjectionAndMigration()
      testOlderDocumentAdoptsNewDefaults()
      testLearningPolicyCodec()
      try testLegacyChineseProfileAdoption(in: directory)
      try testNewerDocumentFailsClosed(in: directory)
      try testOversizedSettingsDocumentFailsClosed(in: directory)
      try testProjectionReconciliationLifecycle(in: directory)
      try testCoreThemeReconciliation(in: directory)
      try testAtomicDocumentExchange(in: directory)
      print("LinnetSettingsProjectionRendererTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testThemeFamilyAndAppearanceMapping() {
    guard LinnetSettingsDocument.currentSchemaVersion == 11,
      LinnetSettingsDocument.ThemeFamily.allCases.map(\.rawValue) == [
        "paper_ledger", "moon_jade", "sidecar_slate", "clay_tiles", "mist_jade",
        "native_glass", "ink_cinnabar",
      ]
    else {
      fail("the settings codec must publish exactly the seven ordered theme families in schema v11")
    }
    let families: [(LinnetSettingsDocument.ThemeFamily, String)] = [
      (.paperLedger, "linnet_paper"),
      (.moonJade, "linnet_moon_jade"),
      (.sidecarSlate, "linnet_sidecar"),
      (.clayTiles, "linnet_clay"),
      (.mistJade, "linnet_mist_jade"),
      (.nativeGlass, "linnet_glass"),
      (.inkCinnabar, "linnet_ink_cinnabar"),
    ]
    for (family, prefix) in families {
      for (mode, lightSuffix, darkSuffix) in [
        (LinnetSettingsDocument.ThemeMode.system, "light", "dark"),
        (.light, "light", "light"),
        (.dark, "dark", "dark"),
      ] {
        var document = LinnetSettingsDocument.default
        document.appearance.themeFamily = family
        document.appearance.themeMode = mode
        if family == .paperLedger && mode == .system {
          require(
            LinnetSettingsProjectionRenderer.renderProjections(document: document)[
              LinnetSettingsProjectionRenderer.squirrelCustomFile] == nil,
            "the bundled default theme pair must not emit a redundant projection")
          continue
        }
        guard let projection = LinnetSettingsProjectionRenderer.renderProjections(
          document: document
        )[LinnetSettingsProjectionRenderer.squirrelCustomFile],
          projection.contains("\"style/color_scheme\": \"\(prefix)_\(lightSuffix)\""),
          projection.contains("\"style/color_scheme_dark\": \"\(prefix)_\(darkSuffix)\"")
        else {
          fail("\(family) did not project its \(mode) Light/Dark contract")
        }
        let materialProjection = "\"style/linnet_material_appearance\""
        if mode == .system {
          require(
            !projection.contains(materialProjection),
            "automatic appearance emitted a redundant fixed material mode"
          )
        } else {
          require(
            projection.contains("\(materialProjection): \"\(mode.rawValue)\""),
            "\(mode) fixed only its palette and not the native material appearance"
          )
        }
      }
    }
  }

  private static func testFontPresetProjection() {
    let expected: [(LinnetSettingsDocument.FontPreset, [String])] = [
      (.humanist, ["Avenir Next", "Hiragino Sans GB"]),
      (.swiss, ["Helvetica Neue", "Heiti SC"]),
      (.editorial, ["Iowan Old Style", "Songti SC"]),
      (.book, ["Charter", "Songti SC"]),
    ]
    for (preset, families) in expected {
      var document = LinnetSettingsDocument.default
      document.appearance.fontPreset = preset
      let face = families.joined(separator: ", ")
      guard let projection = LinnetSettingsProjectionRenderer.renderProjections(
        document: document
      )[LinnetSettingsProjectionRenderer.squirrelCustomFile],
        projection.contains("\"style/font_face\": \"\(face)\""),
        preset.fontFamilies == families,
        preset.displayPair == families.joined(separator: " + ")
      else {
        fail("the \(preset.rawValue) built-in font pair has more than one owner")
      }
      for family in families {
        guard !family.hasPrefix("."), NSFont(name: family, size: 17) != nil else {
          fail("the \(preset.rawValue) face \(family) is not a public built-in macOS font")
        }
      }
    }
  }

  private static func testPageSizeProjection() {
    for pageSize in LinnetSettingsDocument.Appearance.pageSizeOptions {
      var document = LinnetSettingsDocument.default
      document.appearance.pageSize = pageSize
      let projection = LinnetSettingsProjectionRenderer.renderProjections(
        document: document
      )[LinnetSettingsProjectionRenderer.defaultCustomFile]
      if pageSize == LinnetSettingsDocument.Appearance.defaultPageSize {
        require(
          projection == coreInteractionProjection + defaultSchemaOrderProjection,
          "the default document did not preserve unfinished text on a mode switch"
        )
      } else {
        require(
          projection == coreInteractionProjection
            + "  \"menu/page_size\": \(pageSize)\n"
            + defaultSchemaOrderProjection,
          "page size \(pageSize) displaced the canonical mode-switch policy"
        )
      }
    }
  }

  /// A default document matches the bundled distribution defaults: Chinese
  /// Chinese and English candidates are horizontal, the page holds nine, and the
  /// candidate font stays within an input-method-sized 12...32 pt range.
  private static func testDefaultInteractionProjection() {
    guard LinnetSettingsDocument.Appearance.defaultFontPoint == 16.0 else {
      fail("the default font point drifted from the bundled font_point: 16")
    }
    guard LinnetSettingsDocument.Appearance.minimumFontPoint == 12.0,
      LinnetSettingsDocument.Appearance.maximumFontPoint == 32.0,
      LinnetSettingsDocument.Appearance.fontPointStep == 1.0,
      LinnetSettingsDocument.Appearance.default.chineseCandidateLayout == .horizontal,
      LinnetSettingsDocument.Appearance.default.englishCandidateLayout == .horizontal,
      LinnetSettingsDocument.CandidateLayout.allCases == [.horizontal, .vertical],
      LinnetSettingsDocument.CandidateBrowsingMode.allCases == [.scrollingOnly, .expandable],
      LinnetSettingsDocument.Appearance.default.candidateBrowsingMode == .expandable,
      LinnetSettingsDocument.Appearance.default.pageSize == 9,
      LinnetSettingsDocument.Input.default.pinyinReverseTrigger == .verticalBar
    else {
      fail("candidate font bounds or the bilingual layout defaults drifted")
    }
    let bundledDefaults = try? String(
      contentsOfFile: "data/linnet/default.yaml", encoding: .utf8)
    guard bundledDefaults?.contains("pinyin_reverse_lookup: \"^[|][a-z;']*$\"") == true,
      bundledDefaults?.contains("prefix: \"|\"") == true
    else {
      fail("the bundled reverse-lookup base no longer matches the document-owned | default")
    }
    let projections = LinnetSettingsProjectionRenderer.renderProjections(
      document: .default
    )
    let schemaFiles = Set(
      LinnetSettingsProjectionRenderer.chineseCustomFiles
        + [LinnetSettingsProjectionRenderer.englishCustomFile])
    guard Set(projections.keys)
      == schemaFiles.union([LinnetSettingsProjectionRenderer.defaultCustomFile])
    else {
      fail("the document-owned interaction defaults did not cover every schema")
    }
    require(
      projections[LinnetSettingsProjectionRenderer.defaultCustomFile]
        == coreInteractionProjection + defaultSchemaOrderProjection,
      "the default Core projection did not own the complete installed interaction policy"
    )
    for name in schemaFiles {
      guard let contents = projections[name] else {
        fail("the default interaction projection was absent from \(name)")
      }
      guard contents.contains(
        "\"linnet_english_interaction/sentence_capitalization\": false"),
        contents.contains("\"linnet_english_interaction/tab_behavior\": \"smart_complete\""),
        contents.contains("\"linnet_english_interaction/space_adds_trailing_space\": true"),
        !contents.contains("recognizer/patterns/linnet_pinyin"),
        !contents.contains("linnet_pinyin/prefix")
      else {
        fail("the default interaction settings were not authoritative in \(name)")
      }
    }
  }

  private static func testPinyinReverseTriggerProjection() {
    var document = LinnetSettingsDocument.default
    document.input.pinyinReverseTrigger = .semicolon
    let projections = LinnetSettingsProjectionRenderer.renderProjections(
      document: document)
    let reverseLookupFiles =
      LinnetSettingsProjectionRenderer.chineseCustomFiles
      + [LinnetSettingsProjectionRenderer.englishCustomFile]
    guard Set(projections.keys)
      == Set(reverseLookupFiles + [LinnetSettingsProjectionRenderer.defaultCustomFile])
    else {
      fail("the reverse-lookup trigger did not project to both language modes")
    }
    for file in reverseLookupFiles {
      guard let contents = projections[file],
        contents.contains(
          "\"recognizer/patterns/linnet_pinyin\": \"^;[a-z;']*$\""),
        contents.contains("\"linnet_pinyin/prefix\": \";\"")
      else {
        fail("the reverse-lookup recognizer and affix prefix diverged in \(file)")
      }
    }

    do {
      let encoded = try JSONEncoder().encode(document)
      let decoded = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: encoded)
      guard decoded.input.pinyinReverseTrigger == .semicolon else {
        fail("the reverse-lookup trigger did not survive the document codec")
      }
    } catch {
      fail("the reverse-lookup trigger codec failed: \(error)")
    }

    document.input.pinyinReverseTrigger = .verticalBar
    let restored = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    guard restored.values.allSatisfy({
      !$0.contains("recognizer/patterns/linnet_pinyin")
        && !$0.contains("linnet_pinyin/prefix")
    }) else {
      fail("restoring the bundled | reverse-lookup trigger left a projection")
    }

    let invalid = Data("""
      {"schemaVersion":5,"input":{"pinyinReverseTrigger":"unsupported"}}
      """.utf8)
    do {
      let decoded = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: invalid)
      guard decoded.input.pinyinReverseTrigger == .verticalBar else {
        fail("an invalid reverse-lookup trigger did not fail closed to the bundled key")
      }
    } catch {
      fail("an invalid reverse-lookup trigger could not fail closed safely: \(error)")
    }
  }

  private static func testChineseProfileProjectionAndCodec() {
    let expectedProfiles: [(LinnetSettingsContract.ChineseProfile, String)] = [
      (.fullPinyin, "linnet_zh_pinyin"),
      (.natural, "linnet_zh"),
      (.flypy, "linnet_zh_flypy"),
      (.microsoft, "linnet_zh_mspy"),
      (.sogou, "linnet_zh_sogou"),
      (.abc, "linnet_zh_abc"),
      (.ziguang, "linnet_zh_ziguang"),
      (.jiajia, "linnet_zh_jiajia"),
    ]
    require(
      LinnetSettingsContract.ChineseProfile.allCases.map(\.schemaID)
        == expectedProfiles.map(\.1),
      "the typed Chinese profile order diverged from the eight shipped prisms"
    )
    require(
      LinnetSettingsDocument.Input.default.chineseProfile == .fullPinyin,
      "a fresh Settings document did not default to the majority full-pinyin profile"
    )
    for (profile, prism) in expectedProfiles {
      var document = LinnetSettingsDocument.default
      document.input.chineseProfile = profile
      do {
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(LinnetSettingsDocument.self, from: encoded)
        require(decoded.input.chineseProfile == profile,
                "the selected Chinese profile did not survive the current codec")
      } catch {
        fail("the selected Chinese profile codec failed: \(error)")
      }
      let english = LinnetSettingsProjectionRenderer.renderProjections(document: document)[
        LinnetSettingsProjectionRenderer.englishCustomFile]
      let defaultCustom = LinnetSettingsProjectionRenderer.renderProjections(document: document)[
        LinnetSettingsProjectionRenderer.defaultCustomFile]
      guard let selectedIndex = expectedProfiles.firstIndex(where: { $0.0 == profile }) else {
        fail("the selected Chinese profile was absent from the shipped schema list")
      }
      var orderedSchemas = expectedProfiles.map(\.1)
      orderedSchemas.swapAt(0, selectedIndex)
      orderedSchemas.append(LinnetSettingsContract.englishSchemaID)
      let expectedDefault = orderedSchemas.enumerated().reduce(
        coreInteractionProjection
      ) { projection, entry in
        projection + "  \"schema_list/@\(entry.offset)/schema\": \"\(entry.element)\"\n"
      }
      require(
        english?.contains("\"linnet_pinyin/prism\": \"\(prism)\"") == true &&
          english?.contains("\"linnet_mode_switch/chinese_schema\": \"\(prism)\"") == true,
        "the selected Chinese profile did not explicitly own English lookup and Shift return"
      )
      require(
        defaultCustom == expectedDefault,
        "the selected Chinese profile did not explicitly own the complete schema order"
      )
    }

    do {
      let migrated = try JSONDecoder().decode(
        LinnetSettingsDocument.self,
        from: Data(#"{"schemaVersion":7}"#.utf8)
      )
      require(
        migrated.schemaVersion == LinnetSettingsDocument.currentSchemaVersion
          && migrated.input.chineseProfile == .fullPinyin,
        "a legacy document without an explicit profile did not adopt the current full-pinyin default"
      )
    } catch {
      fail("a valid v7 document could not migrate: \(error)")
    }

    do {
      _ = try JSONDecoder().decode(
        LinnetSettingsDocument.self,
        from: Data(#"{"schemaVersion":8,"input":{"chineseProfile":"unknown"}}"#.utf8)
      )
      fail("an unknown Chinese profile did not fail closed")
    } catch {
      // Expected: a present but unknown profile is not a migration case.
    }
  }

  /// Squirrel semantics: linear joins candidates into one row; stacked lists
  /// one per line. Settings owns direction and one global disclosure
  /// capability. The actual expanded/collapsed state remains Panel-transient.
  private static func testCandidateLayoutMapping() {
    var document = LinnetSettingsDocument.default
    document.appearance.chineseCandidateLayout = .vertical
    var projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    guard projections[LinnetSettingsProjectionRenderer.squirrelCustomFile] == nil else {
      fail("a bilingual layout leaked back into the global Squirrel projection")
    }
    for file in LinnetSettingsProjectionRenderer.chineseCustomFiles {
      guard let vertical = projections[file],
        vertical.contains("\"style/candidate_list_layout\": \"stacked\""),
        vertical.contains("\"style/text_orientation\": \"horizontal\"")
      else {
        fail("Chinese vertical layout did not cover \(file)")
      }
    }
    guard let defaultEnglish = projections[LinnetSettingsProjectionRenderer.englishCustomFile],
      !defaultEnglish.contains("style/candidate_list_layout")
    else {
      fail("the default English interaction projection changed candidate layout")
    }

    document.appearance.chineseCandidateLayout = .horizontal
    document.appearance.englishCandidateLayout = .vertical
    projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    guard let english = projections[LinnetSettingsProjectionRenderer.englishCustomFile],
      english.contains("\"style/candidate_list_layout\": \"stacked\""),
      english.contains("\"style/text_orientation\": \"horizontal\"")
    else {
      fail("English vertical layout did not project to a stacked list")
    }
    guard LinnetSettingsProjectionRenderer.chineseCustomFiles.allSatisfy({ name in
      guard let contents = projections[name] else { return false }
      return !contents.contains("style/candidate_list_layout")
    }) else {
      fail("the default Chinese interaction projection changed candidate layout")
    }
    for (name, contents) in projections {
      guard !contents.contains("linnet_expand_candidate_rows"),
        !contents.contains("linnet_candidate_expansion_allowed")
      else {
        fail("transient candidate disclosure leaked into Settings projection \(name)")
      }
    }

    document.appearance.englishCandidateLayout = .horizontal
    document.appearance.candidateBrowsingMode = .scrollingOnly
    projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    guard projections[LinnetSettingsProjectionRenderer.squirrelCustomFile]
      == "patch:\n  \"style/linnet_candidate_expansion_allowed\": false\n"
    else {
      fail("the global scrolling-only capability did not project exactly once")
    }
  }

  private static func testLightweightAppearanceProjection() {
    var baseline = LinnetSettingsDocument.Appearance.default
    baseline.pageSize = 5
    baseline.chineseCandidateLayout = .vertical
    baseline.englishCandidateLayout = .vertical
    baseline.candidateBrowsingMode = .scrollingOnly
    var requested = baseline
    requested.fontPoint = 21
    requested.themeFamily = .nativeGlass
    requested.pageSize = 9
    requested.chineseCandidateLayout = .horizontal
    requested.englishCandidateLayout = .horizontal
    requested.candidateBrowsingMode = .expandable

    let projected = requested.livePanelProjection(over: baseline)
    require(projected.fontPoint == 21 && projected.themeFamily == .nativeGlass,
            "panel-live appearance fields were not retained")
    require(projected.pageSize == 5,
            "page size escaped the full Apply boundary")
    require(projected.chineseCandidateLayout == .vertical
              && projected.englishCandidateLayout == .vertical,
            "candidate layouts escaped the full Apply boundary")
    require(projected.candidateBrowsingMode == .scrollingOnly,
            "candidate browsing capability escaped the full Apply boundary")
  }

  private static func testFontPointProjection() {
    var document = LinnetSettingsDocument.default
    document.appearance.fontPoint = 20
    guard let projection = LinnetSettingsProjectionRenderer.renderProjections(
      document: document
    )[LinnetSettingsProjectionRenderer.squirrelCustomFile],
      projection.contains("\"style/font_point\": 20"),
      projection.contains("\"style/label_font_point\": 12.5"),
      projection.contains("\"style/comment_font_point\": 15"),
      !projection.contains("candidate_list_layout")
    else {
      fail("a non-default font point did not preserve candidate/label/comment proportions")
    }
  }

  /// Switch indices follow linnet_zh.schema.yaml: 2 traditionalization
  /// (default 简), 3 emoji (bundled reset 1). Only deviations emit a patch,
  /// identical across all eight Chinese profiles.
  private static func testSwitchProjections() {
    var document = LinnetSettingsDocument.default
    document.input.emojiEnabled = false
    document.input.traditionalChinese = true
    document.input.asciiPunctuationDefault = true
    document.input.singleCharacterSearchDefault = true
    let projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    let chineseFiles = LinnetSettingsProjectionRenderer.chineseCustomFiles
    guard chineseFiles.count == LinnetSettingsContract.ChineseProfile.allCases.count,
      Set(projections.keys) == Set(
        chineseFiles + [
          LinnetSettingsProjectionRenderer.defaultCustomFile,
          LinnetSettingsProjectionRenderer.englishCustomFile,
        ])
    else {
      fail("switch projections did not cover every Chinese profile")
    }
    for file in chineseFiles {
      guard let contents = projections[file],
        contents.contains("\"switches/@1/reset\": 1"),
        contents.contains("\"switches/@2/reset\": 1"),
        contents.contains("\"switches/@3/reset\": 0"),
        contents.contains("\"switches/@4/reset\": 1")
      else {
        fail("switch projection for \(file) missed the traditionalization or emoji reset")
      }
    }

    document.input.emojiEnabled = true
    document.input.traditionalChinese = false
    document.input.asciiPunctuationDefault = false
    document.input.singleCharacterSearchDefault = false
    let defaults = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    guard Set(defaults.keys) == Set(
      chineseFiles + [
        LinnetSettingsProjectionRenderer.defaultCustomFile,
        LinnetSettingsProjectionRenderer.englishCustomFile,
      ])
    else { fail("default switches changed the document-owned interaction projection set") }
  }

  private static func testChineseLearningPolicyProjection() {
    var document = LinnetSettingsDocument.default
    guard document.input.chineseLearningPolicy == .enhanced else {
      fail("the shipped Chinese learning policy is not enhanced learning")
    }

    document.input.chineseLearningPolicy = .standard
    var projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    for file in LinnetSettingsProjectionRenderer.chineseCustomFiles {
      guard let contents = projections[file],
        contents.contains("\"auto_phrase/enable\": false"),
        !contents.contains("translator/enable_user_dict")
      else {
        fail("standard Chinese learning did not disable only the Linnet enhancement in \(file)")
      }
    }

    document.input.chineseLearningPolicy = .disabled
    projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    for file in LinnetSettingsProjectionRenderer.chineseCustomFiles {
      guard let contents = projections[file],
        contents.contains("\"auto_phrase/enable\": false"),
        contents.contains("\"translator/enable_user_dict\": false")
      else {
        fail("disabled Chinese learning did not close both learning paths in \(file)")
      }
    }
    guard let english = projections[LinnetSettingsProjectionRenderer.englishCustomFile],
      english.contains("\"linnet_english_interaction/sentence_capitalization\": false"),
      english.contains("\"linnet_english_interaction/tab_behavior\": \"smart_complete\""),
      projections[LinnetSettingsProjectionRenderer.squirrelCustomFile] == nil
    else {
      fail("the Chinese learning policy leaked into English or global appearance")
    }

    document.input.chineseLearningPolicy = .enhanced
    let defaults = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    guard Set(defaults.keys)
      == Set(
        LinnetSettingsProjectionRenderer.chineseCustomFiles
          + [
            LinnetSettingsProjectionRenderer.defaultCustomFile,
            LinnetSettingsProjectionRenderer.englishCustomFile,
          ]
      )
    else {
      fail("enhanced Chinese learning did not return to the bundled default")
    }
  }

  private static func testEnglishExperienceProjections() {
    do {
      let legacy = Data("{\"english\":{\"spellingCorrection\":false}}".utf8)
      let restored = try JSONDecoder().decode(LinnetSettingsDocument.self, from: legacy)
      let encoded = try JSONEncoder().encode(restored)
      guard !String(decoding: encoded, as: UTF8.self).contains("spellingCorrection"),
        LinnetSettingsProjectionRenderer.renderProjections(document: restored).values.allSatisfy({
          !$0.contains("spelling_correction")
        })
      else { fail("a retired English correction switch survived import or runtime projection") }
    } catch { fail("legacy English preferences did not migrate: \(error)") }
    var document = LinnetSettingsDocument.default
    document.english.showIPA = false
    document.english.showTranslation = false
    document.english.predictionEnabled = false
    document.english.spaceAddsTrailingSpace = false
    let projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
    guard let english = projections[LinnetSettingsProjectionRenderer.englishCustomFile],
      english.contains("\"linnet_english_interaction/show_ipa\": false"),
      english.contains("\"linnet_english_interaction/show_translation\": false"),
      english.contains("\"switches/@1/reset\": 0"),
      !english.contains("spelling_correction"),
      english.contains("\"linnet_english_interaction/space_adds_trailing_space\": false")
    else {
      fail("English display, prediction, or trailing-space settings were not projected")
    }
    for file in LinnetSettingsProjectionRenderer.chineseCustomFiles {
      guard let contents = projections[file],
        contents.contains("\"linnet_english_interaction/show_ipa\": false"),
        contents.contains("\"linnet_english_interaction/show_translation\": false"),
        !contents.contains("enable_correction"),
        !contents.contains("switches/@1/reset")
      else {
        fail("pinyin reverse-lookup metadata settings did not cover \(file)")
      }
    }
  }

  private static func testEnglishLearningProjectionAndMigration() {
    let disabled = Data("""
      {"schemaVersion":6,"english":{"learnFromSelections":false}}
      """.utf8)
    do {
      let document = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: disabled)
      let projections = LinnetSettingsProjectionRenderer.renderProjections(
        document: document)
      guard let english = projections[LinnetSettingsProjectionRenderer.englishCustomFile],
        english.contains("\"translator/enable_user_dict\": false"),
        english.contains("\"linnet_english_interaction/learning_enabled\": false")
      else {
        fail("turning off English learning did not close both English learning paths")
      }
      for file in LinnetSettingsProjectionRenderer.chineseCustomFiles {
        guard let contents = projections[file],
          contents.contains("\"linnet_english_interaction/learning_enabled\": false"),
          !contents.contains("translator/enable_user_dict")
        else {
          fail("English session learning did not close independently in \(file)")
        }
      }
    } catch {
      fail("the disabled English learning setting did not decode: \(error)")
    }

    let legacy = Data("""
      {"schemaVersion":5,"english":{"predictionEnabled":true}}
      """.utf8)
    do {
      let document = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: legacy)
      let projections = LinnetSettingsProjectionRenderer.renderProjections(document: document)
      guard Set(projections.keys)
        == Set(
          LinnetSettingsProjectionRenderer.chineseCustomFiles
            + [
              LinnetSettingsProjectionRenderer.defaultCustomFile,
              LinnetSettingsProjectionRenderer.englishCustomFile,
            ]
        ),
        let encoded = try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(document)) as? [String: Any],
        let english = encoded["english"] as? [String: Any],
        english["learnFromSelections"] as? Bool == true
      else {
        fail("a document without English learning state did not migrate to enabled")
      }
    } catch {
      fail("an older English learning document did not migrate: \(error)")
    }
  }

  private static func testOlderDocumentAdoptsNewDefaults() {
    let old = Data("""
      {"schemaVersion":1,"appearance":{"fontPoint":16,"themeMode":"system","candidateLayout":"vertical","pageSize":5},"input":{"emojiEnabled":true,"traditionalChinese":false},"english":{"sentenceCapitalization":false,"tabBehavior":"smart_complete"}}
      """.utf8)
    do {
      let decoded = try JSONDecoder().decode(LinnetSettingsDocument.self, from: old)
      guard decoded.input.asciiPunctuationDefault == false,
        decoded.input.singleCharacterSearchDefault == false,
        decoded.input.chineseLearningPolicy == .enhanced,
        decoded.appearance.themeFamily == .paperLedger,
        decoded.appearance.fontPreset == .system,
        decoded.appearance.chineseCandidateLayout == .horizontal,
        decoded.appearance.englishCandidateLayout == .horizontal,
        decoded.appearance.pageSize == 9,
        decoded.english.showIPA,
        decoded.english.showTranslation,
        decoded.english.predictionEnabled,
        decoded.english.spaceAddsTrailingSpace
      else {
        fail("an older settings document did not adopt the shipped behavior defaults")
      }
    } catch {
      fail("an older settings document no longer decodes: \(error)")
    }

    for previousVersion in 1...3 {
      let previousDefaults = Data("""
        {"schemaVersion":\(previousVersion),"appearance":{"fontPoint":16,"themeMode":"system","themeFamily":"paper_ledger","fontPreset":"system","chineseCandidateLayout":"horizontal","englishCandidateLayout":"vertical","pageSize":5}}
        """.utf8)
      do {
        let decoded = try JSONDecoder().decode(
          LinnetSettingsDocument.self, from: previousDefaults)
        guard decoded.schemaVersion == LinnetSettingsDocument.currentSchemaVersion,
          decoded.appearance.englishCandidateLayout == .horizontal,
          decoded.appearance.pageSize == 9,
          decoded.input.pinyinReverseTrigger == .verticalBar
        else {
          fail("v\(previousVersion) shipped layout and page defaults were not migrated")
        }
      } catch {
        fail("v\(previousVersion) default settings document no longer decodes: \(error)")
      }
    }

    let explicitV4Choice = Data("""
      {"schemaVersion":4,"appearance":{"fontPoint":16,"themeMode":"system","themeFamily":"paper_ledger","fontPreset":"system","chineseCandidateLayout":"horizontal","englishCandidateLayout":"vertical","pageSize":5}}
      """.utf8)
    do {
      let decoded = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: explicitV4Choice)
      guard decoded.schemaVersion == LinnetSettingsDocument.currentSchemaVersion,
        decoded.appearance.englishCandidateLayout == .vertical,
        decoded.appearance.pageSize == 5,
        decoded.input.pinyinReverseTrigger == .verticalBar
      else {
        fail("the v4 trigger migration changed an explicit vertical/five choice")
      }
    } catch {
      fail("an explicit v4 settings document no longer decodes: \(error)")
    }

    let explicitV8Choice = Data("""
      {"schemaVersion":8,"appearance":{"fontPoint":16,"themeMode":"system","themeFamily":"native_glass","fontPreset":"system","chineseCandidateLayout":"vertical","englishCandidateLayout":"horizontal","pageSize":7}}
      """.utf8)
    do {
      let decoded = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: explicitV8Choice)
      guard decoded.schemaVersion == LinnetSettingsDocument.currentSchemaVersion,
        decoded.appearance.themeFamily == .nativeGlass,
        decoded.appearance.chineseCandidateLayout == .vertical,
        decoded.appearance.englishCandidateLayout == .horizontal,
        decoded.appearance.pageSize == 7
      else {
        fail("the v8 migration changed an explicit appearance choice")
      }
    } catch {
      fail("an explicit v8 settings document no longer decodes: \(error)")
    }

    let v9LayoutChoices: [(String, String, LinnetSettingsDocument.CandidateLayout,
      LinnetSettingsDocument.CandidateLayout,
      LinnetSettingsDocument.CandidateBrowsingMode)] = [
      ("expanded", "vertical", .horizontal, .vertical, .expandable),
      ("vertical", "expanded", .vertical, .horizontal, .expandable),
      ("expanded", "expanded", .horizontal, .horizontal, .expandable),
      ("horizontal", "vertical", .horizontal, .vertical, .scrollingOnly),
      ("vertical", "horizontal", .vertical, .horizontal, .scrollingOnly),
    ]
    for (chineseRaw, englishRaw, expectedChinese, expectedEnglish, expectedBrowsing)
      in v9LayoutChoices
    {
      let legacy = Data("""
        {"schemaVersion":9,"appearance":{"fontPoint":16,"themeMode":"system","themeFamily":"paper_ledger","fontPreset":"system","chineseCandidateLayout":"\(chineseRaw)","englishCandidateLayout":"\(englishRaw)","pageSize":9}}
        """.utf8)
      do {
        let decoded = try JSONDecoder().decode(LinnetSettingsDocument.self, from: legacy)
        guard decoded.schemaVersion == LinnetSettingsDocument.currentSchemaVersion,
          decoded.appearance.chineseCandidateLayout == expectedChinese,
          decoded.appearance.englishCandidateLayout == expectedEnglish,
          decoded.appearance.candidateBrowsingMode == expectedBrowsing
        else {
          fail("v9 layout did not preserve direction and migrate disclosure capability")
        }
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        guard !encoded.contains("CandidateLayout\":\"expanded"),
          encoded.contains("\"candidateBrowsingMode\":\"\(expectedBrowsing.rawValue)\"")
        else {
          fail("v9 expanded layout survived outside the v10 browsing capability")
        }
      } catch {
        fail("v9 layout migration failed: \(error)")
      }
    }

    for family in [
      LinnetSettingsDocument.ThemeFamily.paperLedger,
      .sidecarSlate,
      .clayTiles,
      .nativeGlass,
    ] {
      let explicitV6Choice = Data("""
        {"schemaVersion":6,"appearance":{"fontPoint":16,"themeMode":"system","themeFamily":"\(family.rawValue)","fontPreset":"system","chineseCandidateLayout":"horizontal","englishCandidateLayout":"vertical","pageSize":5},"input":{"pinyinReverseTrigger":"vertical_bar"}}
        """.utf8)
      do {
        let decoded = try JSONDecoder().decode(
          LinnetSettingsDocument.self, from: explicitV6Choice)
        guard decoded.schemaVersion == LinnetSettingsDocument.currentSchemaVersion,
          decoded.appearance.themeFamily == family,
          decoded.appearance.englishCandidateLayout == .vertical,
          decoded.appearance.pageSize == 5,
          decoded.input.pinyinReverseTrigger == .verticalBar
        else {
          fail("the v6 migration changed an existing explicit theme choice")
        }
      } catch {
        fail("an explicit v6 settings document no longer decodes: \(error)")
      }
    }

    for family in [
      LinnetSettingsDocument.ThemeFamily.moonJade,
      LinnetSettingsDocument.ThemeFamily.mistJade,
      LinnetSettingsDocument.ThemeFamily.inkCinnabar,
    ] {
      var document = LinnetSettingsDocument.default
      document.appearance.themeFamily = family
      do {
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(LinnetSettingsDocument.self, from: encoded)
        guard decoded.schemaVersion == LinnetSettingsDocument.currentSchemaVersion,
          decoded.appearance.themeFamily == family
        else {
          fail("a theme family did not survive the current settings codec")
        }
      } catch {
        fail("a theme family could not round-trip: \(error)")
      }
    }

    let invalidCurrentTheme = Data("""
      {"schemaVersion":10,"appearance":{"themeFamily":"unsupported"}}
      """.utf8)
    do {
      _ = try JSONDecoder().decode(LinnetSettingsDocument.self, from: invalidCurrentTheme)
      fail("an unknown current theme family silently became another user choice")
    } catch DecodingError.dataCorrupted {
      // Expected: a current document with an unknown finite choice fails closed.
    } catch {
      fail("an unknown current theme failed for an unrelated reason: \(error)")
    }

    let invalidLearningPolicy = Data("""
      {"schemaVersion":3,"input":{"emojiEnabled":true,"traditionalChinese":false,"asciiPunctuationDefault":false,"singleCharacterSearchDefault":false,"chineseLearningPolicy":"unsupported"}}
      """.utf8)
    do {
      let decoded = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: invalidLearningPolicy)
      guard decoded.input.chineseLearningPolicy == .disabled else {
        fail("an invalid Chinese learning policy did not fail closed")
      }
    } catch {
      fail("an invalid Chinese learning policy could not be repaired safely: \(error)")
    }

    let invalidLearningType = Data("""
      {"schemaVersion":3,"input":{"emojiEnabled":true,"traditionalChinese":false,"asciiPunctuationDefault":false,"singleCharacterSearchDefault":false,"chineseLearningPolicy":7}}
      """.utf8)
    do {
      let decoded = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: invalidLearningType)
      guard decoded.input.chineseLearningPolicy == .disabled else {
        fail("a malformed Chinese learning policy did not fail closed")
      }
    } catch {
      fail("a malformed Chinese learning policy could not be repaired safely: \(error)")
    }
  }

  private static func testLearningPolicyCodec() {
    var document = LinnetSettingsDocument.default
    document.input.chineseLearningPolicy = .disabled
    do {
      let encoded = try JSONEncoder().encode(document)
      let decoded = try JSONDecoder().decode(LinnetSettingsDocument.self, from: encoded)
      guard decoded.schemaVersion == LinnetSettingsDocument.currentSchemaVersion,
        decoded.input.chineseLearningPolicy == .disabled
      else {
        fail("the Chinese learning policy did not survive the versioned document codec")
      }
    } catch {
      fail("the Chinese learning policy codec failed: \(error)")
    }
  }

  private static func testLegacyChineseProfileAdoption(in directory: URL) throws {
    let document = directory.appending(path: LinnetSettingsDocumentStore.fileName)
    let rimeUserConfig = directory.appending(path: "user.yaml")
    try Data(#"{"schemaVersion":7}"#.utf8).write(to: document)
    try Data("""
      var:
        previously_selected_schema: linnet_zh_jiajia
      """.utf8).write(to: rimeUserConfig)
    let migrated = try LinnetSettingsDocumentStore.load(from: directory)
    require(
      migrated.input.chineseProfile == .jiajia,
      "a legacy selected Chinese profile was reset instead of being adopted once"
    )
    try FileManager.default.removeItem(at: document)
    try FileManager.default.removeItem(at: rimeUserConfig)
  }

  private static func testOversizedSettingsDocumentFailsClosed(in directory: URL) throws {
    let document = directory.appending(path: LinnetSettingsDocumentStore.fileName)
    FileManager.default.createFile(atPath: document.path, contents: nil)
    let handle = try FileHandle(forWritingTo: document)
    try handle.truncate(atOffset: UInt64(LinnetSettingsDocumentStore.maximumDocumentBytes + 1))
    try handle.close()
    do {
      _ = try LinnetSettingsDocumentStore.load(from: directory)
      fail("an oversized settings document was accepted")
    } catch LinnetSettingsDocumentStore.Failure.documentTooLarge {
      // Expected: the codec rejects before JSON decoding or default adoption.
    }
    try FileManager.default.removeItem(at: document)
  }

  private static func testNewerDocumentFailsClosed(in directory: URL) throws {
    let document = directory.appending(path: LinnetSettingsDocumentStore.fileName)
    let newerVersion = LinnetSettingsDocument.currentSchemaVersion + 1
    try Data("""
      {"schemaVersion":\(newerVersion)}
      """.utf8).write(to: document)
    do {
      _ = try LinnetSettingsDocumentStore.load(from: directory)
      fail("a settings document from a newer schema was accepted")
    } catch LinnetSettingsDocumentStore.Failure.newerSchemaVersion(let version) {
      guard version == newerVersion else { fail("the newer schema identity was lost") }
    }
    try FileManager.default.removeItem(at: document)
  }

  /// Reconciliation emits changed files, leaves identical bytes untouched, and
  /// removes only projections that no longer belong to the canonical document.
  private static func testProjectionReconciliationLifecycle(in directory: URL) throws {
    var document = LinnetSettingsDocument.default
    document.appearance.chineseCandidateLayout = .vertical
    document.appearance.englishCandidateLayout = .vertical
    document.input.emojiEnabled = false
    let firstChanges = try LinnetSettingsProjectionRenderer.reconcile(
      document: document, to: directory)
    let chineseCustom = directory.appending(path: "linnet_zh.custom.yaml")
    let englishCustom = directory.appending(
      path: LinnetSettingsProjectionRenderer.englishCustomFile
    )
    let defaultCustom = directory.appending(
      path: LinnetSettingsProjectionRenderer.defaultCustomFile
    )
    guard let chinese = try? String(contentsOf: chineseCustom, encoding: .utf8),
      chinese.contains("\"style/candidate_list_layout\": \"stacked\""),
      let english = try? String(contentsOf: englishCustom, encoding: .utf8),
      english.contains("\"style/candidate_list_layout\": \"stacked\""),
      try String(contentsOf: defaultCustom, encoding: .utf8)
        == coreInteractionProjection + defaultSchemaOrderProjection,
      !FileManager.default.fileExists(
        atPath: directory.appending(path: LinnetSettingsProjectionRenderer.squirrelCustomFile).path
      )
    else {
      fail("projection reconciliation did not stage the expected files")
    }
    guard firstChanges.contains("linnet_zh.custom.yaml"),
      firstChanges.contains(LinnetSettingsProjectionRenderer.defaultCustomFile),
      firstChanges.contains(LinnetSettingsProjectionRenderer.englishCustomFile)
    else { fail("the first reconciliation did not report its changed projections") }

    let before = try fileIdentity(chineseCustom)
    let noChanges = try LinnetSettingsProjectionRenderer.reconcile(
      document: document, to: directory)
    guard noChanges.isEmpty, try fileIdentity(chineseCustom) == before else {
      fail("identical projections were rewritten")
    }

    let reverted = try LinnetSettingsProjectionRenderer.reconcile(
      document: .default,
      to: directory
    )
    for name in LinnetSettingsProjectionRenderer.ownedFiles {
      let exists = FileManager.default.fileExists(atPath: directory.appending(path: name).path)
      if name == LinnetSettingsProjectionRenderer.squirrelCustomFile
      {
        guard !exists else { fail("reverting retained stale projection \(name)") }
      } else {
        guard exists else { fail("reverting removed document interaction owner \(name)") }
      }
    }
    let revertedDefault = try String(contentsOf: defaultCustom, encoding: .utf8)
    require(
      revertedDefault == coreInteractionProjection + defaultSchemaOrderProjection,
      "reverting settings deleted the Core-owned interaction policy"
    )
    guard reverted.contains("linnet_zh.custom.yaml") else {
      fail("reverting did not report the changed schema projection")
    }
  }

  private static func testCoreThemeReconciliation(in directory: URL) throws {
    let core = directory.appending(path: "core-squirrel.yaml")
    let user = directory.appending(path: "core-theme-user")
    let staging = user.appending(path: "build")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let projected = user.appending(path: "squirrel.yaml")
    let compiled = staging.appending(path: "squirrel.yaml")
    let custom = user.appending(path: "squirrel.custom.yaml")
    let preference = "patch:\n  style/font_point: 32\n"
    try preference.write(to: custom, atomically: true, encoding: .utf8)
    let first = "config_version: '1.1'\nstyle:\n  color_scheme: core_first\n"
    try first.write(to: core, atomically: true, encoding: .utf8)
    try LinnetSettingsProjectionRenderer.reconcileCoreConfiguration(
      source: core, to: user, stagingDirectory: staging)
    require(try Data(contentsOf: projected) == Data(first.utf8), "Core theme was not projected")
    let identity = try fileIdentity(projected)
    try Data("compiled".utf8).write(to: compiled)
    try LinnetSettingsProjectionRenderer.reconcileCoreConfiguration(
      source: core, to: user, stagingDirectory: staging)
    require(try fileIdentity(projected) == identity, "unchanged Core theme was rewritten")
    require(FileManager.default.fileExists(atPath: compiled.path), "unchanged theme invalidated its cache")

    let second = first.replacingOccurrences(of: "core_first", with: "core_second")
    try second.write(to: core, atomically: true, encoding: .utf8)
    // No delay or config_version bump: content alone owns the transition.
    try LinnetSettingsProjectionRenderer.reconcileCoreConfiguration(
      source: core, to: user, stagingDirectory: staging)
    require(try Data(contentsOf: projected) == Data(second.utf8), "Core theme update was lost")
    require(!FileManager.default.fileExists(atPath: compiled.path), "changed theme retained stale compiled output")
    require(try String(contentsOf: custom, encoding: .utf8) == preference, "Core update changed user preferences")
    do {
      try LinnetSettingsProjectionRenderer.reconcileCoreConfiguration(
        source: directory.appending(path: "missing-core"), to: user, stagingDirectory: staging)
      fail("missing Core theme was accepted")
    } catch LinnetSettingsProjectionRenderer.Failure.unsafeFile { }
    require(try Data(contentsOf: projected) == Data(second.utf8), "missing Core theme mutated the current projection")
  }

  private static func testAtomicDocumentExchange(in directory: URL) throws {
    let live = directory.appending(path: "exchange-live", directoryHint: .isDirectory)
    let candidate = directory.appending(path: "exchange-candidate", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    var old = LinnetSettingsDocument.default
    old.appearance.fontPoint = 14
    var replacement = LinnetSettingsDocument.default
    replacement.appearance.fontPoint = 22
    try LinnetSettingsDocumentStore.write(old, to: live)
    try LinnetSettingsDocumentStore.write(replacement, to: candidate)

    try LinnetSettingsDocumentStore.exchangeCandidateDocument(
      candidateDirectory: candidate, liveDirectory: live)
    guard try LinnetSettingsDocumentStore.load(from: live) == replacement,
      try LinnetSettingsDocumentStore.load(from: candidate) == old
    else { fail("present document exchange was not atomic and reversible") }
    try LinnetSettingsDocumentStore.exchangeCandidateDocument(
      candidateDirectory: candidate, liveDirectory: live)
    guard try LinnetSettingsDocumentStore.load(from: live) == old,
      try LinnetSettingsDocumentStore.load(from: candidate) == replacement
    else { fail("the document exchange was not involutive") }

    try FileManager.default.removeItem(
      at: live.appending(path: LinnetSettingsDocumentStore.fileName))
    try LinnetSettingsDocumentStore.exchangeCandidateDocument(
      candidateDirectory: candidate, liveDirectory: live)
    guard try LinnetSettingsDocumentStore.load(from: live) == replacement,
      !FileManager.default.fileExists(
        atPath: candidate.appending(path: LinnetSettingsDocumentStore.fileName).path)
    else { fail("a candidate could not atomically replace an absent live document") }
    try LinnetSettingsDocumentStore.exchangeCandidateDocument(
      candidateDirectory: candidate, liveDirectory: live)
    guard !FileManager.default.fileExists(
        atPath: live.appending(path: LinnetSettingsDocumentStore.fileName).path),
      try LinnetSettingsDocumentStore.load(from: candidate) == replacement
    else { fail("an absent live document could not be restored") }
  }

  private static func fileIdentity(_ url: URL) throws -> String {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw TestFailure.invalidFixture }
    return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
  }

  private enum TestFailure: Error { case invalidFixture }

  private static let coreInteractionProjection = """
    patch:
      "ascii_composer/switch_key/Caps_Lock": commit_code
      "ascii_composer/switch_key/Shift_L": commit_code
      "ascii_composer/switch_key/Shift_R": commit_code
      "linnet/recognizer_patterns/zz_code_token": "^(?:(?:www[.]|https?:|ftp[.:]|mailto:|file:).*|(?:[a-z]+[A-Z]|[A-Z][a-z]+[A-Z]|[A-Z]{2,}[a-z]|v[0-9]+|[A-Z][A-Za-z]*[0-9]|[A-Z]{2,}[._/@:+-])[0-9A-Za-z._/@:+?&=%#~-]*)$"

    """

  private static let defaultSchemaOrderProjection = """
      "schema_list/@0/schema": "linnet_zh_pinyin"
      "schema_list/@1/schema": "linnet_zh"
      "schema_list/@2/schema": "linnet_zh_flypy"
      "schema_list/@3/schema": "linnet_zh_mspy"
      "schema_list/@4/schema": "linnet_zh_sogou"
      "schema_list/@5/schema": "linnet_zh_abc"
      "schema_list/@6/schema": "linnet_zh_ziguang"
      "schema_list/@7/schema": "linnet_zh_jiajia"
      "schema_list/@8/schema": "linnet_en"

    """

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
      Data("LinnetSettingsProjectionRendererTests: FAIL: \(message)\n".utf8)
    )
    exit(EXIT_FAILURE)
  }

  private static func require(_ condition: Bool, _ message: String) {
    guard condition else { fail(message) }
  }
}
