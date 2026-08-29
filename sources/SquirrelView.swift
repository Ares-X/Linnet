//
//  SquirrelView.swift
//  Squirrel
//
//  Created by Leo Liu on 5/9/24.
//

import AppKit

private class SquirrelLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation, hyphenating: Bool) -> Bool {
    let index = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location)
    guard let attributedString = textLayoutManager.textContainer?.textView?.textContentStorage?.attributedString,
      LinnetPanelGeometry.containsTextAttributeIndex(index, attributedLength: attributedString.length)
    else { return true }
    let attributes = attributedString.attributes(at: index, effectiveRange: nil)
    if let noBreak = attributes[.noBreak] as? Bool, noBreak { return false }
    return true
  }
}

extension NSAttributedString.Key { static let noBreak = NSAttributedString.Key("noBreak") }

final class SquirrelView: NSView {
  static let controlPointerFeedbackLayerName = "linnetCandidateControlPointerFeedback"

  enum CandidateHit: Equatable {
    case none
    case candidate(Int)
    case control(LinnetCandidatePresentation.CandidateControlAction)
  }

  let textView: NSTextView
  let detailTextView: NSTextView
  let detailDividerView: NSView

  private let squirrelLayoutDelegate: SquirrelLayoutDelegate
  var candidateRanges: [NSRange] = []
  var detailRange: NSRange = .empty
  var hilightedIndex = 0
  var preeditRange: NSRange = .empty
  var canPageUp: Bool = false
  var canPageDown: Bool = false
  private var controlMode: LinnetCandidatePresentation.CandidateControlMode = .paging(canPageUp: false, canPageDown: false)
  var usesGridLayout = false
  var highlightedPreeditRange: NSRange = .empty
  var separatorWidth: CGFloat = 0
  var shape = LinnetCandidatePointerPresentation()
  var pointerControlAction: LinnetCandidatePresentation.CandidateControlAction?
  var pointerControlIsPressed = false
  private(set) var pagingLayout = LinnetPanelGeometry.PagingLayout.none
  private(set) var candidateInteractionFrames: [NSRect] = []
  private var candidateInteractionPaths: [CGPath?] = []
  private var presentationMetrics: LinnetPanelGeometry.PresentationMetrics?
  private var candidateColumnWidth: CGFloat?
  private var pointerTrackingArea: NSTrackingArea?

  var lightTheme = SquirrelTheme()
  var darkTheme = SquirrelTheme()
  private var clientIsDark = false
  var currentTheme: SquirrelTheme { if clientIsDark && darkTheme.available { darkTheme } else { lightTheme } }

  override init(frame frameRect: NSRect) {
    squirrelLayoutDelegate = SquirrelLayoutDelegate()
    textView = NSTextView(frame: frameRect)
    detailTextView = NSTextView(frame: .zero)
    detailDividerView = NSView(frame: .zero)
    textView.drawsBackground = false
    textView.isEditable = false
    textView.isSelectable = false
    textView.textLayoutManager?.delegate = squirrelLayoutDelegate
    detailTextView.drawsBackground = false
    detailTextView.isEditable = false
    detailTextView.isSelectable = false
    detailTextView.isHidden = true
    detailDividerView.isHidden = true
    detailDividerView.wantsLayer = true
    super.init(frame: frameRect)
    textView.textContainer?.lineFragmentPadding = 0
    detailTextView.textContainer?.lineFragmentPadding = 0
    detailTextView.textContainerInset = .zero
    detailTextView.setAccessibilityElement(false)
    detailDividerView.setAccessibilityElement(false)
    self.wantsLayer = true
    self.layer?.masksToBounds = true
  }
  required init?(coder: NSCoder) {
    // The candidate view is programmatic-only; fail closed if a decoder tries
    // to construct it without the required text/layout state.
    return nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
    let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil)
    addTrackingArea(area)
    pointerTrackingArea = area
  }

  override var isFlipped: Bool { true }

  // Will trigger draw(_:) after candidate text and interaction geometry change.
  func drawView(
    candidateRanges: [NSRange], detailRange: NSRange, hilightedIndex: Int, preeditRange: NSRange, highlightedPreeditRange: NSRange,
    controlMode: LinnetCandidatePresentation.CandidateControlMode, usesGridLayout: Bool
  ) {
    self.candidateRanges = candidateRanges
    self.detailRange = detailRange
    self.hilightedIndex = hilightedIndex
    self.preeditRange = preeditRange
    self.highlightedPreeditRange = highlightedPreeditRange
    self.controlMode = controlMode
    self.usesGridLayout = usesGridLayout
    candidateInteractionFrames = []
    candidateInteractionPaths = []
    switch controlMode {
    case .paging(let canPageUp, let canPageDown):
      self.canPageUp = canPageUp
      self.canPageDown = canPageDown
    case .disclosure(let expanded):
      self.canPageUp = expanded
      self.canPageDown = !expanded
    }
    self.needsDisplay = true
  }

  // All drawing is projected from the current candidate publication.
  // swiftlint:disable:next cyclomatic_complexity
  override func draw(_ dirtyRect: NSRect) {
    guard let presentationMetrics else { return }
    var preeditPath: CGPath?
    var candidatePaths: CGMutablePath?
    var highlightedPath: CGMutablePath?
    var highlightedPreeditPath: CGMutablePath?
    let theme = currentTheme

    let contentFrame = LinnetPanelGeometry.pagingLayout(configuration: presentationMetrics.paging, in: bounds, preferredAxisCenter: .nan, vertical: presentationMetrics.vertical)
      .contentFrame
    var containingRect = NSRect(origin: .zero, size: contentFrame.size)
    let contentBackgroundRect = containingRect
    let panelBackgroundRect = NSRect(x: -contentFrame.minX, y: 0, width: bounds.width, height: bounds.height)
    candidateInteractionFrames = []
    candidateInteractionPaths = []
    shape.beginDrawing()

    // Draw preedit Rect
    var preeditRect = NSRect.zero
    if preeditRange.length > 0, let preeditTextRange = convert(range: preeditRange) {
      preeditRect = contentRect(range: preeditTextRange)
      preeditRect.size.width = contentBackgroundRect.size.width
      preeditRect.size.height += theme.edgeInset.height + theme.preeditLinespace / 2 + theme.linespace / 2
      preeditRect.origin = contentBackgroundRect.origin
      if candidateRanges.count == 0 { preeditRect.size.height += theme.edgeInset.height - theme.preeditLinespace / 2 - theme.linespace / 2 }
      containingRect.size.height -= preeditRect.size.height
      containingRect.origin.y += preeditRect.size.height
      if theme.preeditBackgroundColor != nil { preeditPath = drawSmoothLines(rectVertex(of: preeditRect), straightCorner: Set(), alpha: 0, beta: 0) }
    }

    var candidateBackgroundRect = contentBackgroundRect
    var candidateContainingRect = containingRect
    if let candidateColumnWidth {
      candidateBackgroundRect.size.width = min(
        candidateBackgroundRect.width, candidateColumnWidth)
      candidateContainingRect.size.width = min(
        candidateContainingRect.width, candidateColumnWidth)
    }
    containingRect = carveInset(rect: containingRect)
    candidateContainingRect = carveInset(rect: candidateContainingRect)
    // Draw candidate Rects
    if presentationMetrics.role == .candidate {
      for i in 0..<candidateRanges.count {
        let candidate = candidateRanges[i]
        let cellPath = candidate.length > 0
          ? drawPath(
            highlightedRange: candidate,
            context: CandidatePathContext(
              backgroundRect: candidateBackgroundRect,
              preeditRect: preeditRect,
              containingRect: candidateContainingRect,
              extraExpansion: 0, usesSelectionStyle: false))
          : nil
        var interactionTransform = CGAffineTransform(translationX: contentFrame.minX, y: 0)
        candidateInteractionPaths.append(cellPath?.copy(using: &interactionTransform))
        if let candidateFrame = shape.capture(cellPath, candidateIndex: i, horizontalOffset: contentFrame.minX, bounds: bounds) {
          candidateInteractionFrames.append(candidateFrame)
        } else {
          candidateInteractionFrames.append(.zero)
        }
        if i == hilightedIndex {
          // Draw highlighted Rect
          if candidate.length > 0 && theme.highlightedBackColor != nil {
            highlightedPath = (theme.selectionStyle == .tile
              ? cellPath
              : drawPath(
                highlightedRange: candidate,
                context: CandidatePathContext(
                  backgroundRect: candidateBackgroundRect,
                  preeditRect: preeditRect,
                  containingRect: candidateContainingRect,
                  extraExpansion: 0, usesSelectionStyle: true)))?.mutableCopy()
          }
        } else {
          // Draw other highlighted Rect
          if candidate.length > 0 && theme.candidateBackColor != nil {
            let candidatePath = drawPath(
              highlightedRange: candidate,
              context: CandidatePathContext(
                backgroundRect: candidateBackgroundRect,
                preeditRect: preeditRect,
                containingRect: candidateContainingRect,
                extraExpansion: theme.surroundingExtraExpansion, usesSelectionStyle: false))
            if candidatePaths == nil { candidatePaths = CGMutablePath() }
            if let candidatePath = candidatePath { candidatePaths?.addPath(candidatePath) }
          }
        }
      }
    }

    // Draw highlighted part of preedit text
    if (highlightedPreeditRange.length > 0) && (theme.highlightedPreeditColor != nil), let highlightedPreeditTextRange = convert(range: highlightedPreeditRange) {
      var innerBox = preeditRect
      innerBox.size.width -= (theme.edgeInset.width + 1) * 2
      innerBox.origin.x += theme.edgeInset.width + 1
      innerBox.origin.y += theme.edgeInset.height + 1
      if candidateRanges.count == 0 {
        innerBox.size.height -= (theme.edgeInset.height + 1) * 2
      } else {
        innerBox.size.height -= theme.edgeInset.height + theme.preeditLinespace / 2 + theme.linespace / 2 + 2
      }
      var outerBox = preeditRect
      outerBox.size.height -= max(0, theme.hilitedCornerRadius + theme.borderLineWidth)
      outerBox.size.width -= max(0, theme.hilitedCornerRadius + theme.borderLineWidth)
      outerBox.origin.x += max(0, theme.hilitedCornerRadius + theme.borderLineWidth) / 2
      outerBox.origin.y += max(0, theme.hilitedCornerRadius + theme.borderLineWidth) / 2

      let (leadingRect, bodyRect, trailingRect) = multilineRects(forRange: highlightedPreeditTextRange, extraSurounding: 0, bounds: outerBox)
      var (highlightedPoints, highlightedPoints2, rightCorners, rightCorners2) = linearMultilineFor(body: bodyRect, leading: leadingRect, trailing: trailingRect)

      containingRect = carveInset(rect: preeditRect)
      highlightedPoints = expand(vertex: highlightedPoints, innerBorder: innerBox, outerBorder: outerBox)
      rightCorners = removeCorner(highlightedPoints: highlightedPoints, rightCorners: rightCorners, containingRect: containingRect)
      highlightedPreeditPath = drawSmoothLines(highlightedPoints, straightCorner: rightCorners, alpha: 0.3 * theme.hilitedCornerRadius, beta: 1.4 * theme.hilitedCornerRadius)?
        .mutableCopy()
      if highlightedPoints2.count > 0 {
        highlightedPoints2 = expand(vertex: highlightedPoints2, innerBorder: innerBox, outerBorder: outerBox)
        rightCorners2 = removeCorner(highlightedPoints: highlightedPoints2, rightCorners: rightCorners2, containingRect: containingRect)
        let highlightedPreeditPath2 = drawSmoothLines(
          highlightedPoints2, straightCorner: rightCorners2, alpha: 0.3 * theme.hilitedCornerRadius, beta: 1.4 * theme.hilitedCornerRadius)
        if let highlightedPreeditPath2 = highlightedPreeditPath2 { highlightedPreeditPath?.addPath(highlightedPreeditPath2) }
      }
    }

    NSBezierPath.defaultLineWidth = 0
    guard
      let backgroundPath = drawSmoothLines(
        rectVertex(of: panelBackgroundRect), straightCorner: Set(), alpha: 0.3 * presentationMetrics.cornerRadius, beta: 1.4 * presentationMetrics.cornerRadius)
    else { return }

    self.layer?.sublayers = nil
    guard let backPath = backgroundPath.mutableCopy() else { return }
    if let path = preeditPath { backPath.addPath(path) }
    if theme.mutualExclusive {
      if let path = highlightedPath { backPath.addPath(path) }
      if let path = candidatePaths { backPath.addPath(path) }
    }
    let panelLayer = shapeFromPath(path: backPath)
    panelLayer.fillColor = theme.backgroundColor.cgColor
    let panelLayerMask = shapeFromPath(path: backgroundPath)
    panelLayer.mask = panelLayerMask
    self.layer?.addSublayer(panelLayer)

    // Fill in colors
    if let color = theme.preeditBackgroundColor, let path = preeditPath {
      let layer = shapeFromPath(path: path)
      layer.fillColor = color.cgColor
      guard let maskPath = backgroundPath.mutableCopy() else { return }
      if theme.mutualExclusive, let hilitedPath = highlightedPreeditPath { maskPath.addPath(hilitedPath) }
      let mask = shapeFromPath(path: maskPath)
      layer.mask = mask
      panelLayer.addSublayer(layer)
    }
    if theme.borderLineWidth > 0, let color = theme.borderColor {
      let borderLayer = shapeFromPath(path: backgroundPath)
      borderLayer.lineWidth = theme.borderLineWidth * 2
      borderLayer.strokeColor = color.cgColor
      borderLayer.fillColor = nil
      panelLayer.addSublayer(borderLayer)
    }
    if let color = theme.highlightedPreeditColor, let path = highlightedPreeditPath {
      let layer = shapeFromPath(path: path)
      layer.fillColor = color.cgColor
      panelLayer.addSublayer(layer)
    }
    if let color = theme.candidateBackColor, let path = candidatePaths {
      let layer = shapeFromPath(path: path)
      layer.fillColor = color.cgColor
      panelLayer.addSublayer(layer)
    }
    if let color = theme.highlightedBackColor, let path = highlightedPath {
      let layer = shapeFromPath(path: path)
      layer.fillColor = color.cgColor
      if theme.shadowSize > 0 {
        let shadowLayer = CAShapeLayer()
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOffset = NSSize(width: theme.shadowSize / 2, height: (theme.vertical ? -1 : 1) * theme.shadowSize / 2)
        shadowLayer.shadowPath = highlightedPath
        shadowLayer.shadowRadius = theme.shadowSize
        shadowLayer.shadowOpacity = 0.2
        guard let outerPath = backgroundPath.mutableCopy() else { return }
        outerPath.addPath(path)
        let shadowLayerMask = shapeFromPath(path: outerPath)
        shadowLayer.mask = shadowLayerMask
        layer.strokeColor = NSColor.black.withAlphaComponent(0.15).cgColor
        layer.lineWidth = 0.5
        layer.addSublayer(shadowLayer)
      }
      panelLayer.addSublayer(layer)
    }
    shape.render(in: panelLayer)
    panelLayer.setAffineTransform(CGAffineTransform(translationX: contentFrame.minX, y: 0))
    let panelPath = CGMutablePath()
    panelPath.addPath(backgroundPath, transform: panelLayer.affineTransform().scaledBy(x: 1, y: -1).translatedBy(x: 0, y: -self.bounds.height))

    let pagingDrawing = pagingLayer(theme: theme, metrics: presentationMetrics, preeditRect: preeditRect)
    self.pagingLayout = pagingDrawing.layout
    if let feedbackLayer = controlPointerFeedbackLayer(theme: theme) { self.layer?.addSublayer(feedbackLayer) }
    if let sublayers = pagingDrawing.layer.sublayers, !sublayers.isEmpty { self.layer?.addSublayer(pagingDrawing.layer) }
    let flipTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -self.bounds.height)
    if let downPath = pagingDrawing.downPath { panelPath.addPath(downPath, transform: flipTransform) }
    if let upPath = pagingDrawing.upPath { panelPath.addPath(upPath, transform: flipTransform) }

    shape.path = panelPath
  }

}

extension SquirrelView {
  /// The panel and its drawing surface consume one role-specific geometry
  /// projection. Keeping this state in the view prevents candidate paging or
  /// corner metrics from reappearing inside a compact status notice.
  func applyPresentationMetrics(_ metrics: LinnetPanelGeometry.PresentationMetrics) {
    presentationMetrics = metrics
  }

  func applyClientAppearance(isDark: Bool) { clientIsDark = isDark }

  func convert(range: NSRange) -> NSTextRange? {
    guard range != .empty, let textLayoutManager = textView.textLayoutManager else { return nil }
    guard let startLocation = textLayoutManager.location(textLayoutManager.documentRange.location, offsetBy: range.location) else { return nil }
    guard let endLocation = textLayoutManager.location(startLocation, offsetBy: range.length) else { return nil }
    return NSTextRange(location: startLocation, end: endLocation)
  }

  // Get the rectangle containing entire contents, expensive to calculate
  var contentRect: NSRect {
    var ranges = candidateRanges
    if detailRange.length > 0 { ranges.append(detailRange) }
    if preeditRange.length > 0 { ranges.append(preeditRange) }
    return contentRect(ranges: ranges)
  }

  private func contentRect(ranges: [NSRange]) -> NSRect {
    var unionRect: NSRect?
    for range in ranges {
      if let textRange = convert(range: range) {
        let rect = contentRect(range: textRange)
        unionRect = LinnetPanelGeometry.union(unionRect, withFiniteLayoutRect: rect)
      }
    }
    return unionRect ?? .zero
  }

  // Get the rectangle containing the range of text, will first convert to glyph range, expensive to calculate
  func contentRect(range: NSTextRange) -> NSRect {
    guard let textLayoutManager = textView.textLayoutManager else { return .zero }
    var unionRect: NSRect?
    textLayoutManager.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
      unionRect = LinnetPanelGeometry.union(unionRect, withFiniteLayoutRect: rect)
      return true
    }
    return unionRect ?? .zero
  }

  var detailContentRect: NSRect {
    guard !detailTextView.isHidden,
      let textLayoutManager = detailTextView.textLayoutManager,
      detailTextView.textContentStorage?.attributedString?.length ?? 0 > 0
    else { return .zero }
    var unionRect: NSRect?
    textLayoutManager.enumerateTextSegments(
      in: textLayoutManager.documentRange,
      type: .selection,
      options: [.rangeNotRequired]
    ) { _, rect, _, _ in
      unionRect = LinnetPanelGeometry.union(unionRect, withFiniteLayoutRect: rect)
      return true
    }
    return unionRect ?? .zero
  }

  func publishSidecarDetail(_ detail: NSAttributedString?) {
    detailTextView.textContentStorage?.attributedString = detail
      ?? NSAttributedString(string: "")
    let isEmpty = detail?.length ?? 0 == 0
    detailTextView.isHidden = isEmpty
    detailDividerView.isHidden = isEmpty
  }

  func applyCandidateColumnWidth(_ width: CGFloat?) {
    candidateColumnWidth = width
  }

  func click(at clickPoint: NSPoint) -> CandidateHit {
    guard presentationMetrics != nil else { return .none }
    if let nextPage = pagingLayout.nextPage, nextPage.cell.contains(clickPoint) {
      switch controlMode {
      case .paging: return .control(.pageDown)
      case .disclosure: return .control(.expand)
      }
    }
    if let previousPage = pagingLayout.previousPage, previousPage.cell.contains(clickPoint) {
      switch controlMode {
      case .paging: return .control(.pageUp)
      case .disclosure: return .control(.collapse)
      }
    }
    if let candidateIndex = Self.candidateIndex(at: clickPoint, paths: candidateInteractionPaths) { return .candidate(candidateIndex) }
    return .none
  }

  static func candidateIndex(at point: NSPoint, paths: [CGPath?]) -> Int? { paths.firstIndex { $0?.contains(point) == true } }

  func controlPointerFeedbackLayer(theme: SquirrelTheme) -> CAShapeLayer? {
    guard let action = pointerControlAction else { return nil }
    let control =
      switch action {
      case .pageUp, .collapse: pagingLayout.previousPage
      case .pageDown, .expand: pagingLayout.nextPage
      }
    guard let control else { return nil }
    let frame = control.cell.insetBy(dx: 1, dy: 1)
    guard frame.width > 0, frame.height > 0 else { return nil }
    let radius = min(theme.cornerRadius, min(frame.width, frame.height) / 3)
    let layer = CAShapeLayer()
    layer.name = Self.controlPointerFeedbackLayerName
    layer.path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    layer.fillColor = NSColor.labelColor.withAlphaComponent(pointerControlIsPressed ? 0.16 : 0.08).cgColor
    layer.strokeColor = NSColor.labelColor.withAlphaComponent(pointerControlIsPressed ? 0.28 : 0.16).cgColor
    layer.lineWidth = 0.5
    return layer
  }
}
