//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit

final class SquirrelPanel: NSPanel {
  struct Publication {
    let generation: UInt64
    let controllerID: ObjectIdentifier
  }

  let view: SquirrelView
  let back: NSVisualEffectView
  let candidateAccessibility: LinnetCandidateAccessibility
  private(set) weak var inputController: SquirrelInputController?
  var panelPublicationGeneration: UInt64 = 0
  var publication: Publication?

  private(set) var position: NSRect
  var screenRect: NSRect = .zero
  var maxHeight: CGFloat = 0

  // Last caret rectangle accepted as usable; degenerate client responses
  // (e.g. Spotlight reports a zero rectangle) must not teleport the panel
  // to the screen corner.
  private var lastUsablePosition: NSRect?
  // Themes already built per schema, valid until the base configuration is
  // reloaded (resetThemeCache). Shift toggling would otherwise re-read the
  // schema YAML and rebuild both appearances on every tap.
  private var themeCache: [String: (light: SquirrelTheme, dark: SquirrelTheme)] = [:]

  private var statusMessage: String = ""
  var statusTimer: Timer?
  var presentationRole: LinnetPanelGeometry.PresentationRole = .candidate
  var resolvedAppearance = NSAppearance(named: .aqua)!

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  var candidateSnapshot: SquirrelInputController.CandidateSnapshot?
  var index: Int = 0
  var candidateInteraction = LinnetCandidateInteractionState<SquirrelView.CandidateHit>()
  private(set) var candidateExpansionAnchorPage: Int?
  var candidateExpansionRequested: Bool {
    candidateExpansionAnchorPage != nil
  }

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = NSVisualEffectView()
    self.candidateAccessibility = LinnetCandidateAccessibility()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    // CGShieldingWindowLevel is the level of the shielding window that sits
    // in front of a full-screen Space; at the *same* level the panel's
    // ordering against it is undefined and full-screen apps can occlude the
    // candidates. One step above plus canJoinAllSpaces lets the panel onto
    // the full-screen Space (hallelujah uses the same combination).
    self.level = .init(Int(CGShieldingWindowLevel()) + 1)
    self.collectionBehavior = [.canJoinAllSpaces]
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    self.acceptsMouseMovedEvents = true
    back.blendingMode = .behindWindow
    back.material = LinnetCandidatePresentation.candidateMaterial
    back.state = .active
    back.wantsLayer = true
    back.layer?.mask = view.shape
    let contentView = NSView()
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    contentView.addSubview(view.detailDividerView)
    contentView.addSubview(view.detailTextView)
    self.contentView = contentView
    candidateAccessibility.install(parent: view, rawTextView: view.textView)
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }

  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown: beginCandidatePress(event)
    case .leftMouseUp: finishCandidatePress(event)
    case .leftMouseDragged, .mouseEntered, .mouseMoved: moveCandidatePointer(event)
    case .mouseExited:
      candidateInteraction.leavePointer()
      publishCandidatePointerFeedback()
    case .scrollWheel: handleCandidateScroll(event)
    default:
      break
    }
    super.sendEvent(event)
  }

  func bind(controller: SquirrelInputController) {
    if inputController === controller { return }
    inputController = nil
    lastUsablePosition = nil
    statusMessage = ""
    hide()
    guard inputController == nil else { return }
    inputController = controller
  }

  func unbind(controller: SquirrelInputController) {
    guard inputController === controller else { return }
    inputController = nil
    lastUsablePosition = nil
    statusMessage = ""
    hide()
    guard inputController == nil else { return }
    updateAppearance(client: nil)
  }

  func hide(controller: SquirrelInputController) {
    guard inputController === controller else { return }
    hide()
  }

  /// An empty Rime refresh has no candidate geometry to publish. Keep an
  /// active mode-transition timer visible; otherwise dismiss the panel.
  func handlePassiveEmptyUpdate(controller: SquirrelInputController) {
    guard inputController === controller, statusTimer == nil
    else { return }
    hide()
  }

  func hide() {
    panelPublicationGeneration &+= 1
    let hiddenGeneration = panelPublicationGeneration
    publication = nil
    statusTimer?.invalidate()
    statusTimer = nil
    statusMessage = ""
    candidateExpansionAnchorPage = nil
    candidateSnapshot = nil
    candidateInteraction.advancePublication()
    publishCandidatePointerFeedback()
    maxHeight = 0
    guard panelPublicationGeneration == hiddenGeneration else { return }
    orderOut(nil)
    guard panelPublicationGeneration == hiddenGeneration else { return }
    candidateAccessibility.clear(parent: view)
  }

  /// Rebuilds the visible candidate window from the last accepted Rime
  /// snapshot after its themes have been reloaded. No new candidate state is
  /// inferred here; the next Rime update remains the only data owner.
  func refreshAppearance() {
    guard let publication,
      publicationIsCurrent(publication),
      isVisible,
      let candidateSnapshot,
      !candidateSnapshot.items.isEmpty || !preedit.isEmpty
    else { return }
    updateAppearance(client: inputController?.activeClient as? NSObjectProtocol)
    guard publicationIsCurrent(publication) else { return }
    _ = update(
      preedit: preedit,
      selRange: selRange,
      caretPos: caretPos,
      candidates: candidateSnapshot,
      highlighted: index,
      update: false,
      controller: inputController
    )
  }

  func performControl(
    _ action: LinnetCandidatePresentation.CandidateControlAction
  ) -> Bool {
    guard let publication, publicationIsCurrent(publication),
      let inputController
    else { return false }
    switch action {
    case .pageUp:
      return inputController.page(up: true)
    case .pageDown:
      return inputController.page(up: false)
    case .expand:
      guard view.currentTheme.candidateExpansionAllowed,
        candidateSnapshot?.canExpand == true,
        candidateExpansionAnchorPage == nil,
        let currentPage = candidateSnapshot?.currentPage
      else { return false }
      candidateExpansionAnchorPage = currentPage
      inputController.refreshCandidatePresentation()
      return true
    case .collapse:
      guard candidateExpansionAnchorPage != nil else { return false }
      candidateExpansionAnchorPage = nil
      inputController.refreshCandidatePresentation()
      return true
    }
  }

  /// The Rime interaction processor has already accepted a printable paging
  /// key. Reuse the disclosure state without reclassifying the physical key.
  func requestCandidateExpansionForKeyboardPaging() {
    guard view.currentTheme.candidateExpansionAllowed,
      candidateExpansionAnchorPage == nil,
      let currentPage = candidateSnapshot?.currentPage
    else { return }
    candidateExpansionAnchorPage = currentPage
  }
}

extension SquirrelPanel {
  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity
  func update(
    preedit: String,
    selRange: NSRange,
    caretPos: Int,
    candidates: SquirrelInputController.CandidateSnapshot,
    highlighted index: Int,
    update: Bool,
    controller: SquirrelInputController?
  ) -> Bool {
    guard let controller, inputController === controller else { return false }
    let currentPublication: Publication
    if update {
      guard let begun = beginPublication(controller: controller) else {
        return false
      }
      currentPublication = begun
      candidateInteraction.advancePublication()
      publishCandidatePointerFeedback()
      guard publicationIsCurrent(currentPublication) else { return false }
      (self.preedit, self.selRange) = (preedit, selRange)
      self.caretPos = caretPos
      candidateSnapshot = candidates
      candidateExpansionAnchorPage = candidates.isExpanded
        ? candidates.items.first?.page : nil
      self.index = index
    } else {
      guard let publication,
        publication.controllerID == ObjectIdentifier(controller),
        publicationIsCurrent(publication)
      else { return false }
      currentPublication = publication
    }
    if !candidates.items.isEmpty || !preedit.isEmpty {
      presentationRole = .candidate
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        let message = statusMessage
        statusMessage = ""
        show(status: message, publication: currentPublication)
      } else if statusTimer == nil {
        hide()
      }
      return publicationIsCurrent(currentPublication)
    }

    let theme = view.currentTheme

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    // preedit
    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.items.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    let usesInlineComments = LinnetCandidatePresentation.usesInlineComments(
      candidateFormat: theme.candidateFormat)
    let detailGeometry = LinnetCandidatePresentation.candidateDetailGeometry(
      forLinearLayout: linear || candidates.isExpanded || vertical,
      candidateFontPoint: theme.font.pointSize)
    let selectedDetail = usesInlineComments
      ? nil : selectedDetail(
        theme: theme,
        candidates: candidates.items,
        highlighted: index,
        reservesExpandedDetail: candidates.isExpanded)
    let detailRange = NSRange.empty

    // candidates
    var candidateRanges = [NSRange](
      repeating: .empty, count: candidates.items.count)
    let flow: LinnetCandidatePresentation.CandidateFlow = linear ? .horizontal : .vertical
    let visualRows = LinnetCandidatePresentation.visualRows(
      candidateCount: candidates.items.count,
      pageSize: candidates.pageSize,
      flow: flow,
      expanded: candidates.isExpanded
    )
    let usesGridLayout = candidates.isExpanded
    let usesInlineLayout = linear || usesGridLayout
    let inlineSeparator = NSAttributedString(
      string: LinnetCandidatePresentation.inlineCandidateSeparator,
      attributes: theme.attrs)
    view.separatorWidth = usesInlineLayout
      ? inlineSeparator.boundingRect(with: .zero).width : 0
    let candidateLines = candidates.items.enumerated().map { itemIndex, item in
      let attrs = itemIndex == index ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = itemIndex == index ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = itemIndex == index ? theme.commentHighlightedAttrs : theme.commentAttrs
      let label = theme.candidateFormat.contains(/\[label\]/)
        ? item.selectionLabel ?? "" : ""
      let displayedComment = usesInlineComments
        ? LinnetCandidatePresentation.candidateComment(item.comment).displayText : ""
      return LinnetCandidatePresentation.candidateLine(
        candidateFormat: theme.candidateFormat,
        label: label,
        candidate: item.text,
        comment: displayedComment,
        candidateAttributes: attrs,
        labelAttributes: labelAttrs,
        commentAttributes: commentAttrs)
    }
    let gridColumns = usesGridLayout
      ? LinnetCandidatePresentation.candidateGridColumns(
        rows: visualRows,
        itemWidths: candidateLines.map {
          $0.attributedString.boundingRect(
            with: .zero, options: [.usesLineFragmentOrigin]).width
        },
        spacing: view.separatorWidth)
      : nil
    var isFirstCandidate = true
    for row in visualRows {
      for (column, itemIndex) in row.enumerated() {
        let attrs = itemIndex == index ? theme.highlightedAttrs : theme.attrs
        let candidateLine = candidateLines[itemIndex]
        let line = NSMutableAttributedString(
          attributedString: candidateLine.attributedString)

        let paragraphStyleCandidate = NSMutableParagraphStyle()
        paragraphStyleCandidate.setParagraphStyle(
          isFirstCandidate ? theme.firstParagraphStyle : theme.paragraphStyle)
        if usesInlineLayout {
          paragraphStyleCandidate.paragraphSpacingBefore -= detailGeometry.spacing
          paragraphStyleCandidate.lineSpacing = detailGeometry.spacing
        }
        if let gridColumns {
          paragraphStyleCandidate.tabStops = gridColumns.leadingOffsets.dropFirst().map {
            NSTextTab(textAlignment: .left, location: $0, options: [:])
          }
        }
        if !isFirstCandidate {
          let separator = column == 0
            ? "\n" : usesGridLayout ? "\t" : LinnetCandidatePresentation.inlineCandidateSeparator
          var separatorAttributes = attrs
          separatorAttributes[.paragraphStyle] = paragraphStyleCandidate
          text.append(NSAttributedString(
            string: separator, attributes: separatorAttributes))
        }
        if !usesInlineLayout, candidateLine.labelPrefix.length > 0 {
          paragraphStyleCandidate.headIndent = candidateLine.labelPrefix.boundingRect(
            with: .zero, options: [.usesLineFragmentOrigin]).width
        }
        line.addAttribute(
          .paragraphStyle,
          value: paragraphStyleCandidate,
          range: NSRange(location: 0, length: line.length))

        candidateRanges[itemIndex] = NSRange(location: text.length, length: line.length)
        text.append(line)
        isFirstCandidate = false
      }
    }

    // text done!
    guard publicationIsCurrent(currentPublication) else { return false }
    view.textView.textContentStorage?.attributedString = text
    view.publishSidecarDetail(selectedDetail)
    guard publicationIsCurrent(currentPublication) else { return false }
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.detailTextView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    guard publicationIsCurrent(currentPublication) else { return false }
    let controlMode: LinnetCandidatePresentation.CandidateControlMode =
      theme.candidateExpansionAllowed && (candidates.canExpand || candidates.isExpanded)
      ? .disclosure(expanded: candidates.isExpanded)
      : .paging(
        canPageUp: candidates.currentPage > 0,
        canPageDown: !candidates.isLastPage)
    view.drawView(
      candidateRanges: candidateRanges, detailRange: detailRange,
      hilightedIndex: index, preeditRange: preeditRange,
      highlightedPreeditRange: highlightedPreeditRange,
      controlMode: controlMode,
      usesGridLayout: usesGridLayout)
    guard publicationIsCurrent(currentPublication) else { return false }
    guard show(publication: currentPublication) else { return false }
    view.displayIfNeeded()
    guard publicationIsCurrent(currentPublication), let inputController else {
      return false
    }
    let publishedController = inputController
    let publishedGeneration = currentPublication
    candidateAccessibility.publish(
      parent: view,
      publication: .init(
        geometry: view.candidateAccessibilityGeometry(),
        candidates: candidates.items,
        highlightedIndex: index,
        controlMode: controlMode,
        shouldAnnounce: update),
      selectCandidate: { [weak self, weak publishedController] absoluteIndex in
        guard let self, let publishedController else { return false }
        guard publicationIsCurrent(publishedGeneration) else { return false }
        return publishedController.selectCandidate(absoluteIndex: absoluteIndex)
      },
      performControl: { [weak self] action in
        guard let self else { return false }
        guard publicationIsCurrent(publishedGeneration) else { return false }
        return performControl(action)
      }
    )
    return publicationIsCurrent(currentPublication)
  }

  func updateStatus(
    long longMessage: String,
    short shortMessage: String,
    controller: SquirrelInputController
  ) {
    guard inputController === controller else { return }
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  /// Resolves appearance from the current text client at the last responsible
  /// InputMethodKit boundary. No value is cached across clients; unsupported
  /// or malformed optional capability results follow macOS instead.
  func updateAppearance(client: (any NSObjectProtocol)?) {
    let resolution = LinnetClientAppearance.resolve(
      client: client,
      systemAppearance: NSApp.effectiveAppearance
    )
    resolvedAppearance = resolution.appearance
    view.applyClientAppearance(isDark: resolution.isDark)
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }

  /// Updates the caret rectangle the panel follows. A degenerate rectangle
  /// falls back to the last usable one, or to the main screen's visible
  /// center before any usable position was seen.
  func updatePosition(_ candidate: NSRect) {
    if Self.positionIsUsable(candidate) {
      position = candidate
      lastUsablePosition = candidate
    } else if let lastUsablePosition {
      position = lastUsablePosition
    } else if let visibleFrame = NSScreen.main?.visibleFrame {
      position = NSRect(
        origin: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY), size: .zero)
    }
  }

  /// Reuses themes already built for a schema while the base configuration
  /// is unchanged. Returns false when the schema has no cached themes yet.
  func applyCachedThemes(for schemaID: String) -> Bool {
    guard let cached = themeCache[schemaID] else { return false }
    view.lightTheme = cached.light
    view.darkTheme = cached.dark
    return true
  }

  func cacheThemes(for schemaID: String) {
    themeCache[schemaID] = (view.lightTheme, view.darkTheme)
  }

  /// The base configuration was reloaded; themes built from it are stale.
  func resetThemeCache() {
    themeCache.removeAll()
  }
}
