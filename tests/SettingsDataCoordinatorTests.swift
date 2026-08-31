import CryptoKit
import Darwin
import Foundation

private let fixtureRuntimeIdentity = LinnetSettingsContract.ProductIdentity(
  version: "0.1.0",
  build: 1,
  revision: String(repeating: "a", count: 40)
)
import SQLite3

private struct SettingsOwnedFileSnapshot: Equatable {
  let contents: [String: Data]
  let missing: Set<String>
}

private struct SettingsPublicationObservation: Equatable {
  let command: LinnetSettingsContract.DataCommand
  let transactionID: UUID
  let expectedRevision: String
  let alternateRevision: String?
  let liveRevisionBeforePublication: String
  let candidateRevision: String
  let liveFilesBeforePublication: SettingsOwnedFileSnapshot
}

private struct RequestTimeoutObservation: Sendable {
  let command: LinnetSettingsContract.DataCommand
  let timeout: TimeInterval
  let deadline: Date
  let observedAt: Date
}

private enum DiagnoseHealthFixture: Sendable {
  case status(LinnetSettingsContract.RuntimeStatus)
  case unavailable
}

private struct PersonalFileIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
}

private enum PersonalFileIdentityFailure: Error {
  case invalid
}

private func personalFileIdentity(_ url: URL) throws -> PersonalFileIdentity {
  var info = stat()
  guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
    throw PersonalFileIdentityFailure.invalid
  }
  return .init(
    device: UInt64(info.st_dev),
    inode: UInt64(info.st_ino),
    modifiedSeconds: info.st_mtimespec.tv_sec,
    modifiedNanoseconds: info.st_mtimespec.tv_nsec
  )
}

private func personalTableIdentities(at directory: URL) throws -> [String: PersonalFileIdentity] {
  try Dictionary(uniqueKeysWithValues: [
    LinnetPersonalDataStore.customWordsFile,
    LinnetPersonalDataStore.expansionsFile,
  ].map { name in
    (name, try personalFileIdentity(directory.appending(path: name)))
  })
}

private func settingsOwnedFileSnapshot(at directory: URL) throws
  -> SettingsOwnedFileSnapshot
{
  let names = LinnetSettingsProjectionRenderer.ownedFiles.union([
    LinnetSettingsDocumentStore.fileName,
    LinnetPersonalDataStore.userSettingsFile,
    LinnetPersonalDataStore.legacyUserSettingsFile,
  ])
  var contents: [String: Data] = [:]
  var missing: Set<String> = []
  for name in names.sorted() {
    let url = directory.appending(path: name)
    if FileManager.default.fileExists(atPath: url.path) {
      contents[name] = try Data(contentsOf: url)
    } else {
      missing.insert(name)
    }
  }
  return SettingsOwnedFileSnapshot(contents: contents, missing: missing)
}

private final class RequestOrderHarness: @unchecked Sendable {
  private let lock = NSLock()
  private var recording = false
  private var delayNextPause = false
  private var delayNextReload = false
  private var failNextCancel = false
  private var nextPauseStatus: LinnetSettingsContract.RuntimeStatus?
  private var nextLanguageStatus: LinnetSettingsContract.RuntimeStatus?
  private var nextRefreshStatus: LinnetSettingsContract.RuntimeStatus?
  private var nextRefreshFailure: LinnetSettingsTransactionIPC.Failure?
  private var nextReloadStatus: LinnetSettingsContract.RuntimeStatus?
  private var nextReloadFailure: LinnetSettingsTransactionIPC.Failure?
  private var refreshCount = 0
  private var refreshTransactionIDs: [UUID] = []
  private var refreshSnapshots: [SettingsOwnedFileSnapshot] = []
  private var reloadCount = 0
  private var reloadTransactionIDs: [UUID] = []
  private var reloadSnapshots: [SettingsOwnedFileSnapshot] = []
  private var settingsPublications: [SettingsPublicationObservation] = []
  private var requestCount = 0
  private var requestTimeouts: [RequestTimeoutObservation] = []
  private var timeoutNextCommand: LinnetSettingsContract.DataCommand?
  private var nextDiagnoseHealth: DiagnoseHealthFixture?
  private var events: [String] = []
  private var pauseTerminalContinuation: CheckedContinuation<Void, Never>?
  private var pauseTerminalReleased = false
  private var reloadTerminalContinuation: CheckedContinuation<Void, Never>?
  private var reloadTerminalReleased = false

  func armDelayedPause(failCancel: Bool = false) {
    lock.lock()
    recording = true
    delayNextPause = true
    failNextCancel = failCancel
    events = []
    pauseTerminalContinuation = nil
    pauseTerminalReleased = false
    lock.unlock()
  }

  func armDelayedReload() {
    lock.lock()
    recording = true
    delayNextReload = true
    events = []
    reloadTerminalContinuation = nil
    reloadTerminalReleased = false
    lock.unlock()
  }

  func armPauseStatus(_ status: LinnetSettingsContract.RuntimeStatus) {
    lock.lock()
    nextPauseStatus = status
    lock.unlock()
  }

  func takePauseStatus() -> LinnetSettingsContract.RuntimeStatus? {
    lock.lock()
    defer { lock.unlock() }
    defer { nextPauseStatus = nil }
    return nextPauseStatus
  }

  func armLanguageStatus(_ status: LinnetSettingsContract.RuntimeStatus) {
    lock.lock()
    nextLanguageStatus = status
    lock.unlock()
  }

  func takeLanguageStatus() -> LinnetSettingsContract.RuntimeStatus? {
    lock.lock()
    defer { lock.unlock() }
    defer { nextLanguageStatus = nil }
    return nextLanguageStatus
  }

  func armRefreshStatus(_ status: LinnetSettingsContract.RuntimeStatus) {
    lock.lock()
    nextRefreshStatus = status
    lock.unlock()
  }

  func takeRefreshStatus() -> LinnetSettingsContract.RuntimeStatus? {
    lock.lock()
    defer { lock.unlock() }
    defer { nextRefreshStatus = nil }
    return nextRefreshStatus
  }

  func armRefreshFailure(_ failure: LinnetSettingsTransactionIPC.Failure) {
    lock.lock()
    nextRefreshFailure = failure
    lock.unlock()
  }

  func takeRefreshFailure() -> LinnetSettingsTransactionIPC.Failure? {
    lock.lock()
    defer { lock.unlock() }
    defer { nextRefreshFailure = nil }
    return nextRefreshFailure
  }

  func armReloadStatus(_ status: LinnetSettingsContract.RuntimeStatus) {
    lock.lock()
    nextReloadStatus = status
    lock.unlock()
  }

  func takeReloadStatus() -> LinnetSettingsContract.RuntimeStatus? {
    lock.lock()
    defer { lock.unlock() }
    defer { nextReloadStatus = nil }
    return nextReloadStatus
  }

  func armReloadFailure(_ failure: LinnetSettingsTransactionIPC.Failure) {
    lock.lock()
    nextReloadFailure = failure
    lock.unlock()
  }

  func takeReloadFailure() -> LinnetSettingsTransactionIPC.Failure? {
    lock.lock()
    defer { lock.unlock() }
    defer { nextReloadFailure = nil }
    return nextReloadFailure
  }

  func armDiagnoseHealth(_ fixture: DiagnoseHealthFixture) {
    lock.lock()
    nextDiagnoseHealth = fixture
    lock.unlock()
  }

  func takeDiagnoseHealth() -> DiagnoseHealthFixture? {
    lock.lock()
    defer { lock.unlock() }
    defer { nextDiagnoseHealth = nil }
    return nextDiagnoseHealth
  }

  func takeDelayedPause() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard recording else { return false }
    events.append("pause")
    guard delayNextPause else { return false }
    delayNextPause = false
    return true
  }

  func waitForDelayedPauseTerminal() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if pauseTerminalReleased {
        pauseTerminalReleased = false
        lock.unlock()
        continuation.resume()
      } else {
        pauseTerminalContinuation = continuation
        lock.unlock()
      }
    }
  }

  func releaseDelayedPauseTerminal() {
    lock.lock()
    let continuation = pauseTerminalContinuation
    pauseTerminalContinuation = nil
    if continuation == nil { pauseTerminalReleased = true }
    lock.unlock()
    continuation?.resume()
  }

  func takeDelayedReload() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard recording else { return false }
    events.append("reload")
    guard delayNextReload else { return false }
    delayNextReload = false
    return true
  }

  func waitForDelayedReloadTerminal() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if reloadTerminalReleased {
        reloadTerminalReleased = false
        lock.unlock()
        continuation.resume()
      } else {
        reloadTerminalContinuation = continuation
        lock.unlock()
      }
    }
  }

  func releaseDelayedReloadTerminal() {
    lock.lock()
    let continuation = reloadTerminalContinuation
    reloadTerminalContinuation = nil
    if continuation == nil { reloadTerminalReleased = true }
    lock.unlock()
    continuation?.resume()
  }

  func record(_ event: String) {
    lock.lock()
    if recording { events.append(event) }
    lock.unlock()
  }

  func recordRefresh(
    transactionID: UUID,
    snapshot: SettingsOwnedFileSnapshot
  ) {
    lock.lock()
    refreshCount += 1
    refreshTransactionIDs.append(transactionID)
    refreshSnapshots.append(snapshot)
    lock.unlock()
  }

  func recordReload(
    transactionID: UUID,
    snapshot: SettingsOwnedFileSnapshot
  ) {
    lock.lock()
    reloadCount += 1
    reloadTransactionIDs.append(transactionID)
    reloadSnapshots.append(snapshot)
    lock.unlock()
  }

  func recordSettingsPublication(_ observation: SettingsPublicationObservation) {
    lock.lock()
    settingsPublications.append(observation)
    lock.unlock()
  }

  func recordRequest(
    _ request: LinnetSettingsContract.DataRequest,
    timeout: TimeInterval
  ) {
    lock.lock()
    requestCount += 1
    requestTimeouts.append(
      .init(
        command: request.command,
        timeout: timeout,
        deadline: request.deadline,
        observedAt: Date()
      ))
    lock.unlock()
  }

  func currentRequestTimeouts() -> [RequestTimeoutObservation] {
    lock.lock()
    defer { lock.unlock() }
    return requestTimeouts
  }

  func armTransportTimeout(_ command: LinnetSettingsContract.DataCommand) {
    lock.lock()
    timeoutNextCommand = command
    lock.unlock()
  }

  func takeTransportTimeout(_ command: LinnetSettingsContract.DataCommand) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard timeoutNextCommand == command else { return false }
    timeoutNextCommand = nil
    return true
  }

  func currentRequestCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requestCount
  }

  func currentRefreshCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return refreshCount
  }

  func currentRefreshTransactionIDs() -> [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return refreshTransactionIDs
  }

  func currentRefreshSnapshots() -> [SettingsOwnedFileSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return refreshSnapshots
  }

  func currentReloadCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return reloadCount
  }

  func currentReloadTransactionIDs() -> [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return reloadTransactionIDs
  }

  func currentReloadSnapshots() -> [SettingsOwnedFileSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return reloadSnapshots
  }

  func currentSettingsPublications() -> [SettingsPublicationObservation] {
    lock.lock()
    defer { lock.unlock() }
    return settingsPublications
  }

  func takeCancelFailure() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard recording else { return false }
    events.append("cancel")
    let result = failNextCancel
    failNextCancel = false
    return result
  }

  func contains(_ event: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return events.contains(event)
  }

  func finish() -> [String] {
    lock.lock()
    recording = false
    let result = events
    lock.unlock()
    return result
  }
}

private final class PhaseHarness: @unchecked Sendable {
  private let lock = NSLock()
  private var phases: [SettingsDataCoordinator.Phase] = []

  func record(_ phase: SettingsDataCoordinator.Phase) {
    lock.lock()
    phases.append(phase)
    lock.unlock()
  }

  func snapshot() -> [SettingsDataCoordinator.Phase] {
    lock.lock()
    defer { lock.unlock() }
    return phases
  }
}

private final class FixtureTransactionRequester: LinnetSettingsTransactionRequesting,
  @unchecked Sendable
{
  typealias Handler = (
    LinnetSettingsContract.DataRequest,
    TimeInterval,
    @escaping (LinnetSettingsContract.RuntimeReply) -> Void
  ) async throws -> LinnetSettingsContract.RuntimeReply

  private let handler: Handler

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func request(
    _ request: LinnetSettingsContract.DataRequest,
    timeout: TimeInterval,
    onProgress: @escaping @Sendable (LinnetSettingsContract.RuntimeReply) -> Void
  ) async throws -> LinnetSettingsContract.RuntimeReply {
    return try await handler(request, timeout, onProgress)
  }
}

@main
struct SettingsDataCoordinatorTests {
  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static func main() async {
    let fileManager = FileManager.default
    let fixtureRoot = LinnetTestScratch.directory.appending(
      path: "LinnetDataCoordinatorTests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    let productName = "Linnet Data Test \(UUID().uuidString)"
    let registry: LinnetDataRegistry
    do {
      registry = try LinnetDataRegistry(
        productName: productName,
        coreVersion: "1.0.0",
        applicationSupportDirectory: fixtureRoot.appending(
          path: "Application Support", directoryHint: .isDirectory)
      )
    } catch {
      fail("data registry fixture is unavailable: \(error)")
    }
    let live = registry.userDataDirectory
    defer {
      try? fileManager.removeItem(at: fixtureRoot)
    }

    do {
      let settings = try makeBundleFixture(at: fixtureRoot, productName: productName)
      try makeDirectory(fixtureRoot)
      try verifyCoreThemeDeployment(in: fixtureRoot)
      try makeRegistryFixture(registry)
      do {
        _ = try registry.runtimeSnapshot()
      } catch {
        fail("data registry runtime fixture is invalid: \(error)")
      }
      try makeDirectory(live)
      try "# fixture\n".write(
        to: live.appending(path: "user.yaml"),
        atomically: true,
        encoding: .utf8
      )
      try seedDictionary(
        "linnet_custom_words",
        row: "Resurrected\tresurrected\t9",
        directory: live,
        fixtureRoot: fixtureRoot
      )

      let database = fixtureRoot.appending(path: "substitutions.sqlite3")
      try makeSubstitutionDatabase(at: database)
      let legacy = fixtureRoot.appending(path: "legacy-rime", directoryHint: .isDirectory)
      try makeDirectory(legacy)
      try seedDictionary(
        "rime_ice",
        row: "你好\tni hao\t7",
        directory: legacy,
        fixtureRoot: fixtureRoot
      )
      try seedDictionary(
        "melt_eng",
        row: "hello\thello\t6",
        directory: legacy,
        fixtureRoot: fixtureRoot
      )
      let sourceHash = try sha256(database)

      let requestOrder = RequestOrderHarness()
      let transactionRequester = FixtureTransactionRequester { request, timeout, _ in
        requestOrder.recordRequest(request, timeout: timeout)
        let isTransactionTerminal =
          [.pause, .activate, .activateLanguage, .cancel].contains(request.command)
        let remainingAtDispatch = request.deadline.timeIntervalSinceNow
        let admitsVirtualTerminal = !isTransactionTerminal
          || (timeout > 31 && timeout <= remainingAtDispatch + 0.25)
        let delayedPause = request.command == .pause && requestOrder.takeDelayedPause()
        if delayedPause {
          await requestOrder.waitForDelayedPauseTerminal()
          requestOrder.record("pauseReply")
        }
        if requestOrder.takeTransportTimeout(request.command) {
          throw LinnetSettingsTransactionIPC.Failure.timedOut
        }
        // Model a healthy transaction terminal arriving after 31 seconds
        // without making the owner test sleep in wall-clock time.
        guard admitsVirtualTerminal else {
          throw LinnetSettingsTransactionIPC.Failure.timedOut
        }
        switch request.command {
        case .activateCore:
          fail("the data coordinator unexpectedly requested Core activation")
        case .pause:
          if let status = requestOrder.takePauseStatus() {
            return reply(status, "fixture forced pause terminal", request: request)
          }
          return reply(.paused, "fixture paused", request: request)
        case .activate:
          guard let candidate = request.candidate, swap(live, candidate) else {
            return reply(.failed, "fixture swap failed", request: request)
          }
          return reply(.activated, "fixture activated", request: request)
        case .activateLanguage:
          guard let expectedGeneration = request.expectedActiveGeneration,
            let expectedDigest = request.expectedActiveStateSHA256,
            let revision = try? registry.activeRevision(),
            revision.generation == expectedGeneration,
            revision.stateSHA256 == expectedDigest
          else {
            return reply(.rejected, "fixture stale activation", request: request)
          }
          if let status = requestOrder.takeLanguageStatus() {
            return reply(status, "fixture forced language terminal", request: request)
          }
          guard let candidate = request.candidate,
            swap(registry.activeSharedDataDirectory, candidate)
          else {
            return reply(.failed, "fixture language swap failed", request: request)
          }
          guard (try? registry.commitDataChannelUpdate(
            transactionID: request.transactionID)) != nil
          else {
            _ = swap(registry.activeSharedDataDirectory, candidate)
            return reply(.failed, "fixture language commit failed", request: request)
          }
          return reply(.activated, "fixture language activated", request: request)
        case .cancel:
          let failed = requestOrder.takeCancelFailure()
          return reply(
            failed ? .failed : .cancelled,
            failed ? "fixture resume failed" : "fixture cancelled",
            request: request)
        case .refresh:
          let observation = try settingsPublicationObservation(request: request, live: live)
          requestOrder.recordRefresh(
            transactionID: request.transactionID,
            snapshot: observation.liveFilesBeforePublication
          )
          requestOrder.recordSettingsPublication(observation)
          var activeRevision = try publishSettingsCandidate(request: request, live: live)
          if let failure = requestOrder.takeRefreshFailure() {
            throw failure
          }
          let status = requestOrder.takeRefreshStatus() ?? .activated
          if status != .activated {
            activeRevision = try rollbackSettingsCandidate(request: request, live: live)
          }
          return reply(
            status,
            "fixture refresh result",
            request: request,
            health: settingsHealth(activeRevision: activeRevision)
          )
        case .reloadConfiguration:
          let observation = try settingsPublicationObservation(request: request, live: live)
          requestOrder.recordReload(
            transactionID: request.transactionID,
            snapshot: observation.liveFilesBeforePublication
          )
          requestOrder.recordSettingsPublication(observation)
          if requestOrder.takeDelayedReload() {
            await requestOrder.waitForDelayedReloadTerminal()
          }
          var activeRevision = try publishSettingsCandidate(request: request, live: live)
          if let failure = requestOrder.takeReloadFailure() {
            throw failure
          }
          let status = requestOrder.takeReloadStatus() ?? .activated
          if status != .activated {
            activeRevision = try rollbackSettingsCandidate(request: request, live: live)
          }
          return reply(
            status,
            "fixture configuration reload result",
            request: request,
            health: settingsHealth(activeRevision: activeRevision)
          )
        case .diagnose:
          switch requestOrder.takeDiagnoseHealth() ?? .status(.running) {
          case .status(let status):
            return reply(
              status,
              "fixture runtime status",
              request: request,
              health: diagnosticHealth(
                status: status,
                activeRevision: try? LinnetSettingsDocumentStore.snapshot(from: live).revision
              )
            )
          case .unavailable:
            return reply(.failed, "fixture runtime unavailable", request: request)
          }
        }
      }

      let coordinator = SettingsDataCoordinator(
        bundle: settings,
        timeout: 10,
        dataRegistry: registry,
        transactionRequester: transactionRequester
      )
      let oversizedHallelujah = fixtureRoot.appending(path: "oversized-substitutions.sqlite3")
      try makeSubstitutionDatabase(at: oversizedHallelujah)
      let oversizedHallelujahHandle = try FileHandle(forWritingTo: oversizedHallelujah)
      try oversizedHallelujahHandle.truncate(
        atOffset: UInt64(HallelujahSubstitutionImporter.maximumSourceDatabaseBytes + 1)
      )
      try oversizedHallelujahHandle.close()
      let preflightLiveSentinel = try Data(contentsOf: live.appending(path: "user.yaml"))
      let requestsBeforeRejectedPreflight = requestOrder.currentRequestCount()
      do {
        _ = try await coordinator.inspectLegacy(
          hallelujahDatabase: oversizedHallelujah,
          legacyUserDirectory: nil
        )
        fail("an oversized Hallelujah database passed preflight")
      } catch SettingsDataCoordinator.Failure.invalidOperation(let detail) {
        guard detail.contains("Hallelujah") else {
          fail("oversized Hallelujah preflight produced the wrong failure: \(detail)")
        }
      }
      guard requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight else {
        fail("failed Hallelujah preflight paused the Host")
      }
      guard try Data(contentsOf: live.appending(path: "user.yaml")) == preflightLiveSentinel
      else { fail("failed Hallelujah preflight missed its typed terminal or changed live data") }

      let invalidSchema = fixtureRoot.appending(path: "invalid-substitutions.sqlite3")
      try makeInvalidSubstitutionDatabase(at: invalidSchema)
      do {
        _ = try await coordinator.inspectLegacy(
          hallelujahDatabase: invalidSchema, legacyUserDirectory: nil)
        fail("an invalid Hallelujah schema passed preflight")
      } catch SettingsDataCoordinator.Failure.invalidOperation(let detail) {
        guard detail.contains("Hallelujah") else {
          fail("invalid Hallelujah schema lost its typed source failure")
        }
      }
      guard requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight else {
        fail("invalid Hallelujah schema crossed the preflight boundary")
      }

      let missingSource = fixtureRoot.appending(path: "missing-substitutions.sqlite3")
      guard try await coordinator.inspectLegacy(
        hallelujahDatabase: missingSource, legacyUserDirectory: nil) == nil,
        requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight
      else { fail("an absent legacy source did not remain a non-mutating absence") }

      let crowdedLegacy = fixtureRoot.appending(
        path: "crowded-legacy", directoryHint: .isDirectory)
      try makeDirectory(crowdedLegacy)
      for index in 0...LinnetBackupStore.maximumLiveDirectoryEntries {
        FileManager.default.createFile(
          atPath: crowdedLegacy.appending(path: "entry-\(index)").path,
          contents: Data())
      }
      do {
        _ = try await coordinator.inspectLegacy(
          hallelujahDatabase: nil, legacyUserDirectory: crowdedLegacy)
        fail("an over-limit legacy directory passed preflight")
      } catch SettingsDataCoordinator.Failure.invalidOperation {
        // Expected at the bounded directory owner before Host pause.
      }
      guard requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight,
        try Data(contentsOf: live.appending(path: "user.yaml")) == preflightLiveSentinel
      else { fail("over-limit legacy data crossed the preflight boundary") }

      let replacedLegacy = fixtureRoot.appending(
        path: "replaced-legacy", directoryHint: .isDirectory)
      try makeDirectory(replacedLegacy)
      try seedDictionary(
        "rime_ice",
        row: "你好\tni hao\t7",
        directory: replacedLegacy,
        fixtureRoot: fixtureRoot
      )
      guard let replacedLegacyCandidate = try await coordinator.inspectLegacy(
        hallelujahDatabase: nil, legacyUserDirectory: replacedLegacy)
      else { fail("replaceable legacy fixture was not inspected") }
      try fileManager.removeItem(at: replacedLegacy)
      try makeDirectory(replacedLegacy)
      try seedDictionary(
        "rime_ice",
        row: "你好\tni hao\t7",
        directory: replacedLegacy,
        fixtureRoot: fixtureRoot
      )
      let replacedLegacyPhases = PhaseHarness()
      do {
        _ = try await coordinator.run(
          .importLegacy(replacedLegacyCandidate),
          progress: { update in replacedLegacyPhases.record(update.phase) })
        fail("a replaced legacy identity crossed preflight")
      } catch RimeUserDataBridge.Failure.unsafeDirectory {
        // The confirmed identity, not the path, remains authoritative.
      }
      guard requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight,
        replacedLegacyPhases.snapshot() == [.preflight, .failed]
      else { fail("replaced legacy identity paused the Host") }

      let preflightTimeoutCoordinator = SettingsDataCoordinator(
        bundle: settings, timeout: 0, dataRegistry: registry,
        transactionRequester: transactionRequester)
      do {
        _ = try await preflightTimeoutCoordinator.inspectLegacy(
          hallelujahDatabase: database, legacyUserDirectory: nil)
        fail("a timed-out Hallelujah preflight completed")
      } catch SettingsDataCoordinator.Failure.timedOut {
        // Expected typed deadline projection.
      }
      guard requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight else {
        fail("Hallelujah deadline crossed the preflight boundary")
      }

      let cancelledPreflight = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await coordinator.inspectLegacy(
          hallelujahDatabase: database, legacyUserDirectory: nil)
      }
      do {
        _ = try await cancelledPreflight.value
        fail("cancelled Hallelujah preflight completed")
      } catch SettingsDataCoordinator.Failure.cancelled {
        // Expected typed cancellation projection.
      }
      guard requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight else {
        fail("cancelled Hallelujah preflight crossed the pause boundary")
      }

      guard let hallelujahCandidate = try await coordinator.inspectLegacy(
        hallelujahDatabase: database, legacyUserDirectory: nil),
        hallelujahCandidate.sources == [.hallelujah],
        hallelujahCandidate.substitutionCount == 1,
        hallelujahCandidate.recognizedLearningDictionaryCount == 0
      else { fail("Hallelujah inspection summary is not source-owned") }

      let cancelledPreparedPhases = PhaseHarness()
      let cancelledPrepared = Task {
        try await coordinator.run(
          .importLegacy(hallelujahCandidate),
          progress: { update in
            cancelledPreparedPhases.record(update.phase)
            if update.phase == .pausing { withUnsafeCurrentTask { $0?.cancel() } }
          })
      }
      do {
        _ = try await cancelledPrepared.value
        fail("cancelled prepared Hallelujah import completed")
      } catch SettingsDataCoordinator.Failure.cancelled {
        // Expected: prepare succeeded, but no pause request was posted.
      }
      guard requestOrder.currentRequestCount() == requestsBeforeRejectedPreflight,
        cancelledPreparedPhases.snapshot() == [.preflight, .pausing, .cancelled],
        try Data(contentsOf: live.appending(path: "user.yaml")) == preflightLiveSentinel
      else { fail("prepared cancellation paused the Host or changed live data") }
      if ProcessInfo.processInfo.environment["LINNET_SETTINGS_PREFLIGHT_ONLY"] == "1" {
        print("SettingsDataCoordinatorPreflightTests: PASS")
        return
      }
      requestOrder.armDelayedPause()
      let cancelledExport = fixtureRoot.appending(path: "cancelled.linnet-data")
      let cancelledExportPhases = PhaseHarness()
      let cancelledTask = Task {
        do {
          return try await coordinator.run(
            .exportPortable(categories: [.customWords], destination: cancelledExport),
            progress: { update in cancelledExportPhases.record(update.phase) }
          )
        } catch {
          FileHandle.standardError.write(
            Data("cancelled export failed before pause: \(error)\n".utf8)
          )
          throw error
        }
      }
      try await waitForEvent("pause", in: requestOrder)
      cancelledTask.cancel()
      requestOrder.releaseDelayedPauseTerminal()
      do {
        _ = try await cancelledTask.value
        fail("cancelled export completed")
      } catch SettingsDataCoordinator.Failure.cancelled {
        // Cancellation is complete only after the runtime acknowledges resume.
      }
      let cancelledEvents = requestOrder.finish()
      let cancelledExportExists = fileManager.fileExists(atPath: cancelledExport.path)
      guard cancelledEvents == ["pause", "pauseReply", "cancel"],
        cancelledExportPhases.snapshot() == [.preflight, .pausing, .cancelling, .cancelled],
        !cancelledExportExists
      else {
        fail(
          "cancellation raced ahead of the pause terminal or wrote an export: "
            + "events=\(cancelledEvents), phases=\(cancelledExportPhases.snapshot()), "
            + "exportExists=\(cancelledExportExists)"
        )
      }

      requestOrder.armDelayedPause(failCancel: true)
      let failedResumePhases = PhaseHarness()
      let failedResumeTask = Task {
        try await coordinator.run(
          .exportPortable(categories: [.customWords], destination: cancelledExport),
          progress: { update in failedResumePhases.record(update.phase) }
        )
      }
      try await waitForEvent("pause", in: requestOrder)
      failedResumeTask.cancel()
      requestOrder.releaseDelayedPauseTerminal()
      do {
        _ = try await failedResumeTask.value
        fail("cancelled export completed after runtime resume failure")
      } catch SettingsDataCoordinator.Failure.requestFailed(let code) {
        guard code == .runtimeResumeFailed else {
          fail("runtime resume failure code was lost")
        }
      }
      guard requestOrder.finish() == ["pause", "pauseReply", "cancel"],
        failedResumePhases.snapshot() == [.preflight, .pausing, .cancelling, .failed]
      else {
        fail("runtime resume failure bypassed the ordered cancellation protocol")
      }

      let oversizedStable = live.appending(path: "oversized.custom.yaml")
      FileManager.default.createFile(atPath: oversizedStable.path, contents: nil)
      let oversizedHandle = try FileHandle(forWritingTo: oversizedStable)
      try oversizedHandle.truncate(
        atOffset: UInt64(LinnetBackupStore.maximumStableArtifactBytes + 1)
      )
      try oversizedHandle.close()
      let backupsBeforeRejectedSnapshot = Set(
        try fileManager.contentsOfDirectory(atPath: registry.backupsDirectory.path)
      )
      let beforeRejectedSnapshot = try LinnetPersonalDataStore.snapshot(from: live)
      let beforeRejectedDocumentSnapshot = try LinnetSettingsDocumentStore.snapshot(from: live)
      var beforeRejectedPersonal = beforeRejectedSnapshot.data
      beforeRejectedPersonal.disabledWords.append(.init(value: "force-full-backup"))
      var beforeRejectedDocument = beforeRejectedDocumentSnapshot.document
      beforeRejectedDocument.appearance.pageSize =
        beforeRejectedDocument.appearance.pageSize == 7 ? 5 : 7
      do {
        _ = try await coordinator.run(
          .applyConfiguration(
            personal: beforeRejectedPersonal,
            document: beforeRejectedDocument,
            basePersonalRevision: beforeRejectedSnapshot.revision,
            baseDocumentRevision: beforeRejectedDocumentSnapshot.revision
          )
        )
        fail("an oversized stable source was copied into an automatic backup")
      } catch let failure as LinnetBackupStore.Failure {
        guard case .artifactTooLarge = failure else {
          fail("the oversized stable source produced the wrong failure: \(failure)")
        }
      }
      try fileManager.removeItem(at: oversizedStable)
      guard
        Set(try fileManager.contentsOfDirectory(atPath: registry.backupsDirectory.path))
          == backupsBeforeRejectedSnapshot
      else {
        fail("a pre-manifest backup failure left its transaction behind")
      }

      let mergeFailureSentinel = Data(
        "# Rime table\n# coding: utf-8\none\tx;Key\ntwo\tx;key\n".utf8)
      let mergeFailureTable = live.appending(path: LinnetPersonalDataStore.expansionsFile)
      try mergeFailureSentinel.write(to: mergeFailureTable)
      let mergeFailureTransactions = Set(
        try fileManager.contentsOfDirectory(atPath: registry.transactionsDirectory.path))
      let mergeFailurePhases = PhaseHarness()
      requestOrder.armDelayedPause()
      let mergeFailureTask = Task {
        try await coordinator.run(
          .importLegacy(hallelujahCandidate),
          progress: { update in mergeFailurePhases.record(update.phase) })
      }
      try await waitForEvent("pause", in: requestOrder)
      requestOrder.releaseDelayedPauseTerminal()
      do {
        _ = try await mergeFailureTask.value
        fail("a duplicate normalized destination passed Hallelujah merge")
      } catch SettingsDataCoordinator.Failure.invalidOperation(let detail) {
        guard detail.contains("Hallelujah") else {
          fail("post-pause Hallelujah merge lost its typed failure")
        }
      }
      guard requestOrder.finish() == ["pause", "pauseReply", "cancel"],
        mergeFailurePhases.snapshot()
          == [.preflight, .pausing, .snapshotting, .staging, .cancelling, .failed],
        try Data(contentsOf: mergeFailureTable) == mergeFailureSentinel,
        Set(try fileManager.contentsOfDirectory(atPath: registry.transactionsDirectory.path))
          == mergeFailureTransactions
      else { fail("failed Hallelujah merge did not restore Host and preserve live bytes") }
      try fileManager.removeItem(at: mergeFailureTable)

      guard let legacyCandidate = try await coordinator.inspectLegacy(
        hallelujahDatabase: database, legacyUserDirectory: legacy),
        legacyCandidate.sources == [.hallelujah, .rime],
        legacyCandidate.substitutionCount == 1,
        legacyCandidate.recognizedLearningDictionaryCount == 2
      else { fail("combined legacy inspection summary is incomplete") }
      let legacyResult = try await coordinator.run(.importLegacy(legacyCandidate))
      try verifyLegacyResult(
        legacyResult,
        live: live,
        source: database,
        sourceHash: sourceHash,
        fixtureRoot: fixtureRoot
      )
      var originalLearning: [String: [String: String]] = [:]
      for schema in RimeUserDataBridge.learningSchemas.sorted() {
        try seedRawDictionary(schema, directory: live, fixtureRoot: fixtureRoot)
        let state = try rawDictionaryState(schema, directory: live)
        guard state["#@/tick"] == "1000",
          state.values.contains(where: { $0.hasPrefix("c=-3 ") }),
          state.values.contains(where: { $0.contains("d=4.25 ") })
        else { fail("ENVIRONMENT_INVALID: native dictionary fixture lost its raw learning state") }
        originalLearning[schema] = state
      }

      let replacementPersonal = LinnetPersonalData(
        customWords: [.init(value: "Cloud Team", code: "cloud team")],
        disabledWords: ["forbiddenword"],
        expansions: [.init(value: "be right back", trigger: "x;brb")]
      )
      var replacementDocument = try LinnetSettingsDocumentStore.load(from: live)
      let replacementDocumentRevision = try LinnetSettingsDocumentStore.snapshot(from: live).revision
      replacementDocument.input.chineseProfile = .jiajia
      replacementDocument.english.sentenceCapitalization = true
      replacementDocument.english.tabBehavior = .navigate
      do {
        _ = try await coordinator.run(
          .applyConfiguration(
            personal: replacementPersonal,
            document: replacementDocument,
            basePersonalRevision: "stale",
            baseDocumentRevision: replacementDocumentRevision
          )
        )
        fail("stale personal revision was accepted")
      } catch SettingsDataCoordinator.Failure.staleRevision {
        let unchanged = try LinnetPersonalDataStore.snapshot(from: live)
        guard unchanged.revision == legacyResult.personalSnapshot.revision else {
          fail("stale personal apply changed live data")
        }
      }

      let applyResult = try await coordinator.run(
        .applyConfiguration(
          personal: replacementPersonal,
          document: replacementDocument,
          basePersonalRevision: legacyResult.personalSnapshot.revision,
          baseDocumentRevision: replacementDocumentRevision
        )
      )
      for (schema, expected) in originalLearning {
        try verifyRawDictionary(schema, expected: expected, directory: live, operation: "personal apply")
      }
      guard case .submittedDraft(let appliedDocument) = applyResult.documentEffect,
        appliedDocument == (try LinnetSettingsDocumentStore.snapshot(from: live))
      else { fail("apply did not project its committed settings document") }
      let applied = try LinnetPersonalDataStore.load(from: live)
      let appliedRuntimeSettings = try String(
        contentsOf: live.appending(path: LinnetPersonalDataStore.userSettingsFile),
        encoding: .utf8
      )
      let appliedEnglishSchema = try String(
        contentsOf: live.appending(path: LinnetSettingsProjectionRenderer.englishCustomFile),
        encoding: .utf8
      )
      guard applied.customWords.map(\.value) == ["Cloud Team"],
        applied.disabledWords.map(\.value) == ["forbiddenword"],
        applied.expansions.map(\.trigger) == ["x;brb"],
        !appliedRuntimeSettings.contains("sentence_capitalization"),
        !appliedRuntimeSettings.contains("tab_behavior"),
        appliedEnglishSchema.contains(
          "\"linnet_english_interaction/sentence_capitalization\": true"),
        appliedEnglishSchema.contains(
          "\"linnet_english_interaction/tab_behavior\": \"navigate\""),
        requestOrder.currentReloadCount() == 0,
        try exportContains(
          "linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot
        ),
        try exportContains(
          "linnet_en", row: "hello\thello", directory: live, fixtureRoot: fixtureRoot
        )
      else {
        fail("personal apply did not preserve substitutions and zh/en learning")
      }
      let appliedRuntime = try registry.runtimeSnapshot()
      try verifySelectedChineseProfile(
        .jiajia,
        user: live,
        shared: appliedRuntime.sharedDataDirectory,
        product: productName
      )

      let backupsBeforeConfiguration = try LinnetBackupStore.listBackups(
        in: registry.backupsDirectory).count
      let requestsBeforeConfiguration = requestOrder.currentRequestCount()
      let reloadsBeforeConfiguration = requestOrder.currentReloadCount()
      let publicationsBeforeConfiguration = requestOrder.currentSettingsPublications().count
      let liveFilesBeforeConfiguration = try settingsOwnedFileSnapshot(at: live)
      let personalTablesBeforeConfiguration = try personalTableIdentities(at: live)
      var configurationDocument = try LinnetSettingsDocumentStore.load(from: live)
      configurationDocument.input.traditionalChinese = true
      configurationDocument.input.pinyinReverseTrigger = .verticalBar
      configurationDocument.english.sentenceCapitalization = false
      configurationDocument.english.tabBehavior = .pass
      let configurationResult = try await coordinator.run(
        .applyConfiguration(
          personal: applyResult.personalSnapshot.data,
          document: configurationDocument,
          basePersonalRevision: applyResult.personalSnapshot.revision,
          baseDocumentRevision: appliedDocument.revision
        )
      )
      let backupsAfterConfiguration = try LinnetBackupStore.listBackups(
        in: registry.backupsDirectory).count
      let requestsAfterConfiguration = requestOrder.currentRequestCount()
      let reloadsAfterConfiguration = requestOrder.currentReloadCount()
      let configurationPublications = Array(
        requestOrder.currentSettingsPublications().dropFirst(publicationsBeforeConfiguration))
      guard case .submittedDraft(let configuredDocument) = configurationResult.documentEffect,
        configurationResult.backupDirectory == nil,
        configurationResult.personalSnapshot.revision == applyResult.personalSnapshot.revision,
        requestsAfterConfiguration == requestsBeforeConfiguration + 1,
        reloadsAfterConfiguration == reloadsBeforeConfiguration + 1,
        configurationPublications.count == 1,
        configurationPublications[0].command == .reloadConfiguration,
        configurationPublications[0].expectedRevision == appliedDocument.revision,
        configurationPublications[0].alternateRevision == nil,
        configurationPublications[0].liveRevisionBeforePublication == appliedDocument.revision,
        configurationPublications[0].candidateRevision == configuredDocument.revision,
        configurationPublications[0].liveFilesBeforePublication == liveFilesBeforeConfiguration,
        backupsAfterConfiguration == backupsBeforeConfiguration,
        try personalTableIdentities(at: live) == personalTablesBeforeConfiguration
      else {
        fail(
          "document-only settings did not use one configuration reload: "
            + "backup=\(configurationResult.backupDirectory?.path ?? "nil"), "
            + "personal=\(configurationResult.personalSnapshot.revision == applyResult.personalSnapshot.revision), "
            + "requests=\(requestsBeforeConfiguration)->\(requestsAfterConfiguration), "
            + "reloads=\(reloadsBeforeConfiguration)->\(reloadsAfterConfiguration), "
            + "backups=\(backupsBeforeConfiguration)->\(backupsAfterConfiguration)"
        )
      }
      let configured = try LinnetSettingsDocumentStore.load(from: live)
      let configuredEnglish = try String(
        contentsOf: live.appending(path: LinnetPersonalDataStore.userSettingsFile),
        encoding: .utf8
      )
      let configuredChinese = try String(
        contentsOf: live.appending(path: "linnet_zh.custom.yaml"), encoding: .utf8)
      let configuredEnglishSchema = try String(
        contentsOf: live.appending(path: LinnetSettingsProjectionRenderer.englishCustomFile),
        encoding: .utf8
      )
      guard configured.input.traditionalChinese,
        configured.input.pinyinReverseTrigger == .verticalBar,
        !configuredEnglish.contains("sentence_capitalization"),
        !configuredEnglish.contains("tab_behavior"),
        configuredChinese.contains("\"switches/@2/reset\": 1"),
        configuredChinese.contains("\"linnet_english_interaction/sentence_capitalization\": false"),
        configuredChinese.contains("\"linnet_english_interaction/tab_behavior\": \"pass\""),
        !configuredChinese.contains("linnet_pinyin/prefix"),
        configuredEnglishSchema.contains(
          "\"linnet_english_interaction/sentence_capitalization\": false"),
        configuredEnglishSchema.contains(
          "\"linnet_english_interaction/tab_behavior\": \"pass\""),
        !configuredEnglishSchema.contains("linnet_pinyin/prefix"),
        !FileManager.default.fileExists(
          atPath: live.appending(path: LinnetPersonalDataStore.legacyUserSettingsFile).path)
      else {
        fail("document-only settings were not projected into canonical runtime files")
      }

      let configurationFiles = try settingsOwnedFileSnapshot(at: live)
      let reloadsBeforeRejectedConfiguration = requestOrder.currentReloadCount()
      let reloadIDsBeforeRejectedConfiguration =
        requestOrder.currentReloadTransactionIDs().count
      let reloadSnapshotsBeforeRejectedConfiguration =
        requestOrder.currentReloadSnapshots().count
      let publicationsBeforeRejectedConfiguration =
        requestOrder.currentSettingsPublications().count
      var rejectedConfiguration = configured
      rejectedConfiguration.input.traditionalChinese = false
      rejectedConfiguration.input.pinyinReverseTrigger = .semicolon
      requestOrder.armReloadStatus(.failed)
      do {
        _ = try await coordinator.run(
          .applyConfiguration(
            personal: configurationResult.personalSnapshot.data,
            document: rejectedConfiguration,
            basePersonalRevision: configurationResult.personalSnapshot.revision,
            baseDocumentRevision: configuredDocument.revision
          )
        )
        fail("a rejected configuration reload was reported as applied")
      } catch SettingsDataCoordinator.Failure.requestFailed {
        // The first reload rejected the new files; the second confirms rollback.
      }
      let rejectedReloadIDs = Array(
        requestOrder.currentReloadTransactionIDs().dropFirst(
          reloadIDsBeforeRejectedConfiguration))
      let rejectedReloadSnapshots = Array(
        requestOrder.currentReloadSnapshots().dropFirst(
          reloadSnapshotsBeforeRejectedConfiguration))
      let rejectedPublications = Array(
        requestOrder.currentSettingsPublications().dropFirst(
          publicationsBeforeRejectedConfiguration))
      guard requestOrder.currentReloadCount() == reloadsBeforeRejectedConfiguration + 2,
        rejectedReloadIDs.count == 2,
        rejectedReloadIDs[0] != rejectedReloadIDs[1],
        rejectedReloadSnapshots.count == 2,
        rejectedReloadSnapshots[0] == configurationFiles,
        rejectedReloadSnapshots[1] == configurationFiles,
        rejectedPublications.count == 2,
        rejectedPublications[0].transactionID == rejectedReloadIDs[0],
        rejectedPublications[0].expectedRevision == configuredDocument.revision,
        rejectedPublications[0].alternateRevision == nil,
        rejectedPublications[0].liveRevisionBeforePublication == configuredDocument.revision,
        rejectedPublications[0].candidateRevision != configuredDocument.revision,
        rejectedPublications[1].transactionID == rejectedReloadIDs[1],
        rejectedPublications[1].expectedRevision == configuredDocument.revision,
        rejectedPublications[1].alternateRevision
          == rejectedPublications[0].candidateRevision,
        rejectedPublications[1].liveRevisionBeforePublication == configuredDocument.revision,
        rejectedPublications[1].candidateRevision == configuredDocument.revision,
        try settingsOwnedFileSnapshot(at: live) == configurationFiles,
        try personalTableIdentities(at: live) == personalTablesBeforeConfiguration
      else {
        fail("a rejected configuration did not restore disk and Host")
      }

      let reloadsBeforeLostConfigurationReply = requestOrder.currentReloadCount()
      let reloadIDsBeforeLostConfigurationReply =
        requestOrder.currentReloadTransactionIDs().count
      let reloadSnapshotsBeforeLostConfigurationReply =
        requestOrder.currentReloadSnapshots().count
      let publicationsBeforeLostConfigurationReply =
        requestOrder.currentSettingsPublications().count
      requestOrder.armReloadFailure(.timedOut)
      do {
        _ = try await coordinator.run(
          .applyConfiguration(
            personal: configurationResult.personalSnapshot.data,
            document: rejectedConfiguration,
            basePersonalRevision: configurationResult.personalSnapshot.revision,
            baseDocumentRevision: configuredDocument.revision
          )
        )
        fail("a lost configuration reply was reported as applied")
      } catch SettingsDataCoordinator.Failure.timedOut {
        // The recovery reload confirms the restored bytes with a fresh ID.
      }
      let lostConfigurationIDs = Array(
        requestOrder.currentReloadTransactionIDs().dropFirst(
          reloadIDsBeforeLostConfigurationReply))
      let lostConfigurationSnapshots = Array(
        requestOrder.currentReloadSnapshots().dropFirst(
          reloadSnapshotsBeforeLostConfigurationReply))
      let lostConfigurationPublications = Array(
        requestOrder.currentSettingsPublications().dropFirst(
          publicationsBeforeLostConfigurationReply))
      guard requestOrder.currentReloadCount() == reloadsBeforeLostConfigurationReply + 2,
        lostConfigurationIDs.count == 2,
        lostConfigurationIDs[0] != lostConfigurationIDs[1],
        lostConfigurationSnapshots.count == 2,
        lostConfigurationSnapshots[0] == configurationFiles,
        lostConfigurationSnapshots[1] != configurationFiles,
        lostConfigurationPublications.count == 2,
        lostConfigurationPublications[0].transactionID == lostConfigurationIDs[0],
        lostConfigurationPublications[0].expectedRevision == configuredDocument.revision,
        lostConfigurationPublications[0].alternateRevision == nil,
        lostConfigurationPublications[0].liveRevisionBeforePublication
          == configuredDocument.revision,
        lostConfigurationPublications[0].candidateRevision != configuredDocument.revision,
        lostConfigurationPublications[1].transactionID == lostConfigurationIDs[1],
        lostConfigurationPublications[1].expectedRevision == configuredDocument.revision,
        lostConfigurationPublications[1].alternateRevision
          == lostConfigurationPublications[0].candidateRevision,
        lostConfigurationPublications[1].liveRevisionBeforePublication
          == lostConfigurationPublications[0].candidateRevision,
        lostConfigurationPublications[1].candidateRevision == configuredDocument.revision,
        try settingsOwnedFileSnapshot(at: live) == configurationFiles,
        try personalTableIdentities(at: live) == personalTablesBeforeConfiguration
      else {
        fail("a lost configuration reply did not restore disk and Host")
      }

      let liveDocumentBeforeAppearance = try LinnetSettingsDocumentStore.load(from: live)
      let backupsBeforeAppearance = try LinnetBackupStore.listBackups(
        in: registry.backupsDirectory).count
      let refreshesBeforeAppearance = requestOrder.currentRefreshCount()
      let publicationsBeforeAppearance = requestOrder.currentSettingsPublications().count
      let liveFilesBeforeAppearance = try settingsOwnedFileSnapshot(at: live)
      var previewAppearance = liveDocumentBeforeAppearance.appearance
      previewAppearance.fontPoint = 19
      previewAppearance.themeFamily = .sidecarSlate
      previewAppearance.chineseCandidateLayout = .vertical
      previewAppearance.englishCandidateLayout = .vertical
      previewAppearance.candidateBrowsingMode = .scrollingOnly
      let appearanceResult = try await coordinator.run(
        .publishAppearance(
          appearance: previewAppearance,
          basePersonalRevision: applyResult.personalSnapshot.revision,
          baseDocumentRevision: configuredDocument.revision
        )
      )
      let liveDocumentAfterAppearance = try LinnetSettingsDocumentStore.load(from: live)
      let appearancePublications = Array(
        requestOrder.currentSettingsPublications().dropFirst(publicationsBeforeAppearance))
      var expectedPreviewAppearance = previewAppearance
      expectedPreviewAppearance.pageSize = liveDocumentBeforeAppearance.appearance.pageSize
      expectedPreviewAppearance.chineseCandidateLayout =
        liveDocumentBeforeAppearance.appearance.chineseCandidateLayout
      expectedPreviewAppearance.englishCandidateLayout =
        liveDocumentBeforeAppearance.appearance.englishCandidateLayout
      expectedPreviewAppearance.candidateBrowsingMode =
        liveDocumentBeforeAppearance.appearance.candidateBrowsingMode
      let squirrelProjection = try String(
        contentsOf: live.appending(
          path: LinnetSettingsProjectionRenderer.squirrelCustomFile),
        encoding: .utf8
      )
      let chineseLayoutProjection = try? String(
        contentsOf: live.appending(path: "linnet_zh.custom.yaml"),
        encoding: .utf8
      )
      let englishLayoutProjection = try? String(
        contentsOf: live.appending(
          path: LinnetSettingsProjectionRenderer.englishCustomFile),
        encoding: .utf8
      )
      guard case .submittedAppearance(let publishedAppearance) = appearanceResult.documentEffect,
        appearanceResult.backupDirectory == nil
      else {
        fail("live appearance publishing created a backup")
      }
      guard appearanceResult.personalSnapshot.revision
        == applyResult.personalSnapshot.revision
      else { fail("live appearance publishing changed personal data") }
      guard liveDocumentAfterAppearance.appearance == expectedPreviewAppearance else {
        fail("live appearance publishing crossed a session-bound appearance field")
      }
      guard liveDocumentAfterAppearance.input == liveDocumentBeforeAppearance.input else {
        fail("live appearance publishing changed input options")
      }
      guard liveDocumentAfterAppearance.english == liveDocumentBeforeAppearance.english else {
        fail(
          "live appearance publishing changed English options: "
            + "\(liveDocumentBeforeAppearance.english) -> \(liveDocumentAfterAppearance.english)"
        )
      }
      guard try LinnetBackupStore.listBackups(in: registry.backupsDirectory).count
        == backupsBeforeAppearance
      else { fail("live appearance publishing changed backup retention") }
      guard requestOrder.currentRefreshCount() == refreshesBeforeAppearance + 1 else {
        fail("live appearance publishing skipped Host refresh")
      }
      guard appearancePublications.count == 1,
        appearancePublications[0].command == .refresh,
        appearancePublications[0].expectedRevision == configuredDocument.revision,
        appearancePublications[0].alternateRevision == nil,
        appearancePublications[0].liveRevisionBeforePublication == configuredDocument.revision,
        appearancePublications[0].candidateRevision == publishedAppearance.revision,
        appearancePublications[0].liveFilesBeforePublication == liveFilesBeforeAppearance
      else { fail("appearance publication bypassed the atomic candidate boundary") }
      guard squirrelProjection.contains("\"style/font_point\": 19"),
        squirrelProjection.contains("\"style/color_scheme\": \"linnet_sidecar_light\""),
        !squirrelProjection.contains("candidate_list_layout"),
        !squirrelProjection.contains("linnet_expand_candidate_rows"),
        !squirrelProjection.contains("linnet_candidate_expansion_allowed"),
        chineseLayoutProjection?.contains("candidate_list_layout") != true,
        englishLayoutProjection?.contains("candidate_list_layout") != true,
        chineseLayoutProjection?.contains("linnet_expand_candidate_rows") != true,
        englishLayoutProjection?.contains("linnet_expand_candidate_rows") != true
      else { fail("live appearance publishing emitted a session-bound layout projection") }

      let appearanceSnapshot = try LinnetSettingsDocumentStore.snapshot(from: live)
      let appearanceFiles = try settingsOwnedFileSnapshot(at: live)
      let refreshesBeforeStaleAppearance = requestOrder.currentRefreshCount()
      var staleAppearance = previewAppearance
      staleAppearance.fontPoint = 23
      staleAppearance.themeFamily = .clayTiles
      do {
        _ = try await coordinator.run(
          .publishAppearance(
            appearance: staleAppearance,
            basePersonalRevision: "stale-personal-revision",
            baseDocumentRevision: appearanceSnapshot.revision
          )
        )
        fail("a stale personal revision published a lightweight appearance")
      } catch SettingsDataCoordinator.Failure.staleRevision {
        // Both revisions are mandatory before the first file mutation.
      }
      guard try settingsOwnedFileSnapshot(at: live) == appearanceFiles,
        requestOrder.currentRefreshCount() == refreshesBeforeStaleAppearance
      else { fail("stale personal appearance changed files or refreshed Host") }

      do {
        _ = try await coordinator.run(
          .publishAppearance(
            appearance: staleAppearance,
            basePersonalRevision: appearanceResult.personalSnapshot.revision,
            baseDocumentRevision: appliedDocument.revision
          )
        )
        fail("a stale document revision published a lightweight appearance")
      } catch SettingsDataCoordinator.Failure.staleRevision {
        // The successful appearance above made appliedDocument.revision stale.
      }
      guard try settingsOwnedFileSnapshot(at: live) == appearanceFiles,
        requestOrder.currentRefreshCount() == refreshesBeforeStaleAppearance
      else { fail("stale document appearance changed files or refreshed Host") }

      let documentBeforeRejectedPreview = try Data(
        contentsOf: live.appending(path: LinnetSettingsDocumentStore.fileName))
      let projectionBeforeRejectedPreview = try Data(
        contentsOf: live.appending(path: LinnetSettingsProjectionRenderer.squirrelCustomFile))
      let chineseLayoutBeforeRejectedPreview = try? Data(
        contentsOf: live.appending(path: "linnet_zh.custom.yaml"))
      let englishLayoutBeforeRejectedPreview = try? Data(
        contentsOf: live.appending(path: LinnetSettingsProjectionRenderer.englishCustomFile))
      var rejectedAppearance = previewAppearance
      rejectedAppearance.fontPoint = 27
      rejectedAppearance.themeFamily = .clayTiles
      requestOrder.armRefreshStatus(.failed)
      do {
        _ = try await coordinator.run(
          .publishAppearance(
            appearance: rejectedAppearance,
            basePersonalRevision: appearanceResult.personalSnapshot.revision,
            baseDocumentRevision: try LinnetSettingsDocumentStore.snapshot(from: live).revision
          )
        )
        fail("a rejected Host refresh was reported as a published appearance")
      } catch SettingsDataCoordinator.Failure.requestFailed {
        // Expected: the persistent document and projection must be restored.
      }
      guard try Data(contentsOf: live.appending(path: LinnetSettingsDocumentStore.fileName))
        == documentBeforeRejectedPreview,
        try Data(
          contentsOf: live.appending(path: LinnetSettingsProjectionRenderer.squirrelCustomFile))
          == projectionBeforeRejectedPreview,
        (try? Data(contentsOf: live.appending(path: "linnet_zh.custom.yaml")))
          == chineseLayoutBeforeRejectedPreview,
        (try? Data(
          contentsOf: live.appending(path: LinnetSettingsProjectionRenderer.englishCustomFile)))
          == englishLayoutBeforeRejectedPreview
      else { fail("a rejected appearance preview was not rolled back") }

      let refreshesBeforeLostAppearanceReply = requestOrder.currentRefreshCount()
      let refreshIDsBeforeLostAppearanceReply = requestOrder.currentRefreshTransactionIDs().count
      let refreshSnapshotsBeforeLostAppearanceReply = requestOrder.currentRefreshSnapshots().count
      let reloadsBeforeLostAppearanceReply = requestOrder.currentReloadCount()
      let reloadIDsBeforeLostAppearanceReply = requestOrder.currentReloadTransactionIDs().count
      let reloadSnapshotsBeforeLostAppearanceReply = requestOrder.currentReloadSnapshots().count
      let publicationsBeforeLostAppearanceReply =
        requestOrder.currentSettingsPublications().count
      var lostReplyAppearance = previewAppearance
      lostReplyAppearance.fontPoint = 29
      lostReplyAppearance.themeFamily = .mistJade
      requestOrder.armRefreshFailure(.timedOut)
      do {
        _ = try await coordinator.run(
          .publishAppearance(
            appearance: lostReplyAppearance,
            basePersonalRevision: appearanceResult.personalSnapshot.revision,
            baseDocumentRevision: try LinnetSettingsDocumentStore.snapshot(from: live).revision
          )
        )
        fail("a lost appearance reply was reported as a published appearance")
      } catch SettingsDataCoordinator.Failure.timedOut {
        // The first refresh may already have committed. A fresh configuration
        // candidate must restore the old document before surfacing timeout.
      }
      let lostReplyRefreshIDs = Array(
        requestOrder.currentRefreshTransactionIDs().dropFirst(
          refreshIDsBeforeLostAppearanceReply))
      let lostReplyRefreshSnapshots = Array(
        requestOrder.currentRefreshSnapshots().dropFirst(
          refreshSnapshotsBeforeLostAppearanceReply))
      let lostReplyReloadIDs = Array(
        requestOrder.currentReloadTransactionIDs().dropFirst(
          reloadIDsBeforeLostAppearanceReply))
      let lostReplyReloadSnapshots = Array(
        requestOrder.currentReloadSnapshots().dropFirst(
          reloadSnapshotsBeforeLostAppearanceReply))
      let lostAppearancePublications = Array(
        requestOrder.currentSettingsPublications().dropFirst(
          publicationsBeforeLostAppearanceReply))
      guard requestOrder.currentRefreshCount() == refreshesBeforeLostAppearanceReply + 1,
        requestOrder.currentReloadCount() == reloadsBeforeLostAppearanceReply + 1,
        lostReplyRefreshIDs.count == 1,
        lostReplyReloadIDs.count == 1,
        lostReplyRefreshIDs[0] != lostReplyReloadIDs[0],
        lostReplyRefreshSnapshots == [appearanceFiles],
        lostReplyReloadSnapshots.count == 1,
        lostReplyReloadSnapshots[0] != appearanceFiles,
        lostAppearancePublications.count == 2,
        lostAppearancePublications[0].command == .refresh,
        lostAppearancePublications[0].transactionID == lostReplyRefreshIDs[0],
        lostAppearancePublications[0].expectedRevision == appearanceSnapshot.revision,
        lostAppearancePublications[0].alternateRevision == nil,
        lostAppearancePublications[0].liveRevisionBeforePublication
          == appearanceSnapshot.revision,
        lostAppearancePublications[1].command == .reloadConfiguration,
        lostAppearancePublications[1].transactionID == lostReplyReloadIDs[0],
        lostAppearancePublications[1].expectedRevision == appearanceSnapshot.revision,
        lostAppearancePublications[1].alternateRevision
          == lostAppearancePublications[0].candidateRevision,
        lostAppearancePublications[1].liveRevisionBeforePublication
          == lostAppearancePublications[0].candidateRevision,
        lostAppearancePublications[1].candidateRevision == appearanceSnapshot.revision,
        try settingsOwnedFileSnapshot(at: live) == appearanceFiles
      else {
        fail("a lost appearance reply did not restore Host and disk to one terminal state")
      }

      let refreshesBeforeFailedAppearanceRecovery = requestOrder.currentRefreshCount()
      let reloadsBeforeFailedAppearanceRecovery = requestOrder.currentReloadCount()
      requestOrder.armRefreshFailure(.timedOut)
      requestOrder.armReloadFailure(.timedOut)
      do {
        _ = try await coordinator.run(
          .publishAppearance(
            appearance: lostReplyAppearance,
            basePersonalRevision: appearanceResult.personalSnapshot.revision,
            baseDocumentRevision: try LinnetSettingsDocumentStore.snapshot(from: live).revision
          )
        )
        fail("a failed appearance recovery was reported as a published appearance")
      } catch SettingsDataCoordinator.Failure.appearanceRestoreFailed {
        // Disk is restored, but Host did not confirm reloading those bytes.
      }
      guard requestOrder.currentRefreshCount() == refreshesBeforeFailedAppearanceRecovery + 1,
        requestOrder.currentReloadCount() == reloadsBeforeFailedAppearanceRecovery + 1,
        try settingsOwnedFileSnapshot(at: live) == appearanceFiles
      else {
        fail("a failed appearance recovery did not preserve the restored disk state")
      }

      var pageSizeDraft = previewAppearance
      pageSizeDraft.pageSize = 7
      _ = try await coordinator.run(
        .publishAppearance(
          appearance: pageSizeDraft,
          basePersonalRevision: appearanceResult.personalSnapshot.revision,
          baseDocumentRevision: try LinnetSettingsDocumentStore.snapshot(from: live).revision
        )
      )
      let liveAfterPageSizePreview = try LinnetSettingsDocumentStore.load(from: live)
      guard liveAfterPageSizePreview.appearance.pageSize == previewAppearance.pageSize else {
        fail("page size incorrectly used the lightweight appearance path")
      }

      let concurrentSettingsCoordinator = SettingsDataCoordinator(
        bundle: settings, timeout: 30, dataRegistry: registry,
        transactionRequester: transactionRequester)
      var transactionalDocument = liveAfterPageSizePreview
      transactionalDocument.input.traditionalChinese = true
      transactionalDocument.input.chineseLearningPolicy = .disabled
      transactionalDocument.appearance.candidateBrowsingMode = .scrollingOnly
      requestOrder.armDelayedReload()
      let concurrentBaseDocumentRevision = try LinnetSettingsDocumentStore.snapshot(from: live).revision
      let fullApply = Task {
        try await coordinator.run(
          .applyConfiguration(
            personal: appearanceResult.personalSnapshot.data,
            document: transactionalDocument,
            basePersonalRevision: appearanceResult.personalSnapshot.revision,
            baseDocumentRevision: concurrentBaseDocumentRevision
          )
        )
      }
      try await waitForEvent("reload", in: requestOrder)
      var concurrentAppearance = previewAppearance
      concurrentAppearance.themeFamily = .clayTiles
      concurrentAppearance.fontPoint = 21
      var staleSecondDocument = liveAfterPageSizePreview
      staleSecondDocument.appearance = concurrentAppearance
      let staleSecondFullApply = Task {
        try await concurrentSettingsCoordinator.run(
          .applyConfiguration(
            personal: appearanceResult.personalSnapshot.data,
            document: staleSecondDocument,
            basePersonalRevision: appearanceResult.personalSnapshot.revision,
            baseDocumentRevision: concurrentBaseDocumentRevision
          )
        )
      }
      requestOrder.releaseDelayedReloadTerminal()
      _ = try await fullApply.value
      do {
        _ = try await staleSecondFullApply.value
        fail("a stale second Settings instance overwrote a confirmed full Apply")
      } catch SettingsDataCoordinator.Failure.staleRevision {
        // Expected: the document revision changed even though personal data did not.
      }
      let postApplyDocument = try LinnetSettingsDocumentStore.snapshot(from: live)
      _ = try await concurrentSettingsCoordinator.run(
        .publishAppearance(
          appearance: concurrentAppearance,
          basePersonalRevision: appearanceResult.personalSnapshot.revision,
          baseDocumentRevision: postApplyDocument.revision)
      )
      let liveAfterConcurrentApply = try LinnetSettingsDocumentStore.load(from: live)
      guard liveAfterConcurrentApply.input.traditionalChinese,
        liveAfterConcurrentApply.input.chineseLearningPolicy == .disabled,
        liveAfterConcurrentApply.appearance.themeFamily == .clayTiles,
        liveAfterConcurrentApply.appearance.fontPoint == 21,
        liveAfterConcurrentApply.appearance.candidateBrowsingMode == .scrollingOnly,
        try String(
          contentsOf: live.appending(
            path: LinnetSettingsProjectionRenderer.squirrelCustomFile),
          encoding: .utf8
        ).contains("\"style/linnet_candidate_expansion_allowed\": false")
      else {
        fail("cross-process settings mutation serialization lost a confirmed update")
      }
      for file in LinnetSettingsProjectionRenderer.chineseCustomFiles {
        let projection = try String(
          contentsOf: live.appending(path: file), encoding: .utf8)
        guard projection.contains("\"translator/enable_user_dict\": false"),
          projection.contains("\"auto_phrase/enable\": false")
        else {
          fail("the full settings transaction missed disabled learning in \(file)")
        }
      }
      guard try exportContains(
        "linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot
      ) else {
        fail("disabling Chinese learning deleted the preserved user dictionary")
      }

      var reenabledDocument = liveAfterConcurrentApply
      reenabledDocument.input.chineseLearningPolicy = .enhanced
      _ = try await coordinator.run(
        .applyConfiguration(
          personal: appearanceResult.personalSnapshot.data,
          document: reenabledDocument,
          basePersonalRevision: appearanceResult.personalSnapshot.revision,
          baseDocumentRevision: try LinnetSettingsDocumentStore.snapshot(from: live).revision
        )
      )
      guard try LinnetSettingsDocumentStore.load(from: live).input.chineseLearningPolicy
        == .enhanced,
        try exportContains(
          "linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot
        )
      else {
        fail("re-enabling Chinese learning did not restore the preserved user dictionary")
      }

      let portableURL = fixtureRoot.appending(path: "complete.linnet-data")
      _ = try await coordinator.run(
        .exportPortable(
          categories: Set(LinnetBackupStore.Category.allCases), destination: portableURL)
      )
      let exported = try LinnetBackupStore.decodePortable(Data(contentsOf: portableURL))
      guard Set(exported.categories) == Set(LinnetBackupStore.Category.allCases),
        Set(exported.learning.map(\.schema)) == RimeUserDataBridge.learningSchemas
      else {
        fail("portable export did not contain the requested canonical categories")
      }

      let diagnosticResult = try await coordinator.run(.diagnose)
      guard let diagnostics = diagnosticResult.diagnostics,
        diagnostics.reachability == .running,
        diagnostics.runtime?.smartEnglishAvailable == true,
        diagnostics.runtime?.octagramAvailable == true,
        diagnostics.redactedReport.contains("schemas=9/9"),
        !diagnostics.redactedReport.contains("personal_revision="),
        !diagnostics.redactedReport.contains("Cloud Team"),
        !diagnostics.redactedReport.contains(live.path),
        !diagnostics.redactedReport.contains(NSUserName())
      else {
        fail("runtime diagnostics were incomplete or disclosed personal data")
      }
      let reachabilityCases: [
        (fixture: DiagnoseHealthFixture, expected: SettingsRuntimeReachability)
      ] = [
        (.status(.paused), .paused),
        (.status(.degraded), .degraded),
        (.status(.failed), .unreachable),
        (.unavailable, .unreachable),
      ]
      for row in reachabilityCases {
        requestOrder.armDiagnoseHealth(row.fixture)
        let result = try await coordinator.run(.diagnose)
        guard result.diagnostics?.reachability == row.expected else {
          fail("runtime diagnostics classified a fixture into the wrong reachability state")
        }
      }

      let portableReplacement = LinnetPersonalData(
        customWords: [.init(value: "Portable Word", code: "portable word")],
        disabledWords: ["must-not-replace"],
        expansions: [.init(value: "must not replace", trigger: "x;ignored")]
      )
      let portableData = try LinnetBackupStore.encodePortable(
        personalData: portableReplacement,
        learning: [
          RimeUserDataBridge.chineseSchema:
            "# Rime user dictionary export\n你好\tni hao\t19\n"
        ],
        categories: [.customWords, .chineseLearning],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        appVersion: "0.1.0",
        dataVersion: "fixture"
      )
      let replacementURL = fixtureRoot.appending(path: "replacement.linnet-data")
      try portableData.write(to: replacementURL)
      let malformedPortable = fixtureRoot.appending(path: "malformed.linnet-data")
      try Data("{".utf8).write(to: malformedPortable)
      do {
        _ = try await coordinator.inspectPortable(malformedPortable)
        fail("a malformed portable archive produced a confirmation candidate")
      } catch LinnetBackupStore.Failure.invalidDocument {
        // The existing format owner rejected it before any Host request.
      }
      let portableCandidate = try await coordinator.inspectPortable(replacementURL)
      guard portableCandidate.categories == [.chineseLearning, .customWords],
        portableCandidate.recordCount == 2,
        portableCandidate.appVersion == "0.1.0",
        portableCandidate.dataVersion == "fixture"
      else { fail("portable inspection summary did not come from the validated archive") }
      let cloudRecovery = fixtureRoot.appending(path: "cloud-recovery", directoryHint: .isDirectory)
      try fileManager.createDirectory(at: cloudRecovery, withIntermediateDirectories: false)
      _ = try LinnetCloudRecoveryArchive.publish(
        portable: portableData, in: cloudRecovery, repair: false)
      let cloudCandidate = try await coordinator.inspectCloudRecovery(in: cloudRecovery)
      guard cloudCandidate?.archive == portableCandidate.archive else {
        fail("cloud recovery inspection did not use the validated portable archive")
      }
      verifyOperationContracts(
        legacyCandidate: legacyCandidate,
        portableCandidate: portableCandidate,
        fixtureRoot: fixtureRoot
      )
      try fileManager.removeItem(at: replacementURL)
      let unselectedEnglish = try rawDictionaryState("linnet_en", directory: live)
      let firstImport = try await coordinator.run(
        .importPortable(portableCandidate, baseRevision: applyResult.personalSnapshot.revision)
      )
      try verifyPortableReplacement(live: live, fixtureRoot: fixtureRoot)
      try verifyRawDictionary(
        "linnet_en", expected: unselectedEnglish, directory: live, operation: "partial portable import")
      let secondImport = try await coordinator.run(
        .importPortable(portableCandidate, baseRevision: firstImport.personalSnapshot.revision)
      )
      guard firstImport.personalSnapshot.revision == secondImport.personalSnapshot.revision else {
        fail("repeated portable replacement was not idempotent")
      }
      try verifyPortableReplacement(live: live, fixtureRoot: fixtureRoot)
      try verifyRawDictionary(
        "linnet_en", expected: unselectedEnglish, directory: live, operation: "repeated partial import")

      let beforeClearChinese = try rawDictionaryState("linnet_zh", directory: live)
      let clearChinese = try await coordinator.run(.clearLearning([.chinese]))
      try verifyRawDictionary(
        "linnet_en", expected: unselectedEnglish, directory: live, operation: "clear Chinese")
      guard let clearBackup = clearChinese.backupDirectory,
        try !exportContains(
          "linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot
        ),
        try exportContains(
          "linnet_en", row: "hello\thello", directory: live, fixtureRoot: fixtureRoot
        ),
        try LinnetPersonalDataStore.snapshot(from: live).revision
          == secondImport.personalSnapshot.revision
      else {
        fail("clear Chinese did not preserve English and personal data")
      }

      try Data("{".utf8).write(
        to: live.appending(path: LinnetSettingsDocumentStore.fileName),
        options: .atomic
      )
      let restored = try await coordinator.run(.restoreBackup(clearBackup))
      try verifyRawDictionary(
        "linnet_zh", expected: beforeClearChinese, directory: live, operation: "restore Chinese")
      try verifyRawDictionary(
        "linnet_en", expected: unselectedEnglish, directory: live, operation: "restore English")
      guard
        try exportContains(
          "linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot
        ),
        try exportContains(
          "linnet_en", row: "hello\thello", directory: live, fixtureRoot: fixtureRoot
        ),
        restored.personalSnapshot.revision == secondImport.personalSnapshot.revision,
        case .externalReplacement(let restoredDocument) = restored.documentEffect,
        restoredDocument == (try LinnetSettingsDocumentStore.snapshot(from: live))
      else {
        fail("verified restore did not recover the clear operation's undo point")
      }

      let clearBoth = try await coordinator.run(
        .clearLearning(Set(SettingsDataCoordinator.LearningDomain.allCases))
      )
      guard
        try !exportContains(
          "linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot
        ),
        try !exportContains(
          "linnet_en", row: "hello\thello", directory: live, fixtureRoot: fixtureRoot
        ),
        clearBoth.personalSnapshot.revision == restored.personalSnapshot.revision
      else {
        fail("clear both did not preserve personal data")
      }

      try await verifyLegacyBackupRestore(coordinator: coordinator, live: live, fixtureRoot: fixtureRoot)

      // Two independent Settings actors can prepare different pack kinds from
      // the same live revision. Only the first may publish; the second must be
      // rejected by the Host-style CAS. Cancelling it retires its transaction,
      // download and now-unreferenced pack while preserving live user data and
      // verified backups.
      let chineseV2 = try makeLanguagePack(
        .chinese, version: "settings-chinese-v2", sequence: 2, registry: registry)
      let englishV2 = try makeLanguagePack(
        .english, version: "settings-english-v2", sequence: 2, registry: registry)
      let chineseActivation = try activationReplacing(chineseV2, registry: registry)
      let staleEnglishActivation = try activationReplacing(englishV2, registry: registry)
      let secondCoordinator = SettingsDataCoordinator(
        bundle: settings, timeout: 10, dataRegistry: registry,
        transactionRequester: transactionRequester)
      try await coordinator.activateLanguage(chineseActivation)
      do {
        try await secondCoordinator.activateLanguage(staleEnglishActivation)
        fail("cross-Settings stale English activation was accepted")
      } catch SettingsDataCoordinator.Failure.requestFailed(let code) {
        guard code == .staleCandidate else {
          fail("stale CAS rejection code was lost: \(code)")
        }
      }
      try registry.cancelDataChannelUpdate(
        transactionID: staleEnglishActivation.transactionID)
      let stateAfterStaleCancellation = try registry.runtimeSnapshot().state
      guard stateAfterStaleCancellation.packs.contains(chineseV2) else {
        fail("cross-Settings CAS lost the committed Chinese pack")
      }
      guard !stateAfterStaleCancellation.packs.contains(englishV2) else {
        fail("cross-Settings CAS published the stale English pack")
      }
      guard !fileManager.fileExists(
        atPath: registry.transactionsDirectory
          .appending(path: staleEnglishActivation.transactionID.uuidString).path)
      else { fail("stale Settings transaction was not retired") }
      guard !fileManager.fileExists(
        atPath: registry.downloadsDirectory
          .appending(path: staleEnglishActivation.transactionID.uuidString).path)
      else { fail("stale Settings download was not retired") }
      guard !fileManager.fileExists(
        atPath: registry.rootDirectory.appending(path: englishV2.relativePath).path)
      else { fail("unreferenced stale English pack was not collected") }
      guard fileManager.fileExists(atPath: live.path) else {
        fail("stale Settings cleanup removed live personal data")
      }
      guard fileManager.fileExists(atPath: clearBackup.path) else {
        fail("stale Settings cleanup removed a verified backup")
      }

      let failedChinese = try activationReplacing(
        makeLanguagePack(
          .chinese, version: "settings-chinese-v3", sequence: 3, registry: registry),
        registry: registry)
      requestOrder.armLanguageStatus(.failed)
      try await requireLanguageFailure(
        failedChinese, coordinator: coordinator, code: .rollbackFailed)
      try registry.cancelDataChannelUpdate(transactionID: failedChinese.transactionID)
      try requireCancelled(failedChinese, registry: registry)

      let rolledBackEnglishPack = try makeLanguagePack(
        .english, version: "settings-english-v2", sequence: 2, registry: registry)
      print("Coordinator scenario: rolled-back English activation")
      let rolledBackEnglish = try activationReplacing(
        rolledBackEnglishPack, registry: registry)
      requestOrder.armLanguageStatus(.rolledBack)
      try await requireLanguageFailure(
        rolledBackEnglish, coordinator: coordinator, code: .activationRolledBack)
      try registry.cancelDataChannelUpdate(transactionID: rolledBackEnglish.transactionID)
      try requireCancelled(rolledBackEnglish, registry: registry)

      let rejectedEnglishPack = try makeLanguagePack(
        .english, version: "settings-english-v2", sequence: 2, registry: registry)
      let rejectedEnglish = try activationReplacing(
        rejectedEnglishPack, registry: registry)
      requestOrder.armPauseStatus(.rejected)
      try await requireLanguageFailure(
        rejectedEnglish, coordinator: coordinator, code: .invalidCandidate)
      try registry.cancelDataChannelUpdate(transactionID: rejectedEnglish.transactionID)
      try requireCancelled(rejectedEnglish, registry: registry)

      let timedOutEnglishPack = try makeLanguagePack(
        .english, version: "settings-english-v2", sequence: 2, registry: registry)
      let timedOutEnglish = try activationReplacing(
        timedOutEnglishPack, registry: registry)
      let timeoutCoordinator = SettingsDataCoordinator(
        bundle: settings, timeout: 0, dataRegistry: registry,
        transactionRequester: transactionRequester)
      try await timeoutCoordinator.activateLanguage(timedOutEnglish)
      guard try registry.runtimeSnapshot().state.packs.contains(timedOutEnglishPack),
        !fileManager.fileExists(
          atPath: registry.transactionsDirectory
            .appending(path: timedOutEnglish.transactionID.uuidString).path)
      else {
        fail("language activation used the generic 30-second reply timer")
      }

      let modelData = Data("settings-lts-fixture".utf8)
      let ltsVersion = "2026.08.1"
      let ltsRoot = registry.packsDirectory.appending(
        path: "lts/2-\(ltsVersion)", directoryHint: .isDirectory)
      try makeDirectory(ltsRoot)
      try modelData.write(to: ltsRoot.appending(path: "wanxiang-lts-zh-hans.gram"))
      let ltsPack = try writeLanguagePackManifest(
        kind: .lts, version: ltsVersion, sequence: 2,
        directory: ltsRoot, files: ["wanxiang-lts-zh-hans.gram"])
      let languageActivation = try activationReplacing(ltsPack, registry: registry)
      try await coordinator.activateLanguage(languageActivation)
      guard try registry.runtimeSnapshot().state.edition == .standard,
        !fileManager.fileExists(
          atPath: registry.transactionsDirectory
            .appending(path: languageActivation.transactionID.uuidString).path)
      else {
        fail("LTS activation changed the Standard edition or left its transaction")
      }

      let exhaustedExport = fixtureRoot.appending(path: "deadline-exhausted.linnet-data")
      let observationsBeforeExhaustion = requestOrder.currentRequestTimeouts().count
      requestOrder.armTransportTimeout(.pause)
      do {
        _ = try await coordinator.run(
          .exportPortable(categories: [.customWords], destination: exhaustedExport)
        )
        fail("a transaction whose request deadline expired reported success")
      } catch SettingsDataCoordinator.Failure.timedOut {
        // The deadline owner is terminal: no later phase may publish an export.
      }
      let exhaustionObservations = Array(
        requestOrder.currentRequestTimeouts().dropFirst(observationsBeforeExhaustion))
      guard exhaustionObservations.count == 1,
        exhaustionObservations[0].command == .pause,
        !fileManager.fileExists(atPath: exhaustedExport.path)
      else { fail("an exhausted transaction deadline did not fail closed at pause") }

      let transactionCommands: [LinnetSettingsContract.DataCommand] = [
        .pause, .activate, .activateLanguage, .cancel,
      ]
      let timeoutObservations = requestOrder.currentRequestTimeouts().filter {
        transactionCommands.contains($0.command)
      }
      guard transactionCommands.allSatisfy({ command in
        timeoutObservations.contains { $0.command == command }
      }),
        timeoutObservations.allSatisfy({ observation in
          observation.timeout > 31
            && observation.timeout
              <= observation.deadline.timeIntervalSince(observation.observedAt) + 0.25
        })
      else {
        fail("pause/activate/cancel did not share their transaction deadline")
      }

      print("SettingsDataCoordinatorTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func verifyOperationContracts(
    legacyCandidate: SettingsDataCoordinator.LegacyImportCandidate,
    portableCandidate: SettingsDataCoordinator.PortableImportCandidate,
    fixtureRoot: URL
  ) {
    typealias Phase = SettingsDataCoordinator.Phase
    typealias Effect = SettingsDataCoordinator.PersonalEffect
    let removalID = UUID()
    let removal = LinnetBackupStore.BackupRecord(
      transactionDirectory: fixtureRoot.appending(path: removalID.uuidString),
      backupDirectory: fixtureRoot.appending(path: "backup-(removalID.uuidString)"),
      transactionID: removalID,
      state: .incomplete,
      transactionIdentity: nil
    )
    let destination = fixtureRoot.appending(path: "progress-matrix.linnet-data")
    let rows: [
      (
        name: String,
        operation: SettingsDataCoordinator.DataOperation,
        available: Set<Phase>,
        effect: Effect
      )
    ] = [
      (
        "publishAppearance",
        .publishAppearance(
          appearance: LinnetSettingsDocument.default.appearance,
          basePersonalRevision: "fixture", baseDocumentRevision: "fixture"),
        [.preflight, .staging], .observed
      ),
      (
        "applyConfiguration",
        .applyConfiguration(
          personal: .empty, document: .default,
          basePersonalRevision: "fixture", baseDocumentRevision: "fixture"),
        [.preflight, .pausing], .submittedDraft
      ),
      ("importLegacy", .importLegacy(legacyCandidate), [.preflight, .pausing], .externalReplacement),
      (
        "exportPortable",
        .exportPortable(categories: [.customWords], destination: destination),
        [.preflight, .pausing, .snapshotting], .observed
      ),
      (
        "importPortable", .importPortable(portableCandidate, baseRevision: "fixture"),
        [.preflight, .pausing], .externalReplacement
      ),
      ("restoreBackup", .restoreBackup(fixtureRoot), [.preflight, .pausing], .externalReplacement),
      ("removeBackupRecord", .removeBackupRecord(removal), [.preflight], .observed),
      ("clearLearning", .clearLearning([.chinese]), [.preflight, .pausing], .observed),
      ("diagnose", .diagnose, [], .observed),
    ]
    for row in rows {
      guard SettingsDataCoordinator.personalEffect(for: row.operation) == row.effect else {
        fail("\(row.name) projected the wrong personal-data effect")
      }
      for phase in Phase.allCases {
        let progress = SettingsDataCoordinator.operationProgress(
          for: row.operation, phase: phase)
        let expected: SettingsDataCoordinator.CancellationCapability =
          row.available.contains(phase) ? .available : .unavailable
        guard progress.phase == phase, progress.cancellation == expected else {
          fail("\(row.name)/\(phase.rawValue) projected the wrong cancellation capability")
        }
      }
    }
  }

  private static func verifyLegacyResult(
    _ result: SettingsDataCoordinator.Outcome,
    live: URL,
    source: URL,
    sourceHash: String,
    fixtureRoot: URL
  ) throws {
    guard let report = result.importReport,
      let backup = result.backupDirectory,
      report.importedCount == 1,
      result.legacyImportedCount == 2,
      try sha256(source) == sourceHash,
      try LinnetBackupStore.verifyBackup(at: backup).formatVersion
        == LinnetBackupStore.backupFormatVersion,
      !FileManager.default.fileExists(
        atPath: backup.appending(path: "legacy-rime").path
      ),
      !FileManager.default.fileExists(
        atPath: backup.deletingLastPathComponent().appending(path: "inputs/legacy-rime").path
      ),
      !FileManager.default.fileExists(
        atPath: live.appending(path: "linnet_custom_words.userdb").path
      ),
      try String(
        contentsOf: live.appending(path: LinnetPersonalDataStore.expansionsFile),
        encoding: .utf8
      ).contains("be right back\tx;brb"),
      try exportContains(
        "linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot
      ),
      try exportContains(
        "linnet_en", row: "hello\thello", directory: live, fixtureRoot: fixtureRoot
      )
    else {
      fail("legacy import, v2 backup, input separation, or exact learning allowlist failed")
    }
  }

  private static func verifyPortableReplacement(live: URL, fixtureRoot: URL) throws {
    let personal = try LinnetPersonalDataStore.load(from: live)
    let runtimeSettings = try String(
      contentsOf: live.appending(path: LinnetPersonalDataStore.userSettingsFile),
      encoding: .utf8
    )
    let englishSchemaSettings = try String(
      contentsOf: live.appending(path: LinnetSettingsProjectionRenderer.englishCustomFile),
      encoding: .utf8
    )
    guard personal.customWords.map(\.value) == ["Portable Word"],
      personal.disabledWords.map(\.value) == ["forbiddenword"],
      personal.expansions.map(\.trigger) == ["x;brb"],
      !runtimeSettings.contains("sentence_capitalization"),
      !runtimeSettings.contains("tab_behavior"),
      englishSchemaSettings.contains(
        "\"linnet_english_interaction/sentence_capitalization\": false"),
      englishSchemaSettings.contains(
        "\"linnet_english_interaction/tab_behavior\": \"pass\""),
      try exportContains(
        "linnet_zh", row: "你好\tni hao\t19", directory: live, fixtureRoot: fixtureRoot
      ),
      try exportContains(
        "linnet_en", row: "hello\thello", directory: live, fixtureRoot: fixtureRoot
      )
    else {
      fail("portable replacement did not replace selected and preserve unselected categories")
    }
  }

  private static func activationReplacing(
    _ replacement: LinnetDataRegistry.ActivePack,
    registry: LinnetDataRegistry
  ) throws -> LinnetDataRegistry.ActivationCandidate {
    let activeData = try Data(contentsOf: registry.activeSharedDataDirectory.appending(path: "activation.json"))
    let active = try JSONDecoder().decode(LinnetDataRegistry.ActiveState.self, from: activeData)
    var target = active.packs
    target.removeAll { $0.kind == replacement.kind }
    target.append(replacement)
    // Catalog publication advances independently from each pack's sequence.
    let sequence = (active.acceptedCatalog?.sequence ?? 0) + 1
    let document = dataChannelCatalog(for: target, sequence: sequence)
    let catalog = LinnetDataChannel.Verified(
      catalog: document,
      digest: LinnetPackContract.sha256(try LinnetDataChannel.canonicalCatalogData(document)))
    let receipt = try registry.receiptForCatalog(catalog)
    print("Language fixture \(replacement.kind.rawValue) \(replacement.version), pack \(replacement.sequence): "
      + "Catalog \(active.acceptedCatalog?.sequence ?? 0) -> \(sequence); "
      + "snapshot \(active.acceptedCatalog?.packSnapshotDigest ?? "none") -> \(receipt.packSnapshotDigest ?? "none")")
    let edition: LinnetDataRegistry.Edition = target.contains { $0.kind == .extended }
      ? .full : .standard
    var phase = "begin"
    do {
      let update = try registry.beginDataChannelUpdate(accepting: catalog, edition: edition)
      phase = "prepare"
      return try registry.prepareDataChannelUpdate(update, target: target)
    } catch {
      print("Language fixture failed at \(phase): \(replacement.kind.rawValue) "
        + "\(replacement.version), pack sequence \(replacement.sequence), catalog sequence \(sequence): \(error)")
      throw error
    }
  }

  private static func dataChannelCatalog(
    for packs: [LinnetDataRegistry.ActivePack], sequence: UInt64
  ) -> LinnetDataChannel.Catalog {
    let artifacts = packs.map { pack in
      LinnetDataChannel.Artifact(
        kind: pack.kind,
        version: pack.version,
        sequence: pack.sequence,
        dataABI: pack.dataABI,
        minCore: pack.minCore,
        contentSHA256: pack.contentSHA256,
        bytes: 1,
        containerSHA256: String(repeating: "f", count: 64),
        url: URL(string:
          "https://github.com/Ares-X/Linnet/releases/download/data-\(sequence)/\(pack.kind.rawValue).linnetpack")!)
    }
    let edition: LinnetDataRegistry.Edition = packs.contains { $0.kind == .extended }
      ? .full : .standard
    return .init(
      format: LinnetDataChannel.format,
      sequence: sequence,
      core: .init(
        version: "0.1.0", build: 1, revision: String(repeating: "a", count: 40),
        bytes: 1, sha256: String(repeating: "b", count: 64),
        packageURL: URL(
          string:
            "https://github.com/Ares-X/Linnet/releases/download/core-v0.1.0/Linnet-0.1.0-arm64-Core-community-beta.pkg")!,
        releaseURL: URL(string: "https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.0")!),
      activationSets: [.init(edition: edition, packs: artifacts)])
  }

  private static func makeLanguagePack(
    _ kind: LinnetPackContract.Kind,
    version: String,
    sequence: UInt64,
    registry: LinnetDataRegistry
  ) throws -> LinnetDataRegistry.ActivePack {
    let root = registry.packsDirectory.appending(
      path: "\(kind.rawValue)/\(sequence)-\(version)", directoryHint: .isDirectory)
    try makeDirectory(root)
    let files = kind == .chinese
      ? ["default.yaml", "squirrel.yaml", "linnet_zh.schema.yaml", "linnet_zh.dict.yaml"]
      : ["linnet_en.schema.yaml"]
    for file in files {
      try Data("# \(version)\n".utf8).write(to: root.appending(path: file))
    }
    return try writeLanguagePackManifest(
      kind: kind, version: version, sequence: sequence,
      directory: root, files: files)
  }

  private static func writeLanguagePackManifest(
    kind: LinnetPackContract.Kind,
    version: String,
    sequence: UInt64,
    directory: URL,
    files: [String]
  ) throws -> LinnetDataRegistry.ActivePack {
    let entries = try files.sorted().map { path in
      let data = try Data(contentsOf: directory.appending(path: path))
      return LinnetPackContract.FileEntry(
        path: path, bytes: UInt64(data.count), sha256: LinnetPackContract.sha256(data))
    }
    let marker: Character = switch kind {
    case .chinese: "a"
    case .english: "b"
    case .lts: "c"
    case .extended: "d"
    }
    let contentSHA256 = String(repeating: marker, count: 64)
    let requirements: [LinnetPackContract.Requirement] =
      kind == .lts || kind == .extended ? [.init(kind: .chinese, dataABI: 1)] : []
    let manifest = LinnetPackContract.Manifest(
      format: LinnetPackContract.manifestFormat,
      product: LinnetPackContract.productIdentifier,
      packID: kind.packID,
      kind: kind,
      version: version,
      sequence: sequence,
      dataABI: 1,
      minCore: "1.0.0",
      contentSHA256: contentSHA256,
      requires: requirements,
      files: entries)
    let manifestData = try LinnetPackContract.canonicalManifestData(manifest)
    try manifestData.write(to: directory.appending(path: "manifest.json"), options: .atomic)
    return LinnetDataRegistry.ActivePack(
      packID: manifest.packID,
      kind: kind,
      version: version,
      sequence: sequence,
      dataABI: 1,
      contentSHA256: contentSHA256,
      minCore: manifest.minCore,
      requirements: requirements,
      relativePath: "Data/Packs/\(kind.rawValue)/\(sequence)-\(version)",
      manifestSHA256: LinnetPackContract.sha256(manifestData))
  }

  private static func requireLanguageFailure(
    _ activation: LinnetDataRegistry.ActivationCandidate,
    coordinator: SettingsDataCoordinator,
    code: LinnetSettingsContract.RuntimeReplyCode
  ) async throws {
    do {
      try await coordinator.activateLanguage(activation)
      fail("forced language terminal was accepted")
    } catch SettingsDataCoordinator.Failure.requestFailed(let actual) {
      guard actual == code else { fail("language failure code was lost: \(actual)") }
    }
  }

  private static func requireCancelled(
    _ activation: LinnetDataRegistry.ActivationCandidate,
    registry: LinnetDataRegistry
  ) throws {
    guard !FileManager.default.fileExists(
      atPath: registry.transactionsDirectory
        .appending(path: activation.transactionID.uuidString).path),
      FileManager.default.fileExists(atPath: registry.packsDirectory.path),
      FileManager.default.fileExists(atPath: registry.userDataDirectory.path),
      FileManager.default.fileExists(atPath: registry.backupsDirectory.path)
    else { fail("cancel crossed its Transaction ownership boundary") }
  }

  private static func makeRegistryFixture(_ registry: LinnetDataRegistry) throws {
    let plumRoot = URL(fileURLWithPath: "data/plum", isDirectory: true)
    let plumBuild = ProcessInfo.processInfo.environment["LINNET_SETTINGS_TEST_PLUM_BUILD"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? plumRoot.appending(path: "build", directoryHint: .isDirectory)
    let active = registry.activeSharedDataDirectory
    try makeDirectory(active)
    for source in try FileManager.default.contentsOfDirectory(
      at: plumRoot,
      includingPropertiesForKeys: nil
    ) where !["build", "wanxiang-lts-zh-hans.gram"].contains(source.lastPathComponent) {
      try FileManager.default.copyItem(
        at: source,
        to: active.appending(path: source.lastPathComponent)
      )
    }
    let activeBuild = active.appending(path: "build", directoryHint: .isDirectory)
    try makeDirectory(activeBuild)
    for artifact in try FileManager.default.contentsOfDirectory(
      at: plumBuild,
      includingPropertiesForKeys: nil
    ) {
      try FileManager.default.createSymbolicLink(
        at: activeBuild.appending(path: artifact.lastPathComponent),
        withDestinationURL: artifact.absoluteURL
      )
    }
    // data/plum is the Complete source-build view. The Standard runtime fixture
    // must consume the same explicit root as the Chinese pack projector; mixing
    // the Complete root with a Standard pack makes deploy demand absent L3 data.
    for file in [
      "default.yaml", "linnet_en.schema.yaml", "linnet_zh.schema.yaml", "linnet_zh.dict.yaml",
      "linnet_grammar_active.yaml",
    ] {
      let destination = active.appending(path: file)
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "data/linnet/\(file)"),
        to: destination
      )
    }
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "data/opencc", isDirectory: true),
      to: active.appending(path: "opencc", directoryHint: .isDirectory)
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "data/squirrel.yaml"),
      to: active.appending(path: "squirrel.yaml")
    )
    let chinesePack = registry.packsDirectory.appending(
      path: "chinese/1-settings-tests", directoryHint: .isDirectory)
    let englishPack = registry.packsDirectory.appending(
      path: "english/1-settings-tests", directoryHint: .isDirectory)
    let ltsPack = registry.packsDirectory.appending(
      path: "lts/1-settings-tests", directoryHint: .isDirectory)
    try makeDirectory(chinesePack)
    try makeDirectory(englishPack)
    try makeDirectory(ltsPack)
    let extendedOnly = Set([
      "linnet_zh_full.dict.yaml", "dicts/fangyan.dict.yaml",
      "dicts/huaxue.dict.yaml", "dicts/mingren.dict.yaml",
      "dicts/renming.dict.yaml", "dicts/taifeng.dict.yaml",
      "dicts/wuzhong.dict.yaml", "dicts/yaopin.dict.yaml",
      "dicts/yiren.dict.yaml", "dicts/yixue.dict.yaml",
    ])
    var chineseFiles: [String] = []
    var englishFiles: [String] = []
    guard let enumerator = FileManager.default.enumerator(
      at: active,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
    else { fail("cannot enumerate staged Registry fixture") }
    let activePrefix = active.standardizedFileURL.path + "/"
    for case let source as URL in enumerator {
      let values = try source.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      if values.isDirectory == true && values.isSymbolicLink != true { continue }
      let relative = String(source.standardizedFileURL.path.dropFirst(activePrefix.count))
      if relative == "linnet_grammar_active.yaml" || extendedOnly.contains(relative) { continue }
      let isEnglish = relative == "linnet.smart.db"
        || relative == "linnet.english-data-manifest.json"
        || relative == "linnet_english_entities.dict.yaml"
        || relative.hasPrefix("linnet_en.")
        || relative.hasPrefix("build/linnet_en.")
      let destinationRoot = isEnglish ? englishPack : chinesePack
      let destination = destinationRoot.appending(path: relative)
      try makeDirectory(destination.deletingLastPathComponent())
      try Data(contentsOf: source).write(to: destination)
      if isEnglish { englishFiles.append(relative) } else { chineseFiles.append(relative) }
    }
    let ltsModel = ltsPack.appending(path: "wanxiang-lts-zh-hans.gram")
    try Data("settings fixture\n".utf8).write(to: ltsModel)
    let packs = try [
      writeLanguagePackManifest(
        kind: .chinese, version: "settings-tests", sequence: 1,
        directory: chinesePack, files: chineseFiles),
      writeLanguagePackManifest(
        kind: .english, version: "settings-tests", sequence: 1,
        directory: englishPack, files: englishFiles),
      writeLanguagePackManifest(
        kind: .lts, version: "settings-tests", sequence: 1,
        directory: ltsPack, files: ["wanxiang-lts-zh-hans.gram"]),
    ]
    try FileManager.default.removeItem(at: active)
    try makeDirectory(active.appending(path: "build", directoryHint: .isDirectory))
    for (root, files) in [
      (chinesePack, chineseFiles), (englishPack, englishFiles),
      (ltsPack, ["wanxiang-lts-zh-hans.gram"]),
    ] {
      for relative in files where relative != "linnet_zh.dict.yaml" {
        let projection = active.appending(path: relative)
        try makeDirectory(projection.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(
          at: projection, withDestinationURL: root.appending(path: relative))
      }
    }
    try FileManager.default.createSymbolicLink(
      at: active.appending(path: "linnet_zh.dict.yaml"),
      withDestinationURL: chinesePack.appending(path: "linnet_zh.dict.yaml"))
    try Data("grammar:\n  language: wanxiang-lts-zh-hans\n".utf8).write(
      to: active.appending(path: "linnet_grammar_active.yaml"))
    let state = LinnetDataRegistry.ActiveState(
      format: LinnetDataRegistry.stateFormat,
      edition: .standard,
      generation: 1,
      activeView: "Runtime/Active",
      packs: packs
    )
    try JSONEncoder().encode(state).write(
      to: active.appending(path: "activation.json"), options: .atomic)
  }

  private static func verifyCoreThemeDeployment(in root: URL) throws {
    let shared = root.appending(path: "theme-shared")
    let user = root.appending(path: "theme-user")
    let staging = root.appending(path: "theme-build")
    for directory in [shared, user, staging] { try makeDirectory(directory) }
    let source = root.appending(path: "core-theme.yaml")
    let bundled = try String(contentsOfFile: "data/squirrel.yaml", encoding: .utf8)
    try "config_version: '1.1'\nstyle:\n  font_point: 99\n".write(
      to: shared.appending(path: "squirrel.yaml"), atomically: true, encoding: .utf8)
    var document = LinnetSettingsDocument.default
    document.appearance.fontPoint = 32
    document.appearance.themeFamily = .sidecarSlate
    try LinnetSettingsProjectionRenderer.reconcile(document: document, to: user)
    let api = rime_get_api_stdbool().pointee
    for (index, accent) in ["0x995725", "0x123456"].enumerated() {
      if index == 1 {
        // New packs omit UI; the next Core must also replace a same-version
        // theme without waiting for a timestamp tick or touching dictionaries.
        try FileManager.default.removeItem(at: shared.appending(path: "squirrel.yaml"))
      }
      try bundled.replacingOccurrences(of: "0x995725", with: accent).write(
        to: source, atomically: true, encoding: .utf8)
      try LinnetSettingsProjectionRenderer.reconcileCoreConfiguration(
        source: source, to: user, stagingDirectory: staging)
      shared.path.withCString { sharedPath in
        user.path.withCString { userPath in
          staging.path.withCString { stagingPath in
            var traits = RimeTraits()
            traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
            traits.shared_data_dir = sharedPath
            traits.user_data_dir = userPath
            traits.staging_dir = stagingPath
            traits.prebuilt_data_dir = stagingPath
            traits.min_log_level = 3
            api.setup(&traits)
          }
        }
      }
      api.initialize(nil)
      do {
        defer { api.finalize() }
        if api.start_maintenance(false) { api.join_maintenance_thread() }
        guard api.deploy_config_file("squirrel.yaml", "config_version") else {
          fail("Core theme could not be deployed by Rime")
        }
        var config = RimeConfig()
        guard api.config_open("squirrel", &config) else { fail("Core theme could not be opened") }
        defer { _ = api.config_close(&config) }
        var font = 0.0
        guard api.config_get_double(&config, "style/font_point", &font), font == 32,
          let selected = api.config_get_cstring(&config, "style/color_scheme"),
          String(cString: selected) == "linnet_sidecar_light",
          let color = api.config_get_cstring(&config, "preset_color_schemes/linnet_sidecar_light/hilited_candidate_back_color"),
          String(cString: color) == accent
        else { fail("Rime retained pack/old-Core theme or lost the user's appearance choices") }
      }
    }
    print("Core theme deployment: PASS (legacy pack, theme-free pack, same-version Core update, preserved choices)")
  }

  private static func verifySelectedChineseProfile(
    _ expected: LinnetSettingsContract.ChineseProfile,
    user: URL,
    shared: URL,
    product: String
  ) throws {
    let api = rime_get_api_stdbool().pointee
    let prebuilt = shared.appending(path: "build").path
    let staging = user.appending(path: "build").path
    shared.path.withCString { sharedPath in
      prebuilt.withCString { prebuiltPath in
        user.path.withCString { userPath in
          staging.withCString { stagingPath in
            product.withCString { productPath in
              "".withCString { logPath in
                var traits = RimeTraits()
                traits.data_size = Int32(
                  MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
                traits.shared_data_dir = sharedPath
                traits.prebuilt_data_dir = prebuiltPath
                traits.user_data_dir = userPath
                traits.staging_dir = stagingPath
                traits.distribution_name = productPath
                traits.app_name = productPath
                traits.min_log_level = 2
                traits.log_dir = logPath
                api.setup(&traits)
              }
            }
          }
        }
      }
    }
    api.initialize(nil)
    defer { api.finalize() }

    var config = RimeConfig()
    guard api.user_config_open("user", &config) else {
      fail("the applied Rime user configuration could not be opened")
    }
    let staleSchemaID = LinnetSettingsContract.ChineseProfile.natural.schemaID
    let wroteStale = staleSchemaID.withCString {
      api.config_set_string(&config, "var/previously_selected_schema", $0)
    }
    let closed = api.config_close(&config)
    guard wroteStale, closed, staleSchemaID != expected.schemaID else {
      fail("could not establish a stale user.yaml schema selection")
    }

    let session = api.create_session()
    guard session != 0 else {
      fail("a fresh session could not be created after full Apply")
    }
    defer { _ = api.destroy_session(session) }
    var active = [CChar](repeating: 0, count: Int(PATH_MAX))
    let readActive = active.withUnsafeMutableBufferPointer { buffer in
      api.get_current_schema(session, buffer.baseAddress, buffer.count)
    }
    guard readActive, String(cString: active) == expected.schemaID else {
      fail("a stale user.yaml value overrode the document-selected Chinese profile")
    }
  }

  private static func makeBundleFixture(at root: URL, productName: String) throws -> Bundle {
    let host = root.appending(path: "Host.app", directoryHint: .isDirectory)
    let settings = host.appending(
      path: "Contents/Applications/Settings.app",
      directoryHint: .isDirectory
    )
    try makeDirectory(settings.appending(path: "Contents", directoryHint: .isDirectory))
    try writePlist(
      host.appending(path: "Contents/Info.plist"),
      [
        "CFBundleDisplayName": productName,
        "CFBundleExecutable": "Host",
        "CFBundleIdentifier": "io.github.linnet.data-tests.\(UUID().uuidString)",
        "CFBundleName": "Host",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "InputMethodConnectionName": "Linnet_Data_Test",
      ]
    )
    try writePlist(
      settings.appending(path: "Contents/Info.plist"),
      [
        "CFBundleDisplayName": "Linnet Data Settings",
        "CFBundleExecutable": "Settings",
        "CFBundleIdentifier": "io.github.linnet.data-tests.settings",
        "CFBundleName": "Settings",
        "CFBundlePackageType": "APPL",
      ]
    )
    guard let bundle = Bundle(url: settings) else { throw TestFailure.fixture }
    return bundle
  }

  private static func writePlist(_ url: URL, _ values: [String: Any]) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
    try data.write(to: url)
  }

  private static func makeSubstitutionDatabase(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      throw TestFailure.fixture
    }
    defer { sqlite3_close_v2(database) }
    guard
      sqlite3_exec(
        database,
        "CREATE TABLE substitutions(key TEXT PRIMARY KEY, value TEXT)",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else { throw TestFailure.fixture }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "INSERT INTO substitutions(key, value) VALUES (?, ?)",
        -1,
        &statement,
        nil
      ) == SQLITE_OK, let statement
    else { throw TestFailure.fixture }
    defer { sqlite3_finalize(statement) }
    guard
      "brb".withCString({ sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient) })
        == SQLITE_OK,
      "be right back".withCString({ sqlite3_bind_text(statement, 2, $0, -1, sqliteTransient) })
        == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw TestFailure.fixture
    }
  }

  private static func makeInvalidSubstitutionDatabase(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      throw TestFailure.fixture
    }
    defer { sqlite3_close_v2(database) }
    guard
      sqlite3_exec(
        database,
        "CREATE TABLE substitutions(key TEXT PRIMARY KEY, value TEXT, extra TEXT)",
        nil,
        nil,
        nil
      ) == SQLITE_OK
    else { throw TestFailure.fixture }
  }

  private static func seedDictionary(
    _ name: String,
    row: String,
    directory: URL,
    fixtureRoot: URL
  ) throws {
    let source = fixtureRoot.appending(path: "seed-\(name).txt")
    try "# Rime user dictionary export\n\(row)\n".write(
      to: source,
      atomically: true,
      encoding: .utf8
    )
    try runDictionaryTool(["--import", name, source.path], directory: directory)
  }

  private static func verifyLegacyBackupRestore(
    coordinator: SettingsDataCoordinator, live: URL, fixtureRoot: URL
  ) async throws {
    for version in [2, 3] {
      let transactionID = UUID()
      let backup = fixtureRoot.appending(path: "legacy-backups/\(transactionID.uuidString)/backup", directoryHint: .isDirectory)
      let stable = backup.appending(path: "stable", directoryHint: .isDirectory)
      let learning = backup.appending(path: "user-dictionaries", directoryHint: .isDirectory)
      try makeDirectory(stable)
      try makeDirectory(learning)
      _ = try LinnetBackupStore.snapshotStable(from: live, to: stable)
      if version == 2 {
        try FileManager.default.removeItem(at: stable.appending(path: LinnetSettingsDocumentStore.fileName))
        try FileManager.default.removeItem(at: stable.appending(path: LinnetPersonalDataStore.userSettingsFile))
        try "disabled_words: []\nsentence_capitalization: false\ntab_behavior: smart_complete\n".write(
          to: stable.appending(path: LinnetPersonalDataStore.legacyUserSettingsFile), atomically: true, encoding: .utf8)
      }
      for (schema, row) in ["linnet_zh": "你好\tni hao\t19", "linnet_en": "hello\thello\t11"] {
        try "# Rime user dictionary export\n\(row)\n".write(
          to: learning.appending(path: "\(schema).txt"), atomically: true, encoding: .utf8)
      }
      let manifest = LinnetBackupStore.BackupManifest(
        formatVersion: version, complete: true, backupID: UUID(), transactionID: transactionID,
        operation: .applyPersonalData, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        appVersion: "0.1.10", dataVersion: "legacy-fixture",
        personalRevision: try LinnetBackupStore.backupPersonalRevision(at: stable, formatVersion: version),
        artifacts: try LinnetBackupStore.collectBackupArtifacts(backup, formatVersion: version))
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(manifest).write(to: backup.appending(path: "manifest.json"))
      let result = try await coordinator.run(.restoreBackup(backup))
      guard try LinnetBackupStore.verifyBackup(at: backup) == manifest,
        result.personalSnapshot.data.customWords.map(\.value)
          == (try LinnetPersonalDataStore.load(from: stable)).customWords.map(\.value),
        try exportContains("linnet_zh", row: "你好\tni hao", directory: live, fixtureRoot: fixtureRoot),
        try exportContains("linnet_en", row: "hello\thello", directory: live, fixtureRoot: fixtureRoot)
      else { fail("shipped v\(version) backup restore lost stable/learning data or rewrote its source") }
      print("Legacy backup v\(version) native restore: PASS")
    }
  }

  // The native backup codec preserves the database clock and complete c/d/t
  // values, including deletions. A portable table export is not this oracle.
  private static func seedRawDictionary(
    _ name: String, directory: URL, fixtureRoot: URL
  ) throws {
    let rows = name == "linnet_zh"
      ? "ni hao \t你好\tc=11 d=4.25 t=1000\nzhong guo \t中国\tc=-3 d=1.5 t=1000\n"
      : "hello \thello\tc=11 d=4.25 t=1000\nremoved \tremoved\tc=-3 d=1.5 t=1000\n"
    let source = fixtureRoot.appending(path: "raw-\(name).userdb.txt")
    try "# Rime user dictionary\n#@/db_name\t\(name)\n#@/db_type\tuserdb\n#@/tick\t1000\n\(rows)"
      .write(to: source, atomically: true, encoding: .utf8)
    try runDictionaryTool(["--restore", source.path], directory: directory)
  }

  private static func rawDictionaryState(
    _ name: String, directory: URL
  ) throws -> [String: String] {
    let installation = directory.appending(path: "installation.yaml")
    guard !(try String(contentsOf: installation, encoding: .utf8)).contains("sync_dir:") else {
      throw TestFailure.fixture
    }
    try runDictionaryTool(["--backup", name], directory: directory)
    let sync = directory.appending(path: "sync", directoryHint: .isDirectory)
    guard let files = FileManager.default.enumerator(at: sync, includingPropertiesForKeys: nil)
    else { throw TestFailure.fixture }
    let matches = files.compactMap { $0 as? URL }.filter {
      $0.lastPathComponent == "\(name).userdb.txt"
    }
    guard matches.count == 1 else { throw TestFailure.fixture }
    let contents = try String(contentsOf: matches[0], encoding: .utf8)
    var state: [String: String] = [:]
    for line in contents.split(separator: "\n") where !line.hasPrefix("#") || line.hasPrefix("#@") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 2 else { throw TestFailure.fixture }
      let key = fields.dropLast().joined(separator: "\t")
      guard state.updateValue(String(fields.last!), forKey: key) == nil else { throw TestFailure.fixture }
    }
    return state
  }

  private static func verifyRawDictionary(
    _ name: String, expected: [String: String], directory: URL, operation: String
  ) throws {
    let actual = try rawDictionaryState(name, directory: directory)
    guard actual == expected else {
      let changed = Set(expected.keys).union(actual.keys).sorted().filter { expected[$0] != actual[$0] }
      for key in changed {
        print("RAW_LEARNING \(name) \(key): \(expected[key] ?? "<absent>") -> \(actual[key] ?? "<absent>")")
      }
      fail("\(operation) changed the complete native learning state of \(name)")
    }
  }

  private static func exportContains(
    _ name: String,
    row: String,
    directory: URL,
    fixtureRoot: URL
  ) throws -> Bool {
    let output = fixtureRoot.appending(path: "export-\(name)-\(UUID().uuidString).txt")
    try runDictionaryTool(["--export", name, output.path], directory: directory)
    return try String(contentsOf: output, encoding: .utf8).contains(row)
  }

  private static func runDictionaryTool(_ arguments: [String], directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "bin/rime_dict_manager")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw TestFailure.fixture }
  }

  private static func settingsPublicationObservation(
    request: LinnetSettingsContract.DataRequest,
    live: URL
  ) throws -> SettingsPublicationObservation {
    guard LinnetSettingsContract.validDataRequest(request),
      request.command == .refresh || request.command == .reloadConfiguration,
      let candidate = request.candidate,
      candidate.lastPathComponent == "configuration-candidate",
      candidate.deletingLastPathComponent().lastPathComponent == request.transactionID.uuidString,
      let expectedRevision = request.expectedSettingsRevision
    else { throw TestFailure.fixture }
    let candidateEntries = try FileManager.default.contentsOfDirectory(
      at: candidate,
      includingPropertiesForKeys: nil,
      options: []
    )
    guard candidateEntries.map(\.lastPathComponent) == [LinnetSettingsDocumentStore.fileName]
    else { throw TestFailure.fixture }

    let liveSnapshot = try LinnetSettingsDocumentStore.snapshot(from: live)
    let candidateSnapshot = try LinnetSettingsDocumentStore.snapshot(from: candidate)
    guard liveSnapshot.revision == expectedRevision
      || liveSnapshot.revision == request.alternateSettingsRevision
    else { throw TestFailure.fixture }
    if request.command == .refresh {
      guard candidateSnapshot.document.input == liveSnapshot.document.input,
        candidateSnapshot.document.english == liveSnapshot.document.english,
        candidateSnapshot.document.appearance.livePanelProjection(
          over: liveSnapshot.document.appearance) == candidateSnapshot.document.appearance
      else { throw TestFailure.fixture }
    }
    return SettingsPublicationObservation(
      command: request.command,
      transactionID: request.transactionID,
      expectedRevision: expectedRevision,
      alternateRevision: request.alternateSettingsRevision,
      liveRevisionBeforePublication: liveSnapshot.revision,
      candidateRevision: candidateSnapshot.revision,
      liveFilesBeforePublication: try settingsOwnedFileSnapshot(at: live)
    )
  }

  private static func publishSettingsCandidate(
    request: LinnetSettingsContract.DataRequest,
    live: URL
  ) throws -> String {
    let observation = try settingsPublicationObservation(request: request, live: live)
    guard let candidate = request.candidate else { throw TestFailure.fixture }
    let previous = try LinnetSettingsDocumentStore.snapshot(from: live)
    let desired = try LinnetSettingsDocumentStore.snapshot(from: candidate)
    if desired.document != previous.document {
      try LinnetSettingsDocumentStore.exchangeCandidateDocument(
        candidateDirectory: candidate,
        liveDirectory: live
      )
    }
    let published = try LinnetSettingsDocumentStore.snapshot(from: live)
    guard published.document == desired.document,
      published.revision == observation.candidateRevision
    else { throw TestFailure.fixture }
    try LinnetSettingsProjectionRenderer.reconcile(document: published.document, to: live)
    return published.revision
  }

  private static func rollbackSettingsCandidate(
    request: LinnetSettingsContract.DataRequest,
    live: URL
  ) throws -> String {
    guard let candidate = request.candidate else { throw TestFailure.fixture }
    let current = try LinnetSettingsDocumentStore.snapshot(from: live)
    let previous = try LinnetSettingsDocumentStore.snapshot(from: candidate)
    if previous.document != current.document {
      try LinnetSettingsDocumentStore.exchangeCandidateDocument(
        candidateDirectory: candidate,
        liveDirectory: live
      )
    }
    let restored = try LinnetSettingsDocumentStore.snapshot(from: live)
    guard restored.document == previous.document else { throw TestFailure.fixture }
    try LinnetSettingsProjectionRenderer.reconcile(document: restored.document, to: live)
    return restored.revision
  }

  private static func settingsHealth(
    activeRevision: String
  ) -> LinnetSettingsContract.RuntimeHealth {
    diagnosticHealth(status: .running, activeRevision: activeRevision)
  }

  private static func diagnosticHealth(
    status: LinnetSettingsContract.RuntimeStatus,
    activeRevision: String?
  ) -> LinnetSettingsContract.RuntimeHealth {
    let phase: LinnetSettingsContract.RuntimePhase
    switch status {
    case .running, .degraded: phase = .running
    case .paused: phase = .paused
    default: phase = .recovering
    }
    return .init(
      productIdentity: fixtureRuntimeIdentity,
      state: status,
      phase: phase,
      rimeVersion: "fixture",
      smartEnglishAvailable: true,
      octagramAvailable: true,
      availableSchemaCount: 9,
      requiredSchemaCount: 9,
      activeTransactionID: nil,
      activeSettingsRevision: activeRevision
    )
  }

  private static func reply(
    _ status: LinnetSettingsContract.RuntimeStatus,
    _ detail: String,
    request: LinnetSettingsContract.DataRequest,
    health: LinnetSettingsContract.RuntimeHealth? = nil
  ) -> LinnetSettingsContract.RuntimeReply {
    let code: LinnetSettingsContract.RuntimeReplyCode
    if detail.contains("stale") {
      code = .staleCandidate
    } else if detail.contains("resume failed") {
      code = .runtimeResumeFailed
    } else {
      switch status {
      case .running, .degraded: code = .diagnosticsReady
      case .terminating: code = .coreActivationAccepted
      case .paused: code = .runtimePaused
      case .activated: code = .activationVerified
      case .cancelled: code = .runtimeResumed
      case .rolledBack: code = .activationRolledBack
      case .rejected: code = .invalidCandidate
      case .failed: code = .rollbackFailed
      case .verifying: code = .verificationStarted
      }
    }
    return .init(
      transactionID: request.transactionID,
      status: status,
      code: code,
      detail: detail,
      health: health)
  }

  private static func swap(_ first: URL, _ second: URL) -> Bool {
    let swapped = first.path.withCString { firstPath in
      second.path.withCString { secondPath in
        renameatx_np(
          AT_FDCWD,
          firstPath,
          AT_FDCWD,
          secondPath,
          UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
        ) == 0
      }
    }
    if !swapped {
      fputs(
        "fixture rename swap failed with errno \(errno): \(first.path) <-> \(second.path)\n",
        stderr
      )
    }
    return swapped
  }

  private static func makeDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { return }
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private static func waitForEvent(
    _ event: String,
    in harness: RequestOrderHarness
  ) async throws {
    // Match the coordinator fixture's 10-second transaction timeout. Under the
    // composite Release gate the Swift task can take longer than one second to
    // reach the in-process transaction fixture even though the request is healthy.
    for _ in 0..<2_000 {
      if harness.contains(event) { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    fail("timed out waiting for request event: \(event)")
  }

  private static func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private enum TestFailure: Error { case fixture }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
      Data("SettingsDataCoordinatorTests: FAIL: \(message)\n".utf8)
    )
    exit(EXIT_FAILURE)
  }
}
