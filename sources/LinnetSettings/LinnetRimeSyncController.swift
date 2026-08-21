import Darwin
import Foundation

enum LinnetRimeSyncSchedule {
  static let automaticInterval: TimeInterval = 60 * 60
  static let busyRetryInterval: TimeInterval = 5
  static let maximumBusyAttempts = 12

  static func nextAutomaticDate(now: Date, lastAttempt: Date?) -> Date {
    guard let lastAttempt else { return now }
    return max(now, lastAttempt.addingTimeInterval(automaticInterval))
  }

  static func retryDelay(attempt: Int, now: Date, deadline: Date) -> TimeInterval? {
    guard attempt < maximumBusyAttempts,
      now < deadline,
      now.addingTimeInterval(busyRetryInterval) <= deadline
    else { return nil }
    return busyRetryInterval
  }
}

enum LinnetRimeSyncInstallation {
  enum Failure: Error, Equatable {
    case unsafeUserDirectory
    case unsafeInstallation
    case oversizedInstallation
    case invalidEncoding
    case duplicateSyncDirectory
    case duplicateAutomaticConfigBackupPolicy
  }

  private static let maximumBytes = 1_048_576
  private static let automaticConfigBackupProjection = "backup_config_files: false"

  static func project(syncDirectory: URL?, userDirectory: URL) throws {
    try requireOwnedDirectory(userDirectory)
    let installation = userDirectory.appending(component: "installation.yaml")
    let data = try boundedOwnedFile(installation)
    guard let contents = String(data: data, encoding: .utf8) else {
      throw Failure.invalidEncoding
    }

    var lines = contents.components(separatedBy: "\n")
    let syncDirectoryIndices = lines.indices.filter { lines[$0].hasPrefix("sync_dir:") }
    guard syncDirectoryIndices.count <= 1 else { throw Failure.duplicateSyncDirectory }
    let configBackupIndices = lines.indices.filter {
      lines[$0].hasPrefix("backup_config_files:")
    }
    guard configBackupIndices.count <= 1 else {
      throw Failure.duplicateAutomaticConfigBackupPolicy
    }

    if let index = configBackupIndices.first {
      lines[index] = automaticConfigBackupProjection
    } else if lines.last == "" {
      lines.insert(automaticConfigBackupProjection, at: lines.index(before: lines.endIndex))
    } else {
      lines.append(automaticConfigBackupProjection)
    }

    if let syncDirectory {
      let quoted = try jsonQuoted(syncDirectory.standardizedFileURL.path)
      let projection = "sync_dir: \(quoted)"
      if let index = syncDirectoryIndices.first {
        lines[index] = projection
      } else if lines.last == "" {
        lines.insert(projection, at: lines.index(before: lines.endIndex))
      } else {
        lines.append(projection)
      }
    } else if let index = syncDirectoryIndices.first {
      lines.remove(at: index)
    }

    let projected = lines.joined(separator: "\n")
    guard projected != contents else { return }
    try Data(projected.utf8).write(to: installation, options: .atomic)
  }

  private static func jsonQuoted(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let result = String(data: data, encoding: .utf8) else {
      throw Failure.invalidEncoding
    }
    return result
  }

  private static func requireOwnedDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafeUserDirectory }
  }

  private static func boundedOwnedFile(_ url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.unsafeInstallation }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafeInstallation }
    guard info.st_size >= 0, info.st_size <= maximumBytes else {
      throw Failure.oversizedInstallation
    }
    return try handle.readToEnd() ?? Data()
  }
}

/// The Host owns this object on the main run loop. Timer's callback is marked
/// Sendable by Foundation even though every state transition is main-thread
/// confined, so the conformance documents that external ownership contract.
final class LinnetRimeSyncController: @unchecked Sendable {
  struct Configuration {
    let userDirectory: URL
    let syncDirectory: URL?
    let lastAttempt: Date?
  }

  enum Outcome {
    case completed
    case busy
    case failed
  }

  private struct Cycle {
    let id: UUID
    let deadline: Date
    var attempt: Int
    var recorded: Bool
  }

  private let loadConfiguration: () throws -> Configuration
  private let recordAttempt: (Date) -> Bool
  private let operation: () -> Outcome
  private var configuration: Configuration?
  private var timer: Timer?
  private var cycle: Cycle?

  init(
    loadConfiguration: @escaping () throws -> Configuration,
    recordAttempt: @escaping (Date) -> Bool,
    operation: @escaping () -> Outcome
  ) {
    self.loadConfiguration = loadConfiguration
    self.recordAttempt = recordAttempt
    self.operation = operation
  }

  func start() { reload() }

  func stop() {
    timer?.invalidate()
    timer = nil
    cycle = nil
    configuration = nil
  }

  func reload() {
    stop()
    do {
      let loaded = try loadConfiguration()
      try LinnetRimeSyncInstallation.project(
        syncDirectory: loaded.syncDirectory,
        userDirectory: loaded.userDirectory)
      configuration = loaded
      guard loaded.syncDirectory != nil else { return }
      scheduleAutomatic(
        at: LinnetRimeSyncSchedule.nextAutomaticDate(
          now: Date(), lastAttempt: loaded.lastAttempt))
    } catch {
      print("Linnet learning sync configuration is unavailable: \(error.localizedDescription)")
    }
  }

  func synchronizeNow() {
    guard configuration?.syncDirectory != nil else { return }
    begin(at: Date())
  }

  private func scheduleAutomatic(at date: Date) {
    schedule(at: date) { [weak self] in self?.begin(at: Date()) }
  }

  private func begin(at now: Date) {
    timer?.invalidate()
    let cycle = Cycle(
      id: UUID(), deadline: now.addingTimeInterval(60), attempt: 0, recorded: false)
    self.cycle = cycle
    attempt(cycle.id)
  }

  private func attempt(_ id: UUID) {
    guard var current = cycle, current.id == id else { return }
    if !current.recorded {
      guard recordAttempt(Date()) else {
        cycle = nil
        scheduleAutomatic(at: Date().addingTimeInterval(LinnetRimeSyncSchedule.automaticInterval))
        return
      }
      current.recorded = true
    }
    current.attempt += 1
    cycle = current
    switch operation() {
    case .busy:
      let now = Date()
      guard let delay = LinnetRimeSyncSchedule.retryDelay(
        attempt: current.attempt, now: now, deadline: current.deadline)
      else {
        cycle = nil
        scheduleAutomatic(at: now.addingTimeInterval(LinnetRimeSyncSchedule.automaticInterval))
        return
      }
      schedule(at: now.addingTimeInterval(delay)) { [weak self] in self?.attempt(id) }
    case .completed, .failed:
      let attemptedAt = Date()
      cycle = nil
      scheduleAutomatic(
        at: attemptedAt.addingTimeInterval(LinnetRimeSyncSchedule.automaticInterval))
    }
  }

  private func schedule(at date: Date, action: @Sendable @escaping () -> Void) {
    timer?.invalidate()
    let timer = Timer(fire: date, interval: 0, repeats: false) { _ in action() }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
}
