import Foundation

// macOS Foundation's temporaryDirectory ignores TMPDIR. Tests must explicitly
// use the parent runner's root so exit(EXIT_FAILURE) cannot strand fixtures.
enum LinnetTestScratch {
  static let directory: URL = {
    guard let root = ProcessInfo.processInfo.environment["LINNET_SWIFT_TEST_SCRATCH"],
      root.hasPrefix("/private/tmp/linnet-swift-units."), root.hasSuffix("/fixtures") else {
      FileHandle.standardError.write(Data("Run Swift fixtures through tests/verify_swift_units.sh.\n".utf8))
      exit(2)
    }
    return URL(fileURLWithPath: root, isDirectory: true)
  }()
}
