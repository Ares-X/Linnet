import Darwin
import Foundation

@main
struct LinnetRimeSyncControllerTests {
  static func main() {
    do {
      try withTemporaryDirectory { root in
        try testInstallationProjection(root: root)
        try testInstallationProjectionRejectsDuplicateOwner(root: root)
        try testInstallationProjectionRejectsDuplicateBackupPolicy(root: root)
        try testControllerRateLimitAndManualOverride(root: root)
        try testDurableMarkerBlocksOperation(root: root)
      }
      testHourlyAutomaticLimit()
      testBoundedBusyRetry()
      print("LinnetRimeSyncControllerTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testInstallationProjection(root: URL) throws {
    let user = root.appending(component: "UserData", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: false)
    let installation = user.appending(component: "installation.yaml")
    try """
      installation_id: mac-a
      distribution_code_name: Linnet
      nested:
        sync_dir: keep-nested
      sync_dir: old
      """.write(to: installation, atomically: true, encoding: .utf8)
    let sync = root.appending(component: "iCloud \"Linnet\"", directoryHint: .isDirectory)

    try LinnetRimeSyncInstallation.project(syncDirectory: sync, userDirectory: user)
    let projected = try String(contentsOf: installation, encoding: .utf8)
    let rootProjection = projected.split(separator: "\n")
      .first(where: { $0.hasPrefix("sync_dir: ") })
    let decodedPath = try rootProjection.map {
      try JSONDecoder().decode(
        String.self, from: Data($0.dropFirst("sync_dir: ".count).utf8))
    }
    guard projected.contains("installation_id: mac-a"),
      projected.contains("  sync_dir: keep-nested"),
      projected.split(separator: "\n").filter({
        $0 == "backup_config_files: false"
      }).count == 1,
      decodedPath == sync.path
    else { fail("learning-only projection did not preserve the Rime installation owner") }

    try LinnetRimeSyncInstallation.project(syncDirectory: nil, userDirectory: user)
    let disconnected = try String(contentsOf: installation, encoding: .utf8)
    guard disconnected.contains("installation_id: mac-a"),
      disconnected.contains("  sync_dir: keep-nested"),
      disconnected.split(separator: "\n").filter({
        $0 == "backup_config_files: false"
      }).count == 1,
      !disconnected.split(separator: "\n").contains(where: { $0.hasPrefix("sync_dir:") })
    else { fail("disconnect did not retain the learning-only synchronization policy") }
  }

  private static func testInstallationProjectionRejectsDuplicateOwner(root: URL) throws {
    let user = root.appending(component: "Duplicate", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: false)
    let installation = user.appending(component: "installation.yaml")
    try "installation_id: mac-b\nsync_dir: one\nsync_dir: two\n"
      .write(to: installation, atomically: true, encoding: .utf8)
    do {
      try LinnetRimeSyncInstallation.project(syncDirectory: root, userDirectory: user)
      fail("duplicate root sync_dir owners were accepted")
    } catch LinnetRimeSyncInstallation.Failure.duplicateSyncDirectory {}
  }

  private static func testInstallationProjectionRejectsDuplicateBackupPolicy(root: URL) throws {
    let user = root.appending(component: "DuplicateBackup", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: false)
    let installation = user.appending(component: "installation.yaml")
    try "installation_id: mac-c\nbackup_config_files: true\nbackup_config_files: false\n"
      .write(to: installation, atomically: true, encoding: .utf8)
    do {
      try LinnetRimeSyncInstallation.project(syncDirectory: root, userDirectory: user)
      fail("duplicate root automatic config backup policies were accepted")
    } catch LinnetRimeSyncInstallation.Failure.duplicateAutomaticConfigBackupPolicy {}
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
    let sync = root.appending(component: "Sync", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: false)
    var recordedAttempts = 0
    var operations = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: {
        .init(userDirectory: user, syncDirectory: sync, lastAttempt: Date())
      },
      recordAttempt: { _ in
        recordedAttempts += 1
        return true
      },
      operation: {
        operations += 1
        return .completed
      })

    controller.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 0, recordedAttempts == 0 else {
      fail("the hourly automatic window performed an early write")
    }

    controller.synchronizeNow()
    guard operations == 1, recordedAttempts == 1 else {
      fail("an explicit manual synchronization did not override the automatic window once")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 1, recordedAttempts == 1 else {
      fail("a completed cycle scheduled another immediate write")
    }
    controller.stop()
  }

  private static func testDurableMarkerBlocksOperation(root: URL) throws {
    let user = try makeUserDirectory(root: root, name: "MarkerFailure")
    let sync = root.appending(component: "MarkerSync", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: false)
    var operations = 0
    let controller = LinnetRimeSyncController(
      loadConfiguration: {
        .init(userDirectory: user, syncDirectory: sync, lastAttempt: nil)
      },
      recordAttempt: { _ in false },
      operation: {
        operations += 1
        return .completed
      })

    controller.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard operations == 0 else {
      fail("learning sync wrote before its hourly attempt marker was durable")
    }
    controller.stop()
  }

  private static func makeUserDirectory(root: URL, name: String) throws -> URL {
    let user = root.appending(component: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: false)
    try "installation_id: \(name)\n".write(
      to: user.appending(component: "installation.yaml"),
      atomically: true,
      encoding: .utf8)
    return user
  }

  private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    var template = Array("/tmp/linnet-rime-sync.XXXXXX".utf8CString)
    guard let path = mkdtemp(&template) else { throw POSIXError(.EIO) }
    let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }
}

private func fail(_ message: String) -> Never {
  fputs("LinnetRimeSyncControllerTests: \(message)\n", stderr)
  exit(1)
}
