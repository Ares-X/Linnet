import CoreGraphics
import Foundation

@main
struct LinnetPanelGeometryTests {
  static func main() {
    let candidateMetrics: [(CGFloat, CGFloat, Bool, CGFloat)] = [
      (12, 15, false, 7),
      (16, 18, true, 9),
      (24, 0, false, 11),
      (32, 30, true, 13),
    ]
    for (fontPoint, themePagingOffset, vertical, cornerRadius) in candidateMetrics {
      let inset = vertical
        ? CGSize(width: 6, height: 7)
        : CGSize(width: 7, height: 6)
      let paging = LinnetPanelGeometry.pagingConfiguration(
        showPaging: true,
        themeOffset: themePagingOffset,
        canPageUp: themePagingOffset > 0,
        canPageDown: false
      )
      let candidate = LinnetPanelGeometry.presentationMetrics(
        role: .candidate,
        candidateFontPoint: fontPoint,
        candidateEdgeInset: inset,
        candidatePaging: paging,
        candidateVertical: vertical,
        candidateCornerRadius: cornerRadius
      )
      require(
          candidate.role == .candidate &&
          candidate.fontPoint == fontPoint &&
          candidate.edgeInset == inset &&
          candidate.paging == paging &&
          candidate.vertical == vertical &&
          candidate.cornerRadius == cornerRadius,
        "candidate presentation metrics changed"
      )

      let status = LinnetPanelGeometry.presentationMetrics(
        role: .status,
        candidateFontPoint: fontPoint,
        candidateEdgeInset: inset,
        candidatePaging: paging,
        candidateVertical: vertical,
        candidateCornerRadius: cornerRadius
      )
      require(
          status.role == .status &&
          status.fontPoint == 13 &&
          status.edgeInset == CGSize(width: 6, height: 4) &&
          status.paging == .none &&
          !status.vertical &&
          status.cornerRadius == 6,
        "status presentation inherited candidate theme geometry"
      )
    }

    require(
      LinnetPanelGeometry.relativeVerticalPosition(
        caret: CGRect(x: 10, y: 740, width: 2, height: 20),
        screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)
      ) == 0.75,
      "main-screen position was not normalized"
    )
    require(
      approximatelyEqual(
        LinnetPanelGeometry.relativeVerticalPosition(
          caret: CGRect(x: 10, y: 990, width: 2, height: 20),
          screen: CGRect(x: 0, y: 900, width: 1600, height: 900)
        ),
        1.0 / 9.0
      ),
      "screen origin was ignored for an upper display"
    )
    require(
      approximatelyEqual(
        LinnetPanelGeometry.relativeVerticalPosition(
          caret: CGRect(x: 10, y: -110, width: 2, height: 20),
          screen: CGRect(x: 0, y: -900, width: 1600, height: 900)
        ),
        8.0 / 9.0
      ),
      "screen origin was ignored for a lower display"
    )
    require(
      LinnetPanelGeometry.relativeVerticalPosition(
        caret: CGRect(x: 0, y: 2000, width: 2, height: 20),
        screen: CGRect(x: 0, y: 900, width: 1600, height: 900)
      ) == 1,
      "off-screen input was not clamped"
    )
    require(
      LinnetPanelGeometry.relativeVerticalPosition(
        caret: .zero,
        screen: CGRect(x: 0, y: 0, width: 100, height: 0)
      ) == nil,
      "zero-height screen was accepted"
    )

    let firstLayoutRect = CGRect(x: 10, y: 20, width: 30, height: 40)
    let secondLayoutRect = CGRect(x: 35, y: 15, width: 20, height: 10)
    let firstUnion = LinnetPanelGeometry.union(nil, withFiniteLayoutRect: firstLayoutRect)
    let completeUnion = LinnetPanelGeometry.union(firstUnion, withFiniteLayoutRect: secondLayoutRect)
    require(
      completeUnion == CGRect(x: 10, y: 15, width: 45, height: 45),
      "finite layout rectangles were not unioned"
    )
    require(
      LinnetPanelGeometry.union(
        firstUnion,
        withFiniteLayoutRect: CGRect(
          x: CGFloat.infinity, y: 0, width: 10, height: 10)
      ) == firstUnion,
      "non-finite layout rectangle polluted the union"
    )
    require(
      LinnetPanelGeometry.union(
        nil,
        withFiniteLayoutRect: CGRect(x: 0, y: 0, width: 0, height: 10)
      ) == nil,
      "empty layout rectangle became authoritative geometry"
    )

    let themeLineSpacing: [(String, CGFloat)] = [
      ("Paper", 6), ("Slate", 8), ("Clay", 0), ("Glass", 6),
    ]
    let systemLineHeights: [(CGFloat, CGFloat)] = [
      (12, 14.1328125), (16, 18.84375), (32, 37.6875),
    ]
    for (theme, lineSpacing) in themeLineSpacing {
      for (fontPoint, lineHeight) in systemLineHeights {
        let candidateHeight = lineHeight + lineSpacing
        let labelFontPoint = max(10, fontPoint * 0.625)
        let themeOffset = labelFontPoint * 1.5
        let radius = min(0.5 * themeOffset, 2 * candidateHeight / 9)
        let visualSize = CGSize(width: sqrt(3) * radius, height: 1.5 * radius)
        for (canPageUp, canPageDown) in [
          (false, false),
          (true, false),
          (false, true),
          (true, true),
        ] {
          let buttonCount = [canPageUp, canPageDown].filter { $0 }.count
          let expectedAxisExtent = buttonCount == 0 ? CGFloat.zero : CGFloat(20)
          let expectedStripWidth = buttonCount == 0
            ? CGFloat.zero
            : CGFloat(buttonCount) * max(themeOffset, 20) + CGFloat(buttonCount - 1) * 2
          let configuration = LinnetPanelGeometry.pagingConfiguration(
            showPaging: true,
            themeOffset: themeOffset,
            canPageUp: canPageUp,
            canPageDown: canPageDown
          )
          require(
            configuration.axisExtent == expectedAxisExtent,
            "\(theme) \(fontPoint)-point paging reserved the wrong axis extent"
          )
          require(
            configuration.stripWidth == expectedStripWidth,
            "\(theme) \(fontPoint)-point paging reserved the wrong strip width"
          )

          let logicalBounds = CGRect(
            x: 0, y: 0, width: 240,
            height: max(candidateHeight, expectedAxisExtent)
          )
          let layout = LinnetPanelGeometry.pagingLayout(
            configuration: configuration,
            in: logicalBounds,
            preferredAxisCenter: candidateHeight / 2
          )
          if configuration.isVisible {
            require(
              layout.stripFrame.maxX == logicalBounds.maxX,
              "horizontal paging controls must occupy the trailing edge")
          }
          let controls = [layout.previousPage, layout.nextPage].compactMap { $0 }
          require(
            controls.count == [canPageUp, canPageDown].filter { $0 }.count,
            "\(theme) \(fontPoint)-point paging lost or invented a control"
          )
          for control in controls {
            let visualFrame = CGRect(
              x: control.visualCenter.x - visualSize.width / 2,
              y: control.visualCenter.y - visualSize.height / 2,
              width: visualSize.width,
              height: visualSize.height
            )
            require(
              control.cell.width >= 20 && control.cell.height == 20,
              "\(theme) \(fontPoint)-point paging cell is below the minimum target"
            )
            require(
              control.cell.contains(visualFrame),
              "\(theme) \(fontPoint)-point paging cell does not contain its visual triangle"
            )
            require(
              logicalBounds.contains(control.cell),
              "\(theme) \(fontPoint)-point paging cell escaped the logical view"
            )
          }
          if let previous = layout.previousPage, let next = layout.nextPage {
            require(
              previous.cell.maxX + 2 == next.cell.minX,
              "\(theme) \(fontPoint)-point paging cells overlap or use the wrong gap"
            )
          }

          let rotatedBounds = CGRect(
            x: 0, y: 0,
            width: logicalBounds.height,
            height: logicalBounds.width
          )
          let clockwise = CGAffineTransform(
            a: 0, b: -1, c: 1, d: 0,
            tx: 0, ty: logicalBounds.width
          )
          let verticalLayout = LinnetPanelGeometry.pagingLayout(
            configuration: configuration,
            in: logicalBounds,
            preferredAxisCenter: candidateHeight / 2,
            vertical: true)
          if configuration.isVisible {
            require(
              verticalLayout.stripFrame.minX == logicalBounds.minX,
              "vertical paging must preserve the logical leading edge before rotation")
            require(
              verticalLayout.stripFrame.applying(clockwise).maxY == rotatedBounds.maxY,
              "vertical paging moved away from its established terminal edge")
          }
          let rotatedCells = [verticalLayout.previousPage, verticalLayout.nextPage]
            .compactMap { $0?.cell.applying(clockwise) }
          require(
            rotatedCells.allSatisfy(rotatedBounds.contains),
            "\(theme) \(fontPoint)-point paging escaped after vertical rotation"
          )
          if rotatedCells.count == 2 {
            require(
              rotatedCells[1].maxY + 2 == rotatedCells[0].minY,
              "\(theme) \(fontPoint)-point rotated paging cells lost their gap"
            )
          }
        }
      }
    }

    for configuration in [
      LinnetPanelGeometry.pagingConfiguration(
        showPaging: false, themeOffset: 15, canPageUp: true, canPageDown: true),
      LinnetPanelGeometry.pagingConfiguration(
        showPaging: true, themeOffset: 0, canPageUp: true, canPageDown: true),
      LinnetPanelGeometry.pagingConfiguration(
        showPaging: true, themeOffset: 15, canPageUp: false, canPageDown: false),
    ] {
      require(configuration == .none, "inactive paging retained an empty gutter")
    }

    require(
      LinnetPanelGeometry.containsTextAttributeIndex(0, attributedLength: 1),
      "the first character was rejected"
    )
    require(
      LinnetPanelGeometry.containsTextAttributeIndex(4, attributedLength: 5),
      "the final character was rejected"
    )
    require(
      !LinnetPanelGeometry.containsTextAttributeIndex(0, attributedLength: 0),
      "an empty attributed string accepted an index"
    )
    require(
      !LinnetPanelGeometry.containsTextAttributeIndex(5, attributedLength: 5),
      "the document-end location was accepted as a character index"
    )
    require(
      !LinnetPanelGeometry.containsTextAttributeIndex(-1, attributedLength: 5),
      "a negative text location was accepted"
    )

    print("LinnetPanelGeometryTests: PASS")
  }

  private static func approximatelyEqual(_ lhs: CGFloat?, _ rhs: CGFloat) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) < 0.000_001
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("LinnetPanelGeometryTests: FAIL: \(message)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
