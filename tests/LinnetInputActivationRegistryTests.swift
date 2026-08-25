import Foundation

@main
struct LinnetInputActivationRegistryTests {
  static func main() {
    replacesControllersWithoutLeavingTwoOwners()
    rejectsStaleAndMismatchedCloses()
    correlatesDelayedNativeDeactivationByGeneration()
    preservesReentrantActivation()
    keepsTheSourceClosedUntilItIsSelectedAgain()
    neverReopensAfterTermination()
    stopsAuthorizingReleasedObjects()
    print("LinnetInputActivationRegistryTests: PASS")
  }

  private static func replacesControllersWithoutLeavingTwoOwners() {
    let registry = LinnetInputActivationRegistry()
    let firstController = NSObject()
    let secondController = NSObject()
    let firstClient = NSObject()
    let secondClient = NSObject()
    var retired: [LinnetInputActivationRegistry.Token] = []

    guard let first = registry.begin(
      controller: firstController,
      client: firstClient,
      retire: { retired.append($0.token) })
    else { fail("the first activation was rejected") }
    require(registry.currentToken == first, "the first activation was not current")
    require(
      registry.isCurrent(first, controller: firstController, client: firstClient),
      "the current controller/client pair did not validate")
    require(
      registry.isCurrent(first, controller: firstController) &&
        !registry.isCurrent(first, controller: secondController),
      "controller-only ingress validation did not bind the token to its owner")

    guard let second = registry.begin(
      controller: secondController,
      client: secondClient,
      retire: { retired.append($0.token) })
    else { fail("the replacement activation was rejected") }
    require(retired == [first], "replacement did not retire exactly the old owner")
    require(registry.currentToken == second, "replacement was not the sole current owner")
    require(!registry.isCurrent(first), "the old controller remained authoritative")
    require(
      registry.currentController(as: NSObject.self) === secondController &&
        registry.currentClient(as: NSObject.self) === secondClient,
      "the registry projected a controller/client other than its current token")
  }

  private static func rejectsStaleAndMismatchedCloses() {
    let registry = LinnetInputActivationRegistry()
    let controller = NSObject()
    let firstClient = NSObject()
    let secondClient = NSObject()
    guard let first = registry.begin(
      controller: controller, client: firstClient, retire: { _ in })
    else { fail("the first same-controller activation was rejected") }
    guard let second = registry.begin(
      controller: controller, client: secondClient, retire: { _ in })
    else { fail("the second same-controller activation was rejected") }

    require(
      registry.close(first) == nil && registry.currentToken == second,
      "a stale generation closed its replacement")
    require(
      registry.closeNative(controller: controller, client: firstClient) == nil &&
        registry.currentToken == second,
      "a delayed old-client callback closed its replacement")
    require(
      registry.closeNative(controller: NSObject(), client: secondClient) == nil &&
        registry.currentToken == second,
      "another controller closed the current client")
    require(
      registry.closeNative(controller: controller, client: secondClient)?.token == second,
      "the exact controller/client callback did not close its activation")
    require(
      registry.closeNative(controller: controller, client: secondClient) == nil,
      "a duplicate native deactivation closed twice")
  }

  private static func correlatesDelayedNativeDeactivationByGeneration() {
    let registry = LinnetInputActivationRegistry()
    let controller = NSObject()
    let client = NSObject()
    var retired: [LinnetInputActivationRegistry.Token] = []
    guard let first = registry.begin(
      controller: controller, client: client,
      retire: { retired.append($0.token) })
    else { fail("the first same-pair activation was rejected") }
    guard let second = registry.begin(
      controller: controller, client: client,
      retire: { retired.append($0.token) })
    else { fail("the replacement same-pair activation was rejected") }
    require(retired == [first], "same-pair replacement did not retire its old generation")

    require(
      registry.closeNative(controller: controller, client: client) == nil &&
        registry.currentToken == second,
      "the delayed first native deactivate closed the second generation")
    require(
      registry.closeNative(controller: controller, client: client)?.token == second &&
        registry.currentToken == nil,
      "the second native deactivate did not close its matching generation")
  }

  private static func preservesReentrantActivation() {
    let registry = LinnetInputActivationRegistry()
    let firstController = NSObject()
    let attemptedController = NSObject()
    let reentrantController = NSObject()
    let firstClient = NSObject()
    let attemptedClient = NSObject()
    let reentrantClient = NSObject()
    guard registry.begin(
      controller: firstController, client: firstClient, retire: { _ in }) != nil
    else { fail("the activation preceding reentry was rejected") }

    var reentrantToken: LinnetInputActivationRegistry.Token?
    let attemptedToken = registry.begin(
      controller: attemptedController,
      client: attemptedClient,
      retire: { _ in
        reentrantToken = registry.begin(
          controller: reentrantController,
          client: reentrantClient,
          retire: { _ in fail("reentry observed a second open owner") })
      })
    require(reentrantToken != nil, "synchronous IMK reentry did not open")
    require(attemptedToken == nil, "the older activation stack overwrote reentry")
    require(
      registry.currentToken == reentrantToken,
      "the reentrant activation was not the sole current owner")
  }

  private static func keepsTheSourceClosedUntilItIsSelectedAgain() {
    let registry = LinnetInputActivationRegistry()
    let controller = NSObject()
    let client = NSObject()
    guard let token = registry.begin(
      controller: controller, client: client, retire: { _ in })
    else { fail("the source-exit fixture could not activate") }
    var reentrantToken: LinnetInputActivationRegistry.Token?
    require(
      registry.sourceDidTurnOff { closed in
        require(closed.token == token, "source exit retired another generation")
        registry.sourceDidTurnOn()
        reentrantToken = registry.begin(
          controller: NSObject(), client: NSObject(), retire: { _ in })
      } && registry.currentToken == nil,
      "input-source exit did not close the process-wide owner")
    require(reentrantToken == nil, "synchronous exit commit reopened an activation")
    require(
      !registry.sourceDidTurnOff { _ in fail("repeated source exit retired twice") },
      "repeated source exit reported another close")

    require(
      registry.begin(
        controller: NSObject(), client: NSObject(), retire: { _ in }
      ) == nil,
      "the inactive source accepted a delayed activation after exit returned")

    let nextController = NSObject()
    let nextClient = NSObject()
    registry.sourceDidTurnOn()
    guard let next = registry.begin(
      controller: nextController, client: nextClient, retire: { _ in })
    else { fail("a verified source activation did not reopen admission") }
    require(
      registry.closeNative(controller: controller, client: client) == nil &&
        registry.currentToken == next,
      "a pre-exit native callback survived the source boundary")
  }

  private static func neverReopensAfterTermination() {
    let registry = LinnetInputActivationRegistry()
    let controller = NSObject()
    let client = NSObject()
    guard registry.begin(
      controller: controller, client: client, retire: { _ in }) != nil
    else { fail("the termination fixture could not activate") }

    var reentrantToken: LinnetInputActivationRegistry.Token?
    require(
      registry.terminate { _ in
        registry.sourceDidTurnOn()
        reentrantToken = registry.begin(
          controller: NSObject(), client: NSObject(), retire: { _ in })
      },
      "termination did not retire the process-wide owner")
    registry.sourceDidTurnOn()
    require(reentrantToken == nil, "termination allowed synchronous reentry")
    require(
      registry.begin(
        controller: NSObject(), client: NSObject(), retire: { _ in }
      ) == nil,
      "termination reopened after a later input-source notification")
    require(
      !registry.terminate { _ in fail("repeated termination retired twice") },
      "repeated termination reported another close")
  }

  private static func stopsAuthorizingReleasedObjects() {
    let registry = LinnetInputActivationRegistry()
    let controller = NSObject()
    var client: NSObject? = NSObject()
    guard let token = registry.begin(
      controller: controller, client: client!, retire: { _ in })
    else { fail("the released-client fixture could not activate") }
    client = nil
    require(
      !registry.isCurrent(token),
      "a token whose client was released remained authoritative")
    require(
      registry.close(token)?.token == token,
      "a released weak projection could not retire its registry record")
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
      Data("LinnetInputActivationRegistryTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    guard condition() else { fail(message) }
  }
}
