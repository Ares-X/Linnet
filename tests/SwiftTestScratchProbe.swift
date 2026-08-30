import Darwin
import Foundation

// Mirrors real fixtures: the runner owns the root, packs become immutable,
// and a test's exit(EXIT_FAILURE) bypasses its scope-level defer.
@main
enum SwiftTestScratchProbe {
  static func main() throws {
    let fileManager = FileManager.default
    let fixture = LinnetTestScratch.directory.appendingPathComponent("LinnetScratchProbe-\(UUID().uuidString)")
    let pack = fixture.appendingPathComponent("pack")
    let nested = pack.appendingPathComponent("nested")
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
    let payload = nested.appendingPathComponent("payload")
    try Data("fixture".utf8).write(to: payload)
    try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)
    try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: nested.path)
    try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pack.path)
    try fileManager.createSymbolicLink(
      atPath: fixture.appendingPathComponent("external").path,
      withDestinationPath: CommandLine.arguments[2])
    defer { try? fileManager.removeItem(at: fixture) }
    print(fixture.path)
    fflush(stdout)
    if CommandLine.arguments[1] == "failure" {
      exit(37)
    }
  }
}
