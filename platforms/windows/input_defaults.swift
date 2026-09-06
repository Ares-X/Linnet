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
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try defaults.write(
      to: output.appendingPathComponent("linnet_windows_defaults.yaml"),
      atomically: true, encoding: .utf8)
    try LinnetDataRegistry.activeGrammarConfiguration.write(
      to: output.appendingPathComponent("linnet_grammar_active.yaml"), options: .atomic)
  }
}
