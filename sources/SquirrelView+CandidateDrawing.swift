//
//  SquirrelView+CandidateDrawing.swift
//  Squirrel
//
//  Candidate highlight and paging path construction.
//

import AppKit

extension SquirrelView {
  struct CandidatePathContext {
    let backgroundRect: NSRect
    let preeditRect: NSRect
    let containingRect: NSRect
    let extraExpansion: Double
    let usesSelectionStyle: Bool
  }

  struct PagingDrawing {
    let layer: CAShapeLayer
    let layout: LinnetPanelGeometry.PagingLayout
    let downPath: CGPath?
    let upPath: CGPath?
  }

  // A tweaked sign function, to winddown corner radius when the size is small
  func sign(_ number: NSPoint) -> NSPoint { if number.length >= 2 { return number / number.length } else { return number / 2 } }

  // Bezier cubic curve, which has continuous roundness
  func drawSmoothLines(_ vertex: [NSPoint], straightCorner: Set<Int>, alpha: CGFloat, beta rawBeta: CGFloat) -> CGPath? {
    guard vertex.count >= 3 else { return nil }
    let beta = max(0.00001, rawBeta)
    let path = CGMutablePath()
    var previousPoint = vertex[vertex.count - 1]
    var point = vertex[0]
    var nextPoint: NSPoint
    var control1: NSPoint
    var control2: NSPoint
    var target = previousPoint
    var diff = point - previousPoint
    if straightCorner.isEmpty || !straightCorner.contains(vertex.count - 1) { target += sign(diff / beta) * beta }
    path.move(to: target)
    for i in 0..<vertex.count {
      previousPoint = vertex[(vertex.count + i - 1) % vertex.count]
      point = vertex[i]
      nextPoint = vertex[(i + 1) % vertex.count]
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
    [
      rect.origin, NSPoint(x: rect.origin.x, y: rect.origin.y + rect.size.height), NSPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height),
      NSPoint(x: rect.origin.x + rect.size.width, y: rect.origin.y)
    ]
  }

  func nearEmpty(_ rect: NSRect) -> Bool { return rect.size.height * rect.size.width < 1 }

  // Calculate 3 boxes containing the text in range. leadingRect and trailingRect are incomplete line rectangle
  // bodyRect is complete lines in the middle
  func multilineRects(forRange range: NSTextRange, extraSurounding: Double, bounds: NSRect) -> (NSRect, NSRect, NSRect) {
    guard let textLayoutManager = textView.textLayoutManager else { return (.zero, .zero, .zero) }
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

    var (leadingRect, bodyRect, trailingRect) = initialMultilineRects(lineRects)

    if lineRects.count > 2 {
      var minX = CGFloat.infinity
      var maxX = -CGFloat.infinity
      var minY = CGFloat.infinity
      var maxY = -CGFloat.infinity
      for i in 1..<(lineRects.count - 1) {
        let rect = lineRects[i]
        minX = min(rect.minX, minX)
        maxX = max(rect.maxX, maxX)
        minY = min(rect.minY, minY)
        maxY = max(rect.maxY, maxY)
      }
      minY = min(leadingRect.maxY, minY)
      maxY = max(trailingRect.minY, maxY)
      bodyRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    if extraSurounding > 0 {
      if nearEmpty(leadingRect) && nearEmpty(trailingRect) {
        bodyRect = expandHighlightWidth(rect: bodyRect, extraSurrounding: extraSurounding)
      } else {
        if !(nearEmpty(leadingRect)) { leadingRect = expandHighlightWidth(rect: leadingRect, extraSurrounding: extraSurounding) }
        if !(nearEmpty(trailingRect)) { trailingRect = expandHighlightWidth(rect: trailingRect, extraSurrounding: extraSurounding) }
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

  func initialMultilineRects(_ lineRects: [NSRect]) -> (NSRect, NSRect, NSRect) {
    if lineRects.count == 1 {
      return (.zero, lineRects[0], .zero)
    }
    if lineRects.count == 2 {
      return (lineRects[0], .zero, lineRects[1])
    }
    if lineRects.count > 2 {
      return (lineRects[0], .zero, lineRects[lineRects.count - 1])
    }
    return (.zero, .zero, .zero)
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
    } else if !nearEmpty(leadingRect) && !nearEmpty(trailingRect) && nearEmpty(bodyRect) && (leadingRect.maxX > trailingRect.minX) {
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
      } else if point.x > innerBorder.origin.x + innerBorder.size.width {
        point.x = outerBorder.origin.x + outerBorder.size.width
      }
      if point.y < innerBorder.origin.y {
        point.y = outerBorder.origin.y
      } else if point.y > innerBorder.origin.y + innerBorder.size.height {
        point.y = outerBorder.origin.y + outerBorder.size.height
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
        previousPoint = vertex[(vertex.count + i - 1) % vertex.count]
        point = vertex[i]
        nextPoint = vertex[(i + 1) % vertex.count]
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
        if dist < 1e-2 { result.remove(cornerIndex) }
      }
      return result
    } else {
      return rightCorners
    }
  }

  // swiftlint:disable:next large_tuple
  func linearMultilineFor(body: NSRect, leading: NSRect, trailing: NSRect) -> ([NSPoint], [NSPoint], Set<Int>, Set<Int>) {
    let highlightedPoints: [NSPoint]
    let highlightedPoints2: [NSPoint]
    let rightCorners: Set<Int>
    let rightCorners2: Set<Int>
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

  func selectionIndicatorPath(for highlightedRange: NSRange, theme: SquirrelTheme, enabled: Bool) -> CGPath? {
    guard enabled, theme.selectionStyle != .tile, let textRange = convert(range: highlightedRange) else { return nil }
    var rect = contentRect(range: textRange)
    rect.origin.x += theme.edgeInset.width
    rect.origin.y += theme.edgeInset.height
    let selectionInsets = LinnetCandidatePresentation.candidateSelectionInsets(style: theme.selectionStyle, candidateFont: theme.font)
    switch theme.selectionStyle {
    case .underline: return CGPath(rect: NSRect(x: rect.minX, y: rect.maxY + 1, width: rect.width, height: 2), transform: nil)
    case .bar:
      return CGPath(
        rect: NSRect(
          x: max(1, rect.minX - selectionInsets.left), y: rect.minY - selectionInsets.top, width: 3,
          height: rect.height + selectionInsets.top + selectionInsets.bottom),
        transform: nil)
    case .tile: return nil
    }
  }

  func drawPath(highlightedRange: NSRange, context: CandidatePathContext) -> CGPath? {
    let theme = currentTheme
    if let selectionPath = selectionIndicatorPath(for: highlightedRange, theme: theme, enabled: context.usesSelectionStyle) { return selectionPath }
    let backgroundRect = context.backgroundRect
    let preeditRect = context.preeditRect
    let containingRect = context.containingRect
    let extraExpansion = context.extraExpansion
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
    outerBox.size.width -= max(0, theme.hilitedCornerRadius + theme.borderLineWidth) - 2 * extraExpansion
    outerBox.origin.x += max(0.0, theme.hilitedCornerRadius + theme.borderLineWidth) / 2.0 - extraExpansion
    outerBox.origin.y += preeditRect.size.height + max(0, theme.hilitedCornerRadius + theme.borderLineWidth) / 2 - extraExpansion

    let effectiveRadius = max(0, theme.hilitedCornerRadius + 2 * extraExpansion / theme.hilitedCornerRadius * max(0, theme.cornerRadius - theme.hilitedCornerRadius))

    if theme.linear || usesGridLayout, let highlightedTextRange = convert(range: highlightedRange) {
      let (leadingRect, bodyRect, trailingRect) = multilineRects(forRange: highlightedTextRange, extraSurounding: separatorWidth, bounds: outerBox)
      var (highlightedPoints, highlightedPoints2, rightCorners, rightCorners2) = linearMultilineFor(body: bodyRect, leading: leadingRect, trailing: trailingRect)

      // Expand the boxes to reach proper border
      highlightedPoints = enlarge(vertex: highlightedPoints, by: extraExpansion)
      highlightedPoints = expand(vertex: highlightedPoints, innerBorder: innerBox, outerBorder: outerBox)
      rightCorners = removeCorner(highlightedPoints: highlightedPoints, rightCorners: rightCorners, containingRect: currentContainingRect)
      resultingPath = drawSmoothLines(highlightedPoints, straightCorner: rightCorners, alpha: 0.3 * effectiveRadius, beta: 1.4 * effectiveRadius)?.mutableCopy()

      if highlightedPoints2.count > 0 {
        highlightedPoints2 = enlarge(vertex: highlightedPoints2, by: extraExpansion)
        highlightedPoints2 = expand(vertex: highlightedPoints2, innerBorder: innerBox, outerBorder: outerBox)
        rightCorners2 = removeCorner(highlightedPoints: highlightedPoints2, rightCorners: rightCorners2, containingRect: currentContainingRect)
        let highlightedPath2 = drawSmoothLines(highlightedPoints2, straightCorner: rightCorners2, alpha: 0.3 * effectiveRadius, beta: 1.4 * effectiveRadius)
        if let highlightedPath2 = highlightedPath2 { resultingPath?.addPath(highlightedPath2) }
      }
    } else if let highlightedTextRange = convert(range: highlightedRange) {
      var highlightedRect = self.contentRect(range: highlightedTextRange)
      if !nearEmpty(highlightedRect) {
        highlightedRect.size.width = backgroundRect.size.width
        highlightedRect.size.height += theme.linespace
        highlightedRect.origin = NSPoint(x: backgroundRect.origin.x, y: highlightedRect.origin.y + theme.edgeInset.height - halfLinespace)
        if highlightedRange.upperBound == (textView.string as NSString).length { highlightedRect.size.height += theme.edgeInset.height - halfLinespace }
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
        resultingPath = drawSmoothLines(highlightedPoints, straightCorner: Set(), alpha: effectiveRadius * 0.3, beta: effectiveRadius * 1.4)?.mutableCopy()
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
    [
      NSPoint(x: center.x, y: center.y + radius), NSPoint(x: center.x + 0.5 * sqrt(3) * radius, y: center.y - 0.5 * radius),
      NSPoint(x: center.x - 0.5 * sqrt(3) * radius, y: center.y - 0.5 * radius)
    ]
  }

  /// Keep the rendered path centered inside the same cell consumed by mouse
  /// and accessibility actions. Centering the path bounds, rather than the
  /// triangle's construction origin, also handles the rotated arrow exactly.
  func centeredPagingPath(_ path: CGPath, rotationAngle: CGFloat, in control: LinnetPanelGeometry.PagingControl) -> CGPath? {
    var rotation = CGAffineTransform(rotationAngle: rotationAngle)
    guard let orientedPath = path.copy(using: &rotation) else { return nil }
    let visualFrame = orientedPath.boundingBox
    var translation = CGAffineTransform(translationX: control.visualCenter.x - visualFrame.midX, y: control.visualCenter.y - visualFrame.midY)
    guard let centeredPath = orientedPath.copy(using: &translation), control.cell.contains(centeredPath.boundingBox) else { return nil }
    return centeredPath
  }

  func pagingLayer(theme: SquirrelTheme, metrics: LinnetPanelGeometry.PresentationMetrics, preeditRect: CGRect) -> PagingDrawing {
    let layer = CAShapeLayer()
    guard metrics.paging.isVisible, let firstCandidate = candidateRanges.first, let range = convert(range: firstCandidate) else {
      return PagingDrawing(layer: layer, layout: .none, downPath: nil, upPath: nil)
    }
    var height = contentRect(range: range).height
    let preeditHeight = max(0, preeditRect.height + theme.preeditLinespace / 2 + theme.linespace / 2 - theme.edgeInset.height) + theme.edgeInset.height - theme.linespace / 2
    height += theme.linespace
    let layout = LinnetPanelGeometry.pagingLayout(configuration: metrics.paging, in: bounds, preferredAxisCenter: preeditHeight + height / 2, vertical: metrics.vertical)
    guard layout.previousPage != nil || layout.nextPage != nil else { return PagingDrawing(layer: layer, layout: .none, downPath: nil, upPath: nil) }
    let radius = min(0.5 * metrics.paging.themeOffset, 2 * height / 9)
    let effectiveRadius = min(metrics.cornerRadius, 0.6 * radius)
    guard let trianglePath = drawSmoothLines(triangle(center: .zero, radius: radius), straightCorner: [], alpha: 0.3 * effectiveRadius, beta: 1.4 * effectiveRadius) else {
      return PagingDrawing(layer: layer, layout: .none, downPath: nil, upPath: nil)
    }

    let downPath = layout.nextPage.flatMap { centeredPagingPath(trianglePath, rotationAngle: 0, in: $0) }
    let upPath = layout.previousPage.flatMap { centeredPagingPath(trianglePath, rotationAngle: .pi, in: $0) }
    guard layout.nextPage == nil || downPath != nil, layout.previousPage == nil || upPath != nil else {
      return PagingDrawing(layer: layer, layout: .none, downPath: nil, upPath: nil)
    }

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
    return PagingDrawing(layer: layer, layout: layout, downPath: downPath, upPath: upPath)
  }
}
