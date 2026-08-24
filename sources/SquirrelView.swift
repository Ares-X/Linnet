//
//  SquirrelView.swift
//  Squirrel
//
//  Created by Leo Liu on 5/9/24.
//

import AppKit

#sourceLocation(file: "CandidateView.swift", line: 10)
private class SquirrelLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation, hyphenating: Bool) -> Bool {
    let index = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location)
    guard let attributedString = textLayoutManager.textContainer?.textView?.textContentStorage?.attributedString,
          LinnetPanelGeometry.containsTextAttributeIndex(index, attributedLength: attributedString.length)
    else {
      return true
    }
    let attributes = attributedString.attributes(at: index, effectiveRange: nil)
    if let noBreak = attributes[.noBreak] as? Bool, noBreak {
      return false
    }
    return true
  }
}

extension NSAttributedString.Key {
  static let noBreak = NSAttributedString.Key("noBreak")
}

final class SquirrelView: NSView {
  enum HitTarget: Equatable {
    case none
    case candidate(Int)
    case preedit(Int)
    case control(LinnetCandidatePresentation.CandidateControlAction)
  }

  struct PagingLayerResult {
    let layer: CAShapeLayer
    let layout: LinnetPanelGeometry.PagingLayout
    let nextPath: CGPath?
    let previousPath: CGPath?

    static func empty(layer: CAShapeLayer) -> PagingLayerResult {
      .init(layer: layer, layout: .none, nextPath: nil, previousPath: nil)
    }
  }

  let textView: NSTextView

  private let squirrelLayoutDelegate: SquirrelLayoutDelegate
  var candidateRanges: [NSRange] = []
  var detailRange: NSRange = .empty
  var hilightedIndex = 0
  var preeditRange: NSRange = .empty
  var canPageUp: Bool = false
  var canPageDown: Bool = false
  private var controlMode: LinnetCandidatePresentation.CandidateControlMode =
    .paging(canPageUp: false, canPageDown: false)
  private var usesGridLayout = false
  var highlightedPreeditRange: NSRange = .empty
  var separatorWidth: CGFloat = 0
  var shape = CAShapeLayer()
  private(set) var pagingLayout = LinnetPanelGeometry.PagingLayout.none
  private(set) var candidateInteractionFrames: [NSRect] = []
  private var presentationMetrics: LinnetPanelGeometry.PresentationMetrics?
  private var pointerTrackingArea: NSTrackingArea?

  var lightTheme = SquirrelTheme()
  var darkTheme = SquirrelTheme()
  private var clientIsDark = false
  var currentTheme: SquirrelTheme {
    if clientIsDark && darkTheme.available { darkTheme } else { lightTheme }
  }
  var textLayoutManager: NSTextLayoutManager? { textView.textLayoutManager }
  var textContentStorage: NSTextContentStorage? { textView.textContentStorage }
  var textContainer: NSTextContainer? { textLayoutManager?.textContainer }

  /// The panel and its drawing surface consume one role-specific geometry
  /// projection. Keeping this state in the view prevents candidate paging or
  /// corner metrics from reappearing inside a compact status notice.
  func applyPresentationMetrics(
    _ metrics: LinnetPanelGeometry.PresentationMetrics
  ) {
    presentationMetrics = metrics
  }

  override init(frame frameRect: NSRect) {
    squirrelLayoutDelegate = SquirrelLayoutDelegate()
    textView = NSTextView(frame: frameRect)
    textView.drawsBackground = false
    textView.isEditable = false
    textView.isSelectable = false
    textView.textLayoutManager?.delegate = squirrelLayoutDelegate
    super.init(frame: frameRect)
    textContainer?.lineFragmentPadding = 0
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
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways],
      owner: self,
      userInfo: nil)
    addTrackingArea(area)
    pointerTrackingArea = area
  }

  override var isFlipped: Bool {
    true
  }
  func applyClientAppearance(isDark: Bool) {
    clientIsDark = isDark
  }

  func convert(range: NSRange) -> NSTextRange? {
    guard range != .empty, let textLayoutManager else { return nil }
    guard let startLocation = textLayoutManager.location(textLayoutManager.documentRange.location, offsetBy: range.location) else { return nil }
    guard let endLocation = textLayoutManager.location(startLocation, offsetBy: range.length) else { return nil }
    return NSTextRange(location: startLocation, end: endLocation)
  }

  // Get the rectangle containing entire contents, expensive to calculate
  var contentRect: NSRect {
    var ranges = candidateRanges
    if detailRange.length > 0 {
      ranges.append(detailRange)
    }
    if preeditRange.length > 0 {
      ranges.append(preeditRange)
    }
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
    guard let textLayoutManager else { return .zero }
    var unionRect: NSRect?
    textLayoutManager.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
      unionRect = LinnetPanelGeometry.union(unionRect, withFiniteLayoutRect: rect)
      return true
    }
    return unionRect ?? .zero
  }

  // Will triger - (void)drawRect:(NSRect)dirtyRect
  func drawView(
    candidateRanges: [NSRange], detailRange: NSRange, hilightedIndex: Int,
    preeditRange: NSRange, highlightedPreeditRange: NSRange,
    controlMode: LinnetCandidatePresentation.CandidateControlMode,
    usesGridLayout: Bool
  ) {
    self.candidateRanges = candidateRanges
    self.detailRange = detailRange
    self.hilightedIndex = hilightedIndex
    self.preeditRange = preeditRange
    self.highlightedPreeditRange = highlightedPreeditRange
    self.controlMode = controlMode
    self.usesGridLayout = usesGridLayout
    candidateInteractionFrames = []
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

  // All draws happen here
  // swiftlint:disable:next cyclomatic_complexity
  override func draw(_ dirtyRect: NSRect) {
    guard let presentationMetrics else { return }
    var preeditPath: CGPath?
    var candidatePaths: CGMutablePath?
    var highlightedPath: CGMutablePath?
    var highlightedPreeditPath: CGMutablePath?
    let theme = currentTheme

    let contentFrame = LinnetPanelGeometry.pagingLayout(
      configuration: presentationMetrics.paging,
      in: bounds,
      preferredAxisCenter: .nan,
      vertical: presentationMetrics.vertical).contentFrame
    var containingRect = NSRect(origin: .zero, size: contentFrame.size)
    let contentBackgroundRect = containingRect
    let panelBackgroundRect = NSRect(
      x: -contentFrame.minX,
      y: 0,
      width: bounds.width,
      height: bounds.height)
    candidateInteractionFrames = []

    // Draw preedit Rect
    var preeditRect = NSRect.zero
    if preeditRange.length > 0, let preeditTextRange = convert(range: preeditRange) {
      preeditRect = contentRect(range: preeditTextRange)
      preeditRect.size.width = contentBackgroundRect.size.width
      preeditRect.size.height += theme.edgeInset.height + theme.preeditLinespace / 2 + theme.linespace / 2
      preeditRect.origin = contentBackgroundRect.origin
      if candidateRanges.count == 0 {
        preeditRect.size.height += theme.edgeInset.height - theme.preeditLinespace / 2 - theme.linespace / 2
      }
      containingRect.size.height -= preeditRect.size.height
      containingRect.origin.y += preeditRect.size.height
      if theme.preeditBackgroundColor != nil {
        preeditPath = drawSmoothLines(rectVertex(of: preeditRect), straightCorner: Set(), alpha: 0, beta: 0)
      }
    }

    containingRect = carveInset(rect: containingRect)
    // Draw candidate Rects
    if presentationMetrics.role == .candidate {
      for i in 0..<candidateRanges.count {
        let candidate = candidateRanges[i]
        let cellPath = candidate.length > 0
          ? drawPath(
            highlightedRange: candidate,
            backgroundRect: contentBackgroundRect,
            preeditRect: preeditRect,
            containingRect: containingRect,
            extraExpansion: 0,
            usesSelectionStyle: false)
          : nil
        if let cellPath {
          var frame = cellPath.boundingBox
          frame.origin.x += contentFrame.minX
          candidateInteractionFrames.append(frame.intersection(bounds))
        } else {
          candidateInteractionFrames.append(.zero)
        }
        if i == hilightedIndex {
          // Draw highlighted Rect
          if candidate.length > 0 && theme.highlightedBackColor != nil {
            highlightedPath = (theme.selectionStyle == .tile
              ? cellPath
              : drawPath(
                highlightedRange: candidate, backgroundRect: contentBackgroundRect,
                preeditRect: preeditRect, containingRect: containingRect,
                extraExpansion: 0, usesSelectionStyle: true))?.mutableCopy()
          }
        } else {
          // Draw other highlighted Rect
          if candidate.length > 0 && theme.candidateBackColor != nil {
            let candidatePath = drawPath(highlightedRange: candidate, backgroundRect: contentBackgroundRect, preeditRect: preeditRect,
                                         containingRect: containingRect, extraExpansion: theme.surroundingExtraExpansion,
                                         usesSelectionStyle: false)
            if candidatePaths == nil {
              candidatePaths = CGMutablePath()
            }
            if let candidatePath = candidatePath {
              candidatePaths?.addPath(candidatePath)
            }
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
      highlightedPreeditPath = drawSmoothLines(highlightedPoints, straightCorner: rightCorners, alpha: 0.3 * theme.hilitedCornerRadius, beta: 1.4 * theme.hilitedCornerRadius)?.mutableCopy()
      if highlightedPoints2.count > 0 {
        highlightedPoints2 = expand(vertex: highlightedPoints2, innerBorder: innerBox, outerBorder: outerBox)
        rightCorners2 = removeCorner(highlightedPoints: highlightedPoints2, rightCorners: rightCorners2, containingRect: containingRect)
        let highlightedPreeditPath2 = drawSmoothLines(highlightedPoints2, straightCorner: rightCorners2, alpha: 0.3 * theme.hilitedCornerRadius, beta: 1.4 * theme.hilitedCornerRadius)
        if let highlightedPreeditPath2 = highlightedPreeditPath2 {
          highlightedPreeditPath?.addPath(highlightedPreeditPath2)
        }
      }
    }

    NSBezierPath.defaultLineWidth = 0
    guard let backgroundPath = drawSmoothLines(
      rectVertex(of: panelBackgroundRect),
      straightCorner: Set(),
      alpha: 0.3 * presentationMetrics.cornerRadius,
      beta: 1.4 * presentationMetrics.cornerRadius
    ) else { return }

    self.layer?.sublayers = nil
    guard let backPath = backgroundPath.mutableCopy() else { return }
    if let path = preeditPath {
      backPath.addPath(path)
    }
    if theme.mutualExclusive {
      if let path = highlightedPath {
        backPath.addPath(path)
      }
      if let path = candidatePaths {
        backPath.addPath(path)
      }
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
      if theme.mutualExclusive, let hilitedPath = highlightedPreeditPath {
        maskPath.addPath(hilitedPath)
      }
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
        shadowLayer.shadowOffset = NSSize(width: theme.shadowSize/2, height: (theme.vertical ? -1 : 1) * theme.shadowSize/2)
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
    panelLayer.setAffineTransform(
      CGAffineTransform(translationX: contentFrame.minX, y: 0))
    let panelPath = CGMutablePath()
    panelPath.addPath(backgroundPath, transform: panelLayer.affineTransform().scaledBy(x: 1, y: -1).translatedBy(x: 0, y: -self.bounds.height))

    let paging = pagingLayer(
      theme: theme, metrics: presentationMetrics, preeditRect: preeditRect)
    self.pagingLayout = paging.layout
    if let sublayers = paging.layer.sublayers, !sublayers.isEmpty {
      self.layer?.addSublayer(paging.layer)
    }
    let flipTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -self.bounds.height)
    if let nextPath = paging.nextPath {
      panelPath.addPath(nextPath, transform: flipTransform)
    }
    if let previousPath = paging.previousPath {
      panelPath.addPath(previousPath, transform: flipTransform)
    }

    shape.path = panelPath
  }

  func click(at clickPoint: NSPoint) -> HitTarget {
    guard presentationMetrics != nil else { return .none }
    var index = 0
    var preeditIndex: Int?
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
    if let candidateIndex = candidateInteractionFrames.firstIndex(where: {
      !$0.isEmpty && $0.contains(clickPoint)
    }) {
      return .candidate(candidateIndex)
    }
    if let path = shape.path, path.contains(clickPoint) {
      guard let textLayoutManager else { return .none }
      var point = NSPoint(x: clickPoint.x - textView.textContainerInset.width
                            - textView.frame.minX,
                          y: clickPoint.y - textView.textContainerInset.height)
      let fragment = textLayoutManager.textLayoutFragment(for: point)
      if let fragment = fragment {
        point = NSPoint(x: point.x - fragment.layoutFragmentFrame.minX,
                        y: point.y - fragment.layoutFragmentFrame.minY)
        index = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: fragment.rangeInElement.location)
        for lineFragment in fragment.textLineFragments where lineFragment.typographicBounds.contains(point) {
          point = NSPoint(x: point.x - lineFragment.typographicBounds.minX,
                          y: point.y - lineFragment.typographicBounds.minY)
          index += lineFragment.characterIndex(for: point)
          if index >= preeditRange.location && index < preeditRange.upperBound {
            preeditIndex = index
          }
          break
        }
      }
    }
    if let preeditIndex { return .preedit(preeditIndex) }
    return .none
  }
}

private extension SquirrelView {
  // A tweaked sign function, to winddown corner radius when the size is small
  func sign(_ number: NSPoint) -> NSPoint {
    if number.length >= 2 {
      return number / number.length
    } else {
      return number / 2
    }
  }

  // Bezier cubic curve, which has continuous roundness
  func drawSmoothLines(_ vertex: [NSPoint], straightCorner: Set<Int>, alpha: CGFloat, beta rawBeta: CGFloat) -> CGPath? {
    guard vertex.count >= 3 else {
      return nil
    }
    let beta = max(0.00001, rawBeta)
    let path = CGMutablePath()
    var previousPoint = vertex[vertex.count-1]
    var point = vertex[0]
    var nextPoint: NSPoint
    var control1: NSPoint
    var control2: NSPoint
    var target = previousPoint
    var diff = point - previousPoint
    if straightCorner.isEmpty || !straightCorner.contains(vertex.count-1) {
      target += sign(diff / beta) * beta
    }
    path.move(to: target)
    for i in 0..<vertex.count {
      previousPoint = vertex[(vertex.count+i-1)%vertex.count]
      point = vertex[i]
      nextPoint = vertex[(i+1)%vertex.count]
      target = point
      if straightCorner.contains(i) {
        path.addLine(to: target)
      } else {
        control1 = point
        diff = point - previousPoint

        target -= sign(diff / beta) * beta
        control1 -= sign(diff / beta) * alpha

        path.addLine(to: target)
        target = point
        control2 = point
        diff = nextPoint - point

        target += sign(diff / beta) * beta
        control2 += sign(diff / beta) * alpha

        path.addCurve(to: target, control1: control1, control2: control2)
      }
    }
    path.closeSubpath()
    return path
  }

  func rectVertex(of rect: NSRect) -> [NSPoint] {
    [rect.origin,
     NSPoint(x: rect.origin.x, y: rect.origin.y+rect.size.height),
     NSPoint(x: rect.origin.x+rect.size.width, y: rect.origin.y+rect.size.height),
     NSPoint(x: rect.origin.x+rect.size.width, y: rect.origin.y)]
  }

  func nearEmpty(_ rect: NSRect) -> Bool {
    return rect.size.height * rect.size.width < 1
  }

  // Calculate 3 boxes containing the text in range. leadingRect and trailingRect are incomplete line rectangle
  // bodyRect is complete lines in the middle
  func multilineRects(forRange range: NSTextRange, extraSurounding: Double, bounds: NSRect) -> (NSRect, NSRect, NSRect) {
    guard let textLayoutManager else { return (.zero, .zero, .zero) }
    let edgeInset = currentTheme.edgeInset
    var lineRects = [NSRect]()
    textLayoutManager.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
      var newRect = rect
      newRect.origin.x += edgeInset.width
      newRect.origin.y += edgeInset.height
      newRect.size.height += currentTheme.linespace
      newRect.origin.y -= currentTheme.linespace / 2
      lineRects.append(newRect)
      return true
    }

    var leadingRect = NSRect.zero
    var bodyRect = NSRect.zero
    var trailingRect = NSRect.zero
    if lineRects.count == 1 {
      bodyRect = lineRects[0]
    } else if lineRects.count == 2 {
      leadingRect = lineRects[0]
      trailingRect = lineRects[1]
    } else if lineRects.count > 2 {
      leadingRect = lineRects[0]
      trailingRect = lineRects[lineRects.count-1]
      // swiftlint:disable:next identifier_name
      var x0 = CGFloat.infinity, x1 = -CGFloat.infinity, y0 = CGFloat.infinity, y1 = -CGFloat.infinity
      for i in 1..<(lineRects.count-1) {
        let rect = lineRects[i]
        x0 = min(rect.minX, x0)
        x1 = max(rect.maxX, x1)
        y0 = min(rect.minY, y0)
        y1 = max(rect.maxY, y1)
      }
      y0 = min(leadingRect.maxY, y0)
      y1 = max(trailingRect.minY, y1)
      bodyRect = NSRect(x: x0, y: y0, width: x1-x0, height: y1-y0)
    }

    if extraSurounding > 0 {
      if nearEmpty(leadingRect) && nearEmpty(trailingRect) {
        bodyRect = expandHighlightWidth(rect: bodyRect, extraSurrounding: extraSurounding)
      } else {
        if !(nearEmpty(leadingRect)) {
          leadingRect = expandHighlightWidth(rect: leadingRect, extraSurrounding: extraSurounding)
        }
        if !(nearEmpty(trailingRect)) {
          trailingRect = expandHighlightWidth(rect: trailingRect, extraSurrounding: extraSurounding)
        }
      }
    }

    if !nearEmpty(leadingRect) && !nearEmpty(trailingRect) {
      leadingRect.size.width = bounds.maxX - leadingRect.origin.x
      trailingRect.size.width = trailingRect.maxX - bounds.minX
      trailingRect.origin.x = bounds.minX
      if !nearEmpty(bodyRect) {
        bodyRect.size.width = bounds.size.width
        bodyRect.origin.x = bounds.origin.x
      } else {
        let diff = trailingRect.minY - leadingRect.maxY
        leadingRect.size.height += diff / 2
        trailingRect.size.height += diff / 2
        trailingRect.origin.y -= diff / 2
      }
    }

    return (leadingRect, bodyRect, trailingRect)
  }

  // Based on the 3 boxes from multilineRectForRange, calculate the vertex of the polygon containing the text in range
  func multilineVertex(leadingRect: NSRect, bodyRect: NSRect, trailingRect: NSRect) -> [NSPoint] {
    if nearEmpty(bodyRect) && !nearEmpty(leadingRect) && nearEmpty(trailingRect) {
      return rectVertex(of: leadingRect)
    } else if nearEmpty(bodyRect) && nearEmpty(leadingRect) && !nearEmpty(trailingRect) {
      return rectVertex(of: trailingRect)
    } else if nearEmpty(leadingRect) && nearEmpty(trailingRect) && !nearEmpty(bodyRect) {
      return rectVertex(of: bodyRect)
    } else if nearEmpty(trailingRect) && !nearEmpty(bodyRect) {
      let leadingVertex = rectVertex(of: leadingRect)
      let bodyVertex = rectVertex(of: bodyRect)
      return [bodyVertex[0], bodyVertex[1], bodyVertex[2], leadingVertex[3], leadingVertex[0], leadingVertex[1]]
    } else if nearEmpty(leadingRect) && !nearEmpty(bodyRect) {
      let trailingVertex = rectVertex(of: trailingRect)
      let bodyVertex = rectVertex(of: bodyRect)
      return [trailingVertex[1], trailingVertex[2], trailingVertex[3], bodyVertex[2], bodyVertex[3], bodyVertex[0]]
    } else if !nearEmpty(leadingRect) && !nearEmpty(trailingRect) && nearEmpty(bodyRect) && (leadingRect.maxX>trailingRect.minX) {
      let leadingVertex = rectVertex(of: leadingRect)
      let trailingVertex = rectVertex(of: trailingRect)
      return [trailingVertex[0], trailingVertex[1], trailingVertex[2], trailingVertex[3], leadingVertex[2], leadingVertex[3], leadingVertex[0], leadingVertex[1]]
    } else if !nearEmpty(leadingRect) && !nearEmpty(trailingRect) && !nearEmpty(bodyRect) {
      let leadingVertex = rectVertex(of: leadingRect)
      let bodyVertex = rectVertex(of: bodyRect)
      let trailingVertex = rectVertex(of: trailingRect)
      return [trailingVertex[1], trailingVertex[2], trailingVertex[3], bodyVertex[2], leadingVertex[3], leadingVertex[0], leadingVertex[1], bodyVertex[0]]
    } else {
      return [NSPoint]()
    }
  }

  // If the point is outside the innerBox, will extend to reach the outerBox
  func expand(vertex: [NSPoint], innerBorder: NSRect, outerBorder: NSRect) -> [NSPoint] {
    var newVertex = [NSPoint]()
    for i in 0..<vertex.count {
      var point = vertex[i]
      if point.x < innerBorder.origin.x {
        point.x = outerBorder.origin.x
      } else if point.x > innerBorder.origin.x+innerBorder.size.width {
        point.x = outerBorder.origin.x+outerBorder.size.width
      }
      if point.y < innerBorder.origin.y {
        point.y = outerBorder.origin.y
      } else if point.y > innerBorder.origin.y+innerBorder.size.height {
        point.y = outerBorder.origin.y+outerBorder.size.height
      }
      newVertex.append(point)
    }
    return newVertex
  }

  func direction(diff: CGPoint) -> CGPoint {
    if diff.y == 0 && diff.x > 0 {
      return NSPoint(x: 0, y: 1)
    } else if diff.y == 0 && diff.x < 0 {
      return NSPoint(x: 0, y: -1)
    } else if diff.x == 0 && diff.y > 0 {
      return NSPoint(x: -1, y: 0)
    } else if diff.x == 0 && diff.y < 0 {
      return NSPoint(x: 1, y: 0)
    } else {
      return NSPoint(x: 0, y: 0)
    }
  }

  func shapeFromPath(path: CGPath?) -> CAShapeLayer {
    let layer = CAShapeLayer()
    layer.path = path
    layer.fillRule = .evenOdd
    return layer
  }

  // Assumes clockwise iteration
  func enlarge(vertex: [NSPoint], by: Double) -> [NSPoint] {
    if by != 0 {
      var previousPoint: NSPoint
      var point: NSPoint
      var nextPoint: NSPoint
      var results = vertex
      var newPoint: NSPoint
      var displacement: NSPoint
      for i in 0..<vertex.count {
        previousPoint = vertex[(vertex.count+i-1) % vertex.count]
        point = vertex[i]
        nextPoint = vertex[(i+1) % vertex.count]
        newPoint = point
        displacement = direction(diff: point - previousPoint)
        newPoint.x += by * displacement.x
        newPoint.y += by * displacement.y
        displacement = direction(diff: nextPoint - point)
        newPoint.x += by * displacement.x
        newPoint.y += by * displacement.y
        results[i] = newPoint
      }
      return results
    } else {
      return vertex
    }
  }

  // Add gap between horizontal candidates
  func expandHighlightWidth(rect: NSRect, extraSurrounding: CGFloat) -> NSRect {
    var newRect = rect
    if !nearEmpty(newRect) {
      newRect.size.width += extraSurrounding
      newRect.origin.x -= extraSurrounding / 2
    }
    return newRect
  }

  func removeCorner(highlightedPoints: [CGPoint], rightCorners: Set<Int>, containingRect: NSRect) -> Set<Int> {
    if !highlightedPoints.isEmpty && !rightCorners.isEmpty {
      var result = rightCorners
      for cornerIndex in rightCorners {
        let corner = highlightedPoints[cornerIndex]
        let dist = min(containingRect.maxY - corner.y, corner.y - containingRect.minY)
        if dist < 1e-2 {
          result.remove(cornerIndex)
        }
      }
      return result
    } else {
      return rightCorners
    }
  }

  // swiftlint:disable:next large_tuple
  func linearMultilineFor(body: NSRect, leading: NSRect, trailing: NSRect) -> (Array<NSPoint>, Array<NSPoint>, Set<Int>, Set<Int>) {
    let highlightedPoints, highlightedPoints2: [NSPoint]
    let rightCorners, rightCorners2: Set<Int>
    // Handles the special case where containing boxes are separated
    if nearEmpty(body) && !nearEmpty(leading) && !nearEmpty(trailing) && trailing.maxX < leading.minX {
      highlightedPoints = rectVertex(of: leading)
      highlightedPoints2 = rectVertex(of: trailing)
      rightCorners = [2, 3]
      rightCorners2 = [0, 1]
    } else {
      highlightedPoints = multilineVertex(leadingRect: leading, bodyRect: body, trailingRect: trailing)
      highlightedPoints2 = []
      rightCorners = []
      rightCorners2 = []
    }
    return (highlightedPoints, highlightedPoints2, rightCorners, rightCorners2)
  }

  func drawPath(
    highlightedRange: NSRange,
    backgroundRect: NSRect,
    preeditRect: NSRect,
    containingRect: NSRect,
    extraExpansion: Double,
    usesSelectionStyle: Bool
  ) -> CGPath? {
    let theme = currentTheme
    if usesSelectionStyle,
       theme.selectionStyle != .tile,
       let textRange = convert(range: highlightedRange) {
      var rect = contentRect(range: textRange)
      rect.origin.x += theme.edgeInset.width
      rect.origin.y += theme.edgeInset.height
      let selectionInsets = LinnetCandidatePresentation.candidateSelectionInsets(
        style: theme.selectionStyle,
        candidateFont: theme.font)
      switch theme.selectionStyle {
      case .underline:
        return CGPath(
          rect: NSRect(x: rect.minX, y: rect.maxY + 1, width: rect.width, height: 2),
          transform: nil)
      case .bar:
        return CGPath(
          rect: NSRect(
            x: max(1, rect.minX - selectionInsets.left),
            y: rect.minY - selectionInsets.top,
            width: 3,
            height: rect.height + selectionInsets.top + selectionInsets.bottom),
          transform: nil)
      case .tile:
        break
      }
    }
    let resultingPath: CGMutablePath?

    var currentContainingRect = containingRect
    currentContainingRect.size.width += extraExpansion * 2
    currentContainingRect.size.height += extraExpansion * 2
    currentContainingRect.origin.x -= extraExpansion
    currentContainingRect.origin.y -= extraExpansion

    let halfLinespace = theme.linespace / 2
    var innerBox = backgroundRect
    innerBox.size.width -= (theme.edgeInset.width + 1) * 2 - 2 * extraExpansion
    innerBox.origin.x += theme.edgeInset.width + 1 - extraExpansion
    innerBox.size.height += 2 * extraExpansion
    innerBox.origin.y -= extraExpansion
    if preeditRange.length == 0 {
      innerBox.origin.y += theme.edgeInset.height + 1
      innerBox.size.height -= (theme.edgeInset.height + 1) * 2
    } else {
      innerBox.origin.y += preeditRect.size.height + theme.preeditLinespace / 2 + theme.linespace / 2 + 1
      innerBox.size.height -= theme.edgeInset.height + preeditRect.size.height + theme.preeditLinespace / 2 + theme.linespace / 2 + 2
    }
    innerBox.size.height -= theme.linespace
    innerBox.origin.y += halfLinespace

    var outerBox = backgroundRect
    outerBox.size.height -= preeditRect.size.height + max(0, theme.hilitedCornerRadius + theme.borderLineWidth) - 2 * extraExpansion
    outerBox.size.width -= max(0, theme.hilitedCornerRadius + theme.borderLineWidth)  - 2 * extraExpansion
    outerBox.origin.x += max(0.0, theme.hilitedCornerRadius + theme.borderLineWidth) / 2.0 - extraExpansion
    outerBox.origin.y += preeditRect.size.height + max(0, theme.hilitedCornerRadius + theme.borderLineWidth) / 2 - extraExpansion

    let effectiveRadius = max(0, theme.hilitedCornerRadius + 2 * extraExpansion / theme.hilitedCornerRadius * max(0, theme.cornerRadius - theme.hilitedCornerRadius))

    if theme.linear || usesGridLayout,
      let highlightedTextRange = convert(range: highlightedRange) {
      let (leadingRect, bodyRect, trailingRect) = multilineRects(forRange: highlightedTextRange, extraSurounding: separatorWidth, bounds: outerBox)
      var (highlightedPoints, highlightedPoints2, rightCorners, rightCorners2) = linearMultilineFor(body: bodyRect, leading: leadingRect, trailing: trailingRect)

      // Expand the boxes to reach proper border
      highlightedPoints = enlarge(vertex: highlightedPoints, by: extraExpansion)
      highlightedPoints = expand(vertex: highlightedPoints, innerBorder: innerBox, outerBorder: outerBox)
      rightCorners = removeCorner(highlightedPoints: highlightedPoints, rightCorners: rightCorners, containingRect: currentContainingRect)
      resultingPath = drawSmoothLines(highlightedPoints, straightCorner: rightCorners, alpha: 0.3*effectiveRadius, beta: 1.4*effectiveRadius)?.mutableCopy()

      if highlightedPoints2.count > 0 {
        highlightedPoints2 = enlarge(vertex: highlightedPoints2, by: extraExpansion)
        highlightedPoints2 = expand(vertex: highlightedPoints2, innerBorder: innerBox, outerBorder: outerBox)
        rightCorners2 = removeCorner(highlightedPoints: highlightedPoints2, rightCorners: rightCorners2, containingRect: currentContainingRect)
        let highlightedPath2 = drawSmoothLines(highlightedPoints2, straightCorner: rightCorners2, alpha: 0.3*effectiveRadius, beta: 1.4*effectiveRadius)
        if let highlightedPath2 = highlightedPath2 {
          resultingPath?.addPath(highlightedPath2)
        }
      }
    } else if let highlightedTextRange = convert(range: highlightedRange) {
      var highlightedRect = self.contentRect(range: highlightedTextRange)
      if !nearEmpty(highlightedRect) {
        highlightedRect.size.width = backgroundRect.size.width
        highlightedRect.size.height += theme.linespace
        highlightedRect.origin = NSPoint(x: backgroundRect.origin.x, y: highlightedRect.origin.y + theme.edgeInset.height - halfLinespace)
        if highlightedRange.upperBound == (textView.string as NSString).length {
          highlightedRect.size.height += theme.edgeInset.height - halfLinespace
        }
        if highlightedRange.location - (preeditRange == .empty ? 0 : preeditRange.upperBound) <= 1 {
          if preeditRange.length == 0 {
            highlightedRect.size.height += theme.edgeInset.height - halfLinespace
            highlightedRect.origin.y -= theme.edgeInset.height - halfLinespace
          } else {
            highlightedRect.size.height += theme.hilitedCornerRadius / 2
            highlightedRect.origin.y -= theme.hilitedCornerRadius / 2
          }
        }

        var highlightedPoints = rectVertex(of: highlightedRect)
        highlightedPoints = enlarge(vertex: highlightedPoints, by: extraExpansion)
        highlightedPoints = expand(vertex: highlightedPoints, innerBorder: innerBox, outerBorder: outerBox)
        resultingPath = drawSmoothLines(highlightedPoints, straightCorner: Set(), alpha: effectiveRadius*0.3, beta: effectiveRadius*1.4)?.mutableCopy()
      } else {
        resultingPath = nil
      }
    } else {
      resultingPath = nil
    }
    return resultingPath
  }

  func carveInset(rect: NSRect) -> NSRect {
    var newRect = rect
    newRect.size.height -= (currentTheme.hilitedCornerRadius + currentTheme.borderWidth) * 2
    newRect.size.width -= (currentTheme.hilitedCornerRadius + currentTheme.borderWidth) * 2
    newRect.origin.x += currentTheme.hilitedCornerRadius + currentTheme.borderWidth
    newRect.origin.y += currentTheme.hilitedCornerRadius + currentTheme.borderWidth
    return newRect
  }

  func triangle(center: NSPoint, radius: CGFloat) -> [NSPoint] {
    [NSPoint(x: center.x, y: center.y + radius),
     NSPoint(x: center.x + 0.5 * sqrt(3) * radius, y: center.y - 0.5 * radius),
     NSPoint(x: center.x - 0.5 * sqrt(3) * radius, y: center.y - 0.5 * radius)]
  }

  /// Keep the rendered path centered inside the same cell consumed by mouse
  /// and accessibility actions. Centering the path bounds, rather than the
  /// triangle's construction origin, also handles the rotated arrow exactly.
  func centeredPagingPath(
    _ path: CGPath,
    rotationAngle: CGFloat,
    in control: LinnetPanelGeometry.PagingControl
  ) -> CGPath? {
    var rotation = CGAffineTransform(rotationAngle: rotationAngle)
    guard let orientedPath = path.copy(using: &rotation) else { return nil }
    let visualFrame = orientedPath.boundingBox
    var translation = CGAffineTransform(
      translationX: control.visualCenter.x - visualFrame.midX,
      y: control.visualCenter.y - visualFrame.midY
    )
    guard let centeredPath = orientedPath.copy(using: &translation),
      control.cell.contains(centeredPath.boundingBox)
    else { return nil }
    return centeredPath
  }

  func pagingLayer(
    theme: SquirrelTheme,
    metrics: LinnetPanelGeometry.PresentationMetrics,
    preeditRect: CGRect
  ) -> PagingLayerResult {
    let layer = CAShapeLayer()
    guard metrics.paging.isVisible,
      let firstCandidate = candidateRanges.first,
      let range = convert(range: firstCandidate)
    else { return .empty(layer: layer) }
    var height = contentRect(range: range).height
    let preeditHeight = max(0, preeditRect.height + theme.preeditLinespace / 2 + theme.linespace / 2 - theme.edgeInset.height) + theme.edgeInset.height - theme.linespace / 2
    height += theme.linespace
    let layout = LinnetPanelGeometry.pagingLayout(
      configuration: metrics.paging,
      in: bounds,
      preferredAxisCenter: preeditHeight + height / 2,
      vertical: metrics.vertical
    )
    guard layout.previousPage != nil || layout.nextPage != nil else {
      return .empty(layer: layer)
    }
    let radius = min(0.5 * metrics.paging.themeOffset, 2 * height / 9)
    let effectiveRadius = min(metrics.cornerRadius, 0.6 * radius)
    guard let trianglePath = drawSmoothLines(
      triangle(center: .zero, radius: radius),
      straightCorner: [], alpha: 0.3 * effectiveRadius, beta: 1.4 * effectiveRadius
    ) else {
      return .empty(layer: layer)
    }

    let downPath = layout.nextPage.flatMap {
      centeredPagingPath(trianglePath, rotationAngle: 0, in: $0)
    }
    let upPath = layout.previousPage.flatMap {
      centeredPagingPath(trianglePath, rotationAngle: .pi, in: $0)
    }
    guard layout.nextPage == nil || downPath != nil,
      layout.previousPage == nil || upPath != nil
    else { return .empty(layer: layer) }

    if let downPath {
      let downLayer = shapeFromPath(path: downPath)
      downLayer.fillColor = (theme.labelAttrs[.foregroundColor] as? NSColor)?.cgColor
      layer.addSublayer(downLayer)
    }
    if let upPath {
      let upLayer = shapeFromPath(path: upPath)
      upLayer.fillColor = (theme.labelAttrs[.foregroundColor] as? NSColor)?.cgColor
      layer.addSublayer(upLayer)
    }
    return .init(
      layer: layer,
      layout: layout,
      nextPath: downPath,
      previousPath: upPath)
  }
}
