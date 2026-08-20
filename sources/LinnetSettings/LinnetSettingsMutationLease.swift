import Darwin
import Foundation

/// Cross-process serialization for Settings mutations that read and then
/// replace files under Linnet's support directory. The file descriptor owns
/// the lease; dropping it always releases the kernel lock.
final class LinnetSettingsMutationLease: @unchecked Sendable {
  enum Failure: LocalizedError, Equatable, Sendable {
    case unavailable
    case timedOut

    var errorDescription: String? {
      switch self {
      case .unavailable: "The settings mutation lease is unavailable."
      case .timedOut: "Another Linnet settings operation is still running."
      }
    }
  }

  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }

  static func acquire(at url: URL, timeout: TimeInterval) async throws -> LinnetSettingsMutationLease {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw Failure.unavailable }

    let deadline = Date().addingTimeInterval(timeout)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN else {
        _ = close(descriptor)
        throw Failure.unavailable
      }
      guard Date() < deadline else {
        _ = close(descriptor)
        throw Failure.timedOut
      }
      do {
        try await Task.sleep(nanoseconds: 25_000_000)
      } catch {
        _ = close(descriptor)
        throw error
      }
    }
    return LinnetSettingsMutationLease(descriptor: descriptor)
  }
}
