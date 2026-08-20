import Foundation

@main
struct ActivationProfileRuntimeSnapshotTests {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 2 else { throw Failure.usage }
      let support = URL(fileURLWithPath: arguments[0], isDirectory: true)
      let productName = arguments[1]
      let registry = try LinnetDataRegistry(
        productName: productName,
        coreVersion: "0.1.0",
        applicationSupportDirectory: support)
      let snapshot = try registry.runtimeSnapshot()
      guard snapshot.state.edition == .full,
        snapshot.state.packs.map(\.kind) == [.chinese, .english, .lts, .extended]
      else { throw Failure.invalidSnapshot }
      print("ActivationProfileRuntimeSnapshotTests: PASS")
    } catch {
      FileHandle.standardError.write(Data(
        "Activation profile runtime snapshot failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private enum Failure: Error {
    case usage
    case invalidSnapshot
  }
}
