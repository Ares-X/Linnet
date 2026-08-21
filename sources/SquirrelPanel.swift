//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSVisualEffectView
  private let candidateAccessibility: LinnetCandidateAccessibility
  weak var inputController: SquirrelInputController? {
    didSet {
      if oldValue !== inputController {
        candidateExpansionRequested = false
      }
    }
  }

  private(set) var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  // Last caret rectangle accepted as usable; degenerate client responses
  // (e.g. Spotlight reports a zero rectangle) must not teleport the panel
  // to the screen corner.
  private var lastUsablePosition: NSRect?
  // Themes already built per schema, valid until the base configuration is
  // reloaded (resetThemeCache). Shift toggling would otherwise re-read the
  // schema YAML and rebuild both appearances on every tap.
  private var themeCache: [String: (light: SquirrelTheme, dark: SquirrelTheme)] = [:]

  private var statusMessage: String = ""
  private var statusTimer: Timer?
  private var presentationRole: LinnetPanelGeometry.PresentationRole = .candidate
  private var resolvedAppearance = NSAppearance(named: .aqua)!

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidateSnapshot: SquirrelInputController.CandidateSnapshot?
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var pressedHit: SquirrelView.Hit?
  private(set) var candidateExpansionRequested = false

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

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let hit = view.click(at: mousePosition(for: event))
      pressedHit = hit
      if case .candidate(let index) = hit,
        let candidateSnapshot,
        candidateSnapshot.items.indices.contains(index) {
        self.index = index
      }
    case .leftMouseUp:
      let hit = view.click(at: mousePosition(for: event))
      if case .preedit(let preeditIndex) = hit,
        preeditIndex >= 0, preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if hit == pressedHit {
        switch hit {
        case .candidate(let itemIndex):
          if itemIndex == index,
            let candidateSnapshot,
            candidateSnapshot.items.indices.contains(itemIndex) {
            _ = inputController?.selectCandidate(
              absoluteIndex: candidateSnapshot.items[itemIndex].absoluteIndex)
          }
        case .control(let action):
          _ = performControl(action)
        case .preedit, .none:
          break
        }
      }
      pressedHit = nil
    case .mouseExited:
      if cursorIndex != index, let candidateSnapshot {
        update(
          preedit: preedit, selRange: selRange, caretPos: caretPos,
          candidates: candidateSnapshot, highlighted: index, update: false)
      }
      pressedHit = nil
    case .mouseMoved:
      if case .candidate(let itemIndex) = view.click(at: mousePosition(for: event)),
        cursorIndex != itemIndex,
        let candidateSnapshot,
        candidateSnapshot.items.indices.contains(itemIndex) {
        update(
          preedit: preedit, selRange: selRange, caretPos: caretPos,
          candidates: candidateSnapshot, highlighted: itemIndex, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
        // Scrollboard span
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
        // Mouse scroll wheel
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    candidateExpansionRequested = false
    candidateSnapshot = nil
    pressedHit = nil
    candidateAccessibility.clear(parent: view)
    orderOut(nil)
    maxHeight = 0
  }

  /// Rebuilds the visible candidate window from the last accepted Rime
  /// snapshot after its themes have been reloaded. No new candidate state is
  /// inferred here; the next Rime update remains the only data owner.
  func refreshAppearance() {
    guard isVisible,
      let candidateSnapshot,
      !candidateSnapshot.items.isEmpty || !preedit.isEmpty
    else { return }
    updateAppearance(client: inputController?.client() as? NSObjectProtocol)
    update(
      preedit: preedit,
      selRange: selRange,
      caretPos: caretPos,
      candidates: candidateSnapshot,
      highlighted: index,
      update: false
    )
  }

  func performControl(
    _ action: LinnetCandidatePresentation.CandidateControlAction
  ) -> Bool {
    switch action {
    case .pageUp:
      return inputController?.page(up: true) ?? false
    case .pageDown:
      return inputController?.page(up: false) ?? false
    case .expand:
      guard view.currentTheme.candidateExpansionAllowed,
        candidateSnapshot?.canExpand == true,
        !candidateExpansionRequested
      else { return false }
      candidateExpansionRequested = true
      inputController?.refreshCandidatePresentation()
      return true
    case .collapse:
      guard candidateExpansionRequested else { return false }
      candidateExpansionRequested = false
      inputController?.refreshCandidatePresentation()
      return true
    }
  }

  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(
    preedit: String,
    selRange: NSRange,
    caretPos: Int,
    candidates: SquirrelInputController.CandidateSnapshot,
    highlighted index: Int,
    update: Bool
  ) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      candidateSnapshot = candidates
      candidateExpansionRequested = candidates.isExpanded
      self.index = index
    }
    cursorIndex = index

    if !candidates.items.isEmpty || !preedit.isEmpty {
      presentationRole = .candidate
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
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
      forLinearLayout: linear)
    let selectedDetail = usesInlineComments
      ? nil : selectedDetail(theme: theme, candidates: candidates.items, highlighted: index)
    var detailRange = NSRange.empty

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
    var isFirstCandidate = true
    for row in visualRows {
      for (column, itemIndex) in row.enumerated() {
        let item = candidates.items[itemIndex]
        let attrs = itemIndex == index ? theme.highlightedAttrs : theme.attrs
        let labelAttrs = itemIndex == index ? theme.labelHighlightedAttrs : theme.labelAttrs
        let commentAttrs = itemIndex == index ? theme.commentHighlightedAttrs : theme.commentAttrs
        let label = theme.candidateFormat.contains(/\[label\]/)
          ? item.selectionLabel ?? "" : ""
        let displayedComment = usesInlineComments
          ? item.comment : ""
        let candidateLine = LinnetCandidatePresentation.candidateLine(
          candidateFormat: theme.candidateFormat,
          label: label,
          candidate: item.text,
          comment: displayedComment,
          candidateAttributes: attrs,
          labelAttributes: labelAttrs,
          commentAttributes: commentAttrs)
        let line = NSMutableAttributedString(
          attributedString: candidateLine.attributedString)

        if !isFirstCandidate {
          let separator = column == 0
            ? "\n" : LinnetCandidatePresentation.inlineCandidateSeparator
          text.append(NSAttributedString(string: separator, attributes: attrs))
        }

        let paragraphStyleCandidate = NSMutableParagraphStyle()
        paragraphStyleCandidate.setParagraphStyle(
          isFirstCandidate ? theme.firstParagraphStyle : theme.paragraphStyle)
        if usesInlineLayout {
          paragraphStyleCandidate.paragraphSpacingBefore -= detailGeometry.spacing
          paragraphStyleCandidate.lineSpacing = detailGeometry.spacing
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

    if let selectedDetail {
      switch detailGeometry.placement {
      case .footer:
        text.append(NSAttributedString(
          string: detailGeometry.textSeparator,
          attributes: theme.detailAttrs))
        detailRange = NSRange(location: text.length, length: selectedDetail.length)
        text.append(selectedDetail)
      case .sidecar:
        if let sidecarRow = visualRows.first(where: { $0.contains(index) }),
          let rowStartIndex = sidecarRow.first,
          let anchorIndex = sidecarRow.last {
          detailRange = attachSidecar(
            selectedDetail, to: text, candidateRanges: &candidateRanges,
            rowStartIndex: rowStartIndex,
            anchorIndex: anchorIndex,
            detailGeometry: detailGeometry,
            theme: theme)
        }
      }
    }

    // text done!
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
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
    show()
    view.displayIfNeeded()
    candidateAccessibility.publish(
      parent: view,
      geometry: view.candidateAccessibilityGeometry(),
      candidates: candidates.items,
      highlightedIndex: index,
      controlMode: controlMode,
      shouldAnnounce: update,
      selectCandidate: { [weak self] absoluteIndex in
        guard let self else { return false }
        return inputController?.selectCandidate(absoluteIndex: absoluteIndex) ?? false
      },
      performControl: { [weak self] action in
        guard let self else { return false }
        return performControl(action)
      }
    )
  }

}

extension SquirrelPanel {
  func updateStatus(long longMessage: String, short shortMessage: String) {
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

private extension SquirrelPanel {
  /// A caret rectangle is usable only when it is not degenerate and its
  /// origin lies on a connected screen.
  static func positionIsUsable(_ rect: NSRect) -> Bool {
    guard rect != .zero else { return false }
    return NSScreen.screens.contains { $0.frame.contains(rect.origin) }
  }

  func mousePosition(for event: NSEvent) -> NSPoint {
    view.convert(event.locationInWindow, from: nil)
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
  func show() {
    updateUsableScreenRect()
    let theme = view.currentTheme
    let materialAppearance = LinnetClientAppearance.resolveMaterial(
      mode: theme.materialAppearance,
      automaticAppearance: resolvedAppearance
    )
    let metrics = presentationMetrics(theme: theme)
    view.applyPresentationMetrics(metrics)
    guard let textContainer = view.textContainer,
      let textLayoutManager = view.textLayoutManager
    else {
      orderOut(nil)
      return
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
    view.textView.scrollToBeginningOfDocument(nil)

    var panelRect = NSRect.zero
    // in vertical mode, the width and height are interchanged
    var contentRect = view.contentRect
    let relativeCaretY = LinnetPanelGeometry.relativeVerticalPosition(
      caret: position,
      screen: screenRect
    ) ?? 0.5
    if theme.memorizeSize && (metrics.vertical && relativeCaretY < 0.5) ||
        (metrics.vertical && position.minX + max(contentRect.width, maxHeight) + metrics.edgeInset.width * 2 > screenRect.maxX) {
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
          contentRect.width + metrics.edgeInset.width * 2
        ) + metrics.paging.stripWidth
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
          contentRect.width + metrics.edgeInset.width * 2
        ) + metrics.paging.stripWidth,
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
    self.setFrame(panelRect, display: true)

    // rotate the view, the core in vertical mode!
    guard let contentView else {
      orderOut(nil)
      return
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
    orderFrontRegardless()
    // voila!
  }

  func show(status message: String) {
    let theme = view.currentTheme
    presentationRole = .status
    let text = NSMutableAttributedString(
      string: message, attributes: theme.statusAttrs)
    text.addAttribute(
      .paragraphStyle, value: theme.statusParagraphStyle,
      range: NSRange(location: 0, length: text.length))
    guard let textContentStorage = view.textContentStorage else {
      orderOut(nil)
      return
    }
    textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(.horizontal)
    view.drawView(
      candidateRanges: [NSRange(location: 0, length: text.length)], detailRange: .empty,
      hilightedIndex: -1, preeditRange: .empty, highlightedPreeditRange: .empty,
      controlMode: .paging(canPageUp: false, canPageDown: false),
      usesGridLayout: false)
    show()
    candidateAccessibility.publishStatus(parent: view, message: message)

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
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
    rowStartIndex: Int,
    anchorIndex: Int,
    detailGeometry: LinnetCandidatePresentation.CandidateDetailGeometry,
    theme: SquirrelTheme
  ) -> NSRange {
    let divider = NSMutableAttributedString(
      string: detailGeometry.textSeparator,
      attributes: theme.detailAttrs)
    divider.append(detail)
    guard let insertion = LinnetCandidatePresentation.sidecarInsertion(
      candidateRanges: candidateRanges,
      anchorIndex: anchorIndex,
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
    guard candidateRanges.indices.contains(rowStartIndex) else { return .empty }
    let rowStart = candidateRanges[rowStartIndex]
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
