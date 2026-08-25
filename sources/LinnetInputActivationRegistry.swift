/// Owns the one InputMethodKit activation that may mutate or publish Linnet
/// state. Controllers and panels retain only the token issued by this process-
/// wide registry; they never infer the active client independently.
final class LinnetInputActivationRegistry {
  private enum Admission {
    case accepting
    case sourceInactive
    case terminating
  }

  struct Token: Equatable {
    fileprivate let generation: UInt64
    fileprivate let controller: ObjectIdentifier
    fileprivate let client: ObjectIdentifier
  }

  struct ClosedActivation {
    let token: Token
    let controller: AnyObject?
    let client: AnyObject?
  }

  private final class Activation {
    let token: Token
    weak var controller: AnyObject?
    weak var client: AnyObject?

    init(token: Token, controller: AnyObject, client: AnyObject) {
      self.token = token
      self.controller = controller
      self.client = client
    }

    var closed: ClosedActivation {
      ClosedActivation(token: token, controller: controller, client: client)
    }
  }

  private var nextGeneration: UInt64 = 0
  private var activation: Activation?
  // InputMethodKit deactivation callbacks carry only a controller/client pair.
  // Keep their activation generations in delivery order at this external
  // boundary so a delayed callback can retire only the generation it belongs
  // to, including repeated activations of the same pair.
  private var nativeActivations: [Activation] = []
  private var admission = Admission.accepting
  private var retiresActivation = false

  var currentToken: Token? { activation?.token }

  /// Retires the previous owner before opening the requested activation.
  /// Retirement may synchronously activate a newer client through IMK; in
  /// that case the older caller must not overwrite the reentrant winner.
  func begin(
    controller: AnyObject,
    client: AnyObject,
    retire: (ClosedActivation) -> Void
  ) -> Token? {
    guard admission == .accepting, !retiresActivation else { return nil }
    pruneReleasedNativeActivations()
    if let closed = takeCurrent() {
      retire(closed)
    }
    guard admission == .accepting, !retiresActivation, activation == nil
    else { return nil }
    nextGeneration &+= 1
    if nextGeneration == 0 { nextGeneration = 1 }
    let token = Token(
      generation: nextGeneration,
      controller: ObjectIdentifier(controller),
      client: ObjectIdentifier(client))
    let opened = Activation(token: token, controller: controller, client: client)
    activation = opened
    nativeActivations.append(opened)
    return token
  }

  func isCurrent(_ token: Token) -> Bool {
    activation?.token == token &&
      activation?.controller != nil && activation?.client != nil
  }

  func isCurrent(_ token: Token, controller: AnyObject) -> Bool {
    token.controller == ObjectIdentifier(controller) &&
      activation?.token == token && activation?.controller === controller &&
      activation?.client != nil
  }

  func isCurrent(
    _ token: Token,
    controller: AnyObject,
    client: AnyObject
  ) -> Bool {
    token.controller == ObjectIdentifier(controller) &&
      token.client == ObjectIdentifier(client) &&
      activation?.token == token &&
      activation?.controller === controller && activation?.client === client
  }

  func close(_ token: Token) -> ClosedActivation? {
    nativeActivations.removeAll { $0.token == token }
    guard activation?.token == token else { return nil }
    return takeCurrent()
  }

  /// Consumes the oldest unmatched native callback for this exact pair. The
  /// record may already have been retired by a replacement activation; only a
  /// callback whose generation is still current is allowed to close state.
  func closeNative(
    controller: AnyObject,
    client: AnyObject
  ) -> ClosedActivation? {
    pruneReleasedNativeActivations()
    guard let index = nativeActivations.firstIndex(where: {
      $0.controller === controller && $0.client === client
    }) else { return nil }
    let nativeActivation = nativeActivations.remove(at: index)
    guard activation?.token == nativeActivation.token else { return nil }
    return takeCurrent()
  }

  /// Keeps admission closed after the selected input source changes away from
  /// Linnet. Only a later verified source-on transition may reopen it.
  @discardableResult
  func sourceDidTurnOff(retire: (ClosedActivation) -> Void) -> Bool {
    guard admission != .terminating else { return false }
    admission = .sourceInactive
    return retireCurrentAndNativeActivations(retire: retire)
  }

  func sourceDidTurnOn() {
    guard admission != .terminating, !retiresActivation else { return }
    admission = .accepting
  }

  /// Termination is permanent for this process, including reentrant
  /// InputMethodKit activation triggered by committing the retiring client.
  @discardableResult
  func terminate(retire: (ClosedActivation) -> Void) -> Bool {
    admission = .terminating
    return retireCurrentAndNativeActivations(retire: retire)
  }

  private func retireCurrentAndNativeActivations(
    retire: (ClosedActivation) -> Void
  ) -> Bool {
    guard !retiresActivation else { return false }
    retiresActivation = true
    defer { retiresActivation = false }
    let closed = takeCurrent()
    nativeActivations.removeAll(keepingCapacity: true)
    guard let closed else { return false }
    retire(closed)
    return true
  }

  func currentController<Controller: AnyObject>(as _: Controller.Type) -> Controller? {
    activation?.controller as? Controller
  }

  func currentClient<Client: AnyObject>(as _: Client.Type) -> Client? {
    activation?.client as? Client
  }

  private func takeCurrent() -> ClosedActivation? {
    guard let activation else { return nil }
    self.activation = nil
    return activation.closed
  }

  private func pruneReleasedNativeActivations() {
    nativeActivations.removeAll {
      $0.controller == nil || $0.client == nil
    }
  }
}
