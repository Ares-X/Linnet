import Foundation

@main
struct LinnetRimeSessionLeaseTests {
  static func main() {
    guard let first = LinnetRimeSessionLease.acquire(identifier: 41),
      let second = LinnetRimeSessionLease.acquire(identifier: 41)
    else { fail("a nonzero session identifier did not acquire a lease") }

    require(
      !first.isCurrent(sessionExists: { $0 == 41 }),
      "a recycled raw session identifier remained owned by its old controller"
    )
    require(
      second.isCurrent(sessionExists: { $0 == 41 }),
      "the controller that reacquired a recycled identifier did not own it"
    )
    first.retire()
    require(
      second.isCurrent(sessionExists: { $0 == 41 }),
      "retiring a stale lease revoked the current controller's session"
    )
    second.retire()
    require(!second.isCurrent(sessionExists: { _ in true }),
            "a retired lease remained authoritative")
    require(LinnetRimeSessionLease.acquire(identifier: 0) == nil,
            "the invalid session identifier acquired ownership")
    print("LinnetRimeSessionLeaseTests: PASS")
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("LinnetRimeSessionLeaseTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}
