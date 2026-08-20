//
//  LinnetPanelGeometry.swift
//  Linnet
//
//  Screen-local candidate-window geometry shared by every display layout.
//

import CoreGraphics

enum LinnetPanelGeometry {
  enum PresentationRole: Equatable {
    case candidate
    case status
  }

  struct PresentationMetrics: Equatable {
    let role: PresentationRole
    let fontPoint: CGFloat
    let edgeInset: CGSize
    let paging: PagingConfiguration
    let vertical: Bool
    let cornerRadius: CGFloat
  }

  static let statusFontPoint: CGFloat = 13
  static let statusEdgeInset = CGSize(width: 6, height: 4)
  static let statusCornerRadius: CGFloat = 6
  static let pagingCellDimension: CGFloat = 20
  static let pagingCellGap: CGFloat = 2

  struct PagingConfiguration: Equatable {
    let themeOffset: CGFloat
    let stripWidth: CGFloat
    let axisExtent: CGFloat
    let showsPreviousPage: Bool
    let showsNextPage: Bool

    static let none = PagingConfiguration(
      themeOffset: 0,
      stripWidth: 0,
      axisExtent: 0,
      showsPreviousPage: false,
      showsNextPage: false
    )

    var isVisible: Bool {
      stripWidth > 0 && axisExtent > 0 && (showsPreviousPage || showsNextPage)
    }
  }

  struct PagingControl: Equatable {
    let cell: CGRect

    var visualCenter: CGPoint {
      CGPoint(x: cell.midX, y: cell.midY)
    }
  }

  struct PagingLayout: Equatable {
    let contentFrame: CGRect
    let stripFrame: CGRect
    let previousPage: PagingControl?
    let nextPage: PagingControl?

    static let none = PagingLayout(
      contentFrame: .zero,
      stripFrame: .zero,
      previousPage: nil,
      nextPage: nil
    )
  }

  /// Candidate geometry remains entirely theme-owned. A transient mode status
  /// is a compact horizontal system notice and must not inherit candidate font
  /// scaling, theme padding, paging space, or vertical text orientation.
  static func presentationMetrics(
    role: PresentationRole,
    candidateFontPoint: CGFloat,
    candidateEdgeInset: CGSize,
    candidatePaging: PagingConfiguration,
    candidateVertical: Bool,
    candidateCornerRadius: CGFloat
  ) -> PresentationMetrics {
    switch role {
    case .candidate:
      PresentationMetrics(
        role: .candidate,
        fontPoint: candidateFontPoint,
        edgeInset: candidateEdgeInset,
        paging: candidatePaging,
        vertical: candidateVertical,
        cornerRadius: candidateCornerRadius
      )
    case .status:
      PresentationMetrics(
        role: .status,
        fontPoint: statusFontPoint,
        edgeInset: statusEdgeInset,
        paging: .none,
        vertical: false,
        cornerRadius: statusCornerRadius
      )
    }
  }

  static func containsTextAttributeIndex(
    _ index: Int,
    attributedLength: Int
  ) -> Bool {
    index >= 0 && index < attributedLength
  }

  static func relativeVerticalPosition(caret: CGRect, screen: CGRect) -> CGFloat? {
    let screenHeight = screen.size.height
    let screenMinY = screen.origin.y
    let caretMidY = caret.origin.y + caret.size.height / 2
    guard screenHeight.isFinite,
      screenHeight > 0,
      caretMidY.isFinite,
      screenMinY.isFinite
    else { return nil }
    let relative = (caretMidY - screenMinY) / screenHeight
    return min(1, max(0, relative))
  }

  static func union(
    _ accumulated: CGRect?,
    withFiniteLayoutRect rect: CGRect
  ) -> CGRect? {
    guard rect.origin.x.isFinite,
      rect.origin.y.isFinite,
      rect.size.width.isFinite,
      rect.size.height.isFinite,
      rect.size.width > 0,
      rect.size.height > 0
    else { return accumulated }
    guard let accumulated else { return rect }
    return accumulated.union(rect)
  }

  static func pagingConfiguration(
    showPaging: Bool,
    themeOffset: CGFloat,
    canPageUp: Bool,
    canPageDown: Bool
  ) -> PagingConfiguration {
    guard showPaging,
      themeOffset.isFinite,
      themeOffset > 0,
      canPageUp || canPageDown
    else { return .none }

    let buttonCount = (canPageUp ? 1 : 0) + (canPageDown ? 1 : 0)
    let cellWidth = max(themeOffset, pagingCellDimension)
    return PagingConfiguration(
      themeOffset: themeOffset,
      stripWidth: CGFloat(buttonCount) * cellWidth
        + CGFloat(buttonCount - 1) * pagingCellGap,
      axisExtent: pagingCellDimension,
      showsPreviousPage: canPageUp,
      showsNextPage: canPageDown
    )
  }

  /// One logical layout owns the visual centers and the mouse/AX cells. The
  /// caller reserves `stripWidth` by `axisExtent` before asking for a layout.
  static func pagingLayout(
    configuration: PagingConfiguration,
    in bounds: CGRect,
    preferredAxisCenter: CGFloat,
    vertical: Bool = false
  ) -> PagingLayout {
    guard bounds.minX.isFinite,
      bounds.minY.isFinite,
      bounds.width.isFinite,
      bounds.height.isFinite,
      bounds.width >= 0,
      bounds.height >= 0
    else { return .none }
    guard configuration.isVisible else {
      return PagingLayout(
        contentFrame: bounds, stripFrame: .zero,
        previousPage: nil, nextPage: nil)
    }
    guard
      bounds.width >= configuration.stripWidth,
      bounds.height >= configuration.axisExtent
    else { return .none }

    let requestedOrigin = (preferredAxisCenter.isFinite ? preferredAxisCenter : bounds.midY)
      - configuration.axisExtent / 2
    let groupOrigin = min(
      bounds.maxY - configuration.axisExtent,
      max(bounds.minY, requestedOrigin)
    )
    let stripX = vertical
      ? bounds.minX
      : bounds.maxX - configuration.stripWidth
    let stripFrame = CGRect(
      x: stripX,
      y: bounds.minY,
      width: configuration.stripWidth,
      height: bounds.height
    )
    let contentFrame = CGRect(
      x: vertical ? stripFrame.maxX : bounds.minX,
      y: bounds.minY,
      width: bounds.width - stripFrame.width,
      height: bounds.height)
    let buttonCount = (configuration.showsPreviousPage ? 1 : 0)
      + (configuration.showsNextPage ? 1 : 0)
    let cellWidth = (
      configuration.stripWidth - CGFloat(buttonCount - 1) * pagingCellGap
    ) / CGFloat(buttonCount)
    var nextCellOriginX = stripFrame.minX
    var previousPage: PagingControl?
    if configuration.showsPreviousPage {
      previousPage = PagingControl(cell: CGRect(
        x: nextCellOriginX,
        y: groupOrigin,
        width: cellWidth,
        height: configuration.axisExtent
      ))
      nextCellOriginX += cellWidth + pagingCellGap
    }
    let nextPage = configuration.showsNextPage
      ? PagingControl(cell: CGRect(
        x: nextCellOriginX,
        y: groupOrigin,
        width: cellWidth,
        height: configuration.axisExtent
      ))
      : nil
    return PagingLayout(
      contentFrame: contentFrame,
      stripFrame: stripFrame,
      previousPage: previousPage,
      nextPage: nextPage
    )
  }
}
