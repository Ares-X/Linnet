// Local visual projection for the Appearance settings draft. The bundled
// squirrel.yaml remains the only source for theme colors and treatments.

import AppKit
import SwiftUI

enum LinnetSettingsAppearancePreview {
  enum PreviewLanguage: CaseIterable, Hashable {
    case chinese, english
  }

  typealias SelectionStyle = LinnetCandidatePresentation.CandidateSelectionStyle

  enum Failure: LocalizedError, Equatable {
    case bundledThemeUnavailable
    case malformedThemeData
    case requestedThemeUnavailable

    var errorDescription: String? {
      String(localized: "The local candidate preview is unavailable because its bundled theme data could not be read.")
    }
  }

  struct ColorComponents: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(_ rimeBGR: UInt32) {
      red = UInt8(rimeBGR & 0xFF)
      green = UInt8((rimeBGR >> 8) & 0xFF)
      blue = UInt8((rimeBGR >> 16) & 0xFF)
      alpha = rimeBGR > 0xFF_FF_FF ? UInt8((rimeBGR >> 24) & 0xFF) : 255
    }

    var color: Color {
      Color(
        .sRGB,
        red: Double(red) / 255,
        green: Double(green) / 255,
        blue: Double(blue) / 255,
        opacity: Double(alpha) / 255
      )
    }

    var nsColor: NSColor {
      NSColor(
        srgbRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: CGFloat(alpha) / 255)
    }

  }

  struct Palette: Equatable {
    let background: ColorComponents
    let border: ColorComponents
    let primary: ColorComponents
    let secondary: ColorComponents
    let selectedBackground: ColorComponents
    let selectedPrimary: ColorComponents
  }

  struct Catalog {
    struct Scheme: Equatable {
      let identifier: String
      let palette: Palette
      let selectionStyle: SelectionStyle
      let cornerRadius: Double
      let highlightedCornerRadius: Double
      let isTranslucent: Bool
      let isMutuallyExclusive: Bool
    }

    struct ThemePair: Equatable {
      let light: Scheme
      let dark: Scheme
    }

    let schemes: [String: Scheme]

    init(contents: String) throws {
      var parsed: [String: Scheme] = [:]
      var identifier: String?
      var fields: [String: String] = [:]

      for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine.prefix { $0 != "#" })
        let indentation = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        if indentation == 2, trimmed.hasSuffix(":"), !trimmed.contains(": ") {
          if let identifier {
            let scheme = try Self.makeScheme(identifier: identifier, fields: fields)
            guard parsed[identifier] == nil else { throw Failure.malformedThemeData }
            parsed[identifier] = scheme
          }
          let candidate = String(trimmed.dropLast())
          identifier = candidate.hasPrefix("linnet_") ? candidate : nil
          fields = [:]
        } else if identifier != nil, indentation == 4,
          let separator = trimmed.firstIndex(of: ":") {
          let key = String(trimmed[..<separator])
          let value = Self.scalar(String(trimmed[trimmed.index(after: separator)...]))
          fields[key] = value
        }
      }

      if let identifier {
        let scheme = try Self.makeScheme(identifier: identifier, fields: fields)
        guard parsed[identifier] == nil else { throw Failure.malformedThemeData }
        parsed[identifier] = scheme
      }
      guard !parsed.isEmpty else { throw Failure.malformedThemeData }
      schemes = parsed
    }

    func scheme(
      for appearance: LinnetSettingsDocument.Appearance,
      systemIsDark: Bool
    ) -> Scheme? {
      let isDark: Bool
      switch appearance.themeMode {
      case .system: isDark = systemIsDark
      case .light: isDark = false
      case .dark: isDark = true
      }
      guard let pair = pair(for: appearance.themeFamily) else { return nil }
      return isDark ? pair.dark : pair.light
    }

    func pair(for family: LinnetSettingsDocument.ThemeFamily) -> ThemePair? {
      guard
        let light = schemes[family.schemeIdentifier(isDark: false)],
        let dark = schemes[family.schemeIdentifier(isDark: true)]
      else {
        return nil
      }
      return ThemePair(light: light, dark: dark)
    }

    static let bundled: Result<Catalog, Failure> = {
      guard let url = Bundle.main.url(forResource: "squirrel", withExtension: "yaml"),
        let contents = try? String(contentsOf: url, encoding: .utf8)
      else {
        return .failure(.bundledThemeUnavailable)
      }
      do {
        return .success(try Catalog(contents: contents))
      } catch {
        return .failure(.malformedThemeData)
      }
    }()

    private static func makeScheme(
      identifier: String,
      fields: [String: String]
    ) throws -> Scheme {
      guard let selectionStyle = SelectionStyle(
        rawValue: fields["linnet_selection_style"] ?? "")
      else {
        throw Failure.malformedThemeData
      }
      let isTranslucent: Bool
      switch fields["translucency"] {
      case nil, "false": isTranslucent = false
      case "true": isTranslucent = true
      default: throw Failure.malformedThemeData
      }
      let isMutuallyExclusive: Bool
      switch fields["mutual_exclusive"] {
      case nil, "false": isMutuallyExclusive = false
      case "true": isMutuallyExclusive = true
      default: throw Failure.malformedThemeData
      }
      return Scheme(
        identifier: identifier,
        palette: try Palette(
          background: color("back_color", fields),
          border: color("border_color", fields),
          primary: color("candidate_text_color", fields),
          secondary: color("comment_text_color", fields),
          selectedBackground: color("hilited_candidate_back_color", fields),
          selectedPrimary: color("hilited_candidate_text_color", fields)
        ),
        selectionStyle: selectionStyle,
        cornerRadius: try metric("corner_radius", fields),
        highlightedCornerRadius: try metric("hilited_corner_radius", fields),
        isTranslucent: isTranslucent,
        isMutuallyExclusive: isMutuallyExclusive
      )
    }

    private static func color(
      _ key: String,
      _ fields: [String: String]
    ) throws -> ColorComponents {
      guard let raw = fields[key]?.lowercased().replacingOccurrences(of: "0x", with: ""),
        let value = UInt32(raw, radix: 16)
      else {
        throw Failure.malformedThemeData
      }
      return ColorComponents(value)
    }

    private static func metric(_ key: String, _ fields: [String: String]) throws -> Double {
      guard let raw = fields[key], let value = Double(raw), value.isFinite, value >= 0 else {
        throw Failure.malformedThemeData
      }
      return value
    }

    private static func scalar(_ value: String) -> String {
      let trimmed = value.trimmingCharacters(in: .whitespaces)
      guard trimmed.count >= 2,
        (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) ||
          (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
      else {
        return trimmed
      }
      return String(trimmed.dropFirst().dropLast())
    }
  }

  struct Presentation: Equatable {
    let palette: Palette
    let selectionStyle: SelectionStyle
    let cornerRadius: Double
    let highlightedCornerRadius: Double
    let isTranslucent: Bool
    let isMutuallyExclusive: Bool
    let chineseCandidateLayout: LinnetSettingsDocument.CandidateLayout
    let englishCandidateLayout: LinnetSettingsDocument.CandidateLayout
    let candidateBrowsingMode: LinnetSettingsDocument.CandidateBrowsingMode
    let pageSize: Int
    let fontPreset: LinnetSettingsDocument.FontPreset
    let candidateFontPoint: Double
    let labelFontPoint: Double
    let detailFontPoint: Double
    let isDark: Bool

    func detailGeometry(
      for language: PreviewLanguage
    ) -> LinnetCandidatePresentation.CandidateDetailGeometry {
      let layout = language == .chinese
        ? chineseCandidateLayout : englishCandidateLayout
      let linear = switch layout {
      case .horizontal: true
      case .vertical: false
      }
      return LinnetCandidatePresentation.candidateDetailGeometry(
        forLinearLayout: linear,
        candidateFontPoint: CGFloat(candidateFontPoint))
    }
  }

  static func presentation(
    for appearance: LinnetSettingsDocument.Appearance,
    systemIsDark: Bool,
    catalog: Catalog
  ) -> Result<Presentation, Failure> {
    guard let scheme = catalog.scheme(for: appearance, systemIsDark: systemIsDark) else {
      return .failure(.requestedThemeUnavailable)
    }
    let isDark: Bool
    switch appearance.themeMode {
    case .system: isDark = systemIsDark
    case .light: isDark = false
    case .dark: isDark = true
    }
    return .success(Presentation(
      palette: scheme.palette,
      selectionStyle: scheme.selectionStyle,
      cornerRadius: scheme.cornerRadius,
      highlightedCornerRadius: scheme.highlightedCornerRadius,
      isTranslucent: scheme.isTranslucent,
      isMutuallyExclusive: scheme.isMutuallyExclusive,
      chineseCandidateLayout: appearance.chineseCandidateLayout,
      englishCandidateLayout: appearance.englishCandidateLayout,
      candidateBrowsingMode: appearance.candidateBrowsingMode,
      pageSize: appearance.pageSize,
      fontPreset: appearance.fontPreset,
      candidateFontPoint: LinnetSettingsDocument.Appearance.clampFontPoint(appearance.fontPoint),
      labelFontPoint: LinnetSettingsDocument.Appearance.labelFontPoint(for: appearance.fontPoint),
      detailFontPoint: LinnetSettingsDocument.Appearance.commentFontPoint(for: appearance.fontPoint),
      isDark: isDark
    ))
  }
}

/// One material projection serves the local candidate preview. The Settings
/// window itself keeps the native macOS appearance.
struct LinnetSettingsThemeSurface: View {
  let palette: LinnetSettingsAppearancePreview.Palette
  let isTranslucent: Bool
  let isDark: Bool

  var body: some View {
    if isTranslucent {
      ZStack {
        LinnetSettingsCandidateMaterial(isDark: isDark)
        Rectangle().fill(palette.background.color)
      }
      .environment(\.colorScheme, isDark ? .dark : .light)
    } else {
      palette.background.color
    }
  }
}

private struct LinnetSettingsCandidateMaterial: NSViewRepresentable {
  let isDark: Bool

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.state = .active
    view.material = LinnetCandidatePresentation.candidateMaterial
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = LinnetCandidatePresentation.candidateMaterial
    view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
  }
}

private struct LinnetCandidateDetailSurfaceLayout: Layout {
  let geometry: LinnetCandidatePresentation.CandidateDetailGeometry

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    frames(subviews: subviews)?.size ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let frames = frames(subviews: subviews) else { return }
    place(subviews[0], in: frames.candidate, relativeTo: bounds)
    if let divider = frames.divider {
      place(subviews[1], in: divider, relativeTo: bounds)
    } else {
      subviews[1].place(
        at: CGPoint(x: bounds.minX, y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: 0, height: 0))
    }
    place(subviews[2], in: frames.detail, relativeTo: bounds)
  }

  private func frames(
    subviews: Subviews
  ) -> LinnetCandidatePresentation.CandidateDetailFrames? {
    // A transient SwiftUI tree mismatch is a rendering failure, not a process invariant.
    guard subviews.count == 3 else { return nil }
    let candidateProposal = ProposedViewSize(
      width: geometry.candidateColumnMaximumWidth, height: nil)
    let detailProposal = ProposedViewSize(
      width: geometry.detailColumnMaximumWidth, height: nil)
    return geometry.frames(
      candidateSize: subviews[0].sizeThatFits(candidateProposal),
      detailSize: subviews[2].sizeThatFits(detailProposal),
      dividerSize: subviews[1].sizeThatFits(.unspecified))
  }

  private func place(
    _ subview: LayoutSubview,
    in frame: CGRect,
    relativeTo bounds: CGRect
  ) {
    subview.place(
      at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
      anchor: .topLeading,
      proposal: ProposedViewSize(width: frame.width, height: frame.height))
  }
}

struct LinnetSettingsAppearancePreviewView: View {
  let appearance: LinnetSettingsDocument.Appearance

  @Environment(\.colorScheme) private var systemColorScheme
  private var preview: Result<LinnetSettingsAppearancePreview.Presentation, LinnetSettingsAppearancePreview.Failure> {
    switch LinnetSettingsAppearancePreview.Catalog.bundled {
    case .success(let catalog):
      LinnetSettingsAppearancePreview.presentation(
        for: appearance,
        systemIsDark: systemColorScheme == .dark,
        catalog: catalog
      )
    case .failure(let failure): .failure(failure)
    }
  }

  var body: some View {
    GroupBox("Candidate window preview") {
      switch preview {
      case .success(let presentation):
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Theme, font, and appearance mode update here and in the next candidate window. Candidate count and layout require Apply Changes."
          )
            .font(.caption)
            .foregroundStyle(.secondary)
          candidateSurface(presentation, language: .chinese)
          candidateSurface(presentation, language: .english)
        }
        .padding(8)
      case .failure:
        Label("Preview unavailable. The bundled theme data is missing or invalid.", systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(8)
          .accessibilityLabel(Text("Local candidate appearance preview unavailable"))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Local candidate appearance preview"))
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: Text {
    switch preview {
    case .success:
      Text(
        appearance.candidateBrowsingMode == .expandable
          ? "Expanded candidate preview" : "Scrolling-only candidate preview")
    case .failure: Text("Preview unavailable")
    }
  }

  private func candidateSurface(
    _ preview: LinnetSettingsAppearancePreview.Presentation,
    language: LinnetSettingsAppearancePreview.PreviewLanguage
  ) -> some View {
    let expanded = preview.candidateBrowsingMode == .expandable
    let detailGeometry = preview.detailGeometry(for: language)
    return VStack(alignment: .leading, spacing: LinnetCandidatePresentation.candidateRowSpacing) {
      previewLanguageLabel(language)
        .font(.caption.weight(.medium))
        .foregroundStyle(preview.palette.secondary.color)
      ScrollView(.horizontal, showsIndicators: false) {
        LinnetCandidateDetailSurfaceLayout(geometry: detailGeometry) {
          candidateList(preview, language: language, expanded: expanded)
            .fixedSize(horizontal: true, vertical: false)
          candidateDetailDivider(preview, geometry: detailGeometry)
            .fixedSize(horizontal: true, vertical: false)
          candidateDetail(
            preview,
            language: language,
            maximumWidth: detailGeometry.detailColumnMaximumWidth)
        }
        .fixedSize(horizontal: true, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .padding(.horizontal, LinnetCandidatePresentation.candidateWindowInset.width)
      .padding(.vertical, LinnetCandidatePresentation.candidateWindowInset.height)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        LinnetSettingsThemeSurface(
          palette: preview.palette,
          isTranslucent: preview.isTranslucent,
          isDark: preview.isDark
        )
      }
      .overlay(
        RoundedRectangle(cornerRadius: preview.cornerRadius)
          .stroke(preview.palette.border.color, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: preview.cornerRadius))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private extension LinnetSettingsAppearancePreviewView {
  @ViewBuilder
  func candidateList(
    _ preview: LinnetSettingsAppearancePreview.Presentation,
    language: LinnetSettingsAppearancePreview.PreviewLanguage,
    expanded: Bool
  ) -> some View {
    let layout = language == .chinese
      ? preview.chineseCandidateLayout : preview.englishCandidateLayout
    let availableValues = previewCandidateValues(language)
    let requestedCount = expanded
      ? min(
        availableValues.count,
        LinnetCandidatePresentation.expandedCandidateRange(
          page: 0, pageSize: preview.pageSize)?.upperBound ?? preview.pageSize)
      : min(availableValues.count, preview.pageSize)
    let values = Array(availableValues.prefix(requestedCount))
    let flow: LinnetCandidatePresentation.CandidateFlow =
      layout == .horizontal ? .horizontal : .vertical
    let rows = LinnetCandidatePresentation.visualRows(
      candidateCount: values.count,
      pageSize: preview.pageSize,
      flow: flow,
      expanded: expanded)
    let labelFont = LinnetCandidatePresentation.platformFont(
      fontNames: preview.fontPreset.fontFamilies,
      size: CGFloat(preview.labelFontPoint))
    let candidateFont = LinnetCandidatePresentation.platformFont(
      fontNames: preview.fontPreset.fontFamilies,
      size: CGFloat(preview.candidateFontPoint))
    let fonts = (label: labelFont, candidate: candidateFont)
    let inlineSpacing = LinnetCandidatePresentation.inlineCandidateSeparatorWidth(
      font: candidateFont)
    VStack(
      alignment: .leading,
      spacing: LinnetCandidatePresentation.candidateRowSpacing
    ) {
      ForEach(Array(rows.enumerated()), id: \.offset) { row in
        HStack(spacing: inlineSpacing) {
          ForEach(row.element, id: \.self) { index in
            LinnetSettingsAppearancePreview.candidate(
              index < preview.pageSize ? String(index + 1) : "",
              values[index],
              selected: index == 0,
              preview,
              fonts: fonts)
          }
        }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  func previewCandidateValues(
    _ language: LinnetSettingsAppearancePreview.PreviewLanguage
  ) -> [String] {
    switch language {
    case .chinese:
      [
        "输入", "输入法", "候选", "双拼", "设置", "词库", "主题", "学习", "数据",
        "方案", "拼音", "智能", "英文", "简体", "繁体", "符号", "短语", "预测",
        "同步", "更新", "备份", "恢复", "导入", "导出", "用户", "语言", "外观"
      ]
    case .english:
      [
        "interface", "input", "method", "context", "preview", "candidate", "typing", "language", "settings",
        "completion", "prediction", "translation", "spelling", "pronunciation", "learning", "phrase", "layout", "theme",
        "dictionary", "update", "backup", "restore", "import", "export", "profile", "native", "glass"
      ]
    }
  }
}

extension LinnetSettingsAppearancePreview {
  // Theme cards and the full preview share candidate typography and selection.
  static func candidate(
    _ label: String,
    _ value: String,
    selected: Bool,
    _ preview: LinnetSettingsAppearancePreview.Presentation,
    fonts: (label: NSFont, candidate: NSFont)
  ) -> some View {
    let candidateColor = selected
      ? preview.palette.selectedPrimary.nsColor : preview.palette.primary.nsColor
    let labelColor = selected && preview.selectionStyle == .tile
      ? preview.palette.selectedPrimary.nsColor : preview.palette.secondary.nsColor
    let candidateAttributes: [NSAttributedString.Key: Any] = [
      .font: fonts.candidate,
      .foregroundColor: candidateColor,
      .baselineOffset: 0
    ]
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: fonts.label,
      .foregroundColor: labelColor,
      .baselineOffset: LinnetCandidatePresentation.secondaryBaselineOffset(
        primaryFont: fonts.candidate,
        secondaryFont: fonts.label,
        baseOffset: 0,
        verticalText: false,
        placement: .inline)
    ]
    let line = LinnetCandidatePresentation.candidateLine(
      candidateFormat: "[label] [candidate]",
      label: label,
      candidate: value,
      comment: "",
      candidateAttributes: candidateAttributes,
      labelAttributes: labelAttributes,
      commentAttributes: labelAttributes)
    let selectionInsets = LinnetCandidatePresentation.candidateSelectionInsets(
      style: preview.selectionStyle,
      candidateFont: fonts.candidate)
    return candidateCell(
      selected: selected,
      preview: preview,
      selectionInsets: selectionInsets
    ) {
      Text(AttributedString(line.attributedString))
    }
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Candidate"))
    .accessibilityValue(Text(verbatim: value))
    .accessibilityHint(Text(label))
    .accessibilityAddTraits(selected ? .isSelected : .isStaticText)
  }
}

private extension LinnetSettingsAppearancePreviewView {
  @ViewBuilder
  func candidateDetail(
    _ preview: LinnetSettingsAppearancePreview.Presentation,
    language: LinnetSettingsAppearancePreview.PreviewLanguage,
    maximumWidth: CGFloat?
  ) -> some View {
    let rawDetail = switch language {
    case .chinese: "［shu ru］"
    case .english: "/ˈɪntəfeɪs/ · n. 接口"
    }
    let detail = LinnetCandidatePresentation.selectedDetailText(rawDetail)
    if let maximumWidth {
      Text(AttributedString(candidateDetailLine(preview, text: detail)))
        .frame(maxWidth: maximumWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    } else {
      Text(AttributedString(candidateDetailLine(preview, text: detail)))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
  }

  func candidateDetailDivider(
    _ preview: LinnetSettingsAppearancePreview.Presentation,
    geometry: LinnetCandidatePresentation.CandidateDetailGeometry
  ) -> some View {
    Text(AttributedString(candidateDetailLine(preview, text: geometry.dividerText)))
      .accessibilityHidden(true)
  }

  func candidateDetailLine(
    _ preview: LinnetSettingsAppearancePreview.Presentation,
    text: String
  ) -> NSAttributedString {
    let detailFont = LinnetCandidatePresentation.platformFont(
      fontNames: preview.fontPreset.fontFamilies,
      size: CGFloat(preview.detailFontPoint))
    let detailAttributes: [NSAttributedString.Key: Any] = [
      .font: detailFont,
      .foregroundColor: preview.palette.secondary.nsColor,
      .baselineOffset: LinnetCandidatePresentation.secondaryBaselineOffset(
        primaryFont: detailFont,
        secondaryFont: detailFont,
        baseOffset: 0,
        verticalText: false,
        placement: .standaloneDetail)
    ]
    let line = LinnetCandidatePresentation.candidateLine(
      candidateFormat: "[comment]",
      label: "",
      candidate: "",
      comment: text,
      candidateAttributes: detailAttributes,
      labelAttributes: detailAttributes,
      commentAttributes: detailAttributes)
    return line.attributedString
  }
}

extension LinnetSettingsAppearancePreview {
  private static func candidateCell<Content: View>(
    selected: Bool,
    preview: LinnetSettingsAppearancePreview.Presentation,
    selectionInsets: NSEdgeInsets,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .foregroundStyle(selected ? preview.palette.selectedPrimary.color : preview.palette.primary.color)
      .background {
        if selected && preview.selectionStyle == .tile {
          ZStack {
            if preview.isTranslucent && preview.isMutuallyExclusive {
              LinnetSettingsCandidateMaterial(isDark: preview.isDark)
            }
            RoundedRectangle(cornerRadius: preview.highlightedCornerRadius)
              .fill(preview.palette.selectedBackground.color)
          }
          .clipShape(RoundedRectangle(cornerRadius: preview.highlightedCornerRadius))
          .padding(EdgeInsets(
            top: -selectionInsets.top,
            leading: -selectionInsets.left,
            bottom: -selectionInsets.bottom,
            trailing: -selectionInsets.right))
        }
      }
      .overlay(alignment: .bottomLeading) {
        if selected && preview.selectionStyle == .underline {
          Rectangle().fill(preview.palette.selectedBackground.color).frame(height: 2)
        }
      }
      .overlay(alignment: .leading) {
        if selected && preview.selectionStyle == .bar {
          RoundedRectangle(cornerRadius: 2)
            .fill(preview.palette.selectedBackground.color)
            .frame(width: 3)
            .padding(EdgeInsets(
              top: -selectionInsets.top,
              leading: 0,
              bottom: -selectionInsets.bottom,
              trailing: 0))
            .offset(x: -selectionInsets.left)
        }
      }
  }
}

private extension LinnetSettingsAppearancePreviewView {
  @ViewBuilder
  func previewLanguageLabel(
    _ language: LinnetSettingsAppearancePreview.PreviewLanguage
  ) -> some View {
    switch language {
    case .chinese: Text("Chinese candidates")
    case .english: Text("English candidates")
    }
  }
}
