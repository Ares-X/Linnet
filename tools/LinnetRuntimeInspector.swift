import Darwin
import Foundation

@main
struct LinnetRuntimeInspector {
  enum Command: String {
    case probe
  }

  static func main() {
    do {
      let arguments = CommandLine.arguments
      guard arguments.count == 4,
        let command = Command(rawValue: arguments[1]),
        !arguments[2].isEmpty,
        !arguments[2].contains("\n"),
        arguments[3].hasPrefix("/"),
        !arguments[3].contains("\n")
      else {
        throw InspectorFailure.usage
      }
      let state = try LinnetDataRegistry.inspectInstalledRuntime(
        productName: "Linnet",
        coreVersion: arguments[2],
        applicationSupportDirectory: URL(
          fileURLWithPath: arguments[3], isDirectory: true))
      switch command {
      case .probe:
        print(state.rawValue)
      }
    } catch {
      FileHandle.standardError.write(
        Data("linnet-runtime-inspector: \(error.localizedDescription)\n".utf8))
      exit(error is InspectorFailure ? EX_USAGE : 1)
    }
  }

  enum InspectorFailure: LocalizedError {
    case usage

    var errorDescription: String? {
      "usage: linnet-runtime-inspector probe CORE_VERSION APPLICATION_SUPPORT_DIRECTORY"
    }
  }
}
