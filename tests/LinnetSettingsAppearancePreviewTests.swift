import AppKit
import Darwin
import Foundation

@main
struct LinnetSettingsAppearancePreviewTests {
  static func main() {
    testVisualThemeSelectorSourceContract()
    testExactTypographyOverflowSourceContract()
    testCandidateDetailGeometrySourceContract()
    testPreviewDisclosureStateIsPerLanguage()
    testBundledThemeSourceIsComplete()
    testCatalogOwnsThemePairs()
    testThemeProjectionReadsTheCanonicalSource()
    testThemeIdentityDoesNotDependOnDisplayName()
    testThemePairsRemainDistinctAndReadable()
    testTranslucentSelectionContrast()
    testMoonJadeAndNativeGlassVisualRoles()
    testSystemModeAndTypographyStayDraftDerived()
    testPreviewUsesSelectedPageSize()
    testPreviewUsesTheCanonicalBilingualFontCascade()
    testMalformedThemeDataFailsClosed()
    print("LinnetSettingsAppearancePreviewTests: PASS")
  }

  private static func testVisualThemeSelectorSourceContract() {
    let settingsViews = source("sources/LinnetSettings/SettingsViews.swift")
    let preview = appearancePreviewSource()

    require(!settingsViews.contains("Picker(\"Theme\""),
            "the retired Theme menu returned to the leading Settings column")
    require(occurrences(of: "LinnetSettingsThemeFamilyPicker(", in: settingsViews) == 1,
            "Appearance must expose exactly one visual theme-selection entry point")
    require(occurrences(of: "struct LinnetSettingsThemeFamilyPicker: View", in: preview) == 1,
            "the visual theme selector must have exactly one view owner")
    require(preview.contains("ForEach(LinnetSettingsDocument.ThemeFamily.allCases"),
            "the visual selector no longer projects every canonical theme family")
    require(preview.contains("Button {")
              && occurrences(of: "selection = family", in: preview) == 1,
            "theme cards must be direct, keyboard-accessible Button controls")
    require(preview.contains("catalog.pair(for: family)"),
            "theme cards must reuse the Catalog-owned Light/Dark pair")
  }

  private static func testExactTypographyOverflowSourceContract() {
    let preview = appearancePreviewSource()
    let liveTheme = source("sources/SquirrelTheme.swift")
    let livePanel = source("sources/SquirrelPanel.swift")
    require(!preview.contains(".minimumScaleFactor("),
            "candidate preview text must not shrink below the configured point size")
    require(!preview.contains(".lineLimit(1)"),
            "candidate preview text must not ellipsize when horizontal space is tight")
    require(preview.contains("ScrollView(.horizontal, showsIndicators: false)"),
            "exact-size candidate and detail content must receive horizontal scrolling")
    require(!liveTheme.contains("NSFont.userFont("),
            "the live default font bypasses the shared candidate typography owner")
    require(!preview.contains("enum LinnetSettingsFontProjection"),
            "Settings retained a second candidate-font resolver")
    require(!preview.contains("design: .rounded"),
            "candidate labels retained a preview-only rounded font")
    require(
      occurrences(of: "LinnetCandidatePresentation.platformFont(", in: preview) == 3,
      "candidate, label, and detail text must consume the one shared font resolver")
    require(!preview.contains(".thinMaterial"),
            "Settings retained a second candidate material approximation")
    require(!preview.contains(".padding(.horizontal, 7)"),
            "Settings retained a preview-only candidate horizontal inset")
    require(!preview.contains(".padding(.vertical, 4)"),
            "Settings retained a preview-only candidate vertical inset")
    require(!preview.contains(".firstTextBaseline"),
            "Settings retained a SwiftUI-only candidate baseline owner")
    require(!preview.contains("let labelSpacing ="),
            "Settings retained a candidate-font gap instead of the live separator metric")
    require(!preview.contains(".padding(\n      .horizontal,\n      LinnetCandidatePresentation.inlineCandidateSeparatorWidth"),
            "Settings retained unconditional half-separator cell padding")
    require(!preview.contains(".padding(.vertical, LinnetCandidatePresentation.candidateRowSpacing / 2)"),
            "Settings retained unconditional half-row cell padding")
    require(
      preview.contains("LinnetCandidatePresentation.candidateLine(") &&
        livePanel.contains("LinnetCandidatePresentation.candidateLine("),
      "Settings and the live panel do not consume one attributed candidate-line owner")
    require(
      liveTheme.contains("LinnetCandidatePresentation.secondaryBaselineOffset("),
      "the live theme retained a private secondary-baseline formula")
    let detailBlock = sourceSlice(
      preview,
      from: "func candidateDetail(",
      through: "func candidateCell<Content: View>(")
    require(
      detailBlock.contains("LinnetCandidatePresentation.candidateLine("),
      "Settings detail retained a second attributed-text compositor")
    require(
      detailBlock.contains("LinnetCandidatePresentation.selectedDetailText("),
      "Settings detail stopped sharing live metadata normalization")
    require(!detailBlock.contains("HStack(spacing: 8)"),
            "Settings detail retained a preview-only metadata gap")
    require(!detailBlock.contains(".italic()"),
            "Settings detail retained preview-only IPA styling")
    require(detailBlock.contains("placement: .standaloneDetail"),
            "Settings detail reused the inline candidate baseline")
    require(
      preview.contains("LinnetCandidatePresentation.candidateSelectionInsets("),
      "Settings does not project selection-specific live spacing")
    require(
      preview.contains(".offset(x: -selectionInsets.left)"),
      "Settings bar selection does not consume the shared leading gutter")
  }

  private static func sourceSlice(
    _ source: String,
    from startMarker: String,
    through endMarker: String
  ) -> String {
    guard let start = source.range(of: startMarker),
      let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex)
    else { fail("source slice markers are missing") }
    return String(source[start.lowerBound..<end.lowerBound])
  }

  private static func testCandidateDetailGeometrySourceContract() {
    let owner = source("sources/LinnetCandidatePresentation.swift")
    let liveTheme = source("sources/SquirrelTheme.swift")
    let livePanel = source("sources/SquirrelPanel.swift")
      + source("sources/SquirrelPanel+CandidatePresentation.swift")
    let preview = appearancePreviewSource()
    let candidateSurface = sourceSlice(
      preview,
      from: "  private func candidateSurface(",
      through: "  func candidateList(")
    let previewLayout = sourceSlice(
      preview,
      from: "private struct LinnetCandidateDetailSurfaceLayout: Layout",
      through: "struct LinnetSettingsAppearancePreviewView: View")

    require(
      owner.contains("static func candidateDetailGeometry(") &&
        livePanel.contains("LinnetCandidatePresentation.candidateDetailGeometry(") &&
        preview.contains("LinnetCandidatePresentation.candidateDetailGeometry("),
      "live and Settings did not consume one candidate-detail geometry owner")
    require(
      livePanel.contains("detailGeometry.frames(") &&
        previewLayout.contains("geometry.frames("),
      "a candidate-detail consumer retained private frame calculation")
    require(
      candidateSurface.contains("LinnetCandidateDetailSurfaceLayout(geometry: detailGeometry)"),
      "Settings candidate detail bypassed the shared geometry at the SwiftUI boundary")
    require(
      !previewLayout.contains("precondition(") &&
        previewLayout.contains("guard subviews.count == 3 else { return nil }"),
      "a transient SwiftUI child-count mismatch can still terminate Settings")
    require(
      !candidateSurface.contains("HStack(alignment: .top, spacing: 10)") &&
        !candidateSurface.contains("minWidth: 110") &&
        !candidateSurface.contains("idealWidth: 130") &&
        !candidateSurface.contains("maxWidth: 160") &&
        !preview.contains("candidateListViewport(") &&
        !preview.contains("candidateDetailViewport("),
      "Settings retained its independent sidecar/footer geometry or fixed width")
    require(
      !livePanel.contains("widestCandidate + 20") &&
        !liveTheme.contains("var detailPlacement:") &&
        !owner.contains("static func detailPlacement(forLinearLayout:"),
      "the retired live placement/gap path remains authoritative")
  }

  private static func testPreviewDisclosureStateIsPerLanguage() {
    var state = LinnetSettingsAppearancePreview.DisclosureState()
    require(!state.isExpanded(.chinese) && !state.isExpanded(.english),
            "candidate previews did not begin independently collapsed")
    state.toggle(.chinese)
    require(state.isExpanded(.chinese),
            "the Chinese candidate preview did not expand")
    require(!state.isExpanded(.english),
            "expanding Chinese also expanded the independent English preview")
    state.toggle(.english)
    require(state.isExpanded(.chinese) && state.isExpanded(.english),
            "the English candidate preview could not expand independently")
    state.toggle(.chinese)
    require(!state.isExpanded(.chinese) && state.isExpanded(.english),
            "collapsing Chinese also collapsed the independent English preview")
    state.reset()
    require(!state.isExpanded(.chinese) && !state.isExpanded(.english),
            "changing browsing capability did not reset both transient previews")
  }

  private static func testBundledThemeSourceIsComplete() {
    let catalog = canonicalCatalog()
    require(
      catalog.linnetSchemeIDs == [
        "linnet_paper_light", "linnet_paper_dark",
        "linnet_moon_jade_light", "linnet_moon_jade_dark",
        "linnet_sidecar_light", "linnet_sidecar_dark",
        "linnet_clay_light", "linnet_clay_dark",
        "linnet_mist_jade_light", "linnet_mist_jade_dark",
        "linnet_glass_light", "linnet_glass_dark",
        "linnet_ink_cinnabar_light", "linnet_ink_cinnabar_dark",
      ],
      "the canonical source must retain exactly seven paired Linnet theme families"
    )
  }

  private static func testCatalogOwnsThemePairs() {
    let catalog = canonicalCatalog()
    for family in LinnetSettingsDocument.ThemeFamily.allCases {
      guard let pair = catalog.pair(for: family) else {
        fail("the canonical Catalog did not expose both appearances for \(family)")
      }
      require(pair.light.identifier == family.schemeIdentifier(isDark: false),
              "the Catalog Light member diverged from the canonical family identity")
      require(pair.dark.identifier == family.schemeIdentifier(isDark: true),
              "the Catalog Dark member diverged from the canonical family identity")

      var appearance = LinnetSettingsDocument.Appearance.default
      appearance.themeFamily = family
      appearance.themeMode = .light
      require(catalog.scheme(for: appearance, systemIsDark: true) == pair.light,
              "the active Light projection bypassed the Catalog-owned pair")
      appearance.themeMode = .dark
      require(catalog.scheme(for: appearance, systemIsDark: false) == pair.dark,
              "the active Dark projection bypassed the Catalog-owned pair")
    }

    let missingDarkSource = canonicalSource().replacingOccurrences(
      of: "  linnet_paper_dark:", with: "  removed_paper_dark:")
    guard let partial = try? LinnetSettingsAppearancePreview.Catalog(contents: missingDarkSource)
    else { fail("the partial Catalog fixture itself was malformed") }
    require(partial.pair(for: .paperLedger) == nil,
            "a theme with a missing Dark member must fail closed instead of inventing a pair")
  }

  private static func testThemeProjectionReadsTheCanonicalSource() {
    let catalog = canonicalCatalog()
    require(
      LinnetSettingsDocument.CandidateLayout.allCases == [.horizontal, .vertical],
      "Settings preview regained a persisted Expanded layout instead of runtime disclosure"
    )
    for family in LinnetSettingsDocument.ThemeFamily.allCases {
      for mode in [LinnetSettingsDocument.ThemeMode.light, .dark] {
        var appearance = LinnetSettingsDocument.Appearance.default
        appearance.themeFamily = family
        appearance.themeMode = mode
        let preview = projected(appearance, systemIsDark: mode == .dark, catalog: catalog)
        guard let source = catalog.scheme(for: appearance, systemIsDark: mode == .dark) else {
          fail("missing source projection for \(family) \(mode)")
        }
        require(preview.schemeID == source.identifier, "preview must retain the canonical scheme identity")
        require(preview.palette == source.palette, "preview colors must come from the canonical scheme")
        for language in LinnetSettingsAppearancePreview.PreviewLanguage.allCases {
          require(preview.detailGeometry(for: language).placement == .footer,
                  "a horizontal bilingual layout must keep selected detail below")
        }
        require(preview.selectionStyle == source.selectionStyle,
                "preview selection style must come from the canonical scheme")
        require(preview.cornerRadius == source.cornerRadius,
                "preview window radius must come from the canonical scheme")
        require(preview.highlightedCornerRadius == source.highlightedCornerRadius,
                "preview selection radius must come from the canonical scheme")
      }
    }

    for chineseLayout in LinnetSettingsDocument.CandidateLayout.allCases {
      for englishLayout in LinnetSettingsDocument.CandidateLayout.allCases {
        var appearance = LinnetSettingsDocument.Appearance.default
        appearance.chineseCandidateLayout = chineseLayout
        appearance.englishCandidateLayout = englishLayout
        let preview = projected(appearance, systemIsDark: false, catalog: catalog)
        require(
          preview.detailGeometry(for: .chinese).placement
            == (chineseLayout == .vertical ? .sidecar : .footer),
          "Chinese preview detail placement diverged from its layout")
        require(
          preview.detailGeometry(for: .english).placement
            == (englishLayout == .vertical ? .sidecar : .footer),
          "English preview detail placement diverged from its layout")
      }
    }

    let expectedRadii: [LinnetSettingsDocument.ThemeFamily: (Double, Double)] = [
      .paperLedger: (7, 0),
      .moonJade: (10, 0),
      .sidecarSlate: (9, 0),
      .clayTiles: (12, 7),
      .mistJade: (10, 6),
      .nativeGlass: (10, 6),
      .inkCinnabar: (8, 0),
    ]
    for (family, expected) in expectedRadii {
      var appearance = LinnetSettingsDocument.Appearance.default
      appearance.themeFamily = family
      appearance.themeMode = .light
      let preview = projected(appearance, systemIsDark: false, catalog: catalog)
      require(preview.cornerRadius == expected.0, "theme window radius drifted")
      require(preview.highlightedCornerRadius == expected.1, "theme selection radius drifted")
    }

    var glassAppearance = LinnetSettingsDocument.Appearance.default
    glassAppearance.themeFamily = .nativeGlass
    glassAppearance.themeMode = .light
    guard let glass = catalog.scheme(for: glassAppearance, systemIsDark: false) else {
      fail("the native Glass source is unavailable")
    }
    require(glass.isTranslucent, "the native Glass theme must enable material translucency")
    require(glass.palette.background.alpha < 255,
            "the native Glass tint must leave the system material visible")

  }

  private static func testThemePairsRemainDistinctAndReadable() {
    let catalog = canonicalCatalog()
    var lightPaletteKeys = Set<String>()
    var darkPaletteKeys = Set<String>()

    for family in LinnetSettingsDocument.ThemeFamily.allCases {
      var appearance = LinnetSettingsDocument.Appearance.default
      appearance.themeFamily = family

      appearance.themeMode = .light
      guard let light = catalog.scheme(for: appearance, systemIsDark: false) else {
        fail("missing Light source for \(family)")
      }
      appearance.themeMode = .dark
      guard let dark = catalog.scheme(for: appearance, systemIsDark: true) else {
        fail("missing Dark source for \(family)")
      }

      require(light.identifier.hasSuffix("_light") && dark.identifier.hasSuffix("_dark"),
              "a theme family lost its explicit Light/Dark twins")
      require(light.palette != dark.palette, "a theme family reused one palette for both appearances")
      let materialFamilies: Set<LinnetSettingsDocument.ThemeFamily> = [.mistJade, .nativeGlass]
      require(light.isTranslucent == materialFamilies.contains(family),
              "only Mist Jade and Native Glass may own translucent Light surfaces")
      require(dark.isTranslucent == materialFamilies.contains(family),
              "only Mist Jade and Native Glass may own translucent Dark surfaces")
      lightPaletteKeys.insert(paletteKey(light.palette))
      darkPaletteKeys.insert(paletteKey(dark.palette))

      for scheme in [light, dark] where !scheme.isTranslucent {
        require(contrast(scheme.palette.primary, scheme.palette.background) >= 4.5,
                "opaque theme primary text fell below the product contrast floor")
        require(contrast(scheme.palette.secondary, scheme.palette.background) >= 3.0,
                "opaque theme supporting text fell below the product contrast floor")
        let selectedSurface = scheme.selectionStyle == .tile
          ? scheme.palette.selectedBackground : scheme.palette.background
        require(contrast(scheme.palette.selectedPrimary, selectedSurface) >= 4.5,
                "opaque theme selected text fell below the product contrast floor")
      }
    }

    require(lightPaletteKeys.count == 7 && darkPaletteKeys.count == 7,
            "two named theme families collapsed to the same palette")
  }

  private static func testTranslucentSelectionContrast() {
    let catalog = canonicalCatalog()
    let materialBaselines: [(Bool, [LinnetSettingsAppearancePreview.RGB])] = [
      (false, [.init(0xFFFFFF), .init(0xF4F4F4), .init(0xECECEC)]),
      (true, [.init(0x1C1C1E), .init(0x242426), .init(0x2C2C2E)]),
    ]
    for family in [
      LinnetSettingsDocument.ThemeFamily.mistJade,
      LinnetSettingsDocument.ThemeFamily.nativeGlass,
    ] {
      guard let pair = catalog.pair(for: family) else {
        fail("the translucent theme pair is unavailable")
      }
      for (isDark, baselines) in materialBaselines {
        let scheme = isDark ? pair.dark : pair.light
        for baseline in baselines {
          require(
            compositedContrast(
              foreground: scheme.palette.selectedPrimary,
              surface: scheme.palette.selectedBackground,
              over: baseline) >= 4.5,
            "\(scheme.identifier) selected text fell below 4.5:1 over material")
        }
      }
    }
  }

  private static func testMoonJadeAndNativeGlassVisualRoles() {
    let catalog = canonicalCatalog()

    var moon = LinnetSettingsDocument.Appearance.default
    moon.themeFamily = .moonJade
    moon.themeMode = .dark
    guard let moonDark = catalog.scheme(for: moon, systemIsDark: true) else {
      fail("the Moon Jade Dark source is unavailable")
    }
    let moonBackground = moonDark.palette.background
    let moonSpread = [moonBackground.red, moonBackground.green, moonBackground.blue]
      .map(Int.init).max()! - [moonBackground.red, moonBackground.green, moonBackground.blue]
      .map(Int.init).min()!
    require(moonSpread <= 12,
            "Moon Jade Dark must use moonlit neutral charcoal rather than a deep-green field")
    var native = LinnetSettingsDocument.Appearance.default
    native.themeFamily = .nativeGlass
    for mode in [LinnetSettingsDocument.ThemeMode.light, .dark] {
      native.themeMode = mode
      guard let scheme = catalog.scheme(for: native, systemIsDark: mode == .dark) else {
        fail("the standard Native Glass source is unavailable")
      }
      require(scheme.isTranslucent,
              "standard Native Glass must use the shared native material projection")
      let background = scheme.palette.background
      let backgroundSpread = [background.red, background.green, background.blue]
        .map(Int.init).max()! - [background.red, background.green, background.blue]
        .map(Int.init).min()!
      require(backgroundSpread <= 4,
              "standard Native Glass must remain neutral instead of inheriting an artistic tint")
    }
  }

  private static func testThemeIdentityDoesNotDependOnDisplayName() {
    let renamed = canonicalSource()
      .replacingOccurrences(of: "Paper Ledger Light", with: "Renamed Light")
      .replacingOccurrences(of: "Paper Ledger Dark", with: "Renamed Dark")
    let catalog: LinnetSettingsAppearancePreview.Catalog
    do {
      catalog = try LinnetSettingsAppearancePreview.Catalog(contents: renamed)
    } catch {
      fail("display-only theme names unexpectedly became required palette data")
    }
    var appearance = LinnetSettingsDocument.Appearance.default
    appearance.themeFamily = .paperLedger
    for (mode, expectedID) in [
      (LinnetSettingsDocument.ThemeMode.light, "linnet_paper_light"),
      (.dark, "linnet_paper_dark"),
    ] {
      appearance.themeMode = mode
      require(
        catalog.scheme(for: appearance, systemIsDark: mode == .dark)?.identifier == expectedID,
        "theme identity must use its canonical ID rather than its localized display name")
    }
  }

  private static func testSystemModeAndTypographyStayDraftDerived() {
    let catalog = canonicalCatalog()
    var appearance = LinnetSettingsDocument.Appearance.default
    appearance.themeFamily = .clayTiles
    appearance.themeMode = .system
    appearance.fontPreset = .editorial
    appearance.fontPoint = 22
    appearance.chineseCandidateLayout = .vertical
    appearance.englishCandidateLayout = .horizontal
    appearance.candidateBrowsingMode = .scrollingOnly

    let light = projected(appearance, systemIsDark: false, catalog: catalog)
    let dark = projected(appearance, systemIsDark: true, catalog: catalog)
    require(light.schemeID != dark.schemeID, "system mode must select the corresponding source scheme")
    require(!light.isDark && dark.isDark, "system mode must follow the supplied system appearance")
    require(dark.fontPreset == .editorial, "preview must consume the draft typeface")
    require(dark.candidateFontPoint == 22, "preview must consume the draft candidate size")
    require(dark.labelFontPoint == 13.75, "preview must reuse label point derivation")
    require(dark.detailFontPoint == 16.5, "preview must reuse detail point derivation")
    require(dark.chineseCandidateLayout == .vertical,
            "preview must consume the draft Chinese layout")
    require(dark.englishCandidateLayout == .horizontal,
            "preview must consume the draft English layout")
    require(dark.candidateBrowsingMode == .scrollingOnly,
            "preview must expose the draft disclosure capability without persisting runtime state")

    appearance.fontPoint = 48
    let clamped = projected(appearance, systemIsDark: true, catalog: catalog)
    require(clamped.candidateFontPoint == 32,
            "preview must clamp oversized candidate text to the product maximum")
  }

  private static func testPreviewUsesSelectedPageSize() {
    let catalog = canonicalCatalog()
    for pageSize in LinnetSettingsDocument.Appearance.pageSizeOptions {
      var appearance = LinnetSettingsDocument.Appearance.default
      appearance.pageSize = pageSize
      let preview = projected(appearance, systemIsDark: false, catalog: catalog)
      require(
        preview.pageSize == pageSize,
        "candidate preview ignored the selected page size \(pageSize)"
      )
    }
  }

  private static func testMalformedThemeDataFailsClosed() {
    do {
      _ = try LinnetSettingsAppearancePreview.Catalog(contents: "preset_color_schemes:\n  linnet_paper_light:\n")
      fail("an incomplete canonical theme source must be rejected")
    } catch {
      // Expected: no palette fallback is allowed for a malformed source.
    }
  }

  private static func testPreviewUsesTheCanonicalBilingualFontCascade() {
    for preset in LinnetSettingsDocument.FontPreset.allCases where preset != .system {
      let font = LinnetCandidatePresentation.platformFont(
        fontNames: preset.fontFamilies, size: 17)
      let cascade = font.fontDescriptor.fontAttributes[.cascadeList] as? [NSFontDescriptor]
      require(font.familyName == preset.fontFamilies[0],
              "preview Latin font must use the canonical first family")
      require(cascade?.first?.object(forKey: .family) as? String == preset.fontFamilies[1],
              "preview Chinese font must use the canonical second family")
    }
  }

  private static func canonicalCatalog() -> LinnetSettingsAppearancePreview.Catalog {
    do {
      return try LinnetSettingsAppearancePreview.Catalog(contents: canonicalSource())
    } catch {
      fail("the canonical squirrel theme source is malformed")
    }
  }

  private static func canonicalSource() -> String {
    source("data/squirrel.yaml")
  }

  private static func appearancePreviewSource() -> String {
    source("sources/LinnetSettings/LinnetSettingsAppearancePreview.swift")
      + source("sources/LinnetSettings/LinnetSettingsThemeFamilyPicker.swift")
  }

  private static func source(_ path: String) -> String {
    let source = URL(fileURLWithPath: path)
    guard let contents = try? String(contentsOf: source, encoding: .utf8) else {
      fail("the canonical squirrel theme source is unreadable")
    }
    return contents
  }

  private static func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
  }

  private static func projected(
    _ appearance: LinnetSettingsDocument.Appearance,
    systemIsDark: Bool,
    catalog: LinnetSettingsAppearancePreview.Catalog
  ) -> LinnetSettingsAppearancePreview.Presentation {
    switch LinnetSettingsAppearancePreview.presentation(
      for: appearance,
      systemIsDark: systemIsDark,
      catalog: catalog
    ) {
    case .success(let preview): return preview
    case .failure: fail("a complete canonical source must render a preview")
    }
  }

  private static func paletteKey(_ palette: LinnetSettingsAppearancePreview.Palette) -> String {
    [palette.background, palette.border, palette.primary, palette.secondary,
     palette.selectedBackground, palette.selectedPrimary]
      .map { "\($0.red)-\($0.green)-\($0.blue)-\($0.alpha)" }
      .joined(separator: ":")
  }

  private static func contrast(
    _ lhs: LinnetSettingsAppearancePreview.RGB,
    _ rhs: LinnetSettingsAppearancePreview.RGB
  ) -> Double {
    let values = [relativeLuminance(lhs), relativeLuminance(rhs)].sorted()
    return (values[1] + 0.05) / (values[0] + 0.05)
  }

  private static func relativeLuminance(_ color: LinnetSettingsAppearancePreview.RGB) -> Double {
    func linear(_ byte: UInt8) -> Double {
      let value = Double(byte) / 255
      return value <= 0.03928
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red)
      + 0.7152 * linear(color.green)
      + 0.0722 * linear(color.blue)
  }

  private static func compositedContrast(
    foreground: LinnetSettingsAppearancePreview.RGB,
    surface: LinnetSettingsAppearancePreview.RGB,
    over baseline: LinnetSettingsAppearancePreview.RGB
  ) -> Double {
    func channel(_ foreground: UInt8, _ background: UInt8, alpha: UInt8) -> Double {
      let opacity = Double(alpha) / 255
      return (Double(foreground) * opacity + Double(background) * (1 - opacity)) / 255
    }
    func linear(_ value: Double) -> Double {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func luminance(red: Double, green: Double, blue: Double) -> Double {
      0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    let surfaceRed = channel(surface.red, baseline.red, alpha: surface.alpha)
    let surfaceGreen = channel(surface.green, baseline.green, alpha: surface.alpha)
    let surfaceBlue = channel(surface.blue, baseline.blue, alpha: surface.alpha)
    let textRed = channel(foreground.red, UInt8(surfaceRed * 255), alpha: foreground.alpha)
    let textGreen = channel(foreground.green, UInt8(surfaceGreen * 255), alpha: foreground.alpha)
    let textBlue = channel(foreground.blue, UInt8(surfaceBlue * 255), alpha: foreground.alpha)
    let values = [
      luminance(red: surfaceRed, green: surfaceGreen, blue: surfaceBlue),
      luminance(red: textRed, green: textGreen, blue: textBlue),
    ].sorted()
    return (values[1] + 0.05) / (values[0] + 0.05)
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    fputs("LinnetSettingsAppearancePreviewTests: FAIL: \(message)\n", stderr)
    exit(1)
  }
}
