import Darwin
import Foundation

@main
struct LinnetInputSourceRegistrationInspector {
  static func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 2,
      !arguments[1].isEmpty,
      !arguments[1].contains("\n")
    else {
      FileHandle.standardError.write(
        Data("usage: input-source-registration-inspector BUNDLE_IDENTIFIER\n".utf8))
      exit(EX_USAGE)
    }
    print(LinnetInputSourceRegistration.state(identifier: arguments[1]).wireValue)
  }
}
