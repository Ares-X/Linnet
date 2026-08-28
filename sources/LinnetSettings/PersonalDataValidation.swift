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

extension LinnetPersonalDataStore {
  static func validate(_ data: LinnetPersonalData) -> LinnetPersonalDataValidation {
    validate(data, checkCancellation: {})
  }

  static func validate(
    _ data: LinnetPersonalData,
    checkCancellation: CancellationCheck
  ) rethrows -> LinnetPersonalDataValidation {
    try checkCancellation()
    guard data.customWords.count <= maximumRows else {
      return invalid(.collection(.customWords), .tooMany)
    }
    guard data.disabledWords.count <= maximumRows else {
      return invalid(.collection(.disabledWords), .tooMany)
    }
    guard data.expansions.count <= maximumRows else {
      return invalid(.collection(.expansions), .tooMany)
    }

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

  static func invalid(
    _ location: LinnetPersonalDataValidation.Location,
    _ reason: LinnetPersonalDataValidation.Reason
  ) -> LinnetPersonalDataValidation {
    .invalid(.init(location: location, reason: reason))
  }

  static func addRenderedBytes(_ bytes: Int, to total: inout Int) -> Bool {
    guard bytes >= 0, bytes <= maximumFileBytes - total else { return false }
    total += bytes
    return true
  }

  static func validateCustomWords(
    _ rows: [LinnetPersonalData.CustomWord],
    checkCancellation: CancellationCheck
  ) rethrows -> ValidationResult<[LinnetPersonalData.CustomWord]> {
    var customFileBytes = table(name: customWordsFile, rows: []).utf8.count
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
      let lineBytes = customWord.value.utf8.count + 1 + customWord.code.utf8.count
      guard lineBytes <= maximumLineBytes,
        addRenderedBytes(lineBytes + (customWords.isEmpty ? 0 : 1), to: &customFileBytes)
      else {
        return invalid(.collection(.customWords), .tooLarge)
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
    guard fieldIsBounded(value) else {
      return invalid(.customWord(row.id, .value), .tooLarge)
    }
    guard fieldIsBounded(code) else {
      return invalid(.customWord(row.id, .code), .tooLarge)
    }
    guard validValue(value) else {
      return invalid(.customWord(row.id, .value), .invalid)
    }
    guard code.range(
      of: #"^[a-z0-9;']+(?: [a-z0-9;']+)*$"#,
      options: .regularExpression
    ) != nil else {
      return invalid(.customWord(row.id, .code), .invalid)
    }
    return .valid(.init(id: row.id, value: value, code: code))
  }

  static func validateExpansions(
    _ rows: [LinnetPersonalData.Expansion],
    checkCancellation: CancellationCheck
  ) rethrows -> ValidationResult<[LinnetPersonalData.Expansion]> {
    var expansionFileBytes = table(name: expansionsFile, rows: []).utf8.count
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
      let lineBytes = expansion.value.utf8.count + 1 + expansion.trigger.utf8.count
      guard lineBytes <= maximumLineBytes,
        addRenderedBytes(lineBytes + (expansions.isEmpty ? 0 : 1), to: &expansionFileBytes)
      else {
        return invalid(.collection(.expansions), .tooLarge)
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
    guard fieldIsBounded(value) else {
      return invalid(.expansion(row.id, .value), .tooLarge)
    }
    guard fieldIsBounded(trigger) else {
      return invalid(.expansion(row.id, .trigger), .tooLarge)
    }
    guard validValue(value) else {
      return invalid(.expansion(row.id, .value), .invalid)
    }
    guard trigger.range(
      of: #"^x;[-0-9A-Za-z_]+$"#,
      options: .regularExpression
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
      guard fieldIsBounded(normalized) else {
        return invalid(.disabledWord(row.identifier), .tooLarge)
      }
      guard validValue(normalized) else {
        return invalid(.disabledWord(row.identifier), .invalid)
      }
      disabledWords.append(.init(identifier: row.identifier, value: normalized))
    }
    try checkCancellation()
    let uniqueDisabledWords = Dictionary(grouping: disabledWords, by: \.value).values
      .compactMap(\.first).sorted { $0.value < $1.value }
    if !uniqueDisabledWords.isEmpty {
      var userSettingsBytes = 128
      for (index, row) in uniqueDisabledWords.enumerated() {
        try checkCancellation()
        guard let json = try? JSONEncoder().encode(row.value) else {
          return invalid(.collection(.disabledWords), .invalid)
        }
        let lineBytes = 4 + json.count
        guard lineBytes <= maximumLineBytes,
          addRenderedBytes(lineBytes + (index == 0 ? 0 : 1), to: &userSettingsBytes)
        else {
          return invalid(.collection(.disabledWords), .tooLarge)
        }
      }
    }
    return .valid(uniqueDisabledWords)
  }
}
