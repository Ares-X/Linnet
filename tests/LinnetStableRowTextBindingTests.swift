import Darwin
import Foundation
import SwiftUI

@main
struct LinnetStableRowTextBindingTests {
  @MainActor
  static func main() {
    testCustomWordBindingsSurviveRowRemoval()
    testDisabledWordBindingSurvivesRowRemoval()
    testExpansionBindingsSurviveRowRemoval()
    print("LinnetStableRowTextBindingTests: PASS")
  }

  @MainActor
  private static func testCustomWordBindingsSurviveRowRemoval() {
    let first = LinnetPersonalData.CustomWord(value: "first", code: "first-code")
    let second = LinnetPersonalData.CustomWord(value: "second", code: "second-code")
    let box = DraftBox(customWords: [first, second])
    let staleValue = binding(
      box: box, rowID: first.id, fallback: first.value,
      field: .init(rows: \.customWords, identifier: \.id, value: \.value))
    let liveCode = binding(
      box: box, rowID: second.id, fallback: second.code,
      field: .init(rows: \.customWords, identifier: \.id, value: \.code))

    box.draft.customWords.removeFirst()
    require(staleValue.wrappedValue == "first", "retired custom-word read lost its last value")
    staleValue.wrappedValue = "must-not-return"
    liveCode.wrappedValue = "updated-code"
    require(
      box.draft.customWords == [
        .init(id: second.id, value: "second", code: "updated-code")
      ],
      "retired custom-word write changed the surviving row"
    )
  }

  @MainActor
  private static func testDisabledWordBindingSurvivesRowRemoval() {
    let first = LinnetPersonalData.DisabledWord(value: "first")
    let second = LinnetPersonalData.DisabledWord(value: "second")
    let box = DraftBox(disabledWords: [first, second])
    let staleValue = binding(
      box: box, rowID: first.identifier, fallback: first.value,
      field: .init(rows: \.disabledWords, identifier: \.identifier, value: \.value))
    let liveValue = binding(
      box: box, rowID: second.identifier, fallback: second.value,
      field: .init(rows: \.disabledWords, identifier: \.identifier, value: \.value))

    box.draft.disabledWords.removeFirst()
    require(staleValue.wrappedValue == "first", "retired disabled-word read lost its last value")
    staleValue.wrappedValue = "must-not-return"
    liveValue.wrappedValue = "updated"
    require(
      box.draft.disabledWords == [.init(identifier: second.identifier, value: "updated")],
      "retired disabled-word write changed the surviving row"
    )
  }

  @MainActor
  private static func testExpansionBindingsSurviveRowRemoval() {
    let first = LinnetPersonalData.Expansion(value: "first", trigger: "x;first")
    let second = LinnetPersonalData.Expansion(value: "second", trigger: "x;second")
    let box = DraftBox(expansions: [first, second])
    let staleValue = binding(
      box: box, rowID: first.id, fallback: first.value,
      field: .init(rows: \.expansions, identifier: \.id, value: \.value))
    let liveTrigger = binding(
      box: box, rowID: second.id, fallback: second.trigger,
      field: .init(rows: \.expansions, identifier: \.id, value: \.trigger))

    box.draft.expansions.removeFirst()
    require(staleValue.wrappedValue == "first", "retired expansion read lost its last value")
    staleValue.wrappedValue = "must-not-return"
    liveTrigger.wrappedValue = "x;updated"
    require(
      box.draft.expansions == [
        .init(id: second.id, value: "second", trigger: "x;updated")
      ],
      "retired expansion write changed the surviving row"
    )
  }

  @MainActor
  private static func binding<Row>(
    box: DraftBox,
    rowID: UUID,
    fallback: String,
    field: LinnetStableRowTextBinding.Field<Row>
  ) -> Binding<String> {
    LinnetStableRowTextBinding.make(
      draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
      rowIdentifier: rowID,
      fallback: fallback,
      field: field
    )
  }

  @MainActor
  private final class DraftBox {
    var draft: LinnetPersonalData

    init(
      customWords: [LinnetPersonalData.CustomWord] = [],
      disabledWords: [LinnetPersonalData.DisabledWord] = [],
      expansions: [LinnetPersonalData.Expansion] = []
    ) {
      draft = .init(
        customWords: customWords,
        disabledWordRows: disabledWords,
        expansions: expansions
      )
    }
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(
        Data("LinnetStableRowTextBindingTests: FAIL: \(message)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
