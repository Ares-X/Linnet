import Darwin
import Foundation

/// A standalone test failure is an ordinary non-zero exit, never a process
/// crash that can trigger macOS Crash Reporter or a visible system dialog.
enum LinnetTestFailure {
  static func fail(_ message: @autoclosure () -> String) -> Never {
    let line = "TEST FAILURE: \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
    exit(EXIT_FAILURE)
  }
}

#if LINNET_TEST_FAILURE_PROBE
@main
private enum LinnetTestFailureProbe {
  static func main() {
    LinnetTestFailure.fail("graceful failure probe")
  }
}
#endif
