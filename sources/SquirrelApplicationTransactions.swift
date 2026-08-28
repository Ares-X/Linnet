import Darwin
import Foundation

extension SquirrelApplicationDelegate {
  func pauseForDataTransaction(_ request: LinnetSettingsContract.DataRequest) {
    cancelledBeforePause = cancelledBeforePause.filter { $0.value > Date() }
    if cancelledBeforePause.removeValue(forKey: request.transactionID) != nil {
      reply(
        to: request.transactionID,
        status: .cancelled,
        code: .cancelledBeforePause,
        detail: "The data operation was cancelled before runtime pause."
      )
      return
    }
    guard activeDataTransaction == nil else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .transactionBusy,
        detail: "Another data operation is active."
      )
      return
    }
    guard LinnetSettingsContract.requestCanContinue(request) else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .requesterUnavailable,
        detail: "The requester is unavailable or its deadline expired."
      )
      return
    }
    shutdownRime()
    activeDataTransaction = .init(
      transactionID: request.transactionID,
      requesterPID: request.requesterPID,
      deadline: clampedDeadline(request.deadline),
      expectedActiveGeneration: request.expectedActiveGeneration,
      expectedActiveStateSHA256: request.expectedActiveStateSHA256,
      phase: .paused
    )
    startTransactionMonitor()
    reply(
      to: request.transactionID,
      status: .paused,
      code: .runtimePaused,
      detail: "Input runtime paused."
    )
  }

  func cancelDataTransaction(_ request: LinnetSettingsContract.DataRequest) {
    guard let active = activeDataTransaction else {
      cancelledBeforePause[request.transactionID] = clampedDeadline(request.deadline)
      reply(
        to: request.transactionID,
        status: .cancelled,
        code: .cancelledBeforePause,
        detail: "The data operation was cancelled before runtime pause."
      )
      return
    }
    guard
      active.transactionID == request.transactionID,
      active.requesterPID == request.requesterPID,
      active.phase == .paused
    else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .operationNotCancellable,
        detail: "The data operation is not cancellable."
      )
      return
    }
    finishDataTransaction()
    let health = resumeCurrentRuntime()
    guard health.state == .running else {
      reply(
        to: request.transactionID,
        status: .failed,
        code: .runtimeResumeFailed,
        detail: "The original runtime could not resume.",
        health: health
      )
      return
    }
    reply(
      to: request.transactionID,
      status: .cancelled,
      code: .runtimeResumed,
      detail: "Original data resumed.",
      health: health
    )
  }

  func activateDataTransaction(_ request: LinnetSettingsContract.DataRequest) {
    let languageActivation = request.command == .activateLanguage
    let live =
      languageActivation
      ? SquirrelApp.dataRegistry.activeSharedDataDirectory.standardizedFileURL
      : SquirrelApp.userDir.standardizedFileURL
    let candidateName = languageActivation ? "language-active" : "candidate"
    guard var active = activeDataTransaction,
      active.transactionID == request.transactionID,
      active.requesterPID == request.requesterPID,
      active.phase == .paused,
      let candidate = request.candidate,
      validateCandidate(
        candidate,
        live: live,
        candidateName: candidateName,
        transactionID: request.transactionID
      )
    else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .invalidCandidate,
        detail: "Candidate data is invalid."
      )
      return
    }
    if languageActivation {
      guard active.expectedActiveGeneration == request.expectedActiveGeneration,
        active.expectedActiveStateSHA256 == request.expectedActiveStateSHA256,
        let expectedGeneration = request.expectedActiveGeneration,
        let expectedDigest = request.expectedActiveStateSHA256,
        let liveRevision = try? SquirrelApp.dataRegistry.activeRevision(),
        liveRevision.generation == expectedGeneration,
        liveRevision.stateSHA256 == expectedDigest
      else {
        reply(
          to: request.transactionID,
          status: .rejected,
          code: .staleCandidate,
          detail: "Language data changed after this activation candidate was prepared."
        )
        return
      }
    } else if active.expectedActiveGeneration != nil
      || active.expectedActiveStateSHA256 != nil
      || request.expectedActiveGeneration != nil
      || request.expectedActiveStateSHA256 != nil {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .invalidCandidate,
        detail: "Candidate data is invalid."
      )
      return
    }
    active.phase = .activating
    activeDataTransaction = active
    transactionMonitor?.cancel()
    transactionMonitor = nil

    guard swapDirectories(live, candidate) else {
      finishDataTransaction()
      let health = resumeCurrentRuntime()
      reply(
        to: request.transactionID,
        status: .failed,
        code:
          health.state == .running
          ? .activationFailedRuntimeResumed : .activationFailedRuntimeUnavailable,
        detail:
          health.state == .running
          ? "Candidate activation failed; the original data was resumed."
          : "Candidate activation failed and the original runtime could not resume.",
        health: health
      )
      return
    }

    active.phase = .verifying
    activeDataTransaction = active
    reply(
      to: request.transactionID,
      status: .verifying,
      code: .verificationStarted,
      detail: "Candidate activated; runtime verification is in progress."
    )
    let setup = !languageActivation || setupRime(tentativeLanguageActivation: true)
    let started = setup && startReadyRuntime(fullCheck: false)
    let health = started ? runtimeHealth() : degradedHealth(phase: .verifying)
    var committed = !languageActivation
    if started, health.state == .running, languageActivation {
      committed = (try? SquirrelApp.dataRegistry.commitDataChannelUpdate(
        transactionID: request.transactionID)) != nil
    }
    if started, health.state == .running, committed {
      finishDataTransaction()
      reply(
        to: request.transactionID,
        status: .activated,
        code: .activationVerified,
        detail: "Data operation activated and verified.",
        health: health
      )
      return
    }

    if started { shutdownRime() }
    if swapDirectories(live, candidate) {
      let restoredSetup = !languageActivation || setupRime()
      let restored = restoredSetup && startReadyRuntime(fullCheck: false)
      let restoredHealth = restored ? runtimeHealth() : degradedHealth(phase: .recovering)
      finishDataTransaction()
      reply(
        to: request.transactionID,
        status: .rolledBack,
        code: .activationRolledBack,
        detail: "The new data failed health checks; the original data was restored.",
        health: restoredHealth
      )
    } else {
      finishDataTransaction()
      reply(
        to: request.transactionID,
        status: .failed,
        code: .rollbackFailed,
        detail: "Data rollback failed; restart the input method before typing.",
        health: degradedHealth(phase: .recovering)
      )
    }
  }

  func startTransactionMonitor() {
    transactionMonitor?.cancel()
    let monitor = DispatchSource.makeTimerSource(queue: .main)
    monitor.schedule(deadline: .now() + 1, repeating: 1)
    monitor.setEventHandler { [weak self] in self?.recoverAbandonedDataTransaction() }
    transactionMonitor = monitor
    monitor.resume()
  }

  func clampedDeadline(_ deadline: Date) -> Date {
    min(deadline, Date().addingTimeInterval(Self.maximumDataTransactionDuration))
  }

  func recoverAbandonedDataTransaction() {
    guard let active = activeDataTransaction, active.phase == .paused else { return }
    let reason: String
    let code: LinnetSettingsContract.RuntimeReplyCode
    if Date() >= active.deadline {
      reason = "The data operation deadline expired; original data resumed."
      code = .deadlineExpired
    } else if !LinnetSettingsContract.requesterIsAlive(active.requesterPID) {
      reason = "The Settings process exited; original data resumed."
      code = .requesterExited
    } else {
      return
    }
    finishDataTransaction()
    let health = resumeCurrentRuntime()
    reply(
      to: active.transactionID,
      status: .failed,
      code: code,
      detail: reason,
      health: health
    )
  }

  func finishDataTransaction() {
    transactionMonitor?.cancel()
    transactionMonitor = nil
    activeDataTransaction = nil
  }

  func resumeCurrentRuntime() -> LinnetSettingsContract.RuntimeHealth {
    guard startReadyRuntime(fullCheck: false) else {
      return degradedHealth(phase: .recovering)
    }
    return runtimeHealth()
  }

  func runtimeHealth() -> LinnetSettingsContract.RuntimeHealth {
    if let active = activeDataTransaction, active.phase == .paused {
      return .init(
        productIdentity: processProductIdentity,
        state: .paused,
        phase: .paused,
        rimeVersion: rimeVersion(),
        smartEnglishAvailable: false,
        octagramAvailable: false,
        availableSchemaCount: 0,
        requiredSchemaCount: requiredSchemas.count,
        activeTransactionID: active.transactionID,
        activeSettingsRevision: activeSettingsRevision
      )
    }
    let smartEnglishLoaded = "smart_english".withCString {
      rimeAPI.find_module($0) != nil
    }
    let octagramLoaded = "octagram".withCString {
      rimeAPI.find_module($0) != nil
    }
    var deployedSchemas = Set<String>()
    var schemaList = RimeSchemaList()
    if rimeAPI.get_schema_list(&schemaList) {
      defer { rimeAPI.free_schema_list(&schemaList) }
      if let entries = schemaList.list {
        for index in 0..<Int(schemaList.size) {
          guard let schemaID = entries[index].schema_id,
            let schemaName = entries[index].name,
            schemaID.pointee != 0,
            schemaName.pointee != 0
          else { continue }
          deployedSchemas.insert(String(cString: schemaID))
        }
      }
    }
    let available = Set(requiredSchemas).intersection(deployedSchemas).count
    let healthy = isRimeRunning && !isRimeInputSuspended
      && smartEnglishLoaded && octagramLoaded && available == requiredSchemas.count
      && activeSettingsRevision != nil
    return .init(
      productIdentity: processProductIdentity,
      state: healthy ? .running : .degraded,
      phase: activeDataTransaction?.phase ?? .running,
      rimeVersion: rimeVersion(),
      smartEnglishAvailable: smartEnglishLoaded,
      octagramAvailable: octagramLoaded,
      availableSchemaCount: available,
      requiredSchemaCount: requiredSchemas.count,
      activeTransactionID: activeDataTransaction?.transactionID,
      activeSettingsRevision: activeSettingsRevision
    )
  }

  var requiredSchemas: [String] {
    LinnetSettingsContract.ChineseProfile.allCases.map(\.schemaID)
      + [LinnetSettingsContract.englishSchemaID]
  }
  func degradedHealth(
    phase: LinnetSettingsContract.RuntimePhase
  ) -> LinnetSettingsContract.RuntimeHealth {
    return .init(
      productIdentity: processProductIdentity,
      state: .degraded,
      phase: phase,
      rimeVersion: rimeVersion(),
      smartEnglishAvailable: false,
      octagramAvailable: false,
      availableSchemaCount: 0,
      requiredSchemaCount: requiredSchemas.count,
      activeTransactionID: activeDataTransaction?.transactionID,
      activeSettingsRevision: activeSettingsRevision
    )
  }
  func validateCandidate(
    _ candidate: URL,
    live: URL,
    candidateName: String,
    transactionID: UUID
  ) -> Bool {
    let transactionsRoot = SquirrelApp.dataRegistry.transactionsDirectory.standardizedFileURL
    let candidate = candidate.standardizedFileURL
    let transactionDirectory = candidate.deletingLastPathComponent()
    let rootPrefix =
      transactionsRoot.path.hasSuffix("/")
      ? transactionsRoot.path : transactionsRoot.path + "/"
    guard candidate.path.hasPrefix(rootPrefix),
      candidate.lastPathComponent == candidateName,
      transactionDirectory.deletingLastPathComponent() == transactionsRoot,
      UUID(uuidString: transactionDirectory.lastPathComponent) == transactionID,
      candidate.resolvingSymlinksInPath() == candidate,
      live.resolvingSymlinksInPath() == live,
      secureDirectory(transactionsRoot),
      secureDirectory(transactionDirectory),
      secureDirectory(candidate),
      secureDirectory(live)
    else {
      return false
    }

    var liveInfo = stat()
    var candidateInfo = stat()
    guard lstat(live.path, &liveInfo) == 0,
      lstat(candidate.path, &candidateInfo) == 0
    else {
      return false
    }
    return liveInfo.st_dev == candidateInfo.st_dev
  }

  func secureDirectory(_ directory: URL) -> Bool {
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid()
    else {
      return false
    }
    return (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
  }

  func swapDirectories(_ first: URL, _ second: URL) -> Bool {
    first.path.withCString { firstPath in
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
  }

  func reply(
    to transactionID: UUID,
    status: LinnetSettingsContract.RuntimeStatus,
    code: LinnetSettingsContract.RuntimeReplyCode,
    detail: String,
    health: LinnetSettingsContract.RuntimeHealth? = nil
  ) {
    guard let currentTransactionReply,
      currentTransactionReply.0 == transactionID
    else { return }
    currentTransactionReply.1(
      .init(
        transactionID: transactionID,
        status: status,
        code: code,
        detail: detail,
        health: health))
  }

}
