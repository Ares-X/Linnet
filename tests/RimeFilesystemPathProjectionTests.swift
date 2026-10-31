import Darwin
import Foundation

@main
struct RimeFilesystemPathProjectionTests {
  private enum Failure: Error, CustomStringConvertible {
    case requirement(String)

    var description: String {
      switch self {
      case .requirement(let message): message
      }
    }
  }

  static func main() {
    do {
      if CommandLine.arguments.dropFirst().first == "--schema-ids" {
        try verifyConfiguredSchemaIDs()
      } else {
        try verifyRuntimeFromExternalWorkingDirectory()
      }
      print("RimeFilesystemPathProjectionTests: PASS")
    } catch {
      FileHandle.standardError.write(
        Data("RimeFilesystemPathProjectionTests: FAIL: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func verifyConfiguredSchemaIDs() throws {
    let fileManager = FileManager.default
    let runtime = LinnetTestScratch.directory.appending(path: "schema health")
    defer { try? fileManager.removeItem(at: runtime) }
    let user = runtime.appending(path: "user")
    let staging = user.appending(path: "build")
    let logs = runtime.appending(path: "logs")
    for directory in [staging, logs] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let required: Set<String> = [
      "linnet_zh_pinyin", "linnet_zh", "linnet_zh_flypy", "linnet_zh_mspy",
      "linnet_zh_sogou", "linnet_zh_abc", "linnet_zh_ziguang", "linnet_zh_jiajia",
      "linnet_en"
    ]
    let defaultURL = staging.appending(path: "default.yaml")
    let fullList = "schema_list:\n" + required.sorted().map { "  - schema: \($0)\n" }.joined()
    try fullList.write(to: defaultURL, atomically: true, encoding: .utf8)
    for identifier in required {
      try "schema:\n  name: \(identifier)\n".write(
        to: staging.appending(path: "\(identifier).schema.yaml"),
        atomically: true, encoding: .utf8)
    }
    let api = rime_get_api_stdbool().pointee
    let traits = LinnetRimeTraitValues(
      sharedDataDirectory: runtime.path,
      userDataDirectory: user.path,
      prebuiltDataDirectory: staging.path,
      stagingDirectory: staging.path,
      logDirectory: logs.path,
      distributionCodeName: "linnet-health-tests",
      distributionName: "Linnet Health Tests",
      distributionVersion: "0.1.0",
      applicationName: "rime.linnet-health-tests",
      minimumLogLevel: 3)
    try require(traits.apply(to: api), "could not configure the schema health runtime")
    api.initialize(nil)
    defer { api.finalize() }

    try require(rimeConfiguredSchemaIDs(using: api) == required,
                "configured product schema IDs were lost")
    try require(legacySchemaIDs(using: api) == required,
                "configured IDs differed from Rime's schema-list API")

    // Schema-list names are labels, not proof that schema bytes can create a
    // ready session. Rime returns the ID even when that schema file is absent.
    let schema = staging.appending(path: "linnet_en.schema.yaml")
    try fileManager.removeItem(at: schema)
    try require(legacySchemaIDs(using: api) == required,
                "the schema-list fixture unexpectedly established session readiness")
    try require(rimeConfiguredSchemaIDs(using: api) == required,
                "configured availability depended on a schema display name")
    try "schema:\n  name: ''\n".write(to: schema, atomically: true, encoding: .utf8)
    try require(legacySchemaIDs(using: api) == required.subtracting(["linnet_en"]),
                "the empty-name fixture did not exercise the previous name exclusion")
    try require(rimeConfiguredSchemaIDs(using: api) == required,
                "a valid configured ID was rejected because its display name was empty")

    let partial = """
      schema_list:
        - schema: linnet_zh_pinyin
        - schema: linnet_zh_pinyin
        - schema: uninstalled_extra
        - schema: ''
        - unrelated: linnet_en
        - scalar
        - schema: []
      """
    try partial.write(to: defaultURL, atomically: true, encoding: .utf8)
    let partialIDs: Set<String> = ["linnet_zh_pinyin", "uninstalled_extra"]
    try require(rimeConfiguredSchemaIDs(using: api) == partialIDs,
                "empty, malformed or duplicate entries changed configured availability")
    try require(legacySchemaIDs(using: api) == partialIDs,
                "sparse configured IDs differed from Rime's schema-list API")
    try require(required.intersection(rimeConfiguredSchemaIDs(using: api)).count == 1,
                "an absent required schema was reported available")
    for document in ["schema_list: []\n", "unrelated: true\n", "schema_list: {}\n"] {
      try document.write(to: defaultURL, atomically: true, encoding: .utf8)
      try require(rimeConfiguredSchemaIDs(using: api).isEmpty,
                  "an empty, missing or malformed schema list reported available IDs")
      try require(legacySchemaIDs(using: api).isEmpty,
                  "empty-list behavior differed from Rime's schema-list API")
    }
    try fileManager.removeItem(at: defaultURL)
    try require(rimeConfiguredSchemaIDs(using: api).isEmpty,
                "a missing configuration retained stale schema availability")
  }

  private static func legacySchemaIDs(using api: RimeApi_stdbool) -> Set<String> {
    var schemaList = RimeSchemaList()
    guard api.get_schema_list(&schemaList) else { return [] }
    defer { api.free_schema_list(&schemaList) }
    var identifiers = Set<String>()
    if let entries = schemaList.list {
      for index in 0..<Int(schemaList.size) {
        guard let identifier = entries[index].schema_id,
          let name = entries[index].name,
          identifier.pointee != 0, name.pointee != 0
        else { continue }
        identifiers.insert(String(cString: identifier))
      }
    }
    return identifiers
  }

  private static func verifyRuntimeFromExternalWorkingDirectory() throws {
    guard CommandLine.arguments.count == 2 else {
      throw Failure.requirement("expected the repository root")
    }
    let fileManager = FileManager.default
    let launchDirectory = fileManager.currentDirectoryPath
    try require(
      launchDirectory.contains("Rime external cwd"),
      "test was not launched from the external path containing spaces")

    let repository = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      .standardizedFileURL
    try require(
      URL(fileURLWithPath: launchDirectory, isDirectory: true).standardizedFileURL != repository,
      "test unexpectedly launched from the repository")

    let runtime = URL(fileURLWithPath: launchDirectory, isDirectory: true)
      .appending(path: "isolated runtime", directoryHint: .isDirectory)
    let user = runtime.appending(path: "user data", directoryHint: .isDirectory)
    let staging = user.appending(path: "build", directoryHint: .isDirectory)
    let logs = runtime.appending(path: "logs", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: runtime) }
    for directory in [user, staging, logs] {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    try fileManager.createSymbolicLink(
      at: user.appending(path: "opencc", directoryHint: .isDirectory),
      withDestinationURL: repository.appending(path: "data/opencc", directoryHint: .isDirectory))

    let shared = repository.appending(path: "data/plum", directoryHint: .isDirectory)
    let prebuilt = shared.appending(path: "build", directoryHint: .isDirectory)
    let api = rime_get_api_stdbool().pointee
    let traits = LinnetRimeTraitValues(
      sharedDataDirectory: shared.path,
      userDataDirectory: user.path,
      prebuiltDataDirectory: prebuilt.path,
      stagingDirectory: staging.path,
      logDirectory: logs.path,
      distributionCodeName: "linnet-filesystem-tests",
      distributionName: "Linnet Filesystem Tests",
      distributionVersion: "0.1.0",
      applicationName: "rime.linnet-filesystem-tests",
      minimumLogLevel: 3)
    try require(traits.apply(to: api), "could not configure the Rime runtime")
    try require(
      fileManager.currentDirectoryPath == launchDirectory,
      "Rime setup changed the process working directory")

    api.initialize(nil)
    defer { api.finalize() }
    if api.start_maintenance(false) {
      api.join_maintenance_thread()
    }
    let session = api.create_session()
    try require(session != 0, "could not create a Rime session")
    defer { _ = api.destroy_session(session) }
    let selected = "linnet_zh_pinyin".withCString { api.select_schema(session, $0) }
    try require(
      selected,
      "could not load the built-in linnet_zh_pinyin profile by absolute path")
    "emoji".withCString { api.set_option(session, $0, false) }
    "traditionalization".withCString { api.set_option(session, $0, true) }
    for key in "ceshi".utf8 {
      try require(
        api.process_key(session, Int32(key), 0),
        "built-in profile rejected '\(Character(UnicodeScalar(key)))' while exercising OpenCC")
    }

    var iterator = RimeCandidateListIterator()
    try require(
      api.candidate_list_begin(session, &iterator),
      "built-in profile produced no candidate list")
    defer { api.candidate_list_end(&iterator) }
    try require(
      api.candidate_list_next(&iterator),
      "built-in profile produced no first candidate")
    let converted = iterator.candidate.text.map { String(cString: $0) }
    try require(
      converted == "測試",
      "OpenCC conversion did not produce the expected traditional candidate")
    try require(
      fileManager.currentDirectoryPath == launchDirectory,
      "Rime conversion changed the process working directory")
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    if !condition() { throw Failure.requirement(message) }
  }
}
