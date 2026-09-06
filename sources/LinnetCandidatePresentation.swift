//
//  LinnetCandidatePresentation.swift
//  Linnet
//
//  Candidate-window presentation rules shared by AppKit, Settings, and tests.
//

import AppKit
import Foundation

enum LinnetCandidatePresentation {
  struct CandidateComment: Equatable {
    let displayText: String
    let belongsToSmartEnglish: Bool
  }

  private struct FormatReplacement {
    let token: String
    let value: String
    let attributes: [NSAttributedString.Key: Any]
    let isCandidate: Bool
  }

  private struct FormatMatch {
    let range: Range<String.Index>
    let replacement: FormatReplacement
  }

  // TextKit owns visible line truncation. This higher bound is only a safety
  // limit for malformed dictionary metadata, not a display budget.
  static let maximumDetailCharacterCount = 256
  static let maximumFooterDetailLineCount = 3
  static let maximumExpandedCandidateCount = 27
  static let smartEnglishDetailPrefix = "\u{001D}"

  // One compact typographic skeleton serves every bundled theme. Color,
  // material, corner treatment, and selection shape remain theme-owned.
  static let candidateWindowInset = CGSize(width: 7, height: 6)
  static let candidateRowSpacing: CGFloat = 6
  static let preeditSpacing: CGFloat = 8
  static let inlineCandidateSeparator = "  "
  static let candidateMaterial = NSVisualEffectView.Material.popover

  private static let detailPartOfSpeechBoundary =
    #/[；;]\s*(name|n|vt|vi|v|adj|adv|abbr|int|interj|prep|pref|conj|pron|suf|vbl|num|aux|art|det|fig|lit)[.]\s*/#

  /// Smart English owns whether a Rime comment is an English detail surface.
  /// The presentation boundary removes its one-byte marker before any text is
  /// drawn or announced; ordinary Chinese spelling comments remain unmarked.
  static func candidateComment(_ rawComment: String) -> CandidateComment {
    guard rawComment.hasPrefix(smartEnglishDetailPrefix) else {
      return CandidateComment(displayText: rawComment, belongsToSmartEnglish: false)
    }
    return CandidateComment(
      displayText: String(rawComment.dropFirst()), belongsToSmartEnglish: true)
  }

  struct InputModeIdentity: Equatable {
    let schemaID: String
    let asciiMode: Bool
  }

  /// A transient notice is only a live input-mode transition projection.
  /// Initial sampling, Settings reloads, and switches between Chinese profiles
  /// stay quiet. Rime's schema and ascii_mode remain the state owners; this
  /// function only chooses the compact caret label.
  static func inputModeTransitionLabel(
    previous: InputModeIdentity?,
    current: InputModeIdentity
  ) -> String? {
    guard let previous, previous != current else {
      return nil
    }
    if current.asciiMode {
      return "A"
    }

    let previousIsChinese =
      LinnetSettingsContract.ChineseProfile(schemaID: previous.schemaID) != nil
    let currentIsChinese =
      LinnetSettingsContract.ChineseProfile(schemaID: current.schemaID) != nil
    let previousIsEnglish = previous.schemaID == LinnetSettingsContract.englishSchemaID
    let currentIsEnglish = current.schemaID == LinnetSettingsContract.englishSchemaID
    if previous.asciiMode {
      if currentIsEnglish { return "En" }
      if currentIsChinese { return "中" }
      return nil
    }
    if previousIsChinese && currentIsEnglish {
      return "En"
    }
    if previousIsEnglish && currentIsChinese {
      return "中"
    }
    return nil
  }

  struct CandidateMenuPage: Equatable {
    let currentPage: Int
    let pageSize: Int
    let candidateCount: Int
    let highlighted: Int
  }

  /// Rime's selection keys are the single label owner for every selectable
  /// current-page candidate, including zero-input Smart English predictions.
  /// A missing custom label falls back to the same one-based page index used
  /// by direct numeric selection.
  static func candidateSelectionLabel(at index: Int, labels: [String]) -> String {
    if labels.count > 1, labels.indices.contains(index) {
      return labels[index]
    }
    if let customLabels = labels.first, labels.count == 1,
      index >= 0, index < customLabels.count {
      return String(customLabels[customLabels.index(customLabels.startIndex, offsetBy: index)])
    }
    return String(index + 1)
  }

  /// Rime legitimately exposes an all-zero menu while the input session is
  /// idle. Keep that state presentable so schema-transition feedback can use
  /// the normal caret-anchored panel without treating missing menu data as an
  /// input-session failure.
  static func candidateMenuPage(
    currentPage: Int32,
    pageSize: Int32,
    candidateCount: Int32,
    highlighted: Int32
  ) -> CandidateMenuPage? {
    guard let currentPage = Int(exactly: currentPage),
      let pageSize = Int(exactly: pageSize),
      let candidateCount = Int(exactly: candidateCount),
      let highlighted = Int(exactly: highlighted),
      currentPage >= 0,
      pageSize >= 0,
      candidateCount >= 0,
      highlighted >= 0
    else { return nil }
    guard pageSize > 0 else {
      return currentPage == 0 && candidateCount == 0 && highlighted == 0
        ? CandidateMenuPage(
          currentPage: 0, pageSize: 0, candidateCount: 0, highlighted: 0)
        : nil
    }
    guard candidateCount == 0 ? highlighted == 0 : highlighted < candidateCount else {
      return nil
    }
    return CandidateMenuPage(
      currentPage: currentPage,
      pageSize: pageSize,
      candidateCount: candidateCount,
      highlighted: highlighted)
  }

  enum CandidateSelectionStyle: String, Equatable {
    case tile, underline, bar
  }

  struct CandidateLine {
    let attributedString: NSAttributedString
    let labelPrefix: NSAttributedString
    let labelRange: NSRange
  }

  enum SecondaryTextPlacement {
    case inline
    case standaloneDetail
  }

  static func inlineCandidateSeparatorWidth(font: NSFont) -> CGFloat {
    (inlineCandidateSeparator as NSString).size(withAttributes: [.font: font]).width
  }

  /// TextKit and SwiftUI both consume the same selection expansion without
  /// changing the candidate line's intrinsic size. Tiles borrow half of the
  /// inter-candidate gap on each side; bars extend through the shared row gap;
  /// underlines remain attached to the glyph line.
  static func candidateSelectionInsets(
    style: CandidateSelectionStyle,
    candidateFont: NSFont
  ) -> NSEdgeInsets {
    switch style {
    case .tile:
      let horizontal = inlineCandidateSeparatorWidth(font: candidateFont) / 2
      let vertical = candidateRowSpacing / 2
      return NSEdgeInsets(
        top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    case .underline:
      return NSEdgeInsetsZero
    case .bar:
      let vertical = candidateRowSpacing / 2
      return NSEdgeInsets(top: vertical, left: 8, bottom: vertical, right: 0)
    }
  }

  /// Secondary candidate text uses the same optical baseline in the live
  /// panel and Settings preview. Vertical glyph flow already supplies its own
  /// alignment and therefore receives only the configured base offset.
  static func secondaryBaselineOffset(
    primaryFont: NSFont,
    secondaryFont: NSFont,
    baseOffset: CGFloat,
    verticalText: Bool,
    placement: SecondaryTextPlacement
  ) -> CGFloat {
    guard !verticalText, placement == .inline else { return baseOffset }
    return baseOffset + (primaryFont.pointSize - secondaryFont.pointSize) / 2.5
  }

  /// Canonical candidate-line composition. Attribute placeholders before
  /// replacement so arbitrary candidate formats retain label/candidate/comment
  /// typography, and preserve the existing TextKit no-break behavior.
  static func candidateLine(
    candidateFormat: String,
    label: String,
    candidate: String,
    comment: String,
    candidateAttributes: [NSAttributedString.Key: Any],
    labelAttributes: [NSAttributedString.Key: Any],
    commentAttributes: [NSAttributedString.Key: Any]
  ) -> CandidateLine {
    let normalizedCandidate = candidate.precomposedStringWithCanonicalMapping
    let normalizedComment = comment.precomposedStringWithCanonicalMapping
    let line = NSMutableAttributedString()
    var labelPrefix: NSAttributedString?
    var labelRange = NSRange(location: 0, length: 0)
    var remainingFormat = candidateFormat
    while !remainingFormat.isEmpty {
      let replacements: [FormatReplacement] = [
        .init(token: "[label]", value: label, attributes: labelAttributes, isCandidate: false),
        .init(
          token: "[candidate]", value: normalizedCandidate,
          attributes: candidateAttributes, isCandidate: true),
        .init(
          token: "[comment]", value: normalizedComment,
          attributes: commentAttributes, isCandidate: false)
      ]
      let next = replacements.compactMap { replacement -> FormatMatch? in
        guard let range = remainingFormat.range(of: replacement.token) else { return nil }
        return .init(range: range, replacement: replacement)
      }.min { $0.range.lowerBound < $1.range.lowerBound }
      guard let next else {
        line.append(NSAttributedString(
          string: remainingFormat,
          attributes: labelAttributes))
        break
      }

      let literal = String(remainingFormat[..<next.range.lowerBound])
      line.append(NSAttributedString(string: literal, attributes: labelAttributes))
      let token = String(remainingFormat[next.range])
      if labelPrefix == nil, token == "[candidate]" || token == "[comment]" {
        labelPrefix = NSAttributedString(attributedString: line)
      }
      let replacementStart = line.length
      if token == "[label]" {
        labelRange = NSRange(location: replacementStart, length: label.utf16.count)
      }
      line.append(NSAttributedString(
        string: next.replacement.value,
        attributes: next.replacement.attributes))
      if next.replacement.isCandidate,
        normalizedCandidate.count <= 5, normalizedCandidate.count > 1 {
        let firstCharacterEnd = normalizedCandidate.index(after: normalizedCandidate.startIndex)
          .utf16Offset(in: normalizedCandidate)
        line.addAttribute(
          NSAttributedString.Key("noBreak"),
          value: true,
          range: NSRange(
            location: replacementStart + firstCharacterEnd,
            length: normalizedCandidate.utf16.count - firstCharacterEnd))
      }
      remainingFormat = String(remainingFormat[next.range.upperBound...])
    }

    if line.length > 1, line.length <= 10 {
      line.addAttribute(
        NSAttributedString.Key("noBreak"),
        value: true,
        range: NSRange(location: 1, length: line.length - 1))
    }
    return CandidateLine(
      attributedString: NSAttributedString(attributedString: line),
      labelPrefix: labelPrefix ?? NSAttributedString(),
      labelRange: labelRange)
  }

  /// The only candidate-font resolver used by the live AppKit surface and the
  /// Settings preview. Font names remain ordered: the first available family
  /// owns the primary face and later families form its CoreText cascade.
  static func platformFont(
    fontNames: [String],
    size: CGFloat,
    fallback: NSFont? = nil
  ) -> NSFont {
    var seenFamilies = Set<String>()
    let fonts = fontNames.compactMap { rawName -> NSFont? in
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }
      let familyFaceFont: NSFont? = if let separator = name.lastIndex(of: "-"),
        separator != name.startIndex,
        name.index(after: separator) != name.endIndex {
        NSFont(
          descriptor: NSFontDescriptor(fontAttributes: [
            .family: String(name[..<separator]),
            .face: String(name[name.index(after: separator)...])
          ]),
          size: size)
      } else {
        nil
      }
      let font = NSFont(name: name, size: size)
        ?? familyFaceFont
        ?? NSFont(
          descriptor: NSFontDescriptor(fontAttributes: [.family: name]),
          size: size)
      guard let font else { return nil }
      let identity = font.familyName ?? font.fontName
      return seenFamilies.insert(identity).inserted ? font : nil
    }
    guard let primary = fonts.first else {
      return (fallback ?? NSFont.systemFont(ofSize: size)).withSize(size)
    }
    let cascades = fonts.dropFirst().map(\.fontDescriptor)
    guard !cascades.isEmpty else { return primary.withSize(size) }
    let descriptor = primary.fontDescriptor.addingAttributes([.cascadeList: cascades])
    return NSFont(descriptor: descriptor, size: size) ?? primary.withSize(size)
  }

}

extension LinnetCandidatePresentation {
  static func windowInset(verticalText: Bool) -> CGSize {
    guard verticalText else { return candidateWindowInset }
    return CGSize(
      width: candidateWindowInset.height,
      height: candidateWindowInset.width)
  }

  enum CandidateFlow: Equatable {
    case horizontal, vertical
  }

  struct RimeNavigationLayout: Equatable {
    let linear: Bool
    let vertical: Bool
  }

  /// Projects the visible candidate geometry into librime Selector's two
  /// layout options. Compact candidates retain the configured list behavior.
  /// Expanded candidates use the macOS row grid regardless of compact flow:
  /// Left/Right moves one cell and Up/Down keeps the column across pages.
  static func rimeNavigationLayout(
    flow: CandidateFlow,
    verticalText: Bool,
    expanded: Bool
  ) -> RimeNavigationLayout {
    guard expanded else {
      return .init(linear: flow == .horizontal, vertical: verticalText)
    }
    return .init(linear: true, vertical: false)
  }

  enum CandidateControlMode: Equatable {
    case paging(canPageUp: Bool, canPageDown: Bool)
    case disclosure(expanded: Bool)
  }

  enum CandidateControlAction: Equatable, Hashable {
    case pageUp, pageDown, expand, collapse
  }

  /// Absolute candidate bounds requested from librime when the disclosure is
  /// open. The anchor keeps the rendered grid stable while the highlighted
  /// page remains visible; crossing an edge shifts only enough to reveal it.
  /// The iterator remains bounded even when a translation is lazy or
  /// effectively unbounded.
  static func expandedCandidateRange(
    anchorPage: Int,
    currentPage: Int,
    pageSize: Int
  ) -> Range<Int>? {
    guard anchorPage >= 0, currentPage >= 0, pageSize > 0 else { return nil }
    let visiblePageCount = max(1, maximumExpandedCandidateCount / pageSize)
    var firstPage = anchorPage
    if currentPage < firstPage {
      firstPage = currentPage
    } else {
      let (pageEnd, pageEndOverflow) = firstPage.addingReportingOverflow(
        visiblePageCount)
      if pageEndOverflow || currentPage >= pageEnd {
        firstPage = currentPage - (visiblePageCount - 1)
      }
    }
    let (start, startOverflow) = firstPage.multipliedReportingOverflow(by: pageSize)
    guard !startOverflow else { return nil }
    let (end, endOverflow) = start.addingReportingOverflow(maximumExpandedCandidateCount)
    guard !endOverflow else { return nil }
    return start..<end
  }

  struct ExpandedGrid {
    struct Placement: Equatable {
      let item: Int
      let row: Int
      let column: Int
    }
    let columnWidths: [CGFloat]
    let placements: [Placement]
    let visibleRows: Range<Int>

    func columnOffset(_ column: Int, spacing: CGFloat) -> CGFloat {
      columnWidths.prefix(column).reduce(0, +) + spacing * CGFloat(column)
    }
  }

  /// Runtime and Settings share the same packing; neither reorders candidates.
  static func expandedGrid(
    widths: [CGFloat], columns: Int, spacing: CGFloat, maximumWidth: CGFloat,
    visibleRows: Range<Int>, highlighted: Int? = nil
  ) -> ExpandedGrid {
    guard !widths.isEmpty, columns > 0 else {
      return ExpandedGrid(columnWidths: [], placements: [], visibleRows: 0..<0)
    }
    // Keep whole words and shared column guides. The configured count is the
    // upper limit, not a reason to squeeze each word into an equal-width slot.
    for count in stride(from: min(columns, widths.count), through: 1, by: -1) {
      let rowCount = max(1, visibleRows.count)
      var firstRow = min(visibleRows.lowerBound, max(0, (widths.count - 1) / count - rowCount + 1))
      if let highlighted {
        let selectedRow = highlighted / count
        firstRow = min(firstRow, selectedRow)
        firstRow = max(firstRow, selectedRow - rowCount + 1)
      }
      let rows = firstRow..<(firstRow + rowCount)
      var columnWidths = [CGFloat](repeating: 1, count: count)
      for item in widths.indices where rows.contains(item / count) {
        columnWidths[item % count] = max(columnWidths[item % count], widths[item])
      }
      let total = columnWidths.reduce(0, +) + spacing * CGFloat(count - 1)
      if total <= maximumWidth || count == 1 {
        columnWidths = columnWidths.map { min(max(1, maximumWidth), $0) }
        let placements = widths.indices.map { item in
          ExpandedGrid.Placement(item: item, row: item / count, column: item % count)
        }
        return ExpandedGrid(columnWidths: columnWidths, placements: placements, visibleRows: rows)
      }
    }
    preconditionFailure("A nonempty grid always fits a bounded single column")
  }

  /// Compact candidate order; expanded packing is owned by expandedGrid.
  static func visualRows(
    candidateCount: Int,
    flow: CandidateFlow
  ) -> [[Int]] {
    guard candidateCount > 0 else { return [] }
    let indices = Array(0..<candidateCount)
    switch flow {
    case .horizontal: return [indices]
    case .vertical: return indices.map { [$0] }
    }
  }

  enum DetailPlacement: Equatable {
    case footer, sidecar
  }

  struct CandidateDetailFrames: Equatable {
    let candidate: CGRect
    let divider: CGRect?
    let detail: CGRect
    let size: CGSize
  }

  /// Canonical spatial relationship between the candidate body and selected
  /// metadata. TextKit and SwiftUI measure their own glyphs, then consume these
  /// frames instead of independently choosing axes, gaps, or detail widths.
  struct CandidateDetailGeometry: Equatable {
    let placement: DetailPlacement
    let spacing: CGFloat
    let dividerText: String
    let candidateColumnMaximumWidth: CGFloat?
    let detailColumnMaximumWidth: CGFloat?

    func fittedDetailWidth(candidateWidth: CGFloat, detailWidth: CGFloat) -> CGFloat {
      let boundedDetailWidth = min(
        detailWidth,
        detailColumnMaximumWidth ?? detailWidth)
      return placement == .footer
        ? min(max(0, candidateWidth), boundedDetailWidth)
        : boundedDetailWidth
    }

    func frames(
      candidateSize: CGSize,
      detailSize: CGSize,
      dividerSize: CGSize
    ) -> CandidateDetailFrames {
      let fittedCandidateSize = CGSize(
        width: min(candidateSize.width, candidateColumnMaximumWidth ?? candidateSize.width),
        height: candidateSize.height)
      let fittedDetailSize = CGSize(
        width: fittedDetailWidth(
          candidateWidth: fittedCandidateSize.width,
          detailWidth: detailSize.width),
        height: placement == .sidecar
          ? min(detailSize.height, max(0, fittedCandidateSize.height))
          : detailSize.height)
      let candidate = CGRect(origin: .zero, size: fittedCandidateSize)
      switch placement {
      case .footer:
        let detail = CGRect(
          origin: CGPoint(x: 0, y: fittedCandidateSize.height + spacing),
          size: fittedDetailSize)
        return CandidateDetailFrames(
          candidate: candidate,
          divider: nil,
          detail: detail,
          size: CGSize(
            width: max(fittedCandidateSize.width, fittedDetailSize.width),
            height: fittedCandidateSize.height + spacing + fittedDetailSize.height))
      case .sidecar:
        let divider = CGRect(
          origin: CGPoint(x: fittedCandidateSize.width + spacing, y: 0),
          size: CGSize(width: dividerSize.width, height: fittedCandidateSize.height))
        let detail = CGRect(
          origin: CGPoint(x: divider.maxX + spacing, y: 0),
          size: fittedDetailSize)
        return CandidateDetailFrames(
          candidate: candidate,
          divider: divider,
          detail: detail,
          size: CGSize(
            width: detail.maxX,
            height: fittedCandidateSize.height))
      }
    }
  }

  static func candidateDetailGeometry(
    forLinearLayout linear: Bool,
    candidateFontPoint: CGFloat = 16
  ) -> CandidateDetailGeometry {
    let candidateColumnMaximumWidth = min(240, max(150, candidateFontPoint * 10))
    let detailColumnMaximumWidth = linear
      ? min(360, max(240, candidateFontPoint * 16))
      : min(136, max(104, candidateFontPoint * 4.25))
    return CandidateDetailGeometry(
      placement: linear ? .footer : .sidecar,
      spacing: candidateRowSpacing,
      dividerText: "│",
      candidateColumnMaximumWidth: linear ? nil : candidateColumnMaximumWidth,
      detailColumnMaximumWidth: detailColumnMaximumWidth)
  }

  static func usesInlineComments(candidateFormat: String) -> Bool {
    candidateFormat.contains("[comment]")
  }

  static func selectedDetailText(_ rawComment: String) -> String {
    let normalized = rawComment.trimmingCharacters(in: .whitespacesAndNewlines)
    let bounded = normalized.count > maximumDetailCharacterCount
      ? String(normalized.prefix(maximumDetailCharacterCount - 1)) + "…"
      : normalized
    return bounded.replacing(detailPartOfSpeechBoundary) { match in
      "\n\(match.1). "
    }
  }

}
