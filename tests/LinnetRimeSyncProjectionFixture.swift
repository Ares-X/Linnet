import Foundation

@main
struct LinnetRimeSyncProjectionFixture {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      throw POSIXError(.EINVAL)
    }
    try LinnetRimeSyncInstallation.project(
      syncDirectory: URL(
        fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
      userDirectory: URL(
        fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
  }
}
