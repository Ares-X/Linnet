import Foundation

/// Binds a pointer-shaped librime identifier to the resource that acquired
/// it. Reuse transfers ownership immediately, so a delayed callback or deinit
/// from the previous controller cannot mutate the new session at that address.
struct LinnetRimeSessionLease: Equatable {
  let identifier: RimeSessionId
  fileprivate let ownership: UInt64

  static func acquire(identifier: RimeSessionId) -> Self? {
    guard identifier != 0 else { return nil }
    return LinnetRimeSessionLeaseRegistry.acquire(identifier: identifier)
  }

  /// Every librime all-session cleanup also ends the ownership generation,
  /// including controllers that are inactive and therefore receive no callback.
  static func retireAll() {
    LinnetRimeSessionLeaseRegistry.retireAll()
  }

  func isCurrent(
    sessionExists: (RimeSessionId) -> Bool
  ) -> Bool {
    LinnetRimeSessionLeaseRegistry.owns(self)
      && sessionExists(identifier)
  }

  func retire() {
    LinnetRimeSessionLeaseRegistry.retire(self)
  }

}

private enum LinnetRimeSessionLeaseRegistry {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var nextOwnership: UInt64 = 0
  nonisolated(unsafe) private static var owners: [RimeSessionId: UInt64] = [:]

  static func acquire(identifier: RimeSessionId) -> LinnetRimeSessionLease {
    lock.lock()
    defer { lock.unlock() }
    nextOwnership &+= 1
    owners[identifier] = nextOwnership
    return .init(identifier: identifier, ownership: nextOwnership)
  }

  static func owns(_ lease: LinnetRimeSessionLease) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return owners[lease.identifier] == lease.ownership
  }

  static func retire(_ lease: LinnetRimeSessionLease) {
    lock.lock()
    defer { lock.unlock() }
    if owners[lease.identifier] == lease.ownership {
      owners.removeValue(forKey: lease.identifier)
    }
  }

  static func retireAll() {
    lock.lock()
    defer { lock.unlock() }
    owners.removeAll(keepingCapacity: true)
  }
}
