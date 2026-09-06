import SQLite3
import Darwin
import Foundation

@main
struct HallelujahSubstitutionImporterTests {
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static func main() {
    do {
      try testImportConflictsUnicodeAndIdempotence()
      try testCanonicalFingerprintIgnoresInsertionOrder()
      try testUnsafeRowsFailClosed()
      try testSchemaAndDestinationFailClosed()
      try testPreparedSnapshotDoesNotReopenSource()
      try testSQLiteInterruptionClassification()
      try testBoundedPreflightAndMergeCancellation()
      print("HallelujahSubstitutionImporterTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testImportConflictsUnicodeAndIdempotence() throws {
    try inTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("substitutions.sqlite3")
      let destination = directory.appendingPathComponent("linnet_text_expander.txt")
      try makeDatabase(
        source,
        rows: [
          ("foo", "ignored collision"),
          ("NI_HAO", "你好，世界 👋"),
          ("BR", "replacement must not win"),
          ("hash", "# heading"),
          ("Foo", "kept collision"),
          ("unicode_line", "first\u{2028}second"),
        ])
      let originalDatabase = try Data(contentsOf: source)
      expect(
        chmod(source.path, S_IRUSR | S_IRGRP | S_IROTH) == 0,
        "could not make source fixture read-only")
      try Data("# Rime table\n# coding: utf-8\nBest regards,\tx;br\n".utf8)
        .write(to: destination)

      let report = try importSource(
        sourceDatabase: source, destinationTable: destination)
      expect(report.importedCount == 4, "only non-conflicting normalized rows are imported")
      expect(try Data(contentsOf: source) == originalDatabase, "source SQLite bytes changed")

      let output = try String(contentsOf: destination, encoding: .utf8)
      expect(try tableFingerprint(at: destination).count == 64,
             "fingerprint must be lowercase SHA-256")
      expect(
        output.contains("# no comment\n"), "hash-leading values need the Rime no-comment contract")
      expect(output.contains("你好，世界 👋\tx;ni_hao\n"), "Unicode value was not preserved")
      expect(
        output.contains("first\u{2028}second\tx;unicode_line\n"),
        "Rime-safe Unicode line separator was not preserved")
      expect(output.contains("# heading\tx;hash\n"), "hash-leading value was not preserved")
      expect(output.contains("Best regards,\tx;br\n"), "existing value was overwritten")
      expect(!output.contains("replacement must not win"), "source overwrote an existing trigger")
      expect(output.contains("kept collision\tx;foo\n"), "stable case-fold winner changed")
      expect(!output.contains("ignored collision"), "case-fold collision winner was duplicated")
      let codes = dataLines(output).map { $0.split(separator: "\t")[1] }
      expect(
        codes == ["x;br", "x;foo", "x;hash", "x;ni_hao", "x;unicode_line"],
        "stable table rows are not canonically sorted")

      let beforeSecondRun = try Data(contentsOf: destination)
      let second = try importSource(
        sourceDatabase: source, destinationTable: destination)
      expect(second.importedCount == 0, "same canonical source must be idempotent")
      expect(
        try Data(contentsOf: destination) == beforeSecondRun,
        "idempotent run rewrote destination bytes")
    }
  }

  private static func testCanonicalFingerprintIgnoresInsertionOrder() throws {
    try inTemporaryDirectory { directory in
      let rows = [("Alpha", "一"), ("beta_2", "two"), ("Z-last", "末")]
      let first = directory.appendingPathComponent("first.sqlite3")
      let second = directory.appendingPathComponent("second.sqlite3")
      let firstTable = directory.appendingPathComponent("first.txt")
      let secondTable = directory.appendingPathComponent("second.txt")
      try makeDatabase(first, rows: rows)
      try makeDatabase(second, rows: rows.reversed())
      _ = try importSource(sourceDatabase: first, destinationTable: firstTable)
      _ = try importSource(sourceDatabase: second, destinationTable: secondTable)
      let firstFingerprint = try tableFingerprint(at: firstTable)
      let secondFingerprint = try tableFingerprint(at: secondTable)
      expect(
        firstFingerprint == secondFingerprint,
        "canonical fingerprint depends on SQLite insertion order")
      expect(
        firstFingerprint
          == "598a5a320b966bba11f75e1e0dc101ed6641d7de4e5ea5d288911b9e39123f56",
        "canonical fingerprint contract changed: \(firstFingerprint)")
    }
  }

  private static func testUnsafeRowsFailClosed() throws {
    try inTemporaryDirectory { directory in
      let cases: [(String, String, HallelujahSubstitutionImporter.Failure)] = [
        ("bad;key", "value", .invalidTrigger(row: 1)),
        ("empty", "", .emptyValue(row: 1)),
        ("multiline", "first\nsecond", .unrepresentableValue(row: 1)),
        ("tabbed", "first\tsecond", .unrepresentableValue(row: 1)),
      ]
      for (index, item) in cases.enumerated() {
        let source = directory.appendingPathComponent("unsafe-\(index).sqlite3")
        try makeDatabase(source, rows: [(item.0, item.1)])
        expectFailure(item.2) {
          _ = try importSource(
            sourceDatabase: source,
            destinationTable: directory.appendingPathComponent("unsafe-\(index).txt"))
        }
      }
    }
  }

  private static func testSchemaAndDestinationFailClosed() throws {
    try inTemporaryDirectory { directory in
      let invalidSchema = directory.appendingPathComponent("invalid.sqlite3")
      try makeDatabase(
        invalidSchema,
        schema: "CREATE TABLE substitutions(key TEXT PRIMARY KEY, value TEXT, extra TEXT)",
        rows: [])
      expectFailure(.invalidSchema) {
        _ = try importSource(
          sourceDatabase: invalidSchema,
          destinationTable: directory.appendingPathComponent("invalid.txt"))
      }
      let wrongCase = directory.appendingPathComponent("wrong-case.sqlite3")
      try makeDatabase(
        wrongCase, schema: "CREATE TABLE Substitutions(key TEXT PRIMARY KEY, value TEXT)", rows: [])
      expectFailure(.invalidSchema) {
        _ = try importSource(
          sourceDatabase: wrongCase,
          destinationTable: directory.appendingPathComponent("wrong-case.txt"))
      }

      let source = directory.appendingPathComponent("valid.sqlite3")
      try makeDatabase(source, rows: [("one", "1")])
      let sourceLink = directory.appendingPathComponent("source-link.sqlite3")
      try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
      expectFailure(.unsafeSource("source-link.sqlite3")) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: sourceLink, timeout: 10)
      }
      let preparedSource = try HallelujahSubstitutionImporter.prepare(
        sourceDatabase: source, timeout: 10)
      expectFailure(.unsafeDestination) {
        _ = try HallelujahSubstitutionImporter.merge(
          preparedSource, destinationTable: source, timeout: 10)
      }
      let duplicate = directory.appendingPathComponent("duplicate.txt")
      try Data("one\tx;Key\ntwo\tx;key\n".utf8).write(to: duplicate)
      expectFailure(.duplicateExistingTrigger("x;key")) {
        _ = try importSource(
          sourceDatabase: source, destinationTable: duplicate)
      }

      let realFile = directory.appendingPathComponent("real.txt")
      let symlink = directory.appendingPathComponent("link.txt")
      try Data().write(to: realFile)
      try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realFile)
      expectFailure(.unsafeDestination) {
        _ = try importSource(
          sourceDatabase: source, destinationTable: symlink)
      }
    }
  }

  private static func testPreparedSnapshotDoesNotReopenSource() throws {
    try inTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("prepared.sqlite3")
      let destination = directory.appendingPathComponent("prepared.txt")
      try makeDatabase(source, rows: [("snapshot", "prepared value")])
      let prepared = try HallelujahSubstitutionImporter.prepare(
        sourceDatabase: source, timeout: 10)
      expect(prepared.substitutionCount == 1, "prepared summary count is not source-owned")
      try FileManager.default.removeItem(at: source)
      let report = try HallelujahSubstitutionImporter.merge(
        prepared, destinationTable: destination, timeout: 10)
      expect(report.importedCount == 1, "prepared source was not merged")
      expect(
        try String(contentsOf: destination, encoding: .utf8)
          .contains("prepared value\tx;snapshot\n"),
        "merge reopened or depended on the removed source database")
    }
  }

  private static func testSQLiteInterruptionClassification() throws {
    try inTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("schema-interruption.sqlite3")
      try makeDatabase(source, rows: [("one", "1")])
      try addPaddingTables(to: source, count: 2_000)

      var cancellationChecks = 0
      expectCancellation {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: source,
          timeout: 10,
          cancellation: {
            cancellationChecks += 1
            if cancellationChecks == 3 { throw CancellationError() }
          })
      }
      expect(
        cancellationChecks == 3,
        "schema fixture did not interrupt inside SQLite execution")

      var deadlineChecks = 0
      expectFailure(.deadlineExceeded) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: source,
          timeout: 10,
          cancellation: {
            deadlineChecks += 1
            if deadlineChecks == 3 {
              throw HallelujahSubstitutionImporter.Failure.deadlineExceeded
            }
          })
      }
      expect(deadlineChecks == 3, "schema deadline did not interrupt SQLite execution")
    }
  }

  private static func testBoundedPreflightAndMergeCancellation() throws {
    try inTemporaryDirectory { directory in
      let sentinel = Data("existing\tx;existing\n".utf8)

      let oversizedDatabase = directory.appendingPathComponent("oversized.sqlite3")
      try makeDatabase(oversizedDatabase, rows: [("one", "1")])
      let databaseHandle = try FileHandle(forWritingTo: oversizedDatabase)
      try databaseHandle.truncate(
        atOffset: UInt64(HallelujahSubstitutionImporter.maximumSourceDatabaseBytes + 1))
      try databaseHandle.close()
      expectFailure(.sourceTooLarge("oversized.sqlite3")) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: oversizedDatabase, timeout: 10)
      }

      let sidecarDatabase = directory.appendingPathComponent("sidecar.sqlite3")
      try makeDatabase(sidecarDatabase, rows: [("one", "1")])
      let sidecar = URL(fileURLWithPath: sidecarDatabase.path + "-wal")
      FileManager.default.createFile(atPath: sidecar.path, contents: nil)
      let sidecarHandle = try FileHandle(forWritingTo: sidecar)
      try sidecarHandle.truncate(
        atOffset: UInt64(HallelujahSubstitutionImporter.maximumSourceSidecarBytes + 1))
      try sidecarHandle.close()
      expectFailure(.sourceTooLarge("sidecar.sqlite3-wal")) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: sidecarDatabase, timeout: 10)
      }

      let aggregateDatabase = directory.appendingPathComponent("sidecar-aggregate.sqlite3")
      try makeDatabase(aggregateDatabase, rows: [("one", "1")])
      for suffix in ["-wal", "-shm"] {
        let url = URL(fileURLWithPath: aggregateDatabase.path + suffix)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
          atOffset: UInt64(HallelujahSubstitutionImporter.maximumSourceSidecarBytes)
        )
        try handle.close()
      }
      expectFailure(.sourceTooLarge("SQLite source aggregate")) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: aggregateDatabase, timeout: 10)
      }

      let oversizedField = directory.appendingPathComponent("field.sqlite3")
      try makeDatabase(
        oversizedField,
        rows: [(String(repeating: "a", count: HallelujahSubstitutionImporter.maximumFieldBytes + 1), "v")])
      expectFailure(.fieldTooLarge(row: 1)) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: oversizedField, timeout: 10)
      }

      let tooManyRows = directory.appendingPathComponent("rows.sqlite3")
      try makeDatabase(
        tooManyRows,
        rows: (0...HallelujahSubstitutionImporter.maximumRows).map { ("k\($0)", "v") })
      expectFailure(.tooManyRows) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: tooManyRows, timeout: 10)
      }

      let aggregate = directory.appendingPathComponent("aggregate.sqlite3")
      let aggregateValue = String(
        repeating: "v", count: HallelujahSubstitutionImporter.maximumFieldBytes)
      try makeDatabase(
        aggregate,
        rows: (0..<300).map { ("aggregate\($0)", aggregateValue) })
      expectFailure(.canonicalTooLarge) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: aggregate, timeout: 10)
      }

      let valid = directory.appendingPathComponent("valid-bounded.sqlite3")
      try makeDatabase(valid, rows: (0..<20).map { ("valid\($0)", "value\($0)") })
      var prepareChecks = 0
      let unchanged = directory.appendingPathComponent("cancelled-prepare.txt")
      try sentinel.write(to: unchanged)
      expectCancellation {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: valid,
          timeout: 10,
          cancellation: {
            prepareChecks += 1
            if prepareChecks == 4 { throw CancellationError() }
          })
      }
      expect(try Data(contentsOf: unchanged) == sentinel, "cancelled prepare changed destination")

      let prepared = try HallelujahSubstitutionImporter.prepare(
        sourceDatabase: valid, timeout: 10)
      var mergeChecks = 0
      expectCancellation {
        _ = try HallelujahSubstitutionImporter.merge(
          prepared,
          destinationTable: unchanged,
          timeout: 10,
          cancellation: {
            mergeChecks += 1
            if mergeChecks == 4 { throw CancellationError() }
          })
      }
      expect(try Data(contentsOf: unchanged) == sentinel, "cancelled merge changed destination")

      expectFailure(.deadlineExceeded) {
        _ = try HallelujahSubstitutionImporter.merge(
          prepared, destinationTable: unchanged, timeout: 0)
      }
      expect(try Data(contentsOf: unchanged) == sentinel, "timed-out merge changed destination")

      let oversizedExisting = directory.appendingPathComponent("existing-too-large.txt")
      FileManager.default.createFile(atPath: oversizedExisting.path, contents: nil)
      let existingHandle = try FileHandle(forWritingTo: oversizedExisting)
      try existingHandle.truncate(
        atOffset: UInt64(HallelujahSubstitutionImporter.maximumExistingBytes + 1))
      try existingHandle.close()
      expectFailure(.existingTooLarge) {
        _ = try HallelujahSubstitutionImporter.merge(
          prepared, destinationTable: oversizedExisting, timeout: 10)
      }

      let newlineFlood = directory.appendingPathComponent("existing-newline-flood.txt")
      let newlineFloodBytes = Data(
        String(repeating: "\n", count: HallelujahSubstitutionImporter.maximumRows + 129).utf8)
      try newlineFloodBytes.write(to: newlineFlood)
      expectFailure(.tooManyRows) {
        _ = try HallelujahSubstitutionImporter.merge(
          prepared, destinationTable: newlineFlood, timeout: 10)
      }
      expect(
        try Data(contentsOf: newlineFlood) == newlineFloodBytes,
        "existing row flood changed destination")

      let outputSource = directory.appendingPathComponent("output.sqlite3")
      let outputValue = String(repeating: "o", count: 65_000)
      try makeDatabase(
        outputSource,
        rows: (0..<200).map { ("source\($0)", outputValue) })
      let outputPrepared = try HallelujahSubstitutionImporter.prepare(
        sourceDatabase: outputSource, timeout: 10)
      let outputDestination = directory.appendingPathComponent("output.txt")
      let existingOutput = (0..<200).map {
        "\(outputValue)\tx;existing\($0)\n"
      }.joined()
      try Data(existingOutput.utf8).write(to: outputDestination)
      let outputBefore = try Data(contentsOf: outputDestination)
      expectFailure(.outputTooLarge) {
        _ = try HallelujahSubstitutionImporter.merge(
          outputPrepared, destinationTable: outputDestination, timeout: 10)
      }
      expect(
        try Data(contentsOf: outputDestination) == outputBefore,
        "output overflow changed destination")

      let writeFailureDirectory = directory.appendingPathComponent(
        "write-failure", isDirectory: true)
      try FileManager.default.createDirectory(
        at: writeFailureDirectory, withIntermediateDirectories: false)
      let writeFailureDestination = writeFailureDirectory.appendingPathComponent("existing.txt")
      try sentinel.write(to: writeFailureDestination)
      expect(chmod(writeFailureDirectory.path, 0o500) == 0, "could not lock write fixture")
      defer { _ = chmod(writeFailureDirectory.path, 0o700) }
      expectFailure(.writeFailed) {
        _ = try HallelujahSubstitutionImporter.merge(
          prepared, destinationTable: writeFailureDestination, timeout: 10)
      }
      expect(
        try Data(contentsOf: writeFailureDestination) == sentinel,
        "failed atomic write changed destination bytes")

      expectFailure(.deadlineExceeded) {
        _ = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: valid, timeout: 0)
      }
    }
  }

  private static func importSource(
    sourceDatabase: URL,
    destinationTable: URL
  ) throws -> HallelujahSubstitutionImporter.Report {
    let prepared = try HallelujahSubstitutionImporter.prepare(
      sourceDatabase: sourceDatabase, timeout: 10)
    return try HallelujahSubstitutionImporter.merge(
      prepared, destinationTable: destinationTable, timeout: 10)
  }

  private static func tableFingerprint(at table: URL) throws -> String {
    let prefix = "#@/linnet_hallelujah_fingerprint\t"
    let contents = try String(contentsOf: table, encoding: .utf8)
    guard let line = contents.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
    else { fail("fingerprint metadata is missing") }
    return String(line.dropFirst(prefix.count))
  }

  private static func makeDatabase(
    _ url: URL,
    schema: String = "CREATE TABLE substitutions(key TEXT PRIMARY KEY, value TEXT)",
    rows: some Sequence<(String, String)>
  ) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      throw TestFailure.message("could not create SQLite fixture")
    }
    defer { sqlite3_close_v2(database) }
    guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
      throw TestFailure.message("could not create SQLite fixture schema")
    }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "INSERT INTO substitutions(key, value) VALUES (?, ?)", -1, &statement, nil)
        == SQLITE_OK, let statement
    else { throw TestFailure.message("could not prepare fixture insert") }
    defer { sqlite3_finalize(statement) }
    for (key, value) in rows {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      let keyResult = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
      let valueResult = value.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
      guard keyResult == SQLITE_OK, valueResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE
      else { throw TestFailure.message("could not insert SQLite fixture row") }
    }
  }

  private static func addPaddingTables(to url: URL, count: Int) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      throw TestFailure.message("could not open padded schema fixture")
    }
    defer { sqlite3_close_v2(database) }
    guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else {
      throw TestFailure.message("could not begin padded schema fixture")
    }
    for index in 0..<count {
      guard
        sqlite3_exec(
          database, "CREATE TABLE padding_\(index)(value TEXT)", nil, nil, nil) == SQLITE_OK
      else { throw TestFailure.message("could not pad schema fixture") }
    }
    guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
      throw TestFailure.message("could not commit padded schema fixture")
    }
  }

  private static func dataLines(_ contents: String) -> [Substring] {
    var dataStarted = false
    return contents.split(separator: "\n").filter { line in
      if line == "# no comment" {
        dataStarted = true
        return false
      }
      return dataStarted
    }
  }

  private static func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = LinnetTestScratch.directory
      .appendingPathComponent("LinnetImporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  private static func expectFailure(
    _ expected: HallelujahSubstitutionImporter.Failure,
    _ operation: () throws -> Void
  ) {
    do {
      try operation()
      fail("expected failure \(expected)")
    } catch let actual as HallelujahSubstitutionImporter.Failure {
      expect(actual == expected, "expected \(expected), got \(actual)")
    } catch {
      fail("unexpected failure type: \(error)")
    }
  }

  private static func expectCancellation(_ operation: () throws -> Void) {
    do {
      try operation()
      fail("expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      fail("unexpected cancellation failure type: \(error)")
    }
  }

  private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
      if try !condition() { fail(message) }
    } catch {
      fail("\(message): \(error)")
    }
  }

  private enum TestFailure: Error { case message(String) }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
      Data("HallelujahSubstitutionImporterTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}
