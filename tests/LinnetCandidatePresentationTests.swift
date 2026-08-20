import AppKit
import Foundation

@main
struct LinnetCandidatePresentationTests {
  static func main() {
    testExpandedCandidateBounds()
    testCandidateRows()
    testPrintablePagingShortcuts()

    require(
      LinnetCandidatePresentation.candidateWindowInset == CGSize(width: 7, height: 6) &&
        LinnetCandidatePresentation.candidateRowSpacing == 6 &&
        LinnetCandidatePresentation.preeditSpacing == 8,
      "candidate-window typography and spacing lost their shared compact metrics"
    )
    require(
      LinnetCandidatePresentation.windowInset(verticalText: false)
        == CGSize(width: 7, height: 6) &&
        LinnetCandidatePresentation.windowInset(verticalText: true)
        == CGSize(width: 6, height: 7),
      "vertical text did not rotate the one shared candidate-window inset"
    )
    testCanonicalTypography()
    testCandidateLineTypographyOwner()
    testCanonicalInlineMetricsAndMaterial()
    testCandidateDetailGeometry()
    testInputModeTransitions()

    var accessibilitySurface =
      LinnetCandidatePresentation.AccessibilitySurface.candidates
    require(
      accessibilitySurface.exposesCandidateList &&
        accessibilitySurface.localizedLabelKey == "Candidate window",
      "candidate publication lost its list accessibility container"
    )
    accessibilitySurface = .inputModeStatus
    require(
      !accessibilitySurface.exposesCandidateList &&
        accessibilitySurface.localizedLabelKey == "Input mode",
      "status publication retained the candidate-list accessibility container"
    )
    accessibilitySurface = .candidates
    require(
      accessibilitySurface.exposesCandidateList &&
        accessibilitySurface.localizedLabelKey == "Candidate window",
      "candidate publication did not restore its accessibility container"
    )

    require(
      LinnetCandidatePresentation.usesInlineComments(
        candidateFormat: "[label]. [candidate] [comment]"),
      "the standard Squirrel inline-comment format was not preserved"
    )
    require(
      !LinnetCandidatePresentation.usesInlineComments(
        candidateFormat: "[label] [candidate]"),
      "a Linnet selected-detail format was mistaken for inline comments"
    )
    require(
      LinnetCandidatePresentation.selectedDetailText("  short definition  ") == "short definition",
      "short detail was not normalized"
    )
    let long = String(repeating: "释", count: 90)
    let bounded = LinnetCandidatePresentation.selectedDetailText(long)
    require(
      bounded.count == LinnetCandidatePresentation.maximumDetailCharacterCount,
      "detail budget changed"
    )
    require(bounded.last == "…", "truncated detail has no ellipsis")

    let ranges = [
      NSRange(location: 0, length: 3),
      NSRange(location: 5, length: 4),
      NSRange(location: 11, length: 5),
    ]
    guard let insertion = LinnetCandidatePresentation.sidecarInsertion(
      candidateRanges: ranges, anchorIndex: 1, insertedLength: 7)
    else { fail("valid selected candidate was rejected") }
    require(insertion.location == 9, "sidecar did not follow the selected candidate")
    require(insertion.candidateRanges[0] == ranges[0], "earlier candidate moved")
    require(insertion.candidateRanges[1] == ranges[1], "selected candidate range changed")
    require(
      insertion.candidateRanges[2] == NSRange(location: 18, length: 5),
      "later candidate did not move with inserted detail"
    )
    require(
      LinnetCandidatePresentation.sidecarInsertion(
        candidateRanges: ranges, anchorIndex: 3, insertedLength: 2) == nil,
      "invalid selected candidate was accepted"
    )

    // A vertical expanded grid is rendered in visual row order, while the
    // ranges remain indexed by the candidates' absolute order. Inserting a
    // sidecar must therefore shift ranges by their physical text position,
    // not by their logical candidate index.
    let reorderedRanges = [
      NSRange(location: 0, length: 3),
      NSRange(location: 20, length: 4),
      NSRange(location: 5, length: 3),
    ]
    guard let reorderedInsertion = LinnetCandidatePresentation.sidecarInsertion(
      candidateRanges: reorderedRanges, anchorIndex: 2, insertedLength: 4)
    else { fail("valid expanded-grid sidecar anchor was rejected") }
    require(
      reorderedInsertion.location == 8,
      "expanded-grid sidecar did not follow its visual-row anchor"
    )
    require(
      reorderedInsertion.candidateRanges[1] == NSRange(location: 24, length: 4),
      "a physically later candidate did not move with expanded-grid detail"
    )
    require(
      reorderedInsertion.candidateRanges[2] == reorderedRanges[2],
      "the sidecar anchor range changed"
    )

    require(
      LinnetCandidatePresentation.accessibilityAnnouncement(
        candidate: "interface", comment: "  n. 接口  ", page: 2, indexOnPage: 1
      ) == "Page 3, candidate 2, interface, n. 接口",
      "candidate accessibility announcement lost position or definition"
    )
    require(
      LinnetCandidatePresentation.accessibilityAnnouncement(
        candidate: "候选", comment: "", page: 0, indexOnPage: 0
      ) == "Page 1, candidate 1, 候选",
      "empty candidate comment produced accessibility noise"
    )
    require(
      LinnetCandidatePresentation.accessibilityAnnouncement(
        candidate: "candidate", comment: "definition", page: -1, indexOnPage: 0
      ) == nil,
      "invalid highlighted candidate was announced"
    )

    print("LinnetCandidatePresentationTests: PASS")
  }

  private static func testInputModeTransitions() {
    require(
      LinnetCandidatePresentation.inputModeTransitionLabel(
        previousSchemaID: nil, currentSchemaID: "linnet_zh_pinyin") == nil,
      "initial activation was mistaken for a user mode switch"
    )
    require(
      LinnetCandidatePresentation.inputModeTransitionLabel(
        previousSchemaID: "linnet_zh_pinyin", currentSchemaID: "linnet_en") == "En",
      "Chinese to Smart English lost its compact caret label"
    )
    require(
      LinnetCandidatePresentation.inputModeTransitionLabel(
        previousSchemaID: "linnet_en", currentSchemaID: "linnet_zh_flypy") == "中",
      "Smart English to Chinese lost its compact caret label"
    )
    require(
      LinnetCandidatePresentation.inputModeTransitionLabel(
        previousSchemaID: "linnet_zh_pinyin", currentSchemaID: "linnet_zh_flypy") == nil,
      "changing Chinese profiles was mistaken for a Shift language switch"
    )
    require(
      LinnetCandidatePresentation.inputModeTransitionLabel(
        previousSchemaID: "linnet_en", currentSchemaID: "linnet_en") == nil,
      "an unchanged Smart English schema emitted duplicate feedback"
    )
  }

  private static func testCanonicalTypography() {
    for point in [CGFloat(12), 16, 32] {
      let system = LinnetCandidatePresentation.platformFont(fontNames: [], size: point)
      require(
        system.fontName == NSFont.systemFont(ofSize: point).fontName &&
          system.pointSize == point,
        "the default candidate font is not the macOS system font")
      let cascade = LinnetCandidatePresentation.platformFont(
        fontNames: ["Avenir Next", "Hiragino Sans GB"], size: point)
      require(cascade.pointSize == point, "candidate font scaling changed")
      let descriptors = cascade.fontDescriptor.fontAttributes[.cascadeList]
        as? [NSFontDescriptor]
      require(
        cascade.familyName == "Avenir Next" &&
          descriptors?.first?.object(forKey: .family) as? String == "Hiragino Sans GB",
        "the bilingual candidate font cascade changed")
    }
    require(
      LinnetCandidatePresentation.platformFont(
        fontNames: ["Avenir Next-Demi Bold"], size: 16).familyName == "Avenir Next",
      "legacy family-face candidate font names stopped resolving")
  }

  private static func testPrintablePagingShortcuts() {
    typealias Key = LinnetCandidatePresentation.PrintablePagingKey
    typealias Action = LinnetCandidatePresentation.CandidateControlAction
    let previousKeys: [Key] = [.minus, .leftBracket]
    let nextKeys: [Key] = [.equal, .rightBracket]

    for key in previousKeys {
      require(
        LinnetCandidatePresentation.printablePagingAction(
          key: key,
          hasModifiers: false,
          hasActiveInput: true,
          currentPage: 1,
          isLastPage: false,
          candidateCount: 9) == Action.pageUp,
        "\(key) did not page backward when a previous page exists")
      require(
        LinnetCandidatePresentation.printablePagingAction(
          key: key,
          hasModifiers: false,
          hasActiveInput: true,
          currentPage: 0,
          isLastPage: false,
          candidateCount: 9) == nil,
        "\(key) was captured on the first candidate page")
    }
    for key in nextKeys {
      require(
        LinnetCandidatePresentation.printablePagingAction(
          key: key,
          hasModifiers: false,
          hasActiveInput: true,
          currentPage: 0,
          isLastPage: false,
          candidateCount: 9) == Action.pageDown,
        "\(key) did not page forward when a next page exists")
      require(
        LinnetCandidatePresentation.printablePagingAction(
          key: key,
          hasModifiers: false,
          hasActiveInput: true,
          currentPage: 0,
          isLastPage: true,
          candidateCount: 9) == nil,
        "\(key) was captured on the last candidate page")
    }
    for key in previousKeys + nextKeys {
      require(
        LinnetCandidatePresentation.printablePagingAction(
          key: key,
          hasModifiers: true,
          hasActiveInput: true,
          currentPage: 1,
          isLastPage: false,
          candidateCount: 9) == nil,
        "modified \(key) was mistaken for a printable paging shortcut")
      require(
        LinnetCandidatePresentation.printablePagingAction(
          key: key,
          hasModifiers: false,
          hasActiveInput: true,
          currentPage: 1,
          isLastPage: false,
          candidateCount: 0) == nil,
        "\(key) was captured without a candidate menu")
      require(
        LinnetCandidatePresentation.printablePagingAction(
          key: key,
          hasModifiers: false,
          hasActiveInput: false,
          currentPage: 1,
          isLastPage: false,
          candidateCount: 9) == nil,
        "\(key) captured a passive zero-prefix prediction")
    }
  }

  private static func testCandidateLineTypographyOwner() {
    let primaryFont = NSFont.systemFont(ofSize: 16)
    let secondaryFont = NSFont.systemFont(ofSize: 10)
    let baseline = LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: primaryFont,
      secondaryFont: secondaryFont,
      baseOffset: 1,
      verticalText: false,
      placement: .inline)
    require(abs(baseline - 3.4) < 0.0001,
            "secondary candidate typography lost the live baseline formula")
    require(
      LinnetCandidatePresentation.secondaryBaselineOffset(
        primaryFont: primaryFont,
        secondaryFont: secondaryFont,
        baseOffset: 1,
        verticalText: true,
        placement: .inline) == 1,
      "vertical candidate typography retained a horizontal baseline correction")
    require(
      LinnetCandidatePresentation.secondaryBaselineOffset(
        primaryFont: primaryFont,
        secondaryFont: secondaryFont,
        baseOffset: 1,
        verticalText: false,
        placement: .standaloneDetail) == 1,
      "standalone candidate detail inherited the inline optical baseline correction")

    let candidateAttributes: [NSAttributedString.Key: Any] = [
      .font: primaryFont,
      .foregroundColor: NSColor.labelColor,
      .baselineOffset: 1,
    ]
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: secondaryFont,
      .foregroundColor: NSColor.secondaryLabelColor,
      .baselineOffset: baseline,
    ]
    let commentAttributes: [NSAttributedString.Key: Any] = [
      .font: secondaryFont,
      .foregroundColor: NSColor.tertiaryLabelColor,
      .baselineOffset: baseline,
    ]
    let line = LinnetCandidatePresentation.candidateLine(
      candidateFormat: "‹[label]› [candidate] / [comment]",
      label: "1",
      candidate: "输入",
      comment: "名词",
      candidateAttributes: candidateAttributes,
      labelAttributes: labelAttributes,
      commentAttributes: commentAttributes)
    require(line.attributedString.string == "‹1› 输入 / 名词",
            "candidate placeholders no longer preserve arbitrary surrounding format")
    require(line.labelPrefix.string == "‹1› ",
            "stacked candidates lost their attributed label-prefix measurement")

    let rendered = line.attributedString.string as NSString
    let labelIndex = rendered.range(of: "1").location
    let candidateRange = rendered.range(of: "输入")
    let commentIndex = rendered.range(of: "名词").location
    require(
      (line.attributedString.attribute(.font, at: labelIndex, effectiveRange: nil)
        as? NSFont)?.pointSize == 10,
      "candidate label replacement lost its secondary font attributes")
    require(
      (line.attributedString.attribute(.font, at: candidateRange.location, effectiveRange: nil)
        as? NSFont)?.pointSize == 16,
      "candidate replacement lost its primary font attributes")
    require(
      (line.attributedString.attribute(.font, at: commentIndex, effectiveRange: nil)
        as? NSFont)?.pointSize == 10,
      "candidate comment replacement lost its secondary font attributes")
    require(
      line.attributedString.attribute(
        NSAttributedString.Key("noBreak"),
        at: candidateRange.location + 1,
        effectiveRange: nil) as? Bool == true,
      "short candidate replacement lost the live no-break contract")

    let detailFont = NSFont.systemFont(ofSize: 12)
    let detailBaseline = LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: primaryFont,
      secondaryFont: detailFont,
      baseOffset: 1,
      verticalText: false,
      placement: .standaloneDetail)
    let detail = LinnetCandidatePresentation.candidateLine(
      candidateFormat: "[comment]",
      label: "",
      candidate: "",
      comment: "/ef/ · n. 字母 F",
      candidateAttributes: candidateAttributes,
      labelAttributes: labelAttributes,
      commentAttributes: [
        .font: detailFont,
        .foregroundColor: NSColor.secondaryLabelColor,
        .baselineOffset: detailBaseline,
      ])
    require(detail.attributedString.string == "/ef/ · n. 字母 F",
            "standalone candidate detail split the runtime metadata wire shape")
    require(
      (detail.attributedString.attribute(.font, at: 0, effectiveRange: nil)
        as? NSFont)?.pointSize == 12 &&
        (detail.attributedString.attribute(.baselineOffset, at: 0, effectiveRange: nil)
          as? NSNumber)?.doubleValue == 1,
      "standalone candidate detail lost its canonical font or baseline")

    for point in [CGFloat(12), 16, 32] {
      let font = NSFont.systemFont(ofSize: point)
      let separatorWidth = LinnetCandidatePresentation.inlineCandidateSeparatorWidth(
        font: font)
      let tile = LinnetCandidatePresentation.candidateSelectionInsets(
        style: .tile, candidateFont: font)
      require(
        tile.left == separatorWidth / 2 && tile.right == separatorWidth / 2 &&
          tile.top == LinnetCandidatePresentation.candidateRowSpacing / 2 &&
          tile.bottom == LinnetCandidatePresentation.candidateRowSpacing / 2,
        "\(point)pt tile selection lost the live separator or row expansion")
      let underline = LinnetCandidatePresentation.candidateSelectionInsets(
        style: .underline, candidateFont: font)
      require(
        underline.top == 0 && underline.left == 0 &&
          underline.bottom == 0 && underline.right == 0,
        "\(point)pt underline selection incorrectly changed glyph geometry")
      let bar = LinnetCandidatePresentation.candidateSelectionInsets(
        style: .bar, candidateFont: font)
      require(
        bar.left == 8 && bar.right == 0 &&
          bar.top == LinnetCandidatePresentation.candidateRowSpacing / 2 &&
          bar.bottom == LinnetCandidatePresentation.candidateRowSpacing / 2,
        "\(point)pt bar selection lost its shared leading gutter or row expansion")
    }
  }

  private static func testCanonicalInlineMetricsAndMaterial() {
    let font = NSFont.systemFont(ofSize: 16)
    let expected = (LinnetCandidatePresentation.inlineCandidateSeparator as NSString)
      .size(withAttributes: [.font: font]).width
    require(
      LinnetCandidatePresentation.inlineCandidateSeparator == "  " &&
        LinnetCandidatePresentation.inlineCandidateSeparatorWidth(font: font) == expected,
      "inline candidate spacing gained a second pixel owner")
    require(
      LinnetCandidatePresentation.candidateMaterial == .popover,
      "candidate material stopped matching the native popover surface")
  }

  private static func testCandidateDetailGeometry() {
    let footer = LinnetCandidatePresentation.candidateDetailGeometry(
      forLinearLayout: true)
    let footerFrames = footer.frames(
      candidateSize: CGSize(width: 100, height: 20),
      detailSize: CGSize(width: 40, height: 10),
      dividerSize: CGSize(width: 1, height: 20))
    require(
      footer.placement == .footer &&
        footer.spacing == LinnetCandidatePresentation.candidateRowSpacing &&
        footer.textSeparator == "\n",
      "horizontal candidate detail lost its shared footer policy")
    require(
      footerFrames.candidate == CGRect(x: 0, y: 0, width: 100, height: 20) &&
        footerFrames.divider == nil &&
        footerFrames.detail == CGRect(x: 0, y: 26, width: 40, height: 10) &&
        footerFrames.size == CGSize(width: 100, height: 36),
      "footer candidate and detail no longer share one spatial geometry")

    let sidecar = LinnetCandidatePresentation.candidateDetailGeometry(
      forLinearLayout: false)
    let sidecarFrames = sidecar.frames(
      candidateSize: CGSize(width: 40, height: 60),
      detailSize: CGSize(width: 30, height: 12),
      dividerSize: CGSize(width: 1, height: 60))
    require(
      sidecar.placement == .sidecar &&
        sidecar.textSeparator == "\t│\t",
      "vertical candidate detail lost its shared sidecar policy")
    require(
      sidecarFrames.candidate == CGRect(x: 0, y: 0, width: 40, height: 60) &&
        sidecarFrames.divider == CGRect(x: 46, y: 0, width: 1, height: 60) &&
        sidecarFrames.detail == CGRect(x: 53, y: 0, width: 30, height: 12) &&
        sidecarFrames.size == CGSize(width: 83, height: 60),
      "sidecar candidate, divider, and detail no longer share one spatial geometry")
  }

  /// Expansion starts at the current Rime page and may inspect at most three
  /// pages or 27 candidates. The iterator may stop earlier at end-of-list.
  private static func testExpandedCandidateBounds() {
    require(
      LinnetCandidatePresentation.maximumExpandedPageCount == 3,
      "candidate disclosure exceeded the three-page product bound"
    )
    require(
      LinnetCandidatePresentation.maximumExpandedCandidateCount == 27,
      "candidate disclosure exceeded the 27-candidate product bound"
    )
    for (page, pageSize, expected) in [
      (0, 9, 0..<27),
      (2, 9, 18..<45),
      (4, 5, 20..<35),
      (3, 3, 9..<18),
    ] {
      require(
        LinnetCandidatePresentation.expandedCandidateRange(
          page: page, pageSize: pageSize) == expected,
        "expanded candidate iterator lost its current-page bound for page \(page), size \(pageSize)"
      )
    }
  }

  private static func testCandidateRows() {
    for pageSize in [3, 5, 7, 9] {
      let count = pageSize * 3
      let compactHorizontal = LinnetCandidatePresentation.visualRows(
        candidateCount: pageSize, pageSize: pageSize,
        flow: .horizontal, expanded: false)
      require(
        compactHorizontal == [Array(0..<pageSize)],
        "compact horizontal candidates stopped using one Rime page"
      )
      let compactVertical = LinnetCandidatePresentation.visualRows(
        candidateCount: pageSize, pageSize: pageSize,
        flow: .vertical, expanded: false)
      require(
        compactVertical == (0..<pageSize).map { [$0] },
        "compact vertical candidates stopped using one Rime page"
      )

      let horizontal = LinnetCandidatePresentation.visualRows(
        candidateCount: count, pageSize: pageSize,
        flow: .horizontal, expanded: true)
      require(
        horizontal == (0..<3).map { page in
          Array((page * pageSize)..<((page + 1) * pageSize))
        },
        "expanded horizontal candidates are not one row per Rime page"
      )

      let vertical = LinnetCandidatePresentation.visualRows(
        candidateCount: count, pageSize: pageSize,
        flow: .vertical, expanded: true)
      require(
        vertical == (0..<pageSize).map { row in
          [row, pageSize + row, pageSize * 2 + row]
        },
        "expanded vertical candidates are not one column per Rime page"
      )
      require(
        horizontal.flatMap { $0 }.sorted() == Array(0..<count) &&
          vertical.flatMap { $0 }.sorted() == Array(0..<count),
        "expanded presentation lost or duplicated an absolute candidate offset"
      )
    }

    require(
      LinnetCandidatePresentation.visualRows(
        candidateCount: 0, pageSize: 9, flow: .horizontal, expanded: true).isEmpty,
      "an empty candidate list created a visual row"
    )
    require(
      LinnetCandidatePresentation.visualRows(
        candidateCount: 14, pageSize: 5, flow: .vertical, expanded: true
      ) == [
        [0, 5, 10], [1, 6, 11], [2, 7, 12], [3, 8, 13], [4, 9],
      ],
      "a partial final candidate page lost its vertical column mapping"
    )
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
      Data("LinnetCandidatePresentationTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}
