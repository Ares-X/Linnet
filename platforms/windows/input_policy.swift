import Foundation

// Build-time staging and installed language-data deployment use the same
// schema projection. Policy contents still come from the shared renderer.
enum WindowsInputPolicy {
  static func applying(to schema: String, stem: String) -> String {
    schema + "\n__patch:\n  - linnet_windows_" + stem + ":/patch\n  - " + stem + ".custom:/patch?\n"
  }

  static func schemaStem(_ file: String) -> String? {
    if file == "default.yaml" { return "default" }
    if file.hasSuffix(".schema.yaml") { return String(file.dropLast(".schema.yaml".count)) }
    return nil
  }
}
