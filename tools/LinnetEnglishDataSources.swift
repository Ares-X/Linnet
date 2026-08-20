import CryptoKit
import Foundation
import SQLite3

enum LinnetEnglishDataError: Error {
  case invalid(String)
}

@inline(__always)
func linnetRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw LinnetEnglishDataError.invalid(message) }
}

func linnetSHA256(_ url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = SHA256()
  while true {
    let data = try handle.read(upToCount: 1_048_576) ?? Data()
    if data.isEmpty { break }
    hasher.update(data: data)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func linnetByteLess(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

func linnetIsTSVSafe(_ value: String) -> Bool {
  !value.isEmpty && !value.contains { $0 == "\t" || $0 == "\r" || $0 == "\n" }
}

func linnetIsMetadataKeySafe(_ value: String) -> Bool {
  linnetIsTSVSafe(value) && value.utf8.count <= 512
    && value.unicodeScalars.allSatisfy {
      !($0.value < 0x20 || (0x7f...0x9f).contains($0.value)
        || $0.value == 0x2028 || $0.value == 0x2029)
    }
}

func linnetIsASCIIWord(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) }
}

/// Locked Hallelujah Phonex projection for reviewed lowercase words that are
/// absent from its precomputed bucket file. Runtime query encoding remains in
/// SmartEnglishIndex; the native acceptance probe verifies both sides agree.
func linnetPhonex(_ value: String) -> String? {
  guard linnetIsASCIIWord(value) else { return nil }
  var name = value.utf8.map { $0 - 32 }
  while name.last == 83 { name.removeLast() }  // S
  guard !name.isEmpty else { return nil }

  if name.count >= 2 {
    switch (name[0], name[1]) {
    case (75, 78): name[0] = 78; name.remove(at: 1)  // KN -> N
    case (80, 72): name[0] = 70; name.remove(at: 1)  // PH -> F
    case (87, 82): name[0] = 82; name.remove(at: 1)  // WR -> R
    default: break
    }
  }
  if name.first == 72 { name.removeFirst() }  // H
  guard !name.isEmpty else { return nil }

  let vowels = Array("AEIOUY".utf8)
  let firstGroups: [(Array<UInt8>, UInt8)] = [
    (vowels, 65), (Array("BP".utf8), 66), (Array("VF".utf8), 70),
    (Array("KQC".utf8), 67), (Array("JG".utf8), 71),
    (Array("ZS".utf8), 83),
  ]
  for (letters, replacement) in firstGroups where letters.contains(name[0]) {
    name[0] = replacement
    break
  }

  var code = [name[0]]
  var last = name[0]
  if name.count > 1 {
    for index in 1..<name.count {
      let letter = name[index]
      let next = index + 1 < name.count ? name[index + 1] : 0
      let encoding: UInt8
      if Array("BPFV".utf8).contains(letter) {
        encoding = 49
      } else if Array("CSKGJQXZ".utf8).contains(letter) {
        encoding = 50
      } else if (letter == 68 || letter == 84) && next != 67 {
        encoding = 51
      } else if letter == 76 && (vowels.contains(next) || index + 1 == name.count) {
        encoding = 52
      } else if letter == 77 || letter == 78 {
        if next == 68 || next == 71 { name[index + 1] = letter }
        encoding = 53
      } else if letter == 82 && (vowels.contains(next) || index + 1 == name.count) {
        encoding = 54
      } else {
        encoding = 48
      }
      if encoding != last && encoding != 48 { code.append(encoding) }
      last = code.last!
    }
  }
  return String(bytes: code, encoding: .utf8)
}

func linnetContainsCJK(_ value: String) -> Bool {
  value.unicodeScalars.contains {
    (0x3400...0x4dbf).contains($0.value)
      || (0x4e00...0x9fff).contains($0.value)
      || (0xf900...0xfaff).contains($0.value)
  }
}

private func replacingRegex(
  _ pattern: String, in value: String, with replacement: String
) throws -> String {
  let expression = try NSRegularExpression(pattern: pattern)
  let range = NSRange(value.startIndex..., in: value)
  return expression.stringByReplacingMatches(
    in: value, range: range, withTemplate: replacement)
}

private func unescapeNumericEntities(_ input: String) throws -> String {
  var value = try replacingRegex("&%23([0-9]+);", in: input, with: "&#$1;")
  let expression = try NSRegularExpression(pattern: "&#(?:x([0-9A-Fa-f]+)|([0-9]+));")
  let matches = expression.matches(
    in: value, range: NSRange(value.startIndex..., in: value)).reversed()
  for match in matches {
    let fullRange = Range(match.range(at: 0), in: value)!
    let hexRange = Range(match.range(at: 1), in: value)
    let decimalRange = Range(match.range(at: 2), in: value)
    let scalarValue: UInt32?
    if let hexRange {
      scalarValue = UInt32(value[hexRange], radix: 16)
    } else if let decimalRange {
      scalarValue = UInt32(value[decimalRange], radix: 10)
    } else {
      scalarValue = nil
    }
    if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
      value.replaceSubrange(fullRange, with: String(scalar))
    }
  }
  return value
    .replacingOccurrences(of: "&ouml;", with: "ö")
    .replacingOccurrences(of: "&Eacute;", with: "É")
    .replacingOccurrences(of: "&nbsp;", with: "\u{00a0}")
    .replacingOccurrences(of: "&amp;", with: "&")
    .replacingOccurrences(of: "&lt;", with: "<")
    .replacingOccurrences(of: "&gt;", with: ">")
    .replacingOccurrences(of: "&quot;", with: "\"")
    .replacingOccurrences(of: "&#x27;", with: "'")
}

private func balanceDisplayBrackets(_ value: String) -> String {
  let pairs: [Character: Character] = ["(": ")", "（": "）", "[": "]", "【": "】"]
  let closers = Set(pairs.values)
  var stack: [Character] = []
  var output: [Character] = []
  for character in value {
    if let closer = pairs[character] {
      stack.append(closer)
      output.append(character)
    } else if closers.contains(character) {
      if stack.last == character {
        stack.removeLast()
        output.append(character)
      }
    } else {
      output.append(character)
    }
  }
  output.append(contentsOf: stack.reversed())
  return String(output)
}

private func truncateDisplayTranslation(_ value: String) throws -> String {
  let limit = 240
  guard value.count > limit else { return balanceDisplayBrackets(value) }
  let prefix = Array(value.prefix(limit))
  let boundaries = Set<Character>(["；", "。", "！", "？", "、", "/", " "])
  for index in prefix.indices.reversed() where index > 0 && boundaries.contains(prefix[index]) {
    var candidate = String(prefix[..<index])
      .trimmingCharacters(in: CharacterSet(charactersIn: "；;，,、/ "))
    candidate = balanceDisplayBrackets(candidate)
    if !candidate.isEmpty && candidate.count < limit { return candidate + "…" }
  }
  throw LinnetEnglishDataError.invalid("translation has no safe truncation boundary")
}

func linnetNormalizeDisplayTranslation(_ input: String) throws -> String {
  var value = try unescapeNumericEntities(input)
  value = try replacingRegex(#" *(?:\r\n|\r|\n)+ *"#, in: value, with: " / ")
  value = String(value.unicodeScalars.map {
    ($0.value < 0x20 || (0x7f...0x9f).contains($0.value)
      || $0.value == 0x2028 || $0.value == 0x2029) ? " " : Character($0)
  })
  value = try replacingRegex(#"\s*(?:[|；;])\s*"#, in: value, with: "；")
  value = try replacingRegex(#"\s+"#, in: value, with: " ")
    .trimmingCharacters(in: CharacterSet(charactersIn: " ；"))
  value = try replacingRegex(#"\b[A-Z][A-Za-z]{1,30}:\."#, in: value, with: "")
  value = try replacingRegex(#"\s*(?:[|；;])\s*"#, in: value, with: "；")
    .trimmingCharacters(in: CharacterSet(charactersIn: "； "))
  let repeatedPOS = #"\b((?:n|v|vt|vi|adj|adv|prep|conj|pron|aux|abbr|num|int|interj|art)\.)\1"#
  while true {
    let normalized = try replacingRegex(repeatedPOS, in: value, with: "$1")
    if normalized == value { break }
    value = normalized
  }
  let emptyPOS = try NSRegularExpression(
    pattern: #"^(?:n|v|vt|vi|adj|adv|prep|conj|pron|aux|abbr|num|int|interj|art)\.$"#)
  value = value.split(separator: "；", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter {
      !$0.isEmpty
        && emptyPOS.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil
    }
    .joined(separator: "；")
  value = try truncateDisplayTranslation(value)
  value = try replacingRegex(#"\s*(?:[|；;])\s*"#, in: value, with: "；")
    .trimmingCharacters(in: CharacterSet(charactersIn: "； "))
  try linnetRequire(
    linnetIsTSVSafe(value) && linnetContainsCJK(value) && value.count <= 240,
    "invalid display translation")
  return value
}

struct LinnetEnglishLock {
  let hallelujahRepository: String
  let hallelujahTag: String
  let hallelujahCommit: String
  let hallelujahTree: String
  let hallelujahInputs: [String: (path: String, sha256: String)]
  let rimeIceRepository: String
  let rimeIceTag: String
  let rimeIceCommit: String
  let rimeIceTree: String

  static func load(_ url: URL) throws -> Self {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let root = object as? [String: Any],
      let sources = root["sources"] as? [String: Any],
      let hallelujah = sources["hallelujah"] as? [String: Any],
      let rimeIce = sources["rime_ice"] as? [String: Any],
      let repository = hallelujah["repository"] as? String,
      repository == "https://github.com/dongyuwei/hallelujahIM.git",
      let tag = hallelujah["tag"] as? String,
      let commit = hallelujah["commit"] as? String,
      let tree = hallelujah["tree"] as? String,
      let rawInputs = hallelujah["m2_inputs"] as? [String: Any],
      let iceRepository = rimeIce["repository"] as? String,
      iceRepository == "https://github.com/iDvel/rime-ice.git",
      let iceTag = rimeIce["tag"] as? String,
      let iceCommit = rimeIce["commit"] as? String,
      let iceTree = rimeIce["tree"] as? String
    else { throw LinnetEnglishDataError.invalid("invalid upstream lock") }
    let expected = Set(["english_database", "pinyin_to_english", "phonex_index", "phonex_algorithm"])
    try linnetRequire(Set(rawInputs.keys) == expected, "invalid Hallelujah input set")
    var inputs: [String: (path: String, sha256: String)] = [:]
    for name in expected {
      guard let item = rawInputs[name] as? [String: Any],
        let path = item["path"] as? String,
        let sha256 = item["sha256"] as? String,
        !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
        sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
      else { throw LinnetEnglishDataError.invalid("invalid locked input: \(name)") }
      inputs[name] = (path, sha256)
    }
    return .init(
      hallelujahRepository: repository, hallelujahTag: tag,
      hallelujahCommit: commit, hallelujahTree: tree, hallelujahInputs: inputs,
      rimeIceRepository: iceRepository, rimeIceTag: iceTag,
      rimeIceCommit: iceCommit, rimeIceTree: iceTree)
  }
}

struct LinnetEnglishWord {
  let frequency: Int
  let translation: String
  let ipa: String
}

struct LinnetEnglishNGram {
  let order: Int
  let context: String
  let nextWord: String
  let frequency: Int
}

struct LinnetRimeEnglishRow {
  let text: String
  let code: String
  let weight: String?
}

struct LinnetRimeEnglishCounts {
  let sourceRows: Int
  let sourceTexts: Int
  let sourcePairs: Int
  let overlapTexts: Int
  let complementTexts: Int
  let complementPairs: Int
  let letterCodePairs: Int
  let rawBoundaryPairs: Int
}

struct LinnetEnglishSourceSnapshot {
  let lock: LinnetEnglishLock
  let inputURLs: [String: URL]
  let rimeIceInputURLs: [String: URL]
  let words: [String: LinnetEnglishWord]
  let ngrams: [LinnetEnglishNGram]
  let ngramCounts: [Int: Int]
  let rimeIceRows: [LinnetRimeEnglishRow]
  let rimeIceCounts: LinnetRimeEnglishCounts

  private static func safeFile(root: URL, relative: String) throws -> URL {
    var cursor = root
    for part in relative.split(separator: "/") {
      cursor.appendPathComponent(String(part), isDirectory: false)
      let values = try cursor.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      try linnetRequire(values.isSymbolicLink != true, "locked input traverses a symlink")
    }
    let values = try cursor.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    try linnetRequire(values.isRegularFile == true && values.isSymbolicLink != true, "locked input is missing")
    return cursor
  }

  static func load(lockURL: URL, hallelujahRoot: URL, rimeIceRoot: URL) throws -> Self {
    let lock = try LinnetEnglishLock.load(lockURL)
    var inputURLs: [String: URL] = [:]
    for (name, input) in lock.hallelujahInputs {
      let url = try safeFile(root: hallelujahRoot, relative: input.path)
      let digest = try linnetSHA256(url)
      try linnetRequire(digest == input.sha256, "locked Hallelujah bytes changed")
      inputURLs[name] = url
    }
    let rimeInputs = [
      "en": try safeFile(root: rimeIceRoot, relative: "en_dicts/en.dict.yaml"),
      "en_ext": try safeFile(root: rimeIceRoot, relative: "en_dicts/en_ext.dict.yaml"),
    ]
    let (words, ngrams, ngramCounts) = try loadDatabase(inputURLs["english_database"]!)
    let (rows, counts) = try loadRimeIce(rimeInputs, words: words)
    return .init(
      lock: lock, inputURLs: inputURLs, rimeIceInputURLs: rimeInputs,
      words: words, ngrams: ngrams, ngramCounts: ngramCounts,
      rimeIceRows: rows, rimeIceCounts: counts)
  }

  private static func loadDatabase(
    _ url: URL
  ) throws -> ([String: LinnetEnglishWord], [LinnetEnglishNGram], [Int: Int]) {
    var database: OpaquePointer?
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw LinnetEnglishDataError.invalid("invalid Hallelujah database URL")
    }
    components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    guard let databaseURI = components.string,
      sqlite3_open_v2(
        databaseURI, &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil
      ) == SQLITE_OK,
      let database
    else { throw LinnetEnglishDataError.invalid("cannot open Hallelujah database") }
    defer { sqlite3_close(database) }
    try linnetRequire(
      sqlite3_exec(database, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil)
        == SQLITE_OK, "cannot make Hallelujah database read-only")
    var check: OpaquePointer?
    try linnetRequire(
      sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK,
      "cannot check Hallelujah database")
    defer { sqlite3_finalize(check) }
    try linnetRequire(
      sqlite3_step(check) == SQLITE_ROW && String(cString: sqlite3_column_text(check, 0)) == "ok"
        && sqlite3_step(check) == SQLITE_DONE, "Hallelujah database quick_check failed")

    var words: [String: LinnetEnglishWord] = [:]
    var statement: OpaquePointer?
    try linnetRequire(
      sqlite3_prepare_v2(
        database, "SELECT word, frequency, translation, ipa FROM words", -1, &statement, nil)
        == SQLITE_OK, "cannot query Hallelujah words")
    while sqlite3_step(statement) == SQLITE_ROW {
      guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
        sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
        sqlite3_column_type(statement, 2) == SQLITE_TEXT,
        sqlite3_column_type(statement, 3) == SQLITE_TEXT
      else { throw LinnetEnglishDataError.invalid("invalid Hallelujah word row") }
      let word = String(cString: sqlite3_column_text(statement, 0))
      let frequency = Int(sqlite3_column_int64(statement, 1))
      var translation = String(cString: sqlite3_column_text(statement, 2))
      let ipa = String(cString: sqlite3_column_text(statement, 3))
      translation = try replacingRegex(#" *(?:\r\n|\r|\n)+ *"#, in: translation, with: " / ")
      try linnetRequire(
        linnetIsASCIIWord(word) && frequency > 0 && linnetIsTSVSafe(translation)
          && linnetIsTSVSafe(ipa) && words[word] == nil, "invalid Hallelujah word")
      words[word] = .init(frequency: frequency, translation: translation, ipa: ipa)
    }
    sqlite3_finalize(statement)
    try linnetRequire(!words.isEmpty, "empty Hallelujah word table")

    var ngrams: [LinnetEnglishNGram] = []
    var ngramCounts: [Int: Int] = [:]
    statement = nil
    try linnetRequire(
      sqlite3_prepare_v2(
        database, "SELECT n, context, next_word, frequency FROM ngrams", -1, &statement, nil)
        == SQLITE_OK, "cannot query Hallelujah ngrams")
    while sqlite3_step(statement) == SQLITE_ROW {
      let order = Int(sqlite3_column_int64(statement, 0))
      let context = String(cString: sqlite3_column_text(statement, 1))
      let nextWord = String(cString: sqlite3_column_text(statement, 2))
      let frequency = Int(sqlite3_column_int64(statement, 3))
      let joined = context + nextWord
      try linnetRequire(
        (2...5).contains(order) && linnetIsTSVSafe(context) && linnetIsTSVSafe(nextWord)
          && joined.utf8.allSatisfy { (32...126).contains($0) }
          && joined.lowercased() == joined && context.split(separator: " ").count + 1 == order
          && frequency > 0, "invalid Hallelujah ngram")
      ngrams.append(.init(
        order: order, context: context, nextWord: nextWord, frequency: frequency))
      ngramCounts[order, default: 0] += 1
    }
    sqlite3_finalize(statement)
    try linnetRequire(!ngrams.isEmpty, "empty Hallelujah ngram table")
    return (words, ngrams, ngramCounts)
  }

  private static func loadRimeIce(
    _ paths: [String: URL], words: [String: LinnetEnglishWord]
  ) throws -> ([LinnetRimeEnglishRow], LinnetRimeEnglishCounts) {
    var sourceRows: [LinnetRimeEnglishRow] = []
    for name in ["en_ext", "en"] {
      let data = try Data(contentsOf: paths[name]!)
      try linnetRequire(!data.contains(13), "rime-ice English dictionary has CR bytes")
      guard let payload = String(data: data, encoding: .utf8),
        let marker = payload.range(of: "...\n")
      else { throw LinnetEnglishDataError.invalid("invalid rime-ice dictionary") }
      let header = String(payload[..<marker.lowerBound])
      try linnetRequire(
        header.contains("name: \(name)\n") && header.contains("sort: by_weight\n"),
        "invalid rime-ice dictionary header")
      for line in payload[marker.upperBound...].split(separator: "\n") {
        if line.isEmpty || line.hasPrefix("#") { continue }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        try linnetRequire(fields.count == 2 || fields.count == 3, "invalid rime-ice row")
        let weight = fields.count == 3 ? fields[2] : nil
        try linnetRequire(
          linnetIsMetadataKeySafe(fields[0]) && linnetIsTSVSafe(fields[1])
            && (weight == nil || (Int(weight!) ?? 0) > 0 && !weight!.hasPrefix("0")),
          "invalid rime-ice row")
        sourceRows.append(.init(text: fields[0], code: fields[1], weight: weight))
      }
    }
    let sourceTexts = Set(sourceRows.map(\.text))
    let sourcePairs = Set(sourceRows.map { $0.text + "\u{0}" + $0.code })
    let overlap = sourceTexts.intersection(words.keys)
    var complement: [String: LinnetRimeEnglishRow] = [:]
    for row in sourceRows where words[row.text] == nil {
      let key = row.text + "\u{0}" + row.code
      if complement[key] == nil { complement[key] = row }
    }
    let rows = Array(complement.values)
    let complementTexts = Set(rows.map(\.text)).count
    let letterCodes = rows.count { !$0.code.isEmpty && $0.code.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0)
    }}
    return (
      rows,
      .init(
        sourceRows: sourceRows.count, sourceTexts: sourceTexts.count,
        sourcePairs: sourcePairs.count, overlapTexts: overlap.count,
        complementTexts: complementTexts, complementPairs: rows.count,
        letterCodePairs: letterCodes, rawBoundaryPairs: rows.count - letterCodes))
  }
}

struct LinnetTranslationInputs {
  let decisions: [String: String]
  let newWords: [String: Int]
  let ipaOverrides: [String: String]
  let decisionCounts: [String: [String: Int]]
  let decisionData: Data
  let newWordData: Data
  let ipaData: Data

  static func load(
    decisionsURL: URL, newWordsURL: URL, ipaURL: URL,
    snapshot: LinnetEnglishSourceSnapshot
  ) throws -> Self {
    let decisionData = try Data(contentsOf: decisionsURL)
    let newWordData = try Data(contentsOf: newWordsURL)
    let ipaData = try Data(contentsOf: ipaURL)
    let decisions = try loadDecisions(decisionData)
    let newWords = try loadNewWords(newWordData)
    let ipa = try loadIPA(ipaData, words: snapshot.words)
    let missing = Set(snapshot.words.compactMap {
      linnetContainsCJK($0.value.translation) ? nil : $0.key
    })
    let complement = Set(snapshot.rimeIceRows.map(\.text))
    try linnetRequire(missing.isDisjoint(with: complement), "English translation owners overlap")
    try linnetRequire(missing.union(complement).isSubset(of: decisions.keys), "missing reviewed translations")
    let replacements = Set(decisions.keys.filter {
      snapshot.words[$0] != nil && !missing.contains($0)
    })
    let newEntries = Set(decisions.keys).subtracting(snapshot.words.keys).subtracting(complement)
    try linnetRequire(Set(newWords.keys) == newEntries, "new English word ledger differs")
    try linnetRequire(replacements.allSatisfy { decisions[$0] != "-" }, "replacement was skipped")
    var counts: [String: [String: Int]] = [:]
    for (name, values) in [
      ("hallelujah_missing_chinese", missing), ("rime_ice_complement", complement),
      ("curated_replacements", replacements), ("curated_new_words", newEntries),
    ] where !values.isEmpty {
      let translated = values.count { decisions[$0] != "-" }
      counts[name] = [
        "total": values.count, "translated": translated,
        "skipped_proper_term": values.count - translated,
      ]
    }
    counts["total"] = ["total", "translated", "skipped_proper_term"].reduce(into: [:]) {
      total, key in total[key] = counts.values.compactMap { $0[key] }.reduce(0, +)
    }
    return .init(
      decisions: decisions, newWords: newWords, ipaOverrides: ipa,
      decisionCounts: counts, decisionData: decisionData,
      newWordData: newWordData, ipaData: ipaData)
  }

  private static func lines(_ data: Data, header: String) throws -> [Substring] {
    try linnetRequire(data.last == 10 && !data.contains(13), "ledger has invalid line endings")
    guard let value = String(data: data, encoding: .utf8) else {
      throw LinnetEnglishDataError.invalid("ledger is not UTF-8")
    }
    let rows = value.split(separator: "\n", omittingEmptySubsequences: false)
    try linnetRequire(rows.first == Substring(header), "ledger header changed")
    return Array(rows.dropFirst().dropLast())
  }

  private static func loadDecisions(_ data: Data) throws -> [String: String] {
    var result: [String: String] = [:]
    var previous: String?
    for row in try lines(data, header: "text\ttranslation") {
      let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      try linnetRequire(fields.count == 2 && linnetIsMetadataKeySafe(fields[0])
        && linnetIsTSVSafe(fields[1]) && result[fields[0]] == nil
        && (fields[1] == "-" || linnetContainsCJK(fields[1])), "invalid translation decision")
      if let previous { try linnetRequire(linnetByteLess(previous, fields[0]), "decisions are not sorted") }
      previous = fields[0]
      result[fields[0]] = fields[1] == "-" ? "-" : try linnetNormalizeDisplayTranslation(fields[1])
    }
    return result
  }

  private static func loadNewWords(_ data: Data) throws -> [String: Int] {
    var result: [String: Int] = [:]
    var previous: String?
    for row in try lines(data, header: "text\tfrequency") {
      let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      let frequency = fields.count == 2 ? Int(fields[1]) : nil
      try linnetRequire(fields.count == 2 && linnetIsMetadataKeySafe(fields[0])
        && frequency != nil && frequency! > 0 && !fields[1].hasPrefix("0")
        && result[fields[0]] == nil, "invalid new English word")
      if fields[0].contains("'") {
        try linnetRequire(linnetIsASCIIWord(fields[0].replacingOccurrences(of: "'", with: "")), "invalid contraction")
      }
      if let previous { try linnetRequire(linnetByteLess(previous, fields[0]), "new words are not sorted") }
      previous = fields[0]
      result[fields[0]] = frequency
    }
    return result
  }

  private static func loadIPA(
    _ data: Data, words: [String: LinnetEnglishWord]
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    var previous: String?
    for row in try lines(data, header: "text\tipa") {
      let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      let placeholder = fields.count == 2 && fields[1].range(
        of: #"^[A-Za-z]+\*$"#, options: .regularExpression) != nil
      try linnetRequire(fields.count == 2 && linnetIsASCIIWord(fields[0])
        && words[fields[0]] != nil && result[fields[0]] == nil
        && (fields[1] == "-" || linnetIsTSVSafe(fields[1]) && !placeholder), "invalid IPA override")
      if let previous { try linnetRequire(linnetByteLess(previous, fields[0]), "IPA overrides are not sorted") }
      previous = fields[0]
      result[fields[0]] = fields[1]
    }
    try linnetRequire(!result.isEmpty, "empty IPA override ledger")
    return result
  }
}
