import Darwin
import Foundation

@main
struct LinnetRimeSyncControllerTests {
  static func main() {
    do {
      try withTemporaryDirectory { root in
        try testControllerRateLimitAndManualOverride(root: root)
        try testDurableMarkerBlocksOperation(root: root)
        try testUnavailableDirectoryRecoversOnManualRequest(root: root)
        try testDisabledSyncDoesNotRun(root: root)
        try testSlowConfigurationDoesNotBlockInput(root: root)
        try testIncrementalWorkYieldsAndCancellationStopsIt(root: root)
        try testDeferredCycleRetainsHourlyWindow(root: root)
      }
      testHourlyAutomaticLimit()
      testBoundedBusyRetry()
      print("LinnetRimeSyncControllerTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testHourlyAutomaticLimit() {
    let now = Date(timeIntervalSince1970: 10_000)
    guard LinnetRimeSyncSchedule.nextAutomaticDate(now: now, lastAttempt: nil) == now,
      LinnetRimeSyncSchedule.nextAutomaticDate(
        now: now, lastAttempt: now.addingTimeInterval(-3_599)
      ) == now.addingTimeInterval(1),
      LinnetRimeSyncSchedule.nextAutomaticDate(
        now: now, lastAttempt: now.addingTimeInterval(-3_600)
      ) == now
    else { fail("automatic synchronization was not limited to one hourly window") }
  }

  private static func testBoundedBusyRetry() {
    let now = Date(timeIntervalSince1970: 20_000)
    let deadline = now.addingTimeInterval(60)
    guard LinnetRimeSyncSchedule.retryDelay(attempt: 1, now: now, deadline: deadline) == 5,
      LinnetRimeSyncSchedule.retryDelay(attempt: 11, now: now, deadline: deadline) == 5,
      LinnetRimeSyncSchedule.retryDelay(attempt: 12, now: now, deadline: deadline) == nil,
      LinnetRimeSyncSchedule.retryDelay(
        attempt: 1, now: deadline, deadline: deadline) == nil
    else { fail("busy synchronization retries were not bounded") }
  }

  private static func testControllerRateLimitAndManualOverride(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "RateLimit")
    let installation = user.appending(component: "installation.yaml")
    let before = try Data(contentsOf: installation)
    let sync = root.appending(component: "Sync", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: false)
    var recordedAttempts = 0
    var operations = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: {
        .init(syncDirectory: sync, lastAttempt: Date())
      },
      recordAttempt: { _ in
        recordedAttempts += 1
        return true
      },
      operation: { directory in
        guard directory == sync else { fail("sync did not receive its explicit directory") }
        operations += 1
        return .completed
      }, cancelOperation: {})

    controller.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 0, recordedAttempts == 0 else {
      fail("the hourly automatic window performed an early write")
    }

    controller.synchronizeNow()
    waitUntil { operations == 1 }
    guard operations == 1, recordedAttempts == 1 else {
      fail("an explicit manual synchronization did not override the automatic window once")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 1, recordedAttempts == 1,
      try Data(contentsOf: installation) == before
    else {
      fail("a completed cycle scheduled another immediate write")
    }
    controller.stop()
  }

  private static func testDurableMarkerBlocksOperation(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "MarkerFailure")
    let installation = user.appending(component: "installation.yaml")
    let before = try Data(contentsOf: installation)
    let sync = root.appending(component: "MarkerSync", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: false)
    var operations = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: {
        .init(syncDirectory: sync, lastAttempt: nil)
      },
      recordAttempt: { _ in false },
      operation: { _ in
        operations += 1
        return .completed
      }, cancelOperation: {})

    controller.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 0, try Data(contentsOf: installation) == before else {
      fail("learning sync wrote before its hourly attempt marker was durable")
    }
    controller.stop()
  }

  private static func makeUserDirectory(root: URL, name: String) throws -> URL {
    let user = root.appending(component: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: false)
    try """
      # Rime-owned fields are not an online learning-sync transport.
      installation_id: \(name)
      distribution_code_name: Linnet
      sync_dir: "user-configured-offline-sync"
      backup_config_files: true
      nested:
        sync_dir: keep-nested

      """.write(
      to: user.appending(component: "installation.yaml"),
      atomically: true,
      encoding: .utf8)
    return user
  }

  private static func testUnavailableDirectoryRecoversOnManualRequest(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "DirectoryRecovery")
    let sync = root.appending(component: "RecoverySync", directoryHint: .isDirectory)
    let installation = user.appending(component: "installation.yaml")
    let before = try Data(contentsOf: installation)
    var locationIsAvailable = false
    var configurationLoads = 0
    var operations = 0
    var recordedAttempts = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: {
        configurationLoads += 1
        guard locationIsAvailable else { throw POSIXError(.ENOENT) }
        return .init(syncDirectory: sync, lastAttempt: Date())
      },
      recordAttempt: { _ in recordedAttempts += 1; return true },
      operation: { _ in
        operations += 1
        return .completed
      }, cancelOperation: {})
    controller.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 0, recordedAttempts == 0, configurationLoads == 1,
      try Data(contentsOf: installation) == before
    else { fail("an unavailable sync location started a write or erased the configured directory") }
    locationIsAvailable = true
    controller.synchronizeNow()
    waitUntil { operations == 1 }
    guard configurationLoads == 2, operations == 1, recordedAttempts == 1,
      try Data(contentsOf: installation) == before
    else {
      fail("an enabled sync location stayed disconnected after becoming available")
    }
    controller.stop()
  }

  private static func testDisabledSyncDoesNotRun(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "DisabledSync")
    let installation = user.appending(component: "installation.yaml")
    let before = try Data(contentsOf: installation)
    var operations = 0
    var recordedAttempts = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: {
        .init(syncDirectory: nil, lastAttempt: nil)
      },
      recordAttempt: { _ in recordedAttempts += 1; return true },
      operation: { _ in
        operations += 1
        return .completed
      }, cancelOperation: {})
    controller.start()
    controller.synchronizeNow()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 0, recordedAttempts == 0,
      try Data(contentsOf: installation) == before
    else { fail("disabled synchronization wrote a marker, installation, or learning data") }
    controller.stop()
  }

  private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = LinnetTestScratch.directory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  private static func testSlowConfigurationDoesNotBlockInput(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "SlowCloud")
    let before = try Data(contentsOf: user.appending(component: "installation.yaml"))
    let cloudStarted = DispatchSemaphore(value: 0)
    let cloudReleased = DispatchSemaphore(value: 0)
    let cloudFinished = DispatchSemaphore(value: 0)
    var operations = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: {
        guard !Thread.isMainThread else { fail("cloud I/O ran on the input thread") }
        cloudStarted.signal()
        cloudReleased.wait()
        cloudFinished.signal()
        return .init(syncDirectory: root, lastAttempt: nil)
      }, recordAttempt: { _ in true }, operation: { _ in
        operations += 1
        return .completed
      }, cancelOperation: {})
    let started = Date()
    controller.start()
    guard Date().timeIntervalSince(started) < 0.05,
      cloudStarted.wait(timeout: .now() + 1) == .success
    else { fail("configuration loading blocked the input run loop") }
    // Cloud I/O is deliberately still blocked while input work runs and cancels.
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    controller.stop()
    cloudReleased.signal()
    guard cloudFinished.wait(timeout: .now() + 1) == .success else {
      fail("cloud fixture did not finish")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 0,
      try Data(contentsOf: user.appending(component: "installation.yaml")) == before
    else { fail("cancelled configuration wrote or started stale sync work") }
  }

  private static func testIncrementalWorkYieldsAndCancellationStopsIt(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "YieldingSync")
    let installation = user.appending(component: "installation.yaml")
    let originalInstallation = try Data(contentsOf: installation)
    var steps = 0
    var attempts = 0
    var cancellations = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: { .init(syncDirectory: root, lastAttempt: nil) },
      recordAttempt: { _ in attempts += 1; return true },
      operation: { _ in
        guard Thread.isMainThread else { fail("live database work escaped the input owner") }
        steps += 1
        return .inProgress
      }, cancelOperation: { cancellations += 1 })
    controller.start()
    waitUntil { steps >= 4 }
    let before = steps
    let cancelBefore = cancellations
    controller.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    guard attempts == 1, steps == before, cancellations == cancelBefore + 1,
      try Data(contentsOf: installation) == originalInstallation
    else {
      fail("incremental work bypassed throttling or continued after cancellation")
    }
  }

  private static func testDeferredCycleRetainsHourlyWindow(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "DeferredSync")
    let installation = user.appending(component: "installation.yaml")
    let before = try Data(contentsOf: installation)
    var lastAttempt: Date?
    var recordedAttempts = 0
    var operations = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: { .init(syncDirectory: root, lastAttempt: lastAttempt) },
      recordAttempt: { date in
        lastAttempt = date
        recordedAttempts += 1
        return true
      }, operation: { _ in
        operations += 1
        return .deferred
      }, cancelOperation: {})
    controller.start()
    waitUntil { operations == 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    guard operations == 1, recordedAttempts == 1, let lastAttempt,
      LinnetRimeSyncSchedule.nextAutomaticDate(now: lastAttempt, lastAttempt: lastAttempt)
        == lastAttempt.addingTimeInterval(3_600)
    else { fail("deferred learning sync immediately retried or lost its hourly marker") }
    controller.reload()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 1, recordedAttempts == 1,
      try Data(contentsOf: installation) == before
    else { fail("deferred learning sync restarted before its next hourly window") }
    controller.stop()
  }

  private static func waitUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    guard condition() else { fail("asynchronous synchronization did not progress") }
  }
}

private func fail(_ message: String) -> Never {
  fputs("LinnetRimeSyncControllerTests: \(message)\n", stderr)
  exit(1)
}
