import SwiftUI

/// Owns the lifetime boundary between an editable SwiftUI row and its
/// identity-stable personal-data record. A retired row may receive one final
/// presentation read or write while AppKit ends text editing.
@MainActor
enum LinnetStableRowTextBinding {
  struct Field<Row> {
    let rows: WritableKeyPath<LinnetPersonalData, [Row]>
    let identifier: KeyPath<Row, UUID>
    let value: WritableKeyPath<Row, String>
  }

  static func make<Row>(
    draft: Binding<LinnetPersonalData>,
    rowIdentifier: UUID,
    fallback: String,
    field: Field<Row>
  ) -> Binding<String> {
    Binding(
      get: {
        draft.wrappedValue[keyPath: field.rows]
          .first { $0[keyPath: field.identifier] == rowIdentifier }?[keyPath: field.value]
          ?? fallback
      },
      set: { updatedValue in
        var latestDraft = draft.wrappedValue
        guard let index = latestDraft[keyPath: field.rows]
          .firstIndex(where: { $0[keyPath: field.identifier] == rowIdentifier })
        else { return }
        latestDraft[keyPath: field.rows][index][keyPath: field.value] = updatedValue
        draft.wrappedValue = latestDraft
      }
    )
  }
}
