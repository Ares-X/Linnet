import Foundation

@main
struct LinnetRimeSessionLeaseTests {
  nonisolated(unsafe) private static var destroyedSessions: [RimeSessionId] = []
  nonisolated(unsafe) private static var selectedSchemas: [String] = []

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
    testWarmSessionReusesRetiredIdentifier()
    testAllSessionRetirement()
    testWarmSessionCannotDestroyReassignedIdentifier()
    testWarmSessionFailedPrimeReleasesItsLease()
    print("LinnetRimeSessionLeaseTests: PASS")
  }

  private static func testWarmSessionReusesRetiredIdentifier() {
    selectedSchemas = []
    guard let oldController = LinnetRimeSessionLease.acquire(identifier: 91) else {
      fail("the old controller did not acquire its session")
    }
    let api = warmSessionAPI()
    let warm = LinnetRimeWarmSession()
    require(
      warm.prepare(
        using: api, schemaID: "linnet_zh_jiajia", representativeInputCode: "srfa") == 91,
      "the warm session did not initialize")
    require(
      selectedSchemas == ["linnet_zh_jiajia"],
      "the warm session did not select the document-owned schema")
    require(!oldController.isCurrent(sessionExists: { $0 == 91 }),
            "the old controller still owned the identifier recycled by the warm session")
    warm.discard(using: api)
  }

  private static func testAllSessionRetirement() {
    let inactive = LinnetRimeSessionLease.acquire(identifier: 101)!
    let active = LinnetRimeSessionLease.acquire(identifier: 102)!
    let warm = LinnetRimeWarmSession()
    let api = warmSessionAPI()
    require(
      warm.prepare(
        using: api, schemaID: "linnet_zh", representativeInputCode: "srfa") == 91,
      "warm preparation failed")
    LinnetRimeSessionLease.retireAll()
    for retired in [inactive, active] {
      require(!retired.isCurrent(sessionExists: { _ in
        fail("a retired generation still queried librime")
      }), "all-session cleanup retained controller ownership")
    }
    require(!warm.refresh(using: api), "warm ownership survived all-session cleanup")
    let replacement = LinnetRimeSessionLease.acquire(identifier: 101)!
    inactive.retire()
    require(replacement.isCurrent(sessionExists: { _ in true }),
            "a retired generation revoked a new session at the same address")
    replacement.retire()
  }

  private static func testWarmSessionCannotDestroyReassignedIdentifier() {
    destroyedSessions = []
    let warm = LinnetRimeWarmSession()
    let api = warmSessionAPI()
    require(
      warm.prepare(
        using: api, schemaID: "linnet_zh", representativeInputCode: "srfa") == 91,
      "warm preparation failed")
    let controller = LinnetRimeSessionLease.acquire(identifier: 91)!
    warm.discard(using: api)
    require(destroyedSessions.isEmpty, "stale warm cleanup destroyed a controller's session")
    require(controller.isCurrent(sessionExists: { _ in true }),
            "stale warm cleanup revoked a controller's lease")
    controller.retire()
  }

  private static func testWarmSessionFailedPrimeReleasesItsLease() {
    destroyedSessions = []
    var api = warmSessionAPI()
    api.simulate_key_sequence = { _, _ in false }
    let warm = LinnetRimeWarmSession()
    require(
      warm.prepare(
        using: api, schemaID: "linnet_zh", representativeInputCode: "srfa") == nil,
      "failed priming reported a ready resource owner")
    require(warm.identifier == 0 && destroyedSessions == [91],
            "failed priming did not destroy and retire exactly its own session")
    warm.discard(using: api)
    require(destroyedSessions == [91], "retired warm cleanup destroyed the same session twice")
  }

  private static func warmSessionAPI() -> RimeApi_stdbool {
    var api = RimeApi_stdbool()
    api.create_session = { 91 }
    api.find_session = { $0 == 91 }
    api.select_schema = { _, schema in
      guard let schema else { return false }
      LinnetRimeSessionLeaseTests.selectedSchemas.append(String(cString: schema))
      return true
    }
    api.simulate_key_sequence = { _, _ in true }
    api.clear_composition = { _ in }
    api.destroy_session = { identifier in
      LinnetRimeSessionLeaseTests.destroyedSessions.append(identifier)
      return true
    }
    return api
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
