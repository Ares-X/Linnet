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
  }
}

@main
struct LinnetRimeCandidateSnapshotBuilderTests {
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
    print("LinnetRimeCandidateSnapshotBuilderTests: PASS")
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
      expansionRequested: false,
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
        isExpanded: false),
      "zero-input predictions lost labels or the validated highlight in the builder"
    )

    context.menu.highlighted_candidate_index = 2
    require(
      LinnetRimeCandidateSnapshotBuilder.build(
        context: context,
        labels: ["123456789"],
        expansionRequested: false,
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
