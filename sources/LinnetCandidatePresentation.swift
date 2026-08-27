//
//  LinnetCandidatePresentation.swift
//  Linnet
//
//  Candidate-window presentation rules shared by AppKit, Settings, and tests.
//

import AppKit
import Foundation

enum LinnetCandidatePresentation {
  static let maximumDetailCharacterCount = 72
  static let maximumExpandedPageCount = 3
  static let maximumExpandedCandidateCount = 27

  // One compact typographic skeleton serves every bundled theme. Color,
  // material, corner treatment, and selection shape remain theme-owned.
  static let candidateWindowInset = CGSize(width: 7, height: 6)
  static let candidateRowSpacing: CGFloat = 6
  static let preeditSpacing: CGFloat = 8
  static let inlineCandidateSeparator = "  "
  static let candidateMaterial = NSVisualEffectView.Material.popover

  private static let detailPartOfSpeechBoundary =
    #/[；;]\s*(n|vt|vi|v|adj|adv|abbr|int|interj|prep|pref|conj|pron|suf|vbl|num|aux|art|det)[.]\s*/#

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
    var remainingFormat = candidateFormat
    while !remainingFormat.isEmpty {
      let replacements: [(String, String, [NSAttributedString.Key: Any], Bool)] = [
        ("[label]", label, labelAttributes, false),
        ("[candidate]", normalizedCandidate, candidateAttributes, true),
        ("[comment]", normalizedComment, commentAttributes, false)
      ]
      let next = replacements.compactMap { replacement ->
        (Range<String.Index>, String, [NSAttributedString.Key: Any], Bool)? in
        guard let range = remainingFormat.range(of: replacement.0) else { return nil }
        return (range, replacement.1, replacement.2, replacement.3)
      }.min { $0.0.lowerBound < $1.0.lowerBound }
      guard let next else {
        line.append(NSAttributedString(
          string: remainingFormat,
          attributes: labelAttributes))
        break
      }

      let literal = String(remainingFormat[..<next.0.lowerBound])
      line.append(NSAttributedString(string: literal, attributes: labelAttributes))
      let token = String(remainingFormat[next.0])
      if labelPrefix == nil, token == "[candidate]" || token == "[comment]" {
        labelPrefix = NSAttributedString(attributedString: line)
      }
      let replacementStart = line.length
      line.append(NSAttributedString(string: next.1, attributes: next.2))
      if next.3, normalizedCandidate.count <= 5, normalizedCandidate.count > 1 {
        let firstCharacterEnd = normalizedCandidate.index(after: normalizedCandidate.startIndex)
          .utf16Offset(in: normalizedCandidate)
        line.addAttribute(
          NSAttributedString.Key("noBreak"),
          value: true,
          range: NSRange(
            location: replacementStart + firstCharacterEnd,
            length: normalizedCandidate.utf16.count - firstCharacterEnd))
      }
      remainingFormat = String(remainingFormat[next.0.upperBound...])
    }

    if line.length > 1, line.length <= 10 {
      line.addAttribute(
        NSAttributedString.Key("noBreak"),
        value: true,
        range: NSRange(location: 1, length: line.length - 1))
    }
    return CandidateLine(
      attributedString: NSAttributedString(attributedString: line),
      labelPrefix: labelPrefix ?? NSAttributedString())
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

  enum CandidateControlMode: Equatable {
    case paging(canPageUp: Bool, canPageDown: Bool)
    case disclosure(expanded: Bool)
  }

  enum CandidateControlAction: Equatable, Hashable {
    case pageUp, pageDown, expand, collapse
  }

  /// Absolute candidate bounds requested from librime when the disclosure is
  /// open. The iterator remains bounded even when a translation is lazy or
  /// effectively unbounded.
  static func expandedCandidateRange(page: Int, pageSize: Int) -> Range<Int>? {
    guard page >= 0, pageSize > 0 else { return nil }
    let (start, startOverflow) = page.multipliedReportingOverflow(by: pageSize)
    guard !startOverflow else { return nil }
    let pageBound = pageSize > maximumExpandedCandidateCount / maximumExpandedPageCount
      ? maximumExpandedCandidateCount
      : pageSize * maximumExpandedPageCount
    let (end, endOverflow) = start.addingReportingOverflow(pageBound)
    guard !endOverflow else { return nil }
    return start..<end
  }

  /// Maps absolute-order snapshot offsets to visual rows. Horizontal expansion
  /// adds one row per Rime page; vertical expansion adds one column per page.
  /// Every item offset appears exactly once, so click and accessibility indices
  /// remain independent from the visual order.
  static func visualRows(
    candidateCount: Int,
    pageSize: Int,
    flow: CandidateFlow,
    expanded: Bool
  ) -> [[Int]] {
    guard candidateCount > 0, pageSize > 0 else { return [] }
    let indices = Array(0..<candidateCount)
    guard expanded else {
      switch flow {
      case .horizontal: return [indices]
      case .vertical: return indices.map { [$0] }
      }
    }

    switch flow {
    case .horizontal:
      return stride(from: 0, to: candidateCount, by: pageSize).map { start in
        Array(start..<min(candidateCount, start + pageSize))
      }
    case .vertical:
      let pageCount = (candidateCount + pageSize - 1) / pageSize
      return (0..<min(pageSize, candidateCount)).compactMap { row in
        let values = (0..<pageCount).compactMap { page -> Int? in
          let index = page * pageSize + row
          return index < candidateCount ? index : nil
        }
        return values.isEmpty ? nil : values
      }
    }
  }

  enum AccessibilitySurface: Equatable {
    case candidates, inputModeStatus

    var exposesCandidateList: Bool { self == .candidates }

    var localizedLabelKey: String {
      switch self {
      case .candidates: "Candidate window"
      case .inputModeStatus: "Input mode"
      }
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

    var textSeparator: String {
      switch placement {
      case .footer:
        "\n"
      case .sidecar:
        ""
      }
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
        width: min(detailSize.width, detailColumnMaximumWidth ?? detailSize.width),
        height: detailSize.height)
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
          size: dividerSize)
        let detail = CGRect(
          origin: CGPoint(x: divider.maxX + spacing, y: 0),
          size: fittedDetailSize)
        return CandidateDetailFrames(
          candidate: candidate,
          divider: divider,
          detail: detail,
          size: CGSize(
            width: detail.maxX,
            height: max(
              fittedCandidateSize.height, dividerSize.height, fittedDetailSize.height)))
      }
    }
  }

  static func candidateDetailGeometry(
    forLinearLayout linear: Bool,
    candidateFontPoint: CGFloat = 16
  ) -> CandidateDetailGeometry {
    let candidateColumnMaximumWidth = min(240, max(150, candidateFontPoint * 10))
    let detailColumnMaximumWidth = min(160, max(120, candidateFontPoint * 5))
    return CandidateDetailGeometry(
      placement: linear ? .footer : .sidecar,
      spacing: candidateRowSpacing,
      dividerText: "│",
      candidateColumnMaximumWidth: linear ? nil : candidateColumnMaximumWidth,
      detailColumnMaximumWidth: linear ? nil : detailColumnMaximumWidth)
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

  static func accessibilityAnnouncement(
    candidate: String,
    comment: String,
    page: Int,
    indexOnPage: Int
  ) -> String? {
    guard page >= 0, indexOnPage >= 0, !candidate.isEmpty else { return nil }
    let position = String(
      format: NSLocalizedString(
        "Page %1$ld, candidate %2$ld",
        comment: "Candidate accessibility position"
      ),
      locale: Locale.current,
      page + 1,
      indexOnPage + 1
    )
    var parts = [position, candidate]
    let detail = selectedDetailText(comment)
    if !detail.isEmpty {
      parts.append(detail.replacingOccurrences(of: "\n", with: ", "))
    }
    return parts.joined(separator: ", ")
  }

}
