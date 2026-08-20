import Darwin
import Foundation

/// Settings-only mutation boundary for publishing one immutable downloaded pack.
/// It never interprets pack identity; the canonical catalog and pack verifier own that fact.
final class LinnetSettingsExclusiveFileSink {
  typealias Failure = LinnetSettingsDownloadTransport.Failure

  private var parentDescriptor: Int32 = -1
  private var outputDescriptor: Int32 = -1
  private let partialName: String
  private let finalName: String
  private var active = true

  init(destination: URL) throws {
    guard destination.isFileURL, !destination.hasDirectoryPath,
      !destination.lastPathComponent.isEmpty,
      destination.lastPathComponent.utf8.count <= 180
    else { throw Failure.unsafeDestination }
    finalName = destination.lastPathComponent
    partialName = ".\(finalName).partial-\(UUID().uuidString)"
    let parent = destination.deletingLastPathComponent()
    parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentDescriptor >= 0 else { throw Failure.unsafeDestination }

    var parentInfo = stat()
    guard fstat(parentDescriptor, &parentInfo) == 0,
      (parentInfo.st_mode & S_IFMT) == S_IFDIR,
      parentInfo.st_uid == getuid(),
      (parentInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      let code = errno
      closeParent()
      throw code == 0 ? Failure.unsafeDestination : Failure.storage(code)
    }

    var destinationInfo = stat()
    let existing = finalName.withCString {
      fstatat(parentDescriptor, $0, &destinationInfo, AT_SYMLINK_NOFOLLOW)
    }
    guard existing != 0 else {
      closeParent()
      throw Failure.destinationExists
    }
    guard errno == ENOENT else {
      let code = errno
      closeParent()
      throw Failure.storage(code)
    }

    outputDescriptor = partialName.withCString {
      openat(parentDescriptor, $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard outputDescriptor >= 0 else {
      let code = errno
      closeParent()
      throw Failure.storage(code)
    }
  }

  deinit { try? discard() }

  func write(_ data: Data) throws {
    guard active, outputDescriptor >= 0 else { throw Failure.storage(EBADF) }
    try data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = Darwin.write(outputDescriptor, pointer, remaining)
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw Failure.storage(errno == 0 ? EIO : errno) }
        remaining -= written
        pointer = pointer.advanced(by: written)
      }
    }
  }

  func publish() throws {
    guard active, outputDescriptor >= 0, parentDescriptor >= 0 else {
      throw Failure.storage(EBADF)
    }
    while fsync(outputDescriptor) != 0 {
      if errno == EINTR { continue }
      throw Failure.storage(errno)
    }
    guard fchmod(outputDescriptor, 0o444) == 0 else { throw Failure.storage(errno) }
    let descriptor = outputDescriptor
    outputDescriptor = -1
    guard Darwin.close(descriptor) == 0 else { throw Failure.storage(errno) }

    let renamed = partialName.withCString { source in
      finalName.withCString { destination in
        renameatx_np(parentDescriptor, source, parentDescriptor, destination,
          UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
      }
    }
    guard renamed == 0 else { throw Failure.storage(errno) }
    active = false
    closeParent()
  }

  func discard() throws {
    guard active else {
      closeParent()
      return
    }
    var failure: Int32?
    if outputDescriptor >= 0 {
      let descriptor = outputDescriptor
      outputDescriptor = -1
      if Darwin.close(descriptor) != 0 { failure = errno }
    }
    if parentDescriptor >= 0 {
      let removed = partialName.withCString { unlinkat(parentDescriptor, $0, 0) }
      if removed != 0 && errno != ENOENT { failure = failure ?? errno }
    }
    active = false
    closeParent()
    if let failure { throw Failure.storage(failure) }
  }

  private func closeParent() {
    guard parentDescriptor >= 0 else { return }
    let descriptor = parentDescriptor
    parentDescriptor = -1
    _ = Darwin.close(descriptor)
  }
}
