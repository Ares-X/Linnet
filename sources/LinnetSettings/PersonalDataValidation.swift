import Foundation

extension LinnetPersonalDataStore {
  struct Snapshot: Equatable, Sendable {
    let data: LinnetPersonalData
    let revision: String
  }
}

enum LinnetPersonalDataValidation: Equatable, Sendable {
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
  }

  enum Reason: Equatable, Sendable {
    case missing
    case invalid
    case duplicate
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

extension LinnetPersonalDataStore {
  static func validate(_ data: LinnetPersonalData) -> LinnetPersonalDataValidation {
    validate(data, checkCancellation: {})
  }

  static func validate(
    _ data: LinnetPersonalData,
    checkCancellation: CancellationCheck
  ) rethrows -> LinnetPersonalDataValidation {
    try checkCancellation()

    let customWords = try validateCustomWords(
      data.customWords, checkCancellation: checkCancellation)
    guard case .valid(let normalizedCustomWords) = customWords else {
      return customWords.validationFailure
    }
    let expansions = try validateExpansions(
      data.expansions, checkCancellation: checkCancellation)
    guard case .valid(let normalizedExpansions) = expansions else {
      return expansions.validationFailure
    }
    let disabledWords = try validateDisabledWords(
      data.disabledWords, checkCancellation: checkCancellation)
    guard case .valid(let normalizedDisabledWords) = disabledWords else {
      return disabledWords.validationFailure
    }
    try checkCancellation()
    return .valid(
      .init(
        customWords: normalizedCustomWords,
        disabledWordRows: normalizedDisabledWords,
        expansions: normalizedExpansions
      )
    )
  }

  static func normalized(_ data: LinnetPersonalData) throws -> LinnetPersonalData {
    switch validate(data) {
    case .valid(let normalized):
      return normalized
    case .invalid(let issue):
      throw Failure.invalidData(issue)
    }
  }
}

private extension LinnetPersonalDataStore {
  static let customWordCodeExpression = try! NSRegularExpression(
    pattern: #"^[a-z0-9;']+(?: [a-z0-9;']+)*$"#
  )
  static let expansionTriggerExpression = try! NSRegularExpression(
    pattern: #"^x;[-0-9A-Za-z_]+$"#
  )

  enum ValidationResult<Value> {
    case valid(Value)
    case invalid(LinnetPersonalDataValidation.Issue)

    var validationFailure: LinnetPersonalDataValidation {
      guard case .invalid(let issue) = self else {
        preconditionFailure("A valid result cannot produce a validation failure.")
      }
      return .invalid(issue)
    }
  }

  static func invalid<Value>(
    _ location: LinnetPersonalDataValidation.Location,
    _ reason: LinnetPersonalDataValidation.Reason
  ) -> ValidationResult<Value> {
    .invalid(.init(location: location, reason: reason))
  }

  static func validateCustomWords(
    _ rows: [LinnetPersonalData.CustomWord],
    checkCancellation: CancellationCheck
  ) rethrows -> ValidationResult<[LinnetPersonalData.CustomWord]> {
    var customCodes = Set<String>()
    var customWords: [LinnetPersonalData.CustomWord] = []
    for row in rows {
      try checkCancellation()
      let customWord: LinnetPersonalData.CustomWord?
      switch normalizedCustomWord(row) {
      case .valid(let normalized): customWord = normalized
      case .invalid(let issue): return .invalid(issue)
      }
      guard let customWord else { continue }
      guard customCodes.insert(customWord.code).inserted else {
        return invalid(.customWord(row.id, .code), .duplicate)
      }
      customWords.append(customWord)
    }
    return .valid(customWords)
  }

  static func normalizedCustomWord(
    _ row: LinnetPersonalData.CustomWord
  ) -> ValidationResult<LinnetPersonalData.CustomWord?> {
    let value = row.value.trimmingCharacters(in: .whitespaces)
    let code = row.code.trimmingCharacters(in: .whitespaces).lowercased()
    if value.isEmpty, code.isEmpty { return .valid(nil) }
    if value.isEmpty { return invalid(.customWord(row.id, .value), .missing) }
    if code.isEmpty { return invalid(.customWord(row.id, .code), .missing) }
    guard validValue(value) else {
      return invalid(.customWord(row.id, .value), .invalid)
    }
    guard customWordCodeExpression.firstMatch(
      in: code,
      range: NSRange(code.startIndex..<code.endIndex, in: code)
    ) != nil else {
      return invalid(.customWord(row.id, .code), .invalid)
    }
    return .valid(.init(id: row.id, value: value, code: code))
  }

  static func validateExpansions(
    _ rows: [LinnetPersonalData.Expansion],
    checkCancellation: CancellationCheck
  ) rethrows -> ValidationResult<[LinnetPersonalData.Expansion]> {
    var triggers = Set<String>()
    var expansions: [LinnetPersonalData.Expansion] = []
    for row in rows {
      try checkCancellation()
      let expansion: LinnetPersonalData.Expansion?
      switch normalizedExpansion(row) {
      case .valid(let normalized): expansion = normalized
      case .invalid(let issue): return .invalid(issue)
      }
      guard let expansion else { continue }
      guard triggers.insert(expansion.trigger).inserted else {
        return invalid(.expansion(row.id, .trigger), .duplicate)
      }
      expansions.append(expansion)
    }
    return .valid(expansions)
  }

  static func normalizedExpansion(
    _ row: LinnetPersonalData.Expansion
  ) -> ValidationResult<LinnetPersonalData.Expansion?> {
    let value = row.value.trimmingCharacters(in: .whitespaces)
    let trigger = row.trigger.trimmingCharacters(in: .whitespaces)
    if value.isEmpty, trigger.isEmpty || trigger == "x;" { return .valid(nil) }
    if value.isEmpty { return invalid(.expansion(row.id, .value), .missing) }
    if trigger.isEmpty || trigger == "x;" {
      return invalid(.expansion(row.id, .trigger), .missing)
    }
    guard validValue(value) else {
      return invalid(.expansion(row.id, .value), .invalid)
    }
    guard expansionTriggerExpression.firstMatch(
      in: trigger,
      range: NSRange(trigger.startIndex..<trigger.endIndex, in: trigger)
    ) != nil else {
      return invalid(.expansion(row.id, .trigger), .invalid)
    }
    return .valid(.init(id: row.id, value: value, trigger: trigger))
  }

  static func validateDisabledWords(
    _ rows: [LinnetPersonalData.DisabledWord],
    checkCancellation: CancellationCheck
  ) rethrows -> ValidationResult<[LinnetPersonalData.DisabledWord]> {
    var disabledWords: [LinnetPersonalData.DisabledWord] = []
    for row in rows {
      try checkCancellation()
      let normalized = row.value.trimmingCharacters(in: .whitespaces).lowercased()
      if normalized.isEmpty { continue }
      guard validValue(normalized) else {
        return invalid(.disabledWord(row.identifier), .invalid)
      }
      disabledWords.append(.init(identifier: row.identifier, value: normalized))
    }
    try checkCancellation()
    let uniqueDisabledWords = Dictionary(grouping: disabledWords, by: \.value).values
      .compactMap(\.first).sorted { $0.value < $1.value }
    return .valid(uniqueDisabledWords)
  }
}
