import CryptoKit
import Foundation

private final class LinnetBufferedWriter {
  private let handle: FileHandle
  private var buffer = Data()

  init(_ url: URL) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
    buffer.reserveCapacity(1_048_576)
  }

  deinit { try? handle.close() }

  func append(_ value: String) throws {
    buffer.append(contentsOf: value.utf8)
    if buffer.count >= 1_048_576 { try flush() }
  }

  func row(_ key: String, _ value: String, _ weight: Int) throws {
    try linnetRequire(
      linnetIsTSVSafe(key) && linnetIsTSVSafe(value) && weight > 0,
      "invalid smart-index row")
    buffer.append(contentsOf: key.utf8)
    buffer.append(9)
    buffer.append(contentsOf: value.utf8)
    buffer.append(9)
    buffer.append(contentsOf: String(weight).utf8)
    buffer.append(10)
    if buffer.count >= 1_048_576 { try flush() }
  }

  func finish() throws {
    try flush()
    try handle.synchronize()
    try handle.close()
  }

  private func flush() throws {
    guard !buffer.isEmpty else { return }
    try handle.write(contentsOf: buffer)
    buffer.removeAll(keepingCapacity: true)
  }
}

private struct LinnetGeneratorOptions {
  let raw: [String: String]

  var source: URL { url("source") }
  var rimeIceSource: URL { url("rime-ice-source") }
  var decisions: URL { url("translation-decisions") }
  var newWords: URL { url("new-words-frequency") }
  var ipaOverrides: URL { url("ipa-overrides") }
  var lock: URL { url("lock") }
  var output: URL { url("output") }
  var buildPredict: URL { url("build-predict") }
  var enrichedPinyin: URL { url("enriched-pinyin") }
  var pinyinEmbargo: URL { url("pinyin-embargo") }

  private func url(_ name: String) -> URL {
    URL(fileURLWithPath: raw[name]!, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
      .standardizedFileURL
  }

  static func parse(_ arguments: [String]) throws -> Self {
    let expected = Set([
      "source", "rime-ice-source", "translation-decisions", "new-words-frequency",
      "ipa-overrides", "lock", "output", "build-predict", "enriched-pinyin",
      "pinyin-embargo",
    ])
    try linnetRequire(arguments.count == expected.count * 2, "invalid generator arguments")
    var values: [String: String] = [:]
    var cursor = 0
    while cursor < arguments.count {
      let option = arguments[cursor]
      try linnetRequire(option.hasPrefix("--"), "invalid generator option")
      let name = String(option.dropFirst(2))
      try linnetRequire(expected.contains(name) && values[name] == nil, "unknown generator option")
      values[name] = arguments[cursor + 1]
      cursor += 2
    }
    try linnetRequire(Set(values.keys) == expected, "missing generator option")
    return .init(raw: values)
  }
}

private struct LinnetIndexRow {
  let key: String
  let value: String
  let weight: Int
}

private struct LinnetDictionaryCounts {
  let entries: Int
  let texts: Int
}

private struct LinnetPhonexCounts {
  let buckets: Int
  let candidates: Int
}

private struct LinnetPinyinCounts {
  let sourceKeys: Int
  let sourceValues: Int
  let enrichedKeys: Int
  let enrichedValues: Int
  let embargoKeys: Int
  let embargoPairs: Int
  let projectedKeys: Int
  let projectedEdges: Int
  let embargoRemoved: Int
}

private struct LinnetIndexCounts {
  var namespaces: [String: Int] = [:]
  var ipaPlaceholdersDropped = 0
  var phonex = LinnetPhonexCounts(buckets: 0, candidates: 0)
  var pinyin = LinnetPinyinCounts(
    sourceKeys: 0, sourceValues: 0, enrichedKeys: 0, enrichedValues: 0,
    embargoKeys: 0, embargoPairs: 0, projectedKeys: 0, projectedEdges: 0,
    embargoRemoved: 0)

  var total: Int { namespaces.values.reduce(0, +) }
}

private struct LinnetArtifact {
  let bytes: Int
  let sha256: String

  var json: [String: Any] { ["bytes": bytes, "sha256": sha256] }
}

@main
enum LinnetEnglishDataGenerator {
  private static let outputs = Set([
    "linnet_en.dict.yaml", "linnet.smart-index.tsv", "linnet.smart.db",
    "linnet.english-data-manifest.json",
  ])

  static func main() {
    do {
      let options = try LinnetGeneratorOptions.parse(Array(CommandLine.arguments.dropFirst()))
      let result = try generate(options)
      print(
        "generate-linnet-english-data: PASS (\(result.dictionary.entries) dictionary entries, "
          + "\(result.index.total) smart-index rows, \(result.newWords) reviewed new entries)")
    } catch LinnetEnglishDataError.invalid(let detail) {
      fputs("generate-linnet-english-data: ERROR: \(detail)\n", stderr)
      exit(1)
    } catch {
      fputs("generate-linnet-english-data: ERROR: generation failed\n", stderr)
      exit(1)
    }
  }

  private static func generate(
    _ options: LinnetGeneratorOptions
  ) throws -> (dictionary: LinnetDictionaryCounts, index: LinnetIndexCounts, newWords: Int) {
    let snapshot = try LinnetEnglishSourceSnapshot.load(
      lockURL: options.lock, hallelujahRoot: options.source,
      rimeIceRoot: options.rimeIceSource)
    let translations = try LinnetTranslationInputs.load(
      decisionsURL: options.decisions, newWordsURL: options.newWords,
      ipaURL: options.ipaOverrides, snapshot: snapshot)
    let manager = FileManager.default
    let output = options.output
    let parent = output.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    try linnetRequire(
      !manager.fileExists(atPath: output.path)
        && manager.fileExists(atPath: parent.path, isDirectory: &isDirectory)
        && isDirectory.boolValue, "unsafe English output root")
    let staging = parent.appendingPathComponent(".linnet-english-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    var published = false
    defer { if !published { try? manager.removeItem(at: staging) } }

    let dictionaryURL = staging.appendingPathComponent("linnet_en.dict.yaml")
    let indexURL = staging.appendingPathComponent("linnet.smart-index.tsv")
    let databaseURL = staging.appendingPathComponent("linnet.smart.db")
    let manifestURL = staging.appendingPathComponent("linnet.english-data-manifest.json")
    let dictionaryCounts = try writeDictionary(
      dictionaryURL, snapshot: snapshot, translations: translations)
    let indexCounts = try writeIndex(
      indexURL, snapshot: snapshot, translations: translations,
      enrichedPinyin: options.enrichedPinyin, embargo: options.pinyinEmbargo)
    try buildDatabase(
      executable: options.buildPredict, index: indexURL, output: databaseURL,
      forbidden: [options.source.path, options.rimeIceSource.path, staging.path, output.path])
    let beforeManifest = try Set(manager.contentsOfDirectory(atPath: staging.path))
    try linnetRequire(
      beforeManifest == outputs.subtracting(["linnet.english-data-manifest.json"]),
      "unexpected English projection artifact")
    try writeManifest(
      manifestURL, options: options, snapshot: snapshot, translations: translations,
      dictionaryCounts: dictionaryCounts, indexCounts: indexCounts,
      dictionaryURL: dictionaryURL, indexURL: indexURL, databaseURL: databaseURL)
    let finalEntries = try Set(manager.contentsOfDirectory(atPath: staging.path))
    try linnetRequire(
      finalEntries == outputs,
      "incomplete English projection")
    try manager.moveItem(at: staging, to: output)
    published = true
    return (dictionaryCounts, indexCounts, translations.newWords.count)
  }

  private static func writeDictionary(
    _ url: URL, snapshot: LinnetEnglishSourceSnapshot,
    translations: LinnetTranslationInputs
  ) throws -> LinnetDictionaryCounts {
    struct Row {
      let text: String
      let code: String
      let weight: String?
    }
    var rows = snapshot.words.map {
      Row(text: $0.key, code: $0.key, weight: String($0.value.frequency))
    }
    rows.append(contentsOf: snapshot.rimeIceRows.map {
      Row(text: $0.text, code: $0.code, weight: $0.weight)
    })
    rows.append(contentsOf: translations.newWords.map {
      Row(
        text: $0.key, code: $0.key.replacingOccurrences(of: "'", with: ""),
        weight: String($0.value))
    })
    rows.sort {
      if $0.text != $1.text { return linnetByteLess($0.text, $1.text) }
      if $0.code != $1.code { return linnetByteLess($0.code, $1.code) }
      return linnetByteLess($0.weight ?? "", $1.weight ?? "")
    }
    let writer = try LinnetBufferedWriter(url)
    try writer.append(
      """
      # Generated from locked Hallelujah and rime-ice releases; do not edit.
      # Hallelujah owns overlapping word frequency and Smart metadata.
      # Preserved non-letter rime-ice codes do not override raw/code-token routing.
      # Linnet-reviewed new words carry their reviewed rank as weight.
      # Apostrophes are stripped from their codes so contractions stay typable.
      # SPDX-License-Identifier: GPL-3.0-or-later
      ---
      name: linnet_en
      version: "hallelujah-\(snapshot.lock.hallelujahTag)+rime-ice-\(snapshot.lock.rimeIceTag)"
      sort: by_weight
      use_preset_vocabulary: false
      columns:
        - text
        - code
        - weight
      ...

      """)
    for row in rows {
      try linnetRequire(linnetIsMetadataKeySafe(row.text) && linnetIsTSVSafe(row.code), "invalid dictionary row")
      try writer.append(row.text + "\t" + row.code)
      if let weight = row.weight { try writer.append("\t" + weight) }
      try writer.append("\n")
    }
    try writer.finish()
    return .init(entries: rows.count, texts: Set(rows.map(\.text)).count)
  }

  private static func writeIndex(
    _ url: URL, snapshot: LinnetEnglishSourceSnapshot,
    translations: LinnetTranslationInputs, enrichedPinyin: URL, embargo: URL
  ) throws -> LinnetIndexCounts {
    let writer = try LinnetBufferedWriter(url)
    var counts = LinnetIndexCounts()
    counts.phonex = try writePhonex(
      writer, snapshot: snapshot, reviewedNewWords: translations.newWords)
    counts.namespaces["f"] = counts.phonex.candidates

    var rows: [LinnetIndexRow] = []
    var placeholders = 0
    for (word, record) in snapshot.words {
      let ipa = translations.ipaOverrides[word] ?? record.ipa
      if ipa == "-" { continue }
      if ipa.range(of: #"^[A-Za-z]+\*$"#, options: .regularExpression) != nil {
        placeholders += 1
        continue
      }
      rows.append(.init(key: "m/ipa/\(word)", value: ipa, weight: record.frequency))
    }
    try writeSorted(rows, to: writer)
    counts.namespaces["m/ipa"] = rows.count
    counts.ipaPlaceholdersDropped = placeholders

    rows = translations.decisions.compactMap {
      $0.value == "-" ? .init(key: "m/skip/\($0.key)", value: "1", weight: 1) : nil
    }
    try writeSorted(rows, to: writer)
    counts.namespaces["m/skip"] = rows.count

    rows = []
    rows.reserveCapacity(snapshot.words.count + snapshot.rimeIceCounts.complementTexts)
    for (word, record) in snapshot.words {
      if translations.decisions[word] == "-" { continue }
      let raw = translations.decisions[word] ?? record.translation
      rows.append(.init(
        key: "m/zh/\(word)", value: try linnetNormalizeDisplayTranslation(raw),
        weight: record.frequency))
    }
    for text in Set(snapshot.rimeIceRows.map(\.text)) {
      guard let decision = translations.decisions[text], decision != "-" else { continue }
      rows.append(.init(key: "m/zh/\(text)", value: decision, weight: 1))
    }
    for (text, weight) in translations.newWords {
      guard let decision = translations.decisions[text], decision != "-" else { continue }
      rows.append(.init(key: "m/zh/\(text)", value: decision, weight: weight))
    }
    try writeSorted(rows, to: writer)
    counts.namespaces["m/zh"] = rows.count

    rows = snapshot.ngrams.map {
      .init(key: "n/\($0.context)", value: $0.nextWord, weight: $0.frequency)
    }
    try writeSorted(rows, to: writer)
    counts.namespaces["n"] = rows.count

    counts.pinyin = try writePinyin(
      writer, base: snapshot.inputURLs["pinyin_to_english"]!,
      enriched: enrichedPinyin, embargoURL: embargo)
    counts.namespaces["p"] = counts.pinyin.projectedEdges
    try writer.finish()
    return counts
  }

  private static func writeSorted(
    _ input: [LinnetIndexRow], to writer: LinnetBufferedWriter
  ) throws {
    let rows = input.sorted {
      if $0.key != $1.key { return linnetByteLess($0.key, $1.key) }
      if $0.weight != $1.weight { return $0.weight > $1.weight }
      return linnetByteLess($0.value, $1.value)
    }
    for row in rows { try writer.row(row.key, row.value, row.weight) }
  }

  private static func stringArrays(_ url: URL) throws -> [String: [String]] {
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let object = value as? [String: Any] else {
      throw LinnetEnglishDataError.invalid("JSON mapping is not an object")
    }
    var result: [String: [String]] = [:]
    result.reserveCapacity(object.count)
    for (key, raw) in object {
      guard let values = raw as? [String], !values.isEmpty else {
        throw LinnetEnglishDataError.invalid("JSON mapping has invalid candidates")
      }
      result[key] = values
    }
    return result
  }

  private static func writePhonex(
    _ writer: LinnetBufferedWriter, snapshot: LinnetEnglishSourceSnapshot,
    reviewedNewWords: [String: Int]
  ) throws -> LinnetPhonexCounts {
    var buckets = try stringArrays(snapshot.inputURLs["phonex_index"]!)
    for (code, words) in buckets {
      for word in words {
        try linnetRequire(
          linnetPhonex(word) == code,
          "locked Phonex bucket differs from the native-compatible encoder")
      }
    }
    for word in reviewedNewWords.keys.sorted() {
      guard let code = linnetPhonex(word) else { continue }
      buckets[code, default: []].append(word)
    }
    var candidateCount = 0
    for bucket in buckets.keys.sorted() {
      try linnetRequire(
        !bucket.isEmpty && bucket.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) },
        "invalid Phonex bucket")
      var seen = Set<String>()
      var rows: [LinnetIndexRow] = []
      for word in buckets[bucket]! {
        guard let weight = snapshot.words[word]?.frequency ?? reviewedNewWords[word] else {
          throw LinnetEnglishDataError.invalid("Phonex word is absent")
        }
        try linnetRequire(linnetIsASCIIWord(word) && seen.insert(word).inserted, "invalid Phonex word")
        rows.append(.init(key: "f/\(bucket)", value: word, weight: weight))
      }
      try linnetRequire(rows.count <= 64, "Phonex bucket exceeds runtime limit")
      try writeSorted(rows, to: writer)
      candidateCount += rows.count
    }
    return .init(buckets: buckets.count, candidates: candidateCount)
  }

  private static func loadEmbargo(_ url: URL) throws -> [String: Set<String>] {
    let data = try Data(contentsOf: url)
    try linnetRequire(!data.contains(13), "pinyin embargo has CR bytes")
    guard let text = String(data: data, encoding: .utf8) else {
      throw LinnetEnglishDataError.invalid("pinyin embargo is not UTF-8")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    try linnetRequire(lines.first == "pinyin_key\tcandidate", "invalid pinyin embargo header")
    var result: [String: Set<String>] = [:]
    for row in lines.dropFirst() where !row.isEmpty {
      let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      try linnetRequire(
        fields.count == 2 && linnetIsASCIIWord(fields[0])
          && normalizePinyin(fields[1]) == fields[1], "invalid pinyin embargo row")
      let candidate = fields[1].lowercased()
      try linnetRequire(result[fields[0], default: []].insert(candidate).inserted, "duplicate pinyin embargo row")
    }
    try linnetRequire(!result.isEmpty, "empty pinyin embargo")
    return result
  }

  private static func normalizePinyin(_ raw: String) -> String? {
    let value = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    guard !value.isEmpty, value.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }),
      value.utf8.allSatisfy({ (32...126).contains($0) })
    else { return nil }
    return value
  }

  private static func writePinyin(
    _ writer: LinnetBufferedWriter, base: URL, enriched: URL, embargoURL: URL
  ) throws -> LinnetPinyinCounts {
    let baseMapping = try stringArrays(base)
    let enrichedMapping = try stringArrays(enriched)
    let embargo = try loadEmbargo(embargoURL)
    var keys = Array(enrichedMapping.keys)
    keys.append(contentsOf: baseMapping.keys.filter { enrichedMapping[$0] == nil })
    keys.sort()
    var projectedKeys = 0
    var projectedEdges = 0
    var removed = 0
    for key in keys where linnetIsASCIIWord(key) {
      let candidates = enrichedMapping[key] ?? baseMapping[key]!
      var seen = Set<String>()
      var retained: [String] = []
      for raw in candidates {
        guard let value = normalizePinyin(raw), seen.insert(value).inserted else { continue }
        if embargo[key]?.contains(value.lowercased()) == true {
          removed += 1
          continue
        }
        retained.append(value)
        if retained.count == 64 { break }
      }
      guard !retained.isEmpty else { continue }
      projectedKeys += 1
      for (rank, value) in retained.enumerated() {
        try writer.row("p/\(key)", value, 64 - rank)
        projectedEdges += 1
      }
    }
    return .init(
      sourceKeys: baseMapping.count,
      sourceValues: baseMapping.values.reduce(0) { $0 + $1.count },
      enrichedKeys: enrichedMapping.count,
      enrichedValues: enrichedMapping.values.reduce(0) { $0 + $1.count },
      embargoKeys: embargo.count,
      embargoPairs: embargo.values.reduce(0) { $0 + $1.count },
      projectedKeys: projectedKeys, projectedEdges: projectedEdges,
      embargoRemoved: removed)
  }

  private static func buildDatabase(
    executable: URL, index: URL, output: URL, forbidden: [String]
  ) throws {
    let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey, .isSymbolicLinkKey])
    try linnetRequire(
      values.isRegularFile == true && values.isExecutable == true && values.isSymbolicLink != true,
      "build_predict is missing or unsafe")
    let input = try FileHandle(forReadingFrom: index)
    defer { try? input.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = [output.path]
    process.currentDirectoryURL = output.deletingLastPathComponent()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try linnetRequire(process.terminationStatus == 0, "build_predict failed")
    let data = try Data(contentsOf: output)
    try linnetRequire(!data.isEmpty && !data.starts(with: Data("SQLite format 3\0".utf8)), "invalid smart database")
    for value in forbidden where !value.isEmpty {
      try linnetRequire(data.range(of: Data(value.utf8)) == nil, "smart database leaks a build path")
    }
  }

  private static func artifact(_ url: URL) throws -> LinnetArtifact {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else {
      throw LinnetEnglishDataError.invalid("artifact size is unavailable")
    }
    return .init(bytes: size.intValue, sha256: try linnetSHA256(url))
  }

  private static func relativeInput(_ raw: String) -> String {
    raw.hasPrefix(FileManager.default.currentDirectoryPath + "/")
      ? String(raw.dropFirst(FileManager.default.currentDirectoryPath.count + 1)) : raw
  }

  private static func writeManifest(
    _ url: URL, options: LinnetGeneratorOptions,
    snapshot: LinnetEnglishSourceSnapshot, translations: LinnetTranslationInputs,
    dictionaryCounts: LinnetDictionaryCounts, indexCounts: LinnetIndexCounts,
    dictionaryURL: URL, indexURL: URL, databaseURL: URL
  ) throws {
    let artifacts = [
      "linnet_en.dict.yaml": try artifact(dictionaryURL).json,
      "linnet.smart-index.tsv": try artifact(indexURL).json,
      "linnet.smart.db": try artifact(databaseURL).json,
    ]
    let lockInputs = snapshot.lock.hallelujahInputs.keys.sorted().reduce(into: [String: String]()) {
      $0[$1] = snapshot.lock.hallelujahInputs[$1]!.sha256
    }
    let rimeInputs = try snapshot.rimeIceInputURLs.keys.sorted().reduce(into: [String: String]()) {
      $0[$1] = try linnetSHA256(snapshot.rimeIceInputURLs[$1]!)
    }
    let ngramCounts = snapshot.ngramCounts.keys.sorted().reduce(into: [String: Int]()) {
      $0[String($1)] = snapshot.ngramCounts[$1]
    }
    let rime = snapshot.rimeIceCounts
    let manifest: [String: Any] = [
      "format": 4,
      "generator": ["name": "LinnetEnglishDataGenerator", "version": 1],
      "sources": [
        "hallelujah": [
          "repository": snapshot.lock.hallelujahRepository,
          "tag": snapshot.lock.hallelujahTag,
          "commit": snapshot.lock.hallelujahCommit,
          "tree": snapshot.lock.hallelujahTree,
          "inputs": lockInputs,
        ],
        "rime_ice": [
          "repository": snapshot.lock.rimeIceRepository,
          "tag": snapshot.lock.rimeIceTag,
          "commit": snapshot.lock.rimeIceCommit,
          "tree": snapshot.lock.rimeIceTree,
          "inputs": rimeInputs,
        ],
        "curated_translations": [
          "input": relativeInput(options.raw["translation-decisions"]!),
          "bytes": translations.decisionData.count,
          "sha256": SHA256.hash(data: translations.decisionData).map { String(format: "%02x", $0) }.joined(),
        ],
        "curated_new_words": [
          "input": relativeInput(options.raw["new-words-frequency"]!),
          "bytes": translations.newWordData.count,
          "sha256": SHA256.hash(data: translations.newWordData).map { String(format: "%02x", $0) }.joined(),
        ],
        "curated_ipa": [
          "input": relativeInput(options.raw["ipa-overrides"]!),
          "bytes": translations.ipaData.count,
          "sha256": SHA256.hash(data: translations.ipaData).map { String(format: "%02x", $0) }.joined(),
        ],
        "enriched_pinyin": [
          "input": relativeInput(options.raw["enriched-pinyin"]!),
          "bytes": (try artifact(options.enrichedPinyin)).bytes,
          "sha256": try linnetSHA256(options.enrichedPinyin),
        ],
        "pinyin_embargo": [
          "input": relativeInput(options.raw["pinyin-embargo"]!),
          "bytes": (try artifact(options.pinyinEmbargo)).bytes,
          "sha256": try linnetSHA256(options.pinyinEmbargo),
        ],
      ],
      "source_counts": [
        "hallelujah": [
          "words": snapshot.words.count,
          "ngrams": ["total": snapshot.ngrams.count, "by_order": ngramCounts],
          "phonex": ["buckets": indexCounts.phonex.buckets, "candidates": indexCounts.phonex.candidates],
          "pinyin": ["keys": indexCounts.pinyin.sourceKeys, "values": indexCounts.pinyin.sourceValues],
        ],
        "rime_ice": ["rows": rime.sourceRows, "texts": rime.sourceTexts, "pairs": rime.sourcePairs],
        "curated_translations": translations.decisionCounts,
        "enriched_pinyin": ["keys": indexCounts.pinyin.enrichedKeys, "values": indexCounts.pinyin.enrichedValues],
        "pinyin_embargo": ["keys": indexCounts.pinyin.embargoKeys, "pairs": indexCounts.pinyin.embargoPairs],
      ],
      "projection_counts": [
        "dictionary_entries": dictionaryCounts.entries,
        "dictionary_texts": dictionaryCounts.texts,
        "rime_ice_complement": [
          "overlap_texts": rime.overlapTexts,
          "complement_texts": rime.complementTexts,
          "complement_pairs": rime.complementPairs,
          "letter_code_pairs": rime.letterCodePairs,
          "raw_boundary_pairs": rime.rawBoundaryPairs,
        ],
        "curated_new_entries": ["texts": translations.newWords.count],
        "smart_index_rows": indexCounts.total,
        "namespace_rows": indexCounts.namespaces,
        "ipa_placeholders_dropped": indexCounts.ipaPlaceholdersDropped,
        "ipa_overrides": translations.ipaOverrides.count,
        "pinyin_keys": indexCounts.pinyin.projectedKeys,
        "pinyin_edges": indexCounts.pinyin.projectedEdges,
        "pinyin_embargo_removed": indexCounts.pinyin.embargoRemoved,
      ],
      "normalization": [
        "ordinary_english_owner": "standard Rime table_translator",
        "translation_owner": "one reviewed decision ledger over pinned Hallelujah and rime-ice bytes",
        "pinyin_candidate_cap": 64,
        "rime_ice_overlap_policy": "exclude exact texts already owned by Hallelujah",
      ],
      "outputs": artifacts,
    ]
    var data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    try data.write(to: url, options: .withoutOverwriting)
  }
}
