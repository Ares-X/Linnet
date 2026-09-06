import Foundation

// Build-time boundary only: Windows consumes the same Core input policies as
// macOS, with Weasel continuing to own user customization at deployment time.
@main
struct WindowsInputDefaults {
  static func main() throws {
    let projections = LinnetSettingsProjectionRenderer.renderProjections(
      document: .default)
    guard CommandLine.arguments.count == 2,
      let defaults = projections[LinnetSettingsProjectionRenderer.defaultCustomFile]
    else { exit(64) }
    try defaults.write(
      toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
  }
}
