import Foundation

// Build-time boundary only: Windows consumes the same Core input policies as
// macOS, with Weasel continuing to own user customization at deployment time.
@main
struct WindowsInputDefaults {
  static func main() throws {
    let projections = LinnetSettingsProjectionRenderer.renderProjections(
      document: .default)
    guard CommandLine.arguments.count == 3 else { exit(64) }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let source = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    for (name, contents) in projections where name != LinnetSettingsProjectionRenderer.squirrelCustomFile {
      let stem = String(name.dropLast(".custom.yaml".count))
      let policy = "linnet_windows_" + stem
      var policyContents = contents
      if stem == "default" {
        // Weasel uses Rime's switcher; the macOS frontend has its own menu.
        policyContents += "  switcher/hotkeys:\n    - Control+grave\n    - F4\n"
      } else if stem == LinnetSettingsContract.englishSchemaID {
        // Smart English composes with ascii_mode=false. Weasel's native schema
        // icon keeps its tray, language bar and status bubble English too.
        policyContents += "  schema/icon: linnet_english.ico\n"
      }
      try policyContents.write(to: output.appendingPathComponent(policy + ".yaml"),
                               atomically: true, encoding: .utf8)
      let schema = stem == "default" ? "default.yaml" : stem + ".schema.yaml"
      let original = try String(contentsOf: source.appendingPathComponent(schema), encoding: .utf8)
      let patches = "\n__patch:\n  - " + policy + ":/patch\n  - " + stem + ".custom:/patch?\n"
      try (original + patches).write(
        to: output.appendingPathComponent(schema), atomically: true, encoding: .utf8)
    }
    try LinnetDataRegistry.activeGrammarConfiguration.write(
      to: output.appendingPathComponent("linnet_grammar_active.yaml"), options: .atomic)
    try WindowsSettingsCatalog.write(to: output,
      localizations: URL(fileURLWithPath: "resources/Localizable.xcstrings"))
  }
}
