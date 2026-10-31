import AppKit
import Darwin
import Foundation

final class SquirrelInputController {
  struct CandidateItem: Equatable {
    let absoluteIndex: Int
    let page: Int
    let indexOnPage: Int
    let text: String
    let comment: String
    let selectionLabel: String?
  }

  struct CandidateSnapshot: Equatable {
    let items: [CandidateItem]
    let currentPage: Int
    let pageSize: Int
    let highlightedItemIndex: Int
    let isLastPage: Bool
    let canExpand: Bool
    let isExpanded: Bool
    let candidateListEnd: Int?
  }
}

@main
struct LinnetRimeCandidateSnapshotBuilderTests {
  private enum IteratorFixture {
    static var candidates: [RimeCandidate] = []
    static var reads = 0
    static var starts = 0
    static var ends = 0
  }

  static func main() {
    "working".withCString { firstText in
      "n. 工作".withCString { firstComment in
        "workings".withCString { secondText in
          "n. 运作".withCString { secondComment in
            var candidates = [RimeCandidate(), RimeCandidate()]
            candidates[0].text = UnsafeMutablePointer(mutating: firstText)
            candidates[0].comment = UnsafeMutablePointer(mutating: firstComment)
            candidates[1].text = UnsafeMutablePointer(mutating: secondText)
            candidates[1].comment = UnsafeMutablePointer(mutating: secondComment)
            candidates.withUnsafeMutableBufferPointer { buffer in
              verifyCompactSnapshot(candidates: buffer.baseAddress)
            }
          }
        }
      }
    }
    _ = NSApplication.shared
    verifyExpandedWindowContinuity()
    print("LinnetRimeCandidateSnapshotBuilderTests: PASS")
  }

  /// Exercise the real builder and AppKit packing across consecutive Rime
  /// contexts, rather than comparing unrelated static grid snapshots.
  private static func verifyExpandedWindowContinuity() {
    for pageSize in [9, 3] {
      for word in ["word", "longcandidateword"] {
        let strings = (0..<47).map { strdup(word + String(format: "%02d", $0))! }
        defer { strings.forEach { free($0) } }
        IteratorFixture.candidates = strings.map { text in
          var candidate = RimeCandidate()
          candidate.text = text
          return candidate
        }
        defer { IteratorFixture.candidates = [] }
        var api = RimeApi_stdbool()
        api.candidate_list_from_index = { _, iterator, start in
          IteratorFixture.starts += 1
          IteratorFixture.reads = 0
          iterator!.pointee.index = start - 1
          return true
        }
        api.candidate_list_next = { iterator in
          IteratorFixture.reads += 1
          let next = Int(iterator!.pointee.index) + 1
          guard IteratorFixture.candidates.indices.contains(next) else { return false }
          iterator!.pointee.index = Int32(next)
          iterator!.pointee.candidate = IteratorFixture.candidates[next]
          return true
        }
        api.candidate_list_end = { _ in IteratorFixture.ends += 1 }
        let grid = LinnetCandidateGridView(frame: .zero)
        var anchorPage = 0
        let maximumWidth: CGFloat = word == "word" ? 600 : 500
        var fittedColumns = 0

        func publish(_ absolute: Int) -> SquirrelInputController.CandidateSnapshot {
          let page = absolute / pageSize
          var context = RimeContext_stdbool()
          context.menu.page_no = Int32(page)
          context.menu.page_size = Int32(pageSize)
          context.menu.num_candidates = Int32(min(pageSize, strings.count - page * pageSize))
          context.menu.highlighted_candidate_index = Int32(absolute % pageSize)
          context.menu.is_last_page = (page + 1) * pageSize >= strings.count
          var compactCandidates = IteratorFixture.candidates
          let snapshot = compactCandidates.withUnsafeMutableBufferPointer { buffer in
            context.menu.candidates = buffer.baseAddress!.advanced(by: page * pageSize)
            return LinnetRimeCandidateSnapshotBuilder.build(
              context: context, labels: ["123456789"], expansionAnchorPage: anchorPage,
              session: 0, rimeAPI: api)!
          }
          require(snapshot.isExpanded && snapshot.items.count <= 27 && IteratorFixture.reads <= 27,
            "expanded snapshot exceeded its bounded iterator or fell back to compact")
          require(IteratorFixture.starts == IteratorFixture.ends,
            "expanded snapshot retained its Rime iterator")
          require(snapshot.items.map(\.absoluteIndex)
            == Array(snapshot.items.first!.absoluteIndex...snapshot.items.last!.absoluteIndex),
            "expanded snapshot reordered or skipped Rime candidates")
          anchorPage = snapshot.items.first!.page
          let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
          let attrs: [NSAttributedString.Key: Any] = [.font: font]
          let lines = snapshot.items.map {
            LinnetCandidatePresentation.candidateLine(
              candidateFormat: "[label] [candidate]", label: "7", candidate: $0.text,
              comment: "", candidateAttributes: attrs, labelAttributes: attrs,
              commentAttributes: attrs)
          }
          grid.publish(columns: 5, maximumRows: 3, lines: lines,
            highlighted: snapshot.highlightedItemIndex,
            firstCandidateIndex: snapshot.items.first!.absoluteIndex,
            candidateListEnd: snapshot.candidateListEnd,
            verticalText: false, columnSpacing: 8, rowSpacing: 6)
          grid.fitColumns(to: maximumWidth)
          let layout = LinnetCandidatePresentation.expandedGrid(
            widths: grid.subviews.prefix(lines.count).map(\.intrinsicContentSize.width),
            columns: 5, spacing: 8, maximumWidth: maximumWidth,
            visibleRows: 0..<3, highlighted: snapshot.highlightedItemIndex,
            firstCandidateIndex: snapshot.items.first!.absoluteIndex)
          fittedColumns = layout.columnWidths.count
          let selected = absolute / fittedColumns
          let cells = grid.geometries(in: grid)
          require(cells.contains { $0.itemIndex == snapshot.highlightedItemIndex },
            "window transition hid the highlighted candidate")
          for cell in cells {
            let item = snapshot.items[cell.itemIndex]
            let textView = grid.subviews[cell.itemIndex].subviews.first as! NSTextView
            let text = textView.textContentStorage?.attributedString?.string ?? ""
            if item.absoluteIndex / fittedColumns == selected {
              let number = item.absoluteIndex % fittedColumns + 1
              require(text.hasPrefix("\(number) ") &&
                grid.itemForSelectionNumber(number) == cell.itemIndex,
                "selection label/number lost its absolute column after window movement: "
                  + "pageSize=\(pageSize) word=\(word) selected=\(absolute) "
                  + "loaded=\(snapshot.items.first!.absoluteIndex)...\(snapshot.items.last!.absoluteIndex) "
                  + "columns=\(fittedColumns) item=\(item.absoluteIndex) local=\(cell.itemIndex) "
                  + "number=\(number) target=\(String(describing: grid.itemForSelectionNumber(number))) text=\(text)")
            }
            let center = NSPoint(x: cell.cellFrame.midX, y: cell.cellFrame.midY)
            let hit = cells.first { $0.cellFrame.contains(center) }
            require(hit.map { snapshot.items[$0.itemIndex].absoluteIndex } == item.absoluteIndex,
              "grid hit geometry referred to a different absolute candidate")
          }
          for number in 1...5 {
            let expected = snapshot.items.firstIndex {
              $0.absoluteIndex / fittedColumns == selected &&
                $0.absoluteIndex % fittedColumns == number - 1
            }
            require(grid.itemForSelectionNumber(number) == expected,
              "numeric selection escaped the displayed absolute row or numbered an unloaded cell")
          }
          return snapshot
        }

        func selectedFrame(_ snapshot: SquirrelInputController.CandidateSnapshot) -> NSRect {
          grid.geometries(in: grid).first { $0.itemIndex == snapshot.highlightedItemIndex }!.cellFrame
        }

        for edge in [26, 35] {
          let before = publish(edge)
          let previousFrame = selectedFrame(before)
          let columns = fittedColumns
          // Sequential Right/next-candidate updates still cross these exact
          // snapshot boundaries without reanchoring the visible grid.
          let after = publish(edge + 1)
          let nextFrame = selectedFrame(after)
          require(fittedColumns == columns,
            "unchanged word widths changed the fitted column count at a snapshot edge")
          if edge / columns == (edge + 1) / columns {
            require(abs(nextFrame.midY - previousFrame.midY) < 0.01 && nextFrame.minX > previousFrame.minX,
              "cross-snapshot neighbour jumped rows or restarted the absolute column")
          } else {
            require(nextFrame.minX == 0 && nextFrame.midY <= previousFrame.midY,
              "cross-snapshot new row jumped back to the top")
          }
        }
        for absolute in [24, 26, 35] {
          anchorPage = 0
          let before = publish(absolute)
          let columns = fittedColumns
          let target = grid.adjacentCandidateIndex(from: before.highlightedItemIndex, up: false)
          require(target == absolute + columns,
            "Down mistook the bounded iterator edge for a short final row")
          let after = publish(target!)
          require(after.items[after.highlightedItemIndex].absoluteIndex == target &&
            grid.adjacentCandidateIndex(from: after.highlightedItemIndex, up: true) == absolute,
            "Down/new snapshot/Up failed to retain the corresponding absolute column")
        }
        let loaded = publish(36)
        let first = loaded.items.first!.absoluteIndex
        let beforeUp = publish(first)
        let previousFrame = selectedFrame(beforeUp)
        let upTarget = first - fittedColumns
        require(grid.adjacentCandidateIndex(from: beforeUp.highlightedItemIndex, up: true) == upTarget,
          "Up abandoned the corresponding column before the loaded snapshot")
        let afterUp = publish(upTarget)
        require(afterUp.items[afterUp.highlightedItemIndex].absoluteIndex == upTarget &&
          selectedFrame(afterUp).midY >= previousFrame.midY,
          "Up across snapshots reinterpreted the viewport as a local row")
        _ = publish(strings.count - 1)
        let penultimateRow = publish(44)
        require(grid.adjacentCandidateIndex(from: penultimateRow.highlightedItemIndex, up: false)
          == min(44 + fittedColumns, strings.count - 1),
          "a genuine short final row did not clamp to its closest candidate")
        let final = publish(strings.count - 1)
        require(final.items.last!.absoluteIndex == strings.count - 1,
          "expanded final partial row lost its last Rime candidate")
        require(grid.adjacentCandidateIndex(from: final.highlightedItemIndex, up: false)
          == strings.count - 1, "Down moved beyond the genuine final row")
        require(word == "word" ? fittedColumns == 5 : fittedColumns < 5,
          "expanded columns followed compact page size or failed to fit long words")
        // A width change refits columns in the same live grid. Its selection
        // and labels must reproject the absolute identity, not the local offset.
        grid.fitColumns(to: 250)
        let refitted = grid.geometries(in: grid)
        let selected = refitted.first { $0.itemIndex == final.highlightedItemIndex }!
        let activeRow = refitted.filter { abs($0.cellFrame.midY - selected.cellFrame.midY) < 0.01 }
        for cell in activeRow {
          let textView = grid.subviews[cell.itemIndex].subviews.first as! NSTextView
          let text = textView.textContentStorage?.attributedString?.string ?? ""
          let number = Int(text.prefix(1))!
          require(grid.itemForSelectionNumber(number) == cell.itemIndex,
            "a live column refit separated the label from its candidate identity")
        }
        grid.clear()
      }
    }
  }

  private static func verifyCompactSnapshot(
    candidates: UnsafeMutablePointer<RimeCandidate>?
  ) {
    var context = RimeContext_stdbool()
    context.composition.length = 0
    context.menu.page_size = 9
    context.menu.page_no = 0
    context.menu.is_last_page = true
    context.menu.highlighted_candidate_index = 1
    context.menu.num_candidates = 2
    context.menu.candidates = candidates

    let snapshot = LinnetRimeCandidateSnapshotBuilder.build(
      context: context,
      labels: ["123456789"],
      expansionAnchorPage: nil,
      session: 0,
      rimeAPI: RimeApi_stdbool())
    require(
      snapshot == .init(
        items: [
          .init(
            absoluteIndex: 0, page: 0, indexOnPage: 0,
            text: "working", comment: "n. 工作", selectionLabel: "1"),
          .init(
            absoluteIndex: 1, page: 0, indexOnPage: 1,
            text: "workings", comment: "n. 运作", selectionLabel: "2"),
        ],
        currentPage: 0,
        pageSize: 9,
        highlightedItemIndex: 1,
        isLastPage: true,
        canExpand: false,
        isExpanded: false,
        candidateListEnd: 2),
      "zero-input predictions lost labels or the validated highlight in the builder"
    )

    context.menu.page_no = 2
    let finalPageSnapshot = LinnetRimeCandidateSnapshotBuilder.build(
      context: context,
      labels: ["123456789"],
      expansionAnchorPage: nil,
      session: 0,
      rimeAPI: RimeApi_stdbool())
    require(
      finalPageSnapshot?.items.map(\.absoluteIndex) == [18, 19] &&
        finalPageSnapshot?.canExpand == true,
      "a compact final page lost its absolute indices or earlier expandable pages"
    )

    context.menu.highlighted_candidate_index = 2
    require(
      LinnetRimeCandidateSnapshotBuilder.build(
        context: context,
        labels: ["123456789"],
        expansionAnchorPage: nil,
        session: 0,
        rimeAPI: RimeApi_stdbool()) == nil,
      "the builder accepted an out-of-range Rime highlight"
    )
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    guard condition() else {
      fputs("LinnetRimeCandidateSnapshotBuilderTests: FAIL: \(message)\n", stderr)
      exit(EXIT_FAILURE)
    }
  }
}
