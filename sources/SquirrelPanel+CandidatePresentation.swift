//
//  SquirrelPanel+CandidatePresentation.swift
//  Squirrel
//
//  Candidate publication, interaction, and panel geometry.
//

import AppKit

extension LinnetPanelGeometry {
  /// One App-panel owner sizes, places, flips, and clamps candidate/status
  /// windows. Shared Settings presentation code does not depend on this IMK
  /// placement boundary.
  static func panelFrame(
    contentSize: CGSize,
    caret: CGRect,
    screen: CGRect,
    metrics: PresentationMetrics,
    offsetHeight: CGFloat,
    verticalPreeditExtent: CGFloat = 0
  ) -> CGRect? {
    guard contentSize.width.isFinite,
      contentSize.height.isFinite,
      contentSize.width >= 0,
      contentSize.height >= 0,
      caret.minX.isFinite,
      caret.minY.isFinite,
      caret.maxX.isFinite,
      caret.maxY.isFinite,
      screen.minX.isFinite,
      screen.minY.isFinite,
      screen.width.isFinite,
      screen.height.isFinite,
      screen.width > 0,
      screen.height > 0,
      offsetHeight.isFinite,
      verticalPreeditExtent.isFinite
    else { return nil }

    let relativeCaretY = relativeVerticalPosition(caret: caret, screen: screen) ?? 0.5
    var frame = CGRect.zero
    if metrics.vertical {
      frame.size = CGSize(
        width: max(
          metrics.paging.axisExtent,
          min(0.95 * screen.width, contentSize.height + metrics.edgeInset.height * 2)
        ),
        height: min(
          0.95 * screen.height,
          contentSize.width + metrics.edgeInset.width * 2 + metrics.paging.stripWidth
        )
      )
      let layout = pagingLayout(
        configuration: metrics.paging,
        in: CGRect(origin: .zero, size: frame.size),
        preferredAxisCenter: .nan,
        vertical: true)
      frame.origin.y = relativeCaretY >= 0.5
        ? caret.minY - offsetHeight - frame.height + layout.contentFrame.minX
        : caret.maxY + offsetHeight
      frame.origin.x = caret.minX - frame.width - offsetHeight + verticalPreeditExtent
    } else {
      frame.size = CGSize(
        width: min(
          0.95 * screen.width,
          contentSize.width + metrics.edgeInset.width * 2 + metrics.paging.stripWidth
        ),
        height: max(
          metrics.paging.axisExtent,
          min(0.95 * screen.height, contentSize.height + metrics.edgeInset.height * 2)
        )
      )
      let layout = pagingLayout(
        configuration: metrics.paging,
        in: CGRect(origin: .zero, size: frame.size),
        preferredAxisCenter: .nan)
      frame.origin = CGPoint(
        x: caret.minX - layout.contentFrame.minX,
        y: caret.minY - offsetHeight - frame.height)
      if frame.minY < screen.minY {
        frame.origin.y = caret.maxY + offsetHeight
      }
    }

    frame.origin.x = min(
      max(frame.origin.x, screen.minX),
      screen.maxX - frame.width)
    frame.origin.y = min(
      max(frame.origin.y, screen.minY),
      screen.maxY - frame.height)
    return frame
  }
}

extension SquirrelPanel {
  func beginPublication(controller: SquirrelInputController) -> Publication? {
    guard inputController === controller else { return nil }
    panelPublicationGeneration &+= 1
    let publication = Publication(
      generation: panelPublicationGeneration,
      controllerID: ObjectIdentifier(controller))
    self.publication = publication
    return publication
  }

  func publicationIsCurrent(_ publication: Publication) -> Bool {
    guard let current = self.publication, let inputController else { return false }
    return current.generation == publication.generation &&
      current.controllerID == publication.controllerID &&
      publication.controllerID == ObjectIdentifier(inputController)
  }

  /// A caret rectangle is usable only when it is not degenerate and its
  /// origin lies on a connected screen.
  static func positionIsUsable(_ rect: NSRect) -> Bool {
    guard rect != .zero else { return false }
    return NSScreen.screens.contains { $0.frame.contains(rect.origin) }
  }
  func mousePosition(for event: NSEvent) -> NSPoint { view.convert(event.locationInWindow, from: nil) }
  func beginCandidatePress(_ event: NSEvent) {
    guard let publication, publicationIsCurrent(publication) else { return }
    candidateInteraction.beginPress(view.click(at: mousePosition(for: event)))
    publishCandidatePointerFeedback()
  }
  func finishCandidatePress(_ event: NSEvent) {
    guard let publication, publicationIsCurrent(publication),
      let inputController
    else { return }
    let hit = candidateInteraction.finishPress(
      view.click(at: mousePosition(for: event)))
    publishCandidatePointerFeedback()
      guard let hit else { return }
    switch hit {
    case .candidate(let itemIndex):
      guard let candidateSnapshot, candidateSnapshot.items.indices.contains(itemIndex)
      else { return }
      _ = inputController.selectCandidate(
        absoluteIndex: candidateSnapshot.items[itemIndex].absoluteIndex)
    case .control(let action):
      _ = performControl(action)
    case .none:
      break
    }
  }
  func moveCandidatePointer(_ event: NSEvent) {
    guard let publication, publicationIsCurrent(publication) else { return }
    candidateInteraction.movePointer(to: view.click(at: mousePosition(for: event)))
    publishCandidatePointerFeedback()
  }
  func publishCandidatePointerFeedback() {
    guard let publication, publicationIsCurrent(publication) else {
      view.updateCandidatePointerFeedback(hit: nil, isPressed: false)
      return
    }
    let hit: SquirrelView.CandidateHit?
    switch candidateInteraction.pointerHit {
    case .candidate(let itemIndex)
      where candidateSnapshot?.items.indices.contains(itemIndex) == true:
      hit = .candidate(itemIndex)
    case .control(let action):
      hit = .control(action)
    case .some(.none):
      hit = nil
    case nil:
      hit = nil
    default:
      hit = nil
    }
    view.updateCandidatePointerFeedback(
      hit: hit,
      isPressed: candidateInteraction.pointerHitIsPressed)
  }
  func handleCandidateScroll(_ event: NSEvent) {
    guard let publication, publicationIsCurrent(publication),
      let inputController
    else { return }
    let scrollSample =
      LinnetCandidateInteractionState<SquirrelView.CandidateHit>.ScrollSample(
        event: event
      )
    let pagingIntent = candidateInteraction.processScroll(
      scrollSample,
      vertical: vertical)
    publishCandidatePointerFeedback()
    guard let pagingIntent else { return }
    _ = inputController.page(up: pagingIntent == .previousPage)
  }

  func updateUsableScreenRect() {
    let screen = NSScreen.screens.first { $0.frame.contains(position.origin) } ?? NSScreen.main
    if let screen { screenRect = screen.visibleFrame }
  }

  func presentationMetrics(
    theme: SquirrelTheme
  ) -> LinnetPanelGeometry.PresentationMetrics {
    let paging = LinnetPanelGeometry.pagingConfiguration(
      showPaging: theme.showPaging,
      themeOffset: theme.pagingOffset,
      canPageUp: view.canPageUp,
      canPageDown: view.canPageDown
    )
    return LinnetPanelGeometry.presentationMetrics(
      role: presentationRole,
      candidateFontPoint: theme.font.pointSize,
      candidateEdgeInset: theme.edgeInset,
      candidatePaging: paging,
      candidateVertical: vertical,
      candidateCornerRadius: theme.cornerRadius
    )
  }

  func maxTextWidth(
    metrics: LinnetPanelGeometry.PresentationMetrics,
    expanded: Bool
  ) -> CGFloat {
    let fontScale = metrics.fontPoint / 12
    let compactRatio = min(1, 1 / (metrics.vertical ? 4 : 3) + fontScale / 12)
    let textWidthRatio = expanded ? max(0.75, compactRatio) : compactRatio
    let maxWidth = if metrics.vertical {
      screenRect.height * textWidthRatio - metrics.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - metrics.edgeInset.width * 2
    }
    return maxWidth
  }

  /// The existing detached TextKit surface renders both footer and sidecar
  /// details. CandidateDetailGeometry owns its width and frame; this boundary
  /// owns only TextKit line fitting and trailing truncation.
  func fitSelectedDetailText(
    geometry: LinnetCandidatePresentation.CandidateDetailGeometry,
    candidateSize: NSSize,
    theme: SquirrelTheme,
    textContainer: NSTextContainer,
    textLayoutManager: NSTextLayoutManager
  ) -> NSRect {
    let detailFont = (theme.detailAttrs[.font] as? NSFont) ?? theme.font
    let lineHeight = max(
      1, ceil(detailFont.ascender - detailFont.descender + detailFont.leading))
    let maximumLines: Int
    let detailHeight: CGFloat
    switch geometry.placement {
    case .footer:
      maximumLines = LinnetCandidatePresentation.maximumFooterDetailLineCount
      detailHeight = lineHeight * CGFloat(maximumLines)
    case .sidecar:
      maximumLines = max(1, Int(floor(candidateSize.height / lineHeight)))
      detailHeight = candidateSize.height
    }
    let detailWidth = geometry.fittedDetailWidth(
      candidateWidth: candidateSize.width,
      detailWidth: geometry.detailColumnMaximumWidth ?? candidateSize.width)
    guard detailWidth > 0, detailHeight > 0 else { return .zero }
    textContainer.maximumNumberOfLines = maximumLines
    textContainer.lineBreakMode = .byTruncatingTail
    textContainer.size = NSSize(width: detailWidth, height: detailHeight)
    textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
    return view.detailContentRect
  }

  /// Expanded browsing keeps one selected-candidate definition surface stable
  /// while the Rime-owned highlight moves through the grid. Compact browsing
  /// remains content-sized.
  func selectedDetailSurfaceSize(
    geometry: LinnetCandidatePresentation.CandidateDetailGeometry,
    candidateSize: NSSize,
    measuredDetailSize: NSSize,
    theme: SquirrelTheme,
    reservesExpandedDetail: Bool
  ) -> NSSize {
    guard reservesExpandedDetail else { return measuredDetailSize }
    let detailFont = (theme.detailAttrs[.font] as? NSFont) ?? theme.font
    let lineHeight = max(
      1, ceil(detailFont.ascender - detailFont.descender + detailFont.leading))
    switch geometry.placement {
    case .footer:
      return NSSize(
        width: geometry.fittedDetailWidth(
          candidateWidth: candidateSize.width,
          detailWidth: geometry.detailColumnMaximumWidth ?? candidateSize.width),
        height: lineHeight * CGFloat(
          LinnetCandidatePresentation.maximumFooterDetailLineCount))
    case .sidecar:
      return NSSize(
        width: geometry.detailColumnMaximumWidth ?? measuredDetailSize.width,
        height: candidateSize.height)
    }
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show(publication: Publication) -> Bool {
    guard publicationIsCurrent(publication) else { return false }
    updateUsableScreenRect()
    let theme = view.currentTheme
    let materialAppearance = LinnetClientAppearance.resolveMaterial(
      mode: theme.materialAppearance, automaticAppearance: resolvedAppearance)
    let metrics = presentationMetrics(theme: theme)
    view.applyPresentationMetrics(metrics)
    guard let textContainer = view.textView.textContainer,
      let textLayoutManager = view.textView.textLayoutManager else {
      orderOut(nil)
      return false
    }
    if theme.native || view.darkTheme.available {
      self.appearance = materialAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    // Break line if the text is too long, based on screen size.
    let maximumTextWidth = maxTextWidth(
      metrics: metrics,
      expanded: candidateSnapshot?.isExpanded == true)
    view.applyCandidateGridWidthLimit(maximumTextWidth)
    let maxTextHeight = metrics.vertical
      ? screenRect.width - metrics.edgeInset.width * 2
      : screenRect.height - metrics.edgeInset.height * 2
    let detailGeometry = LinnetCandidatePresentation.candidateDetailGeometry(
      forLinearLayout:
        linear || candidateSnapshot?.isExpanded == true || metrics.vertical,
      candidateFontPoint: theme.font.pointSize)
    let hasDetail = !view.detailTextView.isHidden
    let hasSidecar = hasDetail && detailGeometry.placement == .sidecar
    let textWidth = hasSidecar
      ? min(maximumTextWidth, detailGeometry.candidateColumnMaximumWidth ?? maximumTextWidth)
      : maximumTextWidth
    textContainer.size = NSSize(width: textWidth, height: maxTextHeight)
    textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
    guard publicationIsCurrent(publication) else { return false }
    view.textView.scrollToBeginningOfDocument(nil)
    guard publicationIsCurrent(publication) else { return false }

    var contentRect = view.contentRect
    var detailFrames: LinnetCandidatePresentation.CandidateDetailFrames?
    if hasDetail, let detailTextContainer = view.detailTextView.textContainer,
      let detailTextLayoutManager = view.detailTextView.textLayoutManager {
      let detailRect = fitSelectedDetailText(
        geometry: detailGeometry,
        candidateSize: contentRect.size,
        theme: theme,
        textContainer: detailTextContainer,
        textLayoutManager: detailTextLayoutManager)
      let detailSize = selectedDetailSurfaceSize(
        geometry: detailGeometry,
        candidateSize: contentRect.size,
        measuredDetailSize: NSSize(
          width: ceil(detailRect.width),
          height: ceil(detailRect.height)),
        theme: theme,
        reservesExpandedDetail: candidateSnapshot?.isExpanded == true)
      detailFrames = detailGeometry.frames(
        candidateSize: contentRect.size,
        detailSize: detailSize,
        dividerSize: NSSize(width: 1, height: contentRect.height))
      if let detailFrames {
        contentRect = NSRect(origin: .zero, size: detailFrames.size)
      }
    }
    let relativeCaretY = LinnetPanelGeometry.relativeVerticalPosition(
      caret: position,
      screen: screenRect
    ) ?? 0.5
    if theme.memorizeSize && metrics.vertical &&
        (relativeCaretY < 0.5 ||
          position.minX + max(contentRect.width, maxHeight) +
            metrics.edgeInset.width * 2 > screenRect.maxX) {
      if contentRect.width >= maxHeight {
        maxHeight = contentRect.width
      } else {
        contentRect.size.width = maxHeight
        textContainer.size = NSSize(width: maxHeight, height: maxTextHeight)
      }
    }

    var verticalPreeditExtent: CGFloat = 0
    if metrics.vertical,
      view.preeditRange.length > 0,
      let preeditTextRange = view.convert(range: view.preeditRange) {
      let preeditRect = view.contentRect(range: preeditTextRange)
      verticalPreeditExtent = preeditRect.height + metrics.edgeInset.width
    }
    guard let panelRect = LinnetPanelGeometry.panelFrame(
      contentSize: contentRect.size,
      caret: position,
      screen: screenRect,
      metrics: metrics,
      offsetHeight: SquirrelTheme.offsetHeight,
      verticalPreeditExtent: verticalPreeditExtent)
    else {
      orderOut(nil)
      return false
    }
    self.setFrame(panelRect, display: false)
    guard publicationIsCurrent(publication) else { return false }

    // rotate the view, the core in vertical mode!
    guard let contentView else {
      orderOut(nil)
      return false
    }
    if metrics.vertical {
      contentView.boundsRotation = -90
      contentView.setBoundsOrigin(NSPoint(x: 0, y: panelRect.width))
    } else {
      contentView.boundsRotation = 0
      contentView.setBoundsOrigin(.zero)
    }
    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    view.frame = contentView.bounds
    let contentFrame = LinnetPanelGeometry.pagingLayout(
      configuration: metrics.paging,
      in: contentView.bounds,
      preferredAxisCenter: .nan,
      vertical: metrics.vertical).contentFrame
    view.textView.frame = contentFrame
    view.textView.textContainerInset = metrics.edgeInset
    view.layoutCandidateGrid(in: contentFrame, edgeInset: metrics.edgeInset)
    if let detailFrames {
      let top = contentFrame.maxY - metrics.edgeInset.height
      view.detailTextView.frame = NSRect(
        x: contentFrame.minX + metrics.edgeInset.width + detailFrames.detail.minX,
        y: top - detailFrames.detail.maxY,
        width: detailFrames.detail.width,
        height: detailFrames.detail.height)
      if let dividerFrame = detailFrames.divider {
        view.detailDividerView.isHidden = false
        view.detailDividerView.frame = NSRect(
          x: contentFrame.minX + metrics.edgeInset.width + dividerFrame.minX,
          y: top - dividerFrame.maxY,
          width: dividerFrame.width,
          height: dividerFrame.height)
        let dividerColor = (theme.detailAttrs[.foregroundColor] as? NSColor)
          ?? .separatorColor
        view.detailDividerView.layer?.backgroundColor =
          dividerColor.withAlphaComponent(0.3).cgColor
        view.applyCandidateColumnWidth(metrics.edgeInset.width + dividerFrame.minX)
      } else {
        view.detailDividerView.isHidden = true
        view.detailDividerView.frame = .zero
        view.applyCandidateColumnWidth(nil)
      }
    } else {
      view.detailTextView.frame = .zero
      view.detailDividerView.isHidden = true
      view.detailDividerView.frame = .zero
      view.applyCandidateColumnWidth(nil)
    }
    guard publicationIsCurrent(publication) else { return false }

    if theme.translucency {
      back.frame = contentView.bounds
      back.frame.size.width += metrics.paging.stripWidth
      back.appearance = materialAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    invalidateShadow()
    contentView.layoutSubtreeIfNeeded()
    view.needsDisplay = true
    view.displayIfNeeded()
    guard publicationIsCurrent(publication) else { return false }
    orderFrontRegardless()
    return publicationIsCurrent(publication)
  }

  func show(status message: String, publication: Publication) {
    guard publicationIsCurrent(publication) else { return }
    let theme = view.currentTheme
    presentationRole = .status
    let text = NSMutableAttributedString(
      string: message, attributes: theme.statusAttrs)
    text.addAttribute(
      .paragraphStyle, value: theme.statusParagraphStyle,
      range: NSRange(location: 0, length: text.length))
    guard let textContentStorage = view.textView.textContentStorage else {
      orderOut(nil)
      return
    }
    view.candidateGridView.clear()
    textContentStorage.attributedString = text
    view.publishSidecarDetail(nil)
    guard publicationIsCurrent(publication) else { return }
    view.textView.setLayoutOrientation(.horizontal)
    guard publicationIsCurrent(publication) else { return }
    view.drawView(
      candidateRanges: [NSRange(location: 0, length: text.length)], detailRange: .empty,
      hilightedIndex: -1, preeditRange: .empty, highlightedPreeditRange: .empty,
      controlMode: .paging(canPageUp: false, canPageDown: false))
    guard publicationIsCurrent(publication) else { return }
    guard show(publication: publication) else { return }
    guard publicationIsCurrent(publication) else { return }

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      guard self.publicationIsCurrent(publication) else { return }
      self.hide()
    }
  }

  func selectedDetail(
    theme: SquirrelTheme,
    candidates: [SquirrelInputController.CandidateItem],
    highlighted index: Int,
    reservesExpandedDetail: Bool
  ) -> NSAttributedString? {
    guard candidates.indices.contains(index) else { return nil }
    let selectedComment = LinnetCandidatePresentation.candidateComment(
      candidates[index].comment.precomposedStringWithCanonicalMapping)
    var comment = LinnetCandidatePresentation.selectedDetailText(
      selectedComment.displayText)
    if comment.isEmpty,
      reservesExpandedDetail,
      candidates.contains(where: {
        LinnetCandidatePresentation.candidateComment($0.comment).belongsToSmartEnglish
      }) {
      comment = NSLocalizedString(
        "No definition", comment: "Expanded English candidate without a definition")
    }
    guard !comment.isEmpty else { return nil }
    return LinnetCandidatePresentation.candidateLine(
      candidateFormat: "[comment]",
      label: "",
      candidate: "",
      comment: comment,
      candidateAttributes: theme.detailAttrs,
      labelAttributes: theme.detailAttrs,
      commentAttributes: theme.detailAttrs
    ).attributedString
  }

}
