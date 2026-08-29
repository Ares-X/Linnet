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
      guard CommandLine.arguments.count >= 2 else {
        throw Failure.requirement("expected Host source paths")
      }
      let source = try CommandLine.arguments.dropFirst().map {
        try String(contentsOfFile: $0, encoding: .utf8)
      }.joined(separator: "\n")
      let expected = "/Linnet Runtime/Application Support"
      let spacedURL = URL(fileURLWithPath: expected)

      try require(spacedURL.path == expected, "URL.path lost the native filesystem path")
      try require(
        spacedURL.path(percentEncoded: false) == expected,
        "explicitly decoded URL path lost the native filesystem path")
      try require(
        spacedURL.path().contains("%20"),
        "fixture no longer distinguishes URL and native filesystem paths")
      try require(
        !source.contains(".path()"),
        "Host still passes percent-encoded URL paths to filesystem consumers")

      let requiredNativePaths = [
        "fileExists(atPath: settingsURL.path)",
        "setCString(snapshot.sharedDataDirectory.path, to: \\.shared_data_dir)",
        "setCString(snapshot.userDataDirectory.path, to: \\.user_data_dir)",
        "setCString(snapshot.prebuiltDataDirectory.path, to: \\.prebuilt_data_dir)",
        "setCString(snapshot.stagingDirectory.path, to: \\.staging_dir)",
        "let logDirectory = try? SquirrelApp.dataRegistry.prepareRuntimeLogDirectory()",
        "setCString(logDirectory.path, to: \\.log_dir)"
      ]
      for required in requiredNativePaths {
        try require(
          source.components(separatedBy: required).count == 2,
          "missing unique native filesystem projection: \(required)")
      }
      try require(
        !source.contains("SquirrelApp.logDir")
          && !source.contains("FileManager.default.createDirectory(\n        at: logDirectory"),
        "Host regained a second runtime-log path or creation owner")
      print("RimeFilesystemPathProjectionTests: PASS")
    } catch {
      FileHandle.standardError.write(
        Data("RimeFilesystemPathProjectionTests: FAIL: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    if !condition() { throw Failure.requirement(message) }
  }
}
