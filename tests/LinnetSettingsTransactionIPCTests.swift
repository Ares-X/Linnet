import Darwin
import Foundation

// The focused transport test compiles the real Settings contract without the
// pack/runtime implementation; IPC only consumes these registry locations.
struct LinnetDataRegistry {
  let rootDirectory: URL
  let userDataDirectory: URL
  let transactionsDirectory: URL
  let backupsDirectory: URL

  init(productName: String, coreVersion: String) throws {
    guard let root = ProcessInfo.processInfo.environment["LINNET_IPC_TEST_ROOT"],
      root.hasPrefix("/")
    else {
      throw NSError(
        domain: "LinnetSettingsTransactionIPCTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "missing isolated IPC root"])
    }
    rootDirectory = URL(fileURLWithPath: root, isDirectory: true)
    userDataDirectory = rootDirectory.appending(path: "User", directoryHint: .isDirectory)
    transactionsDirectory = rootDirectory.appending(
      path: "Transactions", directoryHint: .isDirectory)
    backupsDirectory = rootDirectory.appending(path: "Backups", directoryHint: .isDirectory)
  }
}

private enum TimeoutRecoveryFixture {
  static let primaryName = "default.custom.yaml"
  static let secondaryName = "linnet_zh.custom.yaml"
  static let nextPrimary = Data("primary-generation=next\n".utf8)
  static let nextSecondary = Data("secondary-generation=next\n".utf8)
  static let stablePrimary = Data("primary-generation=stable\n".utf8)
  static let stableSecondary = Data("secondary-generation=stable\n".utf8)

  static func primary(in directory: URL) -> URL {
    directory.appending(path: primaryName)
  }

  static func secondary(in directory: URL) -> URL {
    directory.appending(path: secondaryName)
  }
}

private enum ConfigurationFixture {
  static let baseRevision = String(repeating: "a", count: 64)
  static let attemptedRevision = String(repeating: "b", count: 64)

  static func candidate(in directory: URL) -> URL {
    directory.appending(path: "configuration-candidate", directoryHint: .isDirectory)
  }
}

@main
struct LinnetSettingsTransactionIPCTests {
  static func main() async {
    do {
      #if LINNET_IPC_HOST_HELPER
        try runHost()
      #elseif LINNET_IPC_SETTINGS_HELPER
        try await runSettings()
      #else
        throw TestFailure.invalidInvocation
      #endif
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  #if LINNET_IPC_HOST_HELPER
    private static func runHost() throws {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard let mode = arguments.first,
        [
          "--serve-success", "--serve-reload", "--serve-rejection",
          "--serve-core-activation",
          "--serve-owner-collision",
          "--serve-timeout-recovery",
        ].contains(mode),
        arguments.count == (mode == "--serve-timeout-recovery" ? 4 : 2)
      else { throw TestFailure.invalidInvocation }
      let invoked = DispatchSemaphore(value: 0)
      let invocation = LockedFlag()
      let recoveryObservations = LockedRecoveryObservations()
      let liveDirectory = mode == "--serve-timeout-recovery"
        ? URL(fileURLWithPath: arguments[2], isDirectory: true) : nil
      let firstReadMarker = mode == "--serve-timeout-recovery"
        ? URL(fileURLWithPath: arguments[3]) : nil
      let host = try LinnetSettingsTransactionIPC.Host(
        startingAt: .main
      ) { request, reply in
        invocation.set()
        defer { invoked.signal() }
        if let liveDirectory, let firstReadMarker {
          do {
            guard request.command == .reloadConfiguration else {
              throw TestFailure.invalidInvocation
            }
            let requestIndex = recoveryObservations.count
            let primary = try Data(
              contentsOf: TimeoutRecoveryFixture.primary(in: liveDirectory))
            if requestIndex == 0 {
              try Data("first-owned-file-read\n".utf8).write(
                to: firstReadMarker, options: .atomic)
              // Keep the first real Host request inside its owned-file read
              // after the Settings-side 3 s reply deadline has elapsed.
              usleep(4_000_000)
            }
            let secondary = try Data(
              contentsOf: TimeoutRecoveryFixture.secondary(in: liveDirectory))
            let canContinue = LinnetSettingsContract.requestCanContinue(request)
            recoveryObservations.append(
              .init(
                transactionID: request.transactionID,
                primary: primary,
                secondary: secondary,
                canContinue: canContinue))
            reply(
              .init(
                transactionID: request.transactionID,
                status: canContinue ? .activated : .rejected,
                code: canContinue ? .configurationApplied : .requesterUnavailable,
                detail: canContinue
                  ? "configuration applied" : "request deadline expired",
                health: nil))
          } catch {
            recoveryObservations.recordFailure(String(describing: error))
            reply(
              .init(
                transactionID: request.transactionID, status: .failed,
                code: .configurationReloadFailed,
                detail: "owned-file read failed", health: nil))
          }
        } else if request.command == .activateCore {
          reply(.init(
            transactionID: request.transactionID, status: .terminating,
            code: .coreActivationAccepted, detail: "Core activation accepted", health: nil))
        } else if request.command == .reloadConfiguration {
          reply(.init(
            transactionID: request.transactionID, status: .activated,
            code: .configurationApplied, detail: "configuration applied", health: nil))
        } else {
          reply(.init(
            transactionID: request.transactionID, status: .verifying,
            code: .verificationStarted, detail: "verification started", health: nil))
          reply(.init(
            transactionID: request.transactionID, status: .activated,
            code: .activationVerified, detail: "activation verified", health: nil))
        }
      }
      try host.start()
      defer { host.stop() }

      if mode == "--serve-owner-collision" {
        let duplicate = try LinnetSettingsTransactionIPC.Host(
          startingAt: .main
        ) { _, _ in }
        do {
          try duplicate.start()
          duplicate.stop()
          throw TestFailure.duplicateOwnerAccepted
        } catch LinnetSettingsTransactionIPC.Failure.unavailable {
          print("LinnetSettingsTransactionIPCTests: active endpoint owner preserved")
        }
      }

      if mode == "--serve-timeout-recovery" {
        for _ in 0..<2 {
          guard invoked.wait(timeout: .now() + 8) == .success else {
            throw TestFailure.handlerNotInvoked
          }
        }
        // The recovery terminal is serialized onto the Host queue after its
        // handler returns. Keep the server alive until the client receives it.
        usleep(300_000)
        let observations = recoveryObservations.snapshot()
        guard recoveryObservations.failure == nil,
          observations.count == 2,
          observations[0].transactionID != observations[1].transactionID,
          observations[0].primary == TimeoutRecoveryFixture.nextPrimary,
          observations[0].secondary == TimeoutRecoveryFixture.stableSecondary,
          !observations[0].canContinue,
          observations[1].primary == TimeoutRecoveryFixture.stablePrimary,
          observations[1].secondary == TimeoutRecoveryFixture.stableSecondary,
          observations[1].canContinue
        else { throw TestFailure.recoveryGeneration }
        print(
          "LinnetSettingsTransactionIPCTests: timeout/recovery generation PASS "
            + "(expired mixed read non-authoritative; stable recovery accepted)")
      } else if mode != "--serve-rejection" {
        guard invoked.wait(timeout: .now() + 5) == .success else {
          throw TestFailure.handlerNotInvoked
        }
        // Replies are serialized onto the Host queue after the handler returns.
        // Keep the signed server alive until the client has consumed both frames.
        usleep(300_000)
        guard invocation.value else { throw TestFailure.handlerNotInvoked }
      } else {
        guard invoked.wait(timeout: .now() + 1.5) == .timedOut,
          !invocation.value
        else { throw TestFailure.untrustedPeerAccepted }
      }
    }
  #endif

  #if LINNET_IPC_SETTINGS_HELPER
    private static func runSettings() async throws {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard let mode = arguments.first,
        [
          "--request-success", "--request-reload", "--expect-rejection",
          "--request-core-activation",
          "--request-timeout-recovery",
        ].contains(mode),
        (mode == "--request-timeout-recovery"
          ? arguments.count == 4 : arguments.count == 2 || arguments.count == 3)
      else { throw TestFailure.invalidInvocation }
      if mode == "--request-timeout-recovery" {
        try await runTimeoutRecovery(
          liveDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true),
          firstReadMarker: URL(fileURLWithPath: arguments[3]))
        return
      }
      let forgedRequesterPID = arguments.count == 3 && arguments[2] == "--forged-requester-pid"
      let reload = mode == "--request-reload"
      let coreActivation = mode == "--request-core-activation"
      let request = LinnetSettingsContract.DataRequest(
        transactionID: UUID(),
        command: coreActivation ? .activateCore : (reload ? .reloadConfiguration : .activate),
        candidate:
          coreActivation ? nil : (reload
          ? URL(fileURLWithPath: "/tmp/linnet-ipc-configuration-candidate", isDirectory: true)
          : URL(fileURLWithPath: "/tmp/linnet-ipc-candidate", isDirectory: true)),
        requesterPID: forgedRequesterPID ? getpid() + 1 : getpid(),
        deadline: Date().addingTimeInterval(10),
        expectedSettingsRevision: reload ? ConfigurationFixture.baseRevision : nil)

      do {
        let client = LinnetSettingsTransactionIPC.Client(startingAt: .main)
        let progress = LockedReplies()
        let terminal = try await client.request(request, timeout: 2) {
          progress.append($0)
        }
        guard mode != "--expect-rejection" else {
          throw TestFailure.untrustedPeerAccepted
        }
        if coreActivation {
          guard terminal.transactionID == request.transactionID,
            terminal.status == .terminating,
            terminal.code == .coreActivationAccepted,
            progress.snapshot().isEmpty
          else { throw TestFailure.legitimateFlow }
          return
        }
        guard terminal.transactionID == request.transactionID,
          terminal.status == .activated,
          terminal.code == (reload ? .configurationApplied : .activationVerified),
          progress.snapshot().map(\.status) == (reload ? [] : [.verifying])
        else { throw TestFailure.legitimateFlow }
      } catch is LinnetSettingsTransactionIPC.Failure {
        guard mode == "--expect-rejection" else { throw TestFailure.legitimateFlow }
      }
    }

    private static func runTimeoutRecovery(
      liveDirectory: URL,
      firstReadMarker: URL
    ) async throws {
      try FileManager.default.createDirectory(
        at: liveDirectory, withIntermediateDirectories: true)
      try TimeoutRecoveryFixture.nextPrimary.write(
        to: TimeoutRecoveryFixture.primary(in: liveDirectory), options: .atomic)
      try TimeoutRecoveryFixture.nextSecondary.write(
        to: TimeoutRecoveryFixture.secondary(in: liveDirectory), options: .atomic)

      let client = LinnetSettingsTransactionIPC.Client(startingAt: .main)
      let firstTransactionID = UUID()
      let first = LinnetSettingsContract.DataRequest(
        transactionID: firstTransactionID,
        command: .reloadConfiguration,
        candidate: ConfigurationFixture.candidate(in: liveDirectory),
        requesterPID: getpid(),
        deadline: Date().addingTimeInterval(3),
        expectedSettingsRevision: ConfigurationFixture.baseRevision)
      let started = Date()
      do {
        _ = try await client.request(first, timeout: 3) { _ in }
        throw TestFailure.timeoutExpected
      } catch LinnetSettingsTransactionIPC.Failure.timedOut {
        guard Date().timeIntervalSince(started) >= 2.8,
          FileManager.default.fileExists(atPath: firstReadMarker.path)
        else { throw TestFailure.timeoutExpected }
      }

      // Mirror the configurationOnly recovery boundary: restore both
      // representative renderer-owned projections before sending a fresh
      // transaction identity over a new socket.
      try TimeoutRecoveryFixture.stablePrimary.write(
        to: TimeoutRecoveryFixture.primary(in: liveDirectory), options: .atomic)
      try TimeoutRecoveryFixture.stableSecondary.write(
        to: TimeoutRecoveryFixture.secondary(in: liveDirectory), options: .atomic)

      let recoveryTransactionID = UUID()
      let recovery = LinnetSettingsContract.DataRequest(
        transactionID: recoveryTransactionID,
        command: .reloadConfiguration,
        candidate: ConfigurationFixture.candidate(in: liveDirectory),
        requesterPID: getpid(),
        deadline: Date().addingTimeInterval(3),
        expectedSettingsRevision: ConfigurationFixture.baseRevision,
        alternateSettingsRevision: ConfigurationFixture.attemptedRevision)
      let terminal = try await client.request(recovery, timeout: 3) { _ in }
      guard recoveryTransactionID != firstTransactionID,
        terminal.transactionID == recoveryTransactionID,
        terminal.status == .activated,
        terminal.code == .configurationApplied,
        try Data(contentsOf: TimeoutRecoveryFixture.primary(in: liveDirectory))
          == TimeoutRecoveryFixture.stablePrimary,
        try Data(contentsOf: TimeoutRecoveryFixture.secondary(in: liveDirectory))
          == TimeoutRecoveryFixture.stableSecondary
      else { throw TestFailure.recoveryGeneration }
    }
  #endif

  private enum TestFailure: Error {
    case invalidInvocation
    case handlerNotInvoked
    case untrustedPeerAccepted
    case legitimateFlow
    case timeoutExpected
    case recoveryGeneration
    case duplicateOwnerAccepted
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
      Data("LinnetSettingsTransactionIPCTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}

private struct RecoveryObservation: Equatable {
  let transactionID: UUID
  let primary: Data
  let secondary: Data
  let canContinue: Bool
}

private final class LockedRecoveryObservations: @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [RecoveryObservation] = []
  private var errorDetail: String?

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return observations.count
  }

  var failure: String? {
    lock.lock()
    defer { lock.unlock() }
    return errorDetail
  }

  func append(_ observation: RecoveryObservation) {
    lock.lock()
    observations.append(observation)
    lock.unlock()
  }

  func recordFailure(_ detail: String) {
    lock.lock()
    if errorDetail == nil { errorDetail = detail }
    lock.unlock()
  }

  func snapshot() -> [RecoveryObservation] {
    lock.lock()
    defer { lock.unlock() }
    return observations
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var state = false
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state
  }
  func set() {
    lock.lock()
    state = true
    lock.unlock()
  }
}

private final class LockedReplies: @unchecked Sendable {
  private let lock = NSLock()
  private var replies: [LinnetSettingsContract.RuntimeReply] = []
  func append(_ reply: LinnetSettingsContract.RuntimeReply) {
    lock.lock()
    replies.append(reply)
    lock.unlock()
  }
  func snapshot() -> [LinnetSettingsContract.RuntimeReply] {
    lock.lock()
    defer { lock.unlock() }
    return replies
  }
}
