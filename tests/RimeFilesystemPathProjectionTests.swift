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
      try verifyRuntimeFromExternalWorkingDirectory()
      print("RimeFilesystemPathProjectionTests: PASS")
    } catch {
      FileHandle.standardError.write(
        Data("RimeFilesystemPathProjectionTests: FAIL: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
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
