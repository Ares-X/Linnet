import AppKit

@main
struct LinnetClientAppearanceTests {
  private final class DarkClient: NSObject {
    @objc func windowEffectiveAppearance() -> NSAppearance {
      NSAppearance(named: .darkAqua)!
    }
  }

  private final class MalformedClient: NSObject {
    @objc func windowEffectiveAppearance() -> NSString {
      "dark"
    }
  }

  private final class OrdinaryClient: NSObject {}

  static func main() {
    let light = NSAppearance(named: .aqua)!
    let dark = NSAppearance(named: .darkAqua)!

    let client = LinnetClientAppearance.resolve(
      client: DarkClient(), systemAppearance: light)
    require(client.isDark,
            "the active client's window appearance did not own automatic mode")
    require(client.appearance.name == .darkAqua,
            "the client appearance was replaced after it was resolved")

    let unsupported = LinnetClientAppearance.resolve(
      client: OrdinaryClient(), systemAppearance: dark)
    require(unsupported.isDark && unsupported.appearance.name == .darkAqua,
            "a client without the optional appearance capability did not use macOS")

    let malformed = LinnetClientAppearance.resolve(
      client: MalformedClient(), systemAppearance: light)
    require(!malformed.isDark && malformed.appearance.name == .aqua,
            "a malformed private capability result became authoritative")

    let absent = LinnetClientAppearance.resolve(
      client: nil, systemAppearance: light)
    require(!absent.isDark && absent.appearance.name == .aqua,
            "an absent input client retained a stale application appearance")

    require(
      LinnetClientAppearance.resolveMaterial(
        mode: .light, automaticAppearance: dark).name == .aqua,
      "fixed Light inherited a dark client material"
    )
    require(
      LinnetClientAppearance.resolveMaterial(
        mode: .dark, automaticAppearance: light).name == .darkAqua,
      "fixed Dark inherited a light client material"
    )
    require(
      LinnetClientAppearance.resolveMaterial(
        mode: .system, automaticAppearance: dark).name == .darkAqua,
      "automatic material stopped following the resolved client appearance"
    )

    print("LinnetClientAppearanceTests: PASS")
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("LinnetClientAppearanceTests: \(message)\n".utf8))
      exit(1)
    }
  }
}
