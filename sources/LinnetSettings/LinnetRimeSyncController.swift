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

/// The Host owns this object on the main run loop. Timer's callback is marked
/// Sendable by Foundation even though every state transition is main-thread
/// confined, so the conformance documents that external ownership contract.
struct LinnetRimeSyncConfiguration: Sendable {
  let syncDirectory: URL?
  let lastAttempt: Date?
}

enum LinnetRimeSyncOutcome {
  case completed
  case inProgress
  case deferred
  case busy
  case failed
}

private struct LinnetRimeSyncCycle {
  let cycleID: UUID
  let deadline: Date
  var attempt: Int
  var recorded: Bool
  let syncDirectory: URL
}

final class LinnetRimeSyncController: @unchecked Sendable {

  private let loadConfiguration: () throws -> LinnetRimeSyncConfiguration
  private let recordAttempt: (Date) -> Bool
  private let operation: (URL) -> LinnetRimeSyncOutcome
  private let cancelOperation: () -> Void
  private let configurationQueue = DispatchQueue(label: "Linnet.learning-sync", qos: .utility)
  private var configurationOperation: BlockOperation?
  private var timer: Timer?
  private var cycle: LinnetRimeSyncCycle?

  init(
    loadConfiguration: @escaping () throws -> LinnetRimeSyncConfiguration,
    recordAttempt: @escaping (Date) -> Bool,
    operation: @escaping (URL) -> LinnetRimeSyncOutcome,
    cancelOperation: @escaping () -> Void
  ) {
    self.loadConfiguration = loadConfiguration
    self.recordAttempt = recordAttempt
    self.operation = operation
    self.cancelOperation = cancelOperation
  }

  func start() { reload() }

  func stop() {
    configurationOperation?.cancel()
    configurationOperation = nil
    cancelOperation()
    timer?.invalidate()
    timer = nil
    cycle = nil
  }

  func reload(synchronizeImmediately: Bool = false) {
    stop()
    let request = BlockOperation()
    configurationOperation = request
    request.addExecutionBlock { [weak self, weak request] in
      guard let self, let request, !request.isCancelled else { return }
      let result = Result { try self.loadConfiguration() }
      DispatchQueue.main.async { [weak self] in
        guard let self, !request.isCancelled else { return }
        configurationOperation = nil
        finishReload(result, synchronizeImmediately: synchronizeImmediately)
      }
    }
    configurationQueue.async { request.start() }
  }

  private func finishReload(
    _ result: Result<LinnetRimeSyncConfiguration, Error>, synchronizeImmediately: Bool
  ) {
    do {
      let loaded = try result.get()
      guard let syncDirectory = loaded.syncDirectory else { return }
      let now = Date()
      let next = synchronizeImmediately ? now : LinnetRimeSyncSchedule.nextAutomaticDate(
        now: now, lastAttempt: loaded.lastAttempt)
      if next <= now {
        begin(at: now, syncDirectory: syncDirectory)
      } else {
        scheduleAutomatic(at: next)
      }
    } catch {
      print("Linnet learning sync configuration is unavailable: \(error.localizedDescription)")
      scheduleAutomatic(at: Date().addingTimeInterval(LinnetRimeSyncSchedule.automaticInterval))
    }
  }

  func synchronizeNow() {
    reload(synchronizeImmediately: true)
  }

  private func scheduleAutomatic(at date: Date) {
    schedule(at: date) { [weak self] in self?.reload() }
  }

  private func begin(at now: Date, syncDirectory: URL) {
    timer?.invalidate()
    let cycle = LinnetRimeSyncCycle(
      cycleID: UUID(), deadline: now.addingTimeInterval(60), attempt: 0, recorded: false,
      syncDirectory: syncDirectory)
    self.cycle = cycle
    attempt(cycle.cycleID)
  }

  private func attempt(_ cycleID: UUID) {
    guard var current = cycle, current.cycleID == cycleID else { return }
    if !current.recorded {
      guard recordAttempt(Date()) else {
        cycle = nil
        scheduleAutomatic(at: Date().addingTimeInterval(LinnetRimeSyncSchedule.automaticInterval))
        return
      }
      current.recorded = true
    }
    cycle = current
    switch operation(current.syncDirectory) {
    case .inProgress:
      let now = Date()
      guard now < current.deadline else {
        cancelOperation()
        cycle = nil
        print("Linnet learning sync deferred; input and pending learning were preserved.")
        scheduleAutomatic(at: now.addingTimeInterval(LinnetRimeSyncSchedule.automaticInterval))
        return
      }
      schedule(at: now.addingTimeInterval(0.01)) { [weak self] in self?.attempt(cycleID) }
    case .busy:
      current.attempt += 1
      cycle = current
      let now = Date()
      guard let delay = LinnetRimeSyncSchedule.retryDelay(
        attempt: current.attempt, now: now, deadline: current.deadline)
      else {
        cancelOperation()
        cycle = nil
        scheduleAutomatic(at: now.addingTimeInterval(LinnetRimeSyncSchedule.automaticInterval))
        return
      }
      schedule(at: now.addingTimeInterval(delay)) { [weak self] in self?.attempt(cycleID) }
    case .completed, .deferred, .failed:
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
