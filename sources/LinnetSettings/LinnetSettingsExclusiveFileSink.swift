import Foundation

/// Streams one download into a sibling temporary file and publishes it without
/// replacing an existing destination. Catalog and pack verification stay with
/// their existing owners.
final class LinnetSettingsExclusiveFileSink {
  typealias Failure = LinnetSettingsDownloadTransport.Failure

  private let destination: URL
  private let partial: URL
  private var handle: FileHandle?
  private var active = true

  init(destination: URL) throws {
    guard destination.isFileURL, !destination.hasDirectoryPath,
      !destination.lastPathComponent.isEmpty
    else { throw Failure.unsafeDestination }

    let parent = destination.deletingLastPathComponent()
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(
      atPath: parent.path, isDirectory: &isDirectory
    ), isDirectory.boolValue else { throw Failure.unsafeDestination }
    guard !Self.itemExists(at: destination) else { throw Failure.destinationExists }

    self.destination = destination
    partial = parent.appending(
      path: ".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
    guard FileManager.default.createFile(
      atPath: partial.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600]
    ) else { throw Failure.storage(EIO) }
    do {
      handle = try FileHandle(forWritingTo: partial)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw Failure.storage(Self.code(for: error))
    }
  }

  deinit { try? discard() }

  func write(_ data: Data) throws {
    guard active, let handle else { throw Failure.storage(EBADF) }
    do {
      try handle.write(contentsOf: data)
    } catch {
      throw Failure.storage(Self.code(for: error))
    }
  }

  func publish() throws {
    guard active, let handle else { throw Failure.storage(EBADF) }
    do {
      try handle.synchronize()
      try handle.close()
      self.handle = nil
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444], ofItemAtPath: partial.path)
      try FileManager.default.moveItem(at: partial, to: destination)
      active = false
    } catch {
      if Self.itemExists(at: destination) {
        throw Failure.destinationExists
      }
      throw Failure.storage(Self.code(for: error))
    }
  }

  func discard() throws {
    guard active else { return }
    active = false
    var firstError: Error?
    if let handle {
      do { try handle.close() } catch { firstError = error }
      self.handle = nil
    }
    if Self.itemExists(at: partial) {
      do { try FileManager.default.removeItem(at: partial) } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError { throw Failure.storage(Self.code(for: firstError)) }
  }

  private static func itemExists(at url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  private static func code(for error: Error) -> Int32 {
    Int32(clamping: (error as NSError).code)
  }
}
