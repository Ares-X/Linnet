import Foundation

extension LinnetPersonalDataStore {
  struct Snapshot: Equatable, Sendable {
    let data: LinnetPersonalData
    let revision: String
  }

  /// Decoded identity of the immutable backup-v2 personal-data boundary.
  /// Only restore/import code may consume this retired physical format.
  struct LegacyV2Snapshot: Equatable, Sendable {
    let data: LinnetPersonalData
    let sentenceCapitalization: Bool
    let tabBehavior: String
    let revision: String
  }
}

enum LinnetPersonalDataValidation: Equatable, Sendable {
  enum Collection: Equatable, Sendable {
    case customWords
    case disabledWords
    case expansions
  }

  enum CustomField: Equatable, Sendable {
    case value
    case code
  }

  enum ExpansionField: Equatable, Sendable {
    case value
    case trigger
  }

  enum Location: Equatable, Sendable {
    case customWord(UUID, CustomField)
    case disabledWord(UUID)
    case expansion(UUID, ExpansionField)
    case collection(Collection)
  }

  enum Reason: Equatable, Sendable {
    case missing
    case invalid
    case tooLarge
    case duplicate
    case tooMany
  }

  struct Issue: Equatable, Sendable {
    let location: Location
    let reason: Reason
  }

  case valid(LinnetPersonalData)
  case invalid(Issue)

  var firstIssue: Issue? {
    guard case .invalid(let issue) = self else { return nil }
    return issue
  }

  var isValid: Bool { if case .valid = self { true } else { false } }
}
