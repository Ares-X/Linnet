import Foundation

enum SquirrelApp {
  static let bundleIdentifier = "io.github.ares-x.inputmethod.Linnet"
  static let appDir = URL(fileURLWithPath: "/tmp/Linnet.app", isDirectory: true)
}

@main
struct LinnetInputSourceLifecycleTests {
  static func main() {
    let identifier = SquirrelApp.bundleIdentifier
    do {
      guard try SquirrelInstaller.registrationRequired(
        inputSourceCount: 0, identifier: identifier)
      else { fatalError("missing source was not registered") }
      guard try !SquirrelInstaller.registrationRequired(
        inputSourceCount: 1, identifier: identifier)
      else { fatalError("existing source was re-registered") }
      _ = try SquirrelInstaller.registrationRequired(
        inputSourceCount: 2, identifier: identifier)
      fatalError("duplicate sources were accepted")
    } catch SquirrelInstaller.Failure.inputSourceCountMismatch(
      let actualIdentifier, let count
    ) {
      guard actualIdentifier == identifier, count == 2 else {
        fatalError("duplicate-source failure lost its identity")
      }
    } catch {
      fatalError("unexpected registration failure: \(error)")
    }
    print("LinnetInputSourceLifecycleTests: PASS")
  }
}
