//
//  SquirrelTheme.swift
//  Squirrel
//
//  Created by Leo Liu on 5/9/24.
//

import AppKit

final class SquirrelTheme {
  static let offsetHeight: CGFloat = 5
  static let defaultFontSize: CGFloat = NSFont.systemFontSize
  static let showStatusDuration: Double = 1.2

  enum StatusMessageType: String {
    case long, short, mix
  }
  typealias SelectionStyle = LinnetCandidatePresentation.CandidateSelectionStyle
  enum RimeColorSpace {
    case displayP3, sRGB
    static func from(name: String) -> Self {
      if name == "display_p3" {
        return .displayP3
      } else {
        return .sRGB
      }
    }
  }

  private(set) var available = true
  private(set) var native = true
  private(set) var memorizeSize = true
  private var colorSpace: RimeColorSpace = .sRGB

  var backgroundColor: NSColor = .windowBackgroundColor
  var highlightedPreeditColor: NSColor?
  var highlightedBackColor: NSColor? = .selectedTextBackgroundColor
  var preeditBackgroundColor: NSColor?
  var candidateBackColor: NSColor?
  var borderColor: NSColor?

  private var textColor: NSColor = .secondaryLabelColor
  private var highlightedTextColor: NSColor = .labelColor
  private var candidateTextColor: NSColor = .labelColor
  private var highlightedCandidateTextColor: NSColor = .labelColor
  private var candidateLabelColor: NSColor? = .secondaryLabelColor
  private var highlightedCandidateLabelColor: NSColor? = .secondaryLabelColor
  private var commentTextColor: NSColor? = .secondaryLabelColor
  private var highlightedCommentTextColor: NSColor? = .secondaryLabelColor

  private(set) var cornerRadius: CGFloat = 0
  private(set) var hilitedCornerRadius: CGFloat = 0
  private(set) var surroundingExtraExpansion: CGFloat = 0
  private(set) var shadowSize: CGFloat = 0
  private(set) var borderWidth: CGFloat = 0
  private(set) var borderHeight: CGFloat = 0
  let linespace = LinnetCandidatePresentation.candidateRowSpacing
  let preeditLinespace = LinnetCandidatePresentation.preeditSpacing
  private(set) var baseOffset: CGFloat = 0
  private(set) var alpha: CGFloat = 1

  private(set) var translucency = false
  private(set) var mutualExclusive = false
  private(set) var linear = false
  private(set) var vertical = false
  private(set) var candidateExpansionAllowed = false
  private(set) var inlinePreedit = false
  private(set) var inlineCandidate = false
  private(set) var showPaging = false
  private(set) var selectionStyle: SelectionStyle = .tile
  private(set) var materialAppearance = LinnetClientAppearance.MaterialMode.system

  private var fontNames = [String]()
  private var labelFontNames = [String]()
  private var commentFontNames = [String]()
  private var fontSize: CGFloat?
  private var labelFontSize: CGFloat?
  private var commentFontSize: CGFloat?

  private var _candidateFormat = "[label]. [candidate] [comment]"
  private(set) var statusMessageType: StatusMessageType = .mix

  private var defaultFont: NSFont {
    LinnetCandidatePresentation.platformFont(
      fontNames: [], size: fontSize ?? Self.defaultFontSize)
  }

  private(set) lazy var font = LinnetCandidatePresentation.platformFont(
    fontNames: fontNames, size: fontSize ?? Self.defaultFontSize, fallback: defaultFont)
  private(set) lazy var labelFont = LinnetCandidatePresentation.platformFont(
    fontNames: labelFontNames,
    size: labelFontSize ?? fontSize ?? Self.defaultFontSize,
    fallback: font)
  private(set) lazy var commentFont = LinnetCandidatePresentation.platformFont(
    fontNames: commentFontNames,
    size: commentFontSize ?? fontSize ?? Self.defaultFontSize,
    fallback: font)
  private(set) lazy var attrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: candidateTextColor,
    .font: font,
    .baselineOffset: baseOffset
  ]
  private(set) lazy var statusAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: candidateTextColor,
    .font: NSFont.systemFont(
      ofSize: LinnetPanelGeometry.statusFontPoint, weight: .medium)
  ]
  private(set) lazy var highlightedAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: highlightedCandidateTextColor,
    .font: font,
    .baselineOffset: baseOffset
  ]
  private(set) lazy var labelAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: candidateLabelColor ?? blendColor(foregroundColor: self.candidateTextColor, backgroundColor: self.backgroundColor),
    .font: labelFont,
    .baselineOffset: LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: font, secondaryFont: labelFont,
      baseOffset: baseOffset, verticalText: vertical, placement: .inline)
  ]
  private(set) lazy var labelHighlightedAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: highlightedCandidateLabelColor ?? blendColor(foregroundColor: highlightedCandidateTextColor, backgroundColor: highlightedBackColor),
    .font: labelFont,
    .baselineOffset: LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: font, secondaryFont: labelFont,
      baseOffset: baseOffset, verticalText: vertical, placement: .inline)
  ]
  private(set) lazy var commentAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: commentTextColor ?? candidateTextColor,
    .font: commentFont,
    .baselineOffset: LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: font, secondaryFont: commentFont,
      baseOffset: baseOffset, verticalText: vertical, placement: .inline)
  ]
  private(set) lazy var commentHighlightedAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: highlightedCommentTextColor ?? highlightedCandidateTextColor,
    .font: commentFont,
    .baselineOffset: LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: font, secondaryFont: commentFont,
      baseOffset: baseOffset, verticalText: vertical, placement: .inline)
  ]
  private(set) lazy var detailAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: commentTextColor ?? candidateTextColor,
    .font: commentFont,
    .baselineOffset: LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: font, secondaryFont: commentFont,
      baseOffset: baseOffset, verticalText: vertical, placement: .standaloneDetail)
  ]
  private(set) lazy var preeditAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: textColor,
    .font: font,
    .baselineOffset: baseOffset
  ]
  private(set) lazy var preeditHighlightedAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: highlightedTextColor,
    .font: font,
    .baselineOffset: baseOffset
  ]

  private(set) lazy var firstParagraphStyle: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = linespace / 2
    style.paragraphSpacingBefore = preeditLinespace / 2 + linespace / 2
    return style as NSParagraphStyle
  }()
  private(set) lazy var paragraphStyle: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = linespace / 2
    style.paragraphSpacingBefore = linespace / 2
    return style as NSParagraphStyle
  }()
  private(set) lazy var statusParagraphStyle: NSParagraphStyle =
    NSMutableParagraphStyle()
  private(set) lazy var preeditParagraphStyle: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = preeditLinespace / 2 + linespace / 2
    style.lineSpacing = linespace
    return style as NSParagraphStyle
  }()
  private(set) lazy var edgeInset =
    LinnetCandidatePresentation.windowInset(verticalText: vertical)
  private(set) lazy var borderLineWidth: CGFloat = min(borderHeight, borderWidth)
  private(set) var candidateFormat: String {
    get {
      _candidateFormat
    } set {
      var newTemplate = newValue
      if newTemplate.contains(/%@/) {
        newTemplate.replace(/%@/, with: "[candidate] [comment]")
      }
      if newTemplate.contains(/%c/) {
        newTemplate.replace(/%c/, with: "[label]")
      }
      _candidateFormat = newTemplate
    }
  }
  var pagingOffset: CGFloat {
    if showPaging {
      (labelFontSize ?? fontSize ?? Self.defaultFontSize) * 1.5
    } else {
      0
    }
  }

  func load(config: SquirrelConfig, dark: Bool) {
    linear ?= config.getString("style/candidate_list_layout").map { $0 == "linear" }
    vertical ?= config.getString("style/text_orientation").map { $0 == "vertical" }
    candidateExpansionAllowed ?= config.getBool(
      "style/linnet_candidate_expansion_allowed")
    inlinePreedit ?= config.getBool("style/inline_preedit")
    inlineCandidate ?= config.getBool("style/inline_candidate")
    translucency ?= config.getBool("style/translucency")
    mutualExclusive ?= config.getBool("style/mutual_exclusive")
    memorizeSize ?= config.getBool("style/memorize_size")
    showPaging ?= config.getBool("style/show_paging")
    materialAppearance ?= config.getString("style/linnet_material_appearance")
      .flatMap(LinnetClientAppearance.MaterialMode.init(rawValue:))

    statusMessageType ?= .init(rawValue: config.getString("style/status_message_type") ?? "")
    selectionStyle ?= .init(rawValue: config.getString("style/linnet_selection_style") ?? "")
    candidateFormat ?= config.getString("style/candidate_format")

    alpha ?= config.getDouble("style/alpha").map { min(1, max(0, $0)) }
    cornerRadius ?= config.getDouble("style/corner_radius")
    hilitedCornerRadius ?= config.getDouble("style/hilited_corner_radius")
    surroundingExtraExpansion ?= config.getDouble("style/surrounding_extra_expansion")
    borderHeight ?= config.getDouble("style/border_height")
    borderWidth ?= config.getDouble("style/border_width")
    baseOffset ?= config.getDouble("style/base_offset")
    shadowSize ?= config.getDouble("style/shadow_size").map { max(0, $0) }

    var fontName = config.getString("style/font_face")
    var fontSize = config.getDouble("style/font_point")
    var labelFontName = config.getString("style/label_font_face")
    var labelFontSize = config.getDouble("style/label_font_point")
    var commentFontName = config.getString("style/comment_font_face")
    var commentFontSize = config.getDouble("style/comment_font_point")

    let colorSchemeOption = dark ? "style/color_scheme_dark" : "style/color_scheme"
    if let colorScheme = config.getString(colorSchemeOption) {
      if colorScheme != "native" {
        native = false
        let prefix = "preset_color_schemes/\(colorScheme)"
        colorSpace = .from(name: config.getString("\(prefix)/color_space") ?? "")
        backgroundColor ?= config.getColor("\(prefix)/back_color", inSpace: colorSpace)
        highlightedPreeditColor = config.getColor("\(prefix)/hilited_back_color", inSpace: colorSpace)
        highlightedBackColor = config.getColor("\(prefix)/hilited_candidate_back_color", inSpace: colorSpace) ?? highlightedPreeditColor
        preeditBackgroundColor = config.getColor("\(prefix)/preedit_back_color", inSpace: colorSpace)
        candidateBackColor = config.getColor("\(prefix)/candidate_back_color", inSpace: colorSpace)
        borderColor = config.getColor("\(prefix)/border_color", inSpace: colorSpace)

        textColor ?= config.getColor("\(prefix)/text_color", inSpace: colorSpace)
        highlightedTextColor = config.getColor("\(prefix)/hilited_text_color", inSpace: colorSpace) ?? textColor
        candidateTextColor = config.getColor("\(prefix)/candidate_text_color", inSpace: colorSpace) ?? textColor
        highlightedCandidateTextColor = config.getColor("\(prefix)/hilited_candidate_text_color", inSpace: colorSpace) ?? highlightedTextColor
        candidateLabelColor = config.getColor("\(prefix)/label_color", inSpace: colorSpace)
        highlightedCandidateLabelColor = config.getColor("\(prefix)/hilited_candidate_label_color", inSpace: colorSpace)
        commentTextColor = config.getColor("\(prefix)/comment_text_color", inSpace: colorSpace)
        highlightedCommentTextColor = config.getColor("\(prefix)/hilited_comment_text_color", inSpace: colorSpace)

        // the following per-color-scheme configurations, if exist, will
        // override configurations with the same name under the global 'style'
        // section
        linear ?= config.getString("\(prefix)/candidate_list_layout").map { $0 == "linear" }
        vertical ?= config.getString("\(prefix)/text_orientation").map { $0 == "vertical" }
        inlinePreedit ?= config.getBool("\(prefix)/inline_preedit")
        inlineCandidate ?= config.getBool("\(prefix)/inline_candidate")
        translucency ?= config.getBool("\(prefix)/translucency")
        mutualExclusive ?= config.getBool("\(prefix)/mutual_exclusive")
        showPaging ?= config.getBool("\(prefix)/show_paging")
        selectionStyle ?= .init(
          rawValue: config.getString("\(prefix)/linnet_selection_style") ?? "")
        candidateFormat ?= config.getString("\(prefix)/candidate_format")
        fontName ?= config.getString("\(prefix)/font_face")
        fontSize ?= config.getDouble("\(prefix)/font_point")
        labelFontName ?= config.getString("\(prefix)/label_font_face")
        labelFontSize ?= config.getDouble("\(prefix)/label_font_point")
        commentFontName ?= config.getString("\(prefix)/comment_font_face")
        commentFontSize ?= config.getDouble("\(prefix)/comment_font_point")

        alpha ?= config.getDouble("\(prefix)/alpha").map { max(0, min(1, $0)) }
        cornerRadius ?= config.getDouble("\(prefix)/corner_radius")
        hilitedCornerRadius ?= config.getDouble("\(prefix)/hilited_corner_radius")
        surroundingExtraExpansion ?= config.getDouble("\(prefix)/surrounding_extra_expansion")
        borderHeight ?= config.getDouble("\(prefix)/border_height")
        borderWidth ?= config.getDouble("\(prefix)/border_width")
        baseOffset ?= config.getDouble("\(prefix)/base_offset")
        shadowSize ?= config.getDouble("\(prefix)/shadow_size").map { max(0, $0) }
      }
    } else {
      available = false
    }

    fontNames = decodeFontNames(from: fontName)
    self.fontSize = fontSize
    labelFontNames = decodeFontNames(from: labelFontName ?? fontName)
    self.labelFontSize = labelFontSize
    commentFontNames = decodeFontNames(from: commentFontName ?? fontName)
    self.commentFontSize = commentFontSize
  }
}

private extension SquirrelTheme {
  func decodeFontNames(from fontString: String?) -> [String] {
    guard let fontString else { return [] }
    var seen = Set<String>()
    return fontString.split(separator: ",").compactMap { rawName in
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, seen.insert(name).inserted else { return nil }
      return name
    }
  }

  func blendColor(foregroundColor: NSColor, backgroundColor: NSColor?) -> NSColor {
    let foregroundColor = foregroundColor.usingColorSpace(NSColorSpace.deviceRGB)
      ?? NSColor(deviceWhite: 0, alpha: 1)
    let backgroundColor = (backgroundColor ?? NSColor.gray).usingColorSpace(NSColorSpace.deviceRGB)
      ?? NSColor(deviceWhite: 0.5, alpha: 1)
    func blend(foreground: CGFloat, background: CGFloat) -> CGFloat {
      return (foreground * 2 + background) / 3
    }
    return NSColor(deviceRed: blend(foreground: foregroundColor.redComponent, background: backgroundColor.redComponent),
                   green: blend(foreground: foregroundColor.greenComponent, background: backgroundColor.greenComponent),
                   blue: blend(foreground: foregroundColor.blueComponent, background: backgroundColor.blueComponent),
                   alpha: blend(foreground: foregroundColor.alphaComponent, background: backgroundColor.alphaComponent))
  }
}
