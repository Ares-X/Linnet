//
//  SquirrelPanel+CandidatePresentation.swift
//  Squirrel
//
//  Candidate publication, interaction, and panel geometry.
//

import AppKit

extension SquirrelPanel {
  struct SidecarLayout {
    let rowStartIndex: Int
    let anchorIndex: Int
    let detailGeometry: LinnetCandidatePresentation.CandidateDetailGeometry
    let theme: SquirrelTheme
  }

  func beginPublication(
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Publication? {
    guard self.activationToken == activationToken,
      inputController?.inputActivationIsCurrent(activationToken) == true
    else { return nil }
    panelPublicationGeneration &+= 1
    let publication = Publication(
      generation: panelPublicationGeneration,
      activationToken: activationToken)
    self.publication = publication
    return publication
  }

  func publicationIsCurrent(_ publication: Publication) -> Bool {
    self.publication == publication &&
      activationToken == publication.activationToken &&
      inputController?.inputActivationIsCurrent(
        publication.activationToken) == true
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
        absoluteIndex: candidateSnapshot.items[itemIndex].absoluteIndex,
        activationToken: publication.activationToken)
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
    _ = inputController.page(
      up: pagingIntent == .previousPage,
      activationToken: publication.activationToken)
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
    metrics: LinnetPanelGeometry.PresentationMetrics
  ) -> CGFloat {
    let fontScale = metrics.fontPoint / 12
    let textWidthRatio = min(1, 1 / (metrics.vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if metrics.vertical {
      screenRect.height * textWidthRatio - metrics.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - metrics.edgeInset.width * 2
    }
    return maxWidth
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show(publication: Publication) -> Bool {
    guard publicationIsCurrent(publication) else { return false }
    updateUsableScreenRect()
    let theme = view.currentTheme
    let materialAppearance = LinnetClientAppearance.resolveMaterial(
      mode: theme.materialAppearance,
      automaticAppearance: resolvedAppearance
    )
    let metrics = presentationMetrics(theme: theme)
    view.applyPresentationMetrics(metrics)
    guard let textContainer = view.textView.textContainer,
      let textLayoutManager = view.textView.textLayoutManager
    else {
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
    let textWidth = maxTextWidth(metrics: metrics)
    let maxTextHeight = metrics.vertical
      ? screenRect.width - metrics.edgeInset.width * 2
      : screenRect.height - metrics.edgeInset.height * 2
    textContainer.size = NSSize(width: textWidth, height: maxTextHeight)
    textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
    guard publicationIsCurrent(publication) else { return false }
    view.textView.scrollToBeginningOfDocument(nil)
    guard publicationIsCurrent(publication) else { return false }

    var panelRect = NSRect.zero
    // in vertical mode, the width and height are interchanged
    var contentRect = view.contentRect
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

    if metrics.vertical {
      panelRect.size = NSSize(
        width: max(
          metrics.paging.axisExtent,
          min(0.95 * screenRect.width, contentRect.height + metrics.edgeInset.height * 2)
        ),
        height: min(
          0.95 * screenRect.height,
          contentRect.width + metrics.edgeInset.width * 2 +
            metrics.paging.stripWidth
        )
      )
      let logicalLayout = LinnetPanelGeometry.pagingLayout(
        configuration: metrics.paging,
        in: NSRect(origin: .zero, size: panelRect.size),
        preferredAxisCenter: .nan,
        vertical: true)

      // To avoid jumping up and down while typing, use the lower screen when
      // typing on upper, and vice versa
      if relativeCaretY >= 0.5 {
        panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight
          - panelRect.height + logicalLayout.contentFrame.minX
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      // Make the first candidate fixed at the left of cursor
      panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
        let preeditRect = view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + metrics.edgeInset.width
      }
    } else {
      panelRect.size = NSSize(
        width: min(
          0.95 * screenRect.width,
          contentRect.width + metrics.edgeInset.width * 2 +
            metrics.paging.stripWidth
        ),
        height: max(
          metrics.paging.axisExtent,
          min(0.95 * screenRect.height, contentRect.height + metrics.edgeInset.height * 2)
        )
      )
      let logicalLayout = LinnetPanelGeometry.pagingLayout(
        configuration: metrics.paging,
        in: NSRect(origin: .zero, size: panelRect.size),
        preferredAxisCenter: .nan)
      panelRect.origin = NSPoint(
        x: position.minX - logicalLayout.contentFrame.minX,
        y: position.minY - SquirrelTheme.offsetHeight - panelRect.height
      )
    }
    if panelRect.maxX > screenRect.maxX {
      panelRect.origin.x = screenRect.maxX - panelRect.width
    }
    if panelRect.minX < screenRect.minX {
      panelRect.origin.x = screenRect.minX
    }
    if panelRect.minY < screenRect.minY {
      if metrics.vertical {
        panelRect.origin.y = screenRect.minY
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
    }
    if panelRect.maxY > screenRect.maxY {
      panelRect.origin.y = screenRect.maxY - panelRect.height
    }
    if panelRect.minY < screenRect.minY {
      panelRect.origin.y = screenRect.minY
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
    view.textView.frame = LinnetPanelGeometry.pagingLayout(
      configuration: metrics.paging,
      in: contentView.bounds,
      preferredAxisCenter: .nan,
      vertical: metrics.vertical).contentFrame
    view.textView.textContainerInset = metrics.edgeInset
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
    textContentStorage.attributedString = text
    guard publicationIsCurrent(publication) else { return }
    view.textView.setLayoutOrientation(.horizontal)
    guard publicationIsCurrent(publication) else { return }
    view.drawView(
      candidateRanges: [NSRange(location: 0, length: text.length)], detailRange: .empty,
      hilightedIndex: -1, preeditRange: .empty, highlightedPreeditRange: .empty,
      controlMode: .paging(canPageUp: false, canPageDown: false),
      usesGridLayout: false)
    guard publicationIsCurrent(publication) else { return }
    guard show(publication: publication) else { return }
    candidateAccessibility.publishStatus(parent: view, message: message)
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
    highlighted index: Int
  ) -> NSAttributedString? {
    guard candidates.indices.contains(index) else { return nil }
    let comment = LinnetCandidatePresentation.selectedDetailText(
      candidates[index].comment.precomposedStringWithCanonicalMapping)
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

  func attachSidecar(
    _ detail: NSAttributedString,
    to text: NSMutableAttributedString,
    candidateRanges: inout [NSRange],
    layout: SidecarLayout
  ) -> NSRange {
    let detailGeometry = layout.detailGeometry
    let theme = layout.theme
    let divider = NSMutableAttributedString(
      string: detailGeometry.textSeparator,
      attributes: theme.detailAttrs)
    divider.append(detail)
    guard let insertion = LinnetCandidatePresentation.sidecarInsertion(
      candidateRanges: candidateRanges,
      anchorIndex: layout.anchorIndex,
      insertedLength: divider.length
    ) else { return .empty }

    let physicalRanges = candidateRanges.filter { $0.location != NSNotFound }
    guard let candidateStart = physicalRanges.map(\.location).min(),
      let candidateEnd = physicalRanges.map(\.upperBound).max()
    else { return .empty }
    let candidateSize = text.attributedSubstring(
      from: NSRange(location: candidateStart, length: candidateEnd - candidateStart)
    ).boundingRect(
      with: NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin]).size
    let detailSize = detail.boundingRect(
      with: NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin]).size
    let dividerSize = NSAttributedString(
      string: detailGeometry.dividerText,
      attributes: theme.detailAttrs).boundingRect(
        with: NSSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin]).size
    let frames = detailGeometry.frames(
      candidateSize: candidateSize,
      detailSize: detailSize,
      dividerSize: dividerSize)
    text.insert(divider, at: insertion.location)
    candidateRanges = insertion.candidateRanges
    guard candidateRanges.indices.contains(layout.rowStartIndex) else { return .empty }
    let rowStart = candidateRanges[layout.rowStartIndex]
    let paragraph = NSMutableParagraphStyle()
    paragraph.setParagraphStyle(theme.firstParagraphStyle)
    guard let dividerFrame = frames.divider else { return .empty }
    paragraph.tabStops = [
      NSTextTab(textAlignment: .left, location: dividerFrame.minX),
      NSTextTab(textAlignment: .left, location: frames.detail.minX)
    ]
    text.addAttribute(
      .paragraphStyle,
      value: paragraph,
      range: NSRange(
        location: rowStart.location,
        length: insertion.location + divider.length - rowStart.location))
    return NSRange(location: insertion.location, length: divider.length)
  }
}
