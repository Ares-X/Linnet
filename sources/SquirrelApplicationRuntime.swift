import AppKit
import Darwin
import InputMethodKit

extension SquirrelApplicationDelegate {
  func applicationWillTerminate(_ notification: Notification) {
    rimeSyncController.stop()
    removeObservers()
    transactionMonitor?.cancel()
    transactionMonitor = nil
    panel?.hide()
    shutdownRime()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }
  // MARK: Rime-owned status projection
  @discardableResult
  func setupRime(tentativeLanguageActivation: Bool = false) -> Bool {
    if !tentativeLanguageActivation {
      guard (try? SquirrelApp.dataRegistry.recoverPreparedLanguageActivation()) != nil else {
        runtimeDataSnapshot = nil
        return false
      }
    }
    let snapshot = tentativeLanguageActivation
      ? try? SquirrelApp.dataRegistry.tentativeRuntimeSnapshot()
      : try? SquirrelApp.dataRegistry.runtimeSnapshot()
    guard let snapshot else {
      runtimeDataSnapshot = nil
      return false
    }
    runtimeDataSnapshot = snapshot
    // OpenCC resolves dictionary paths relative to the one activated data
    // view. A runtime restart repeats this after Settings repairs or updates.
    FileManager.default.changeCurrentDirectoryPath(snapshot.sharedDataDirectory.path)
    do {
      try FileManager.default.createDirectory(
        at: SquirrelApp.logDir,
        withIntermediateDirectories: true)
    } catch {
      print("Error creating user data directory: \(SquirrelApp.logDir.path)")
    }
    // swiftlint:disable identifier_name
    let notification_handler:
      @convention(c) (
        UnsafeMutableRawPointer?, RimeSessionId, UnsafePointer<CChar>?, UnsafePointer<CChar>?
      ) -> Void = notificationHandler
    let context_object = Unmanaged.passUnretained(self).toOpaque()
    // swiftlint:enable identifier_name
    rimeAPI.set_notification_handler(notification_handler, context_object)

    var rimeDuoTraits = RimeTraits.rimeStructInit()
    rimeDuoTraits.setCString(snapshot.sharedDataDirectory.path, to: \.shared_data_dir)
    rimeDuoTraits.setCString(snapshot.userDataDirectory.path, to: \.user_data_dir)
    rimeDuoTraits.setCString(snapshot.prebuiltDataDirectory.path, to: \.prebuilt_data_dir)
    rimeDuoTraits.setCString(snapshot.stagingDirectory.path, to: \.staging_dir)
    rimeDuoTraits.setCString(SquirrelApp.logDir.path, to: \.log_dir)
    rimeDuoTraits.setCString(SquirrelApp.productName, to: \.distribution_code_name)
    rimeDuoTraits.setCString(SquirrelApp.productName, to: \.distribution_name)
    rimeDuoTraits.setCString(SquirrelApp.productVersion, to: \.distribution_version)
    rimeDuoTraits.setCString(SquirrelApp.rimeAppName, to: \.app_name)
    rimeAPI.setup(&rimeDuoTraits)
    return true
  }
  @discardableResult
  func startRime(fullCheck: Bool) -> Bool {
    print("Initializing la rime...")
    // Reconciliation is a pre-start boundary. Mutating projection caches while
    // an existing runtime owns them would publish bytes it has not activated.
    guard !isRimeRunning else { return activeSettingsRevision != nil }
    func failStart(_ message: String) -> Bool {
      print(message)
      isRimeInputSuspended = true
      rimeAPI.finalize()
      isRimeRunning = false
      return false
    }
    let settingsSnapshot: LinnetSettingsDocumentStore.Snapshot
    do {
      settingsSnapshot = try reconcileLiveSettings()
    } catch {
      print("Linnet settings reconciliation failed.")
      isRimeInputSuspended = true
      return false
    }
    rimeAPI.initialize(nil)
    let smartEnglishLoaded = "smart_english".withCString {
      rimeAPI.find_module($0) != nil
    }
    let octagramLoaded = "octagram".withCString {
      rimeAPI.find_module($0) != nil
    }
    guard smartEnglishLoaded, octagramLoaded else {
      // A schema with an unknown filter can still create sessions. Finalize
      // instead of silently degrading the product's English contract.
      return failStart("Required Linnet runtime component is unavailable.")
    }
    // check for configuration updates
    if rimeAPI.start_maintenance(fullCheck) {
      // Maintenance disables Service::CreateSession. Do not publish Host
      // readiness or deploy another config task until its worker has exited.
      rimeAPI.join_maintenance_thread()
      guard rimeAPI.deploy_config_file("squirrel.yaml", "config_version") else {
        return failStart("Linnet runtime configuration deployment failed.")
      }
    }
    guard warmRimeSession.prepare(using: rimeAPI) != nil else {
      return failStart("Linnet runtime session readiness check failed.")
    }
    reopenRimeInput()
    isRimeRunning = true
    activeSettingsRevision = settingsSnapshot.revision
    startStaleSessionCleaner()
    return true
  }
  /// Rebase physical modifiers before the single runtime gate is reopened.
  /// Events that passed through while Rime was suspended must not become the
  /// next Shift/Caps transition baseline.
  private func reopenRimeInput() {
    if let inputController = panel?.inputController {
      inputController.resetModifierEpoch()
    }
    isRimeInputSuspended = false
  }
  private func startStaleSessionCleaner() {
    staleSessionCleaner?.invalidate()
    staleSessionCleaner = Timer.scheduledTimer(
      withTimeInterval: Self.staleSessionCleanupInterval, repeats: true
    ) { [weak self] _ in
      guard let self, canAcceptRimeInput else { return }
      panel?.inputController?.refreshSessionLeaseForStaleCleanup()
      warmRimeSession.refresh(using: rimeAPI)
      rimeAPI.cleanup_stale_sessions()
    }
  }
  /// The typed document is durable truth; every Rime custom YAML is a cache
  /// rebuilt before an engine can accept input.
  private func reconcileLiveSettings() throws -> LinnetSettingsDocumentStore.Snapshot {
    guard let directory = runtimeDataSnapshot?.userDataDirectory else {
      throw LinnetSettingsDocumentStore.Failure.unsafePath("UserData")
    }
    let snapshot = try LinnetSettingsDocumentStore.snapshot(from: directory)
    try LinnetSettingsProjectionRenderer.reconcile(
      document: snapshot.document,
      to: directory
    )
    return snapshot
  }
  @discardableResult
  func loadSettings() -> Bool {
    let loadedConfig = SquirrelConfig()
    guard loadedConfig.openBaseConfig() else { return false }
    config = loadedConfig
    enableNotifications = loadedConfig.getString("show_notifications_when") != "never"
    showStatusIcon = loadedConfig.getBool("status_icon/show") ?? true
    refreshStatusItem()
    if let panel = panel, let config = self.config {
      panel.resetThemeCache()
      panel.load(config: config, forDarkMode: false)
      panel.load(config: config, forDarkMode: true)
    }
    return true
  }
  /// Transaction recovery is complete only when both the engine and its
  /// presentation configuration are ready. A half-started runtime must not be
  /// reported as healthy or left accepting input.
  @discardableResult
  func startReadyRuntime(fullCheck: Bool) -> Bool {
    guard startRime(fullCheck: fullCheck) else { return false }
    guard loadSettings() else {
      shutdownRime()
      return false
    }
    return true
  }
  func loadSettings(for schemaID: String) {
    if schemaID.count == 0 || schemaID.first == "." {
      return
    }
    lastLoadedSchemaID = schemaID
    // Shift toggling re-enters here on every tap; reusing themes already
    // built from an unchanged base configuration avoids re-reading the
    // schema YAML and rebuilding both appearances each time. loadSettings()
    // resets this cache whenever the base configuration is reloaded.
    if let panel = panel, panel.applyCachedThemes(for: schemaID) {
      return
    }
    let schema = SquirrelConfig()
    if let panel = panel, let config = self.config {
      if schema.open(schemaID: schemaID, baseConfig: config) && schema.has(section: "style") {
        panel.load(config: schema, forDarkMode: false)
        panel.load(config: schema, forDarkMode: true)
      } else {
        panel.load(config: config, forDarkMode: false)
        panel.load(config: config, forDarkMode: true)
      }
      panel.cacheThemes(for: schemaID)
    }
    schema.close()
  }
  // add an awakeFromNib item so that we can set the action method.  Note that
  // any menuItems without an action will be disabled when displayed in the Text
  // Input Menu.
  func addObservers() {
    removeObservers()
    let center = NSWorkspace.shared.notificationCenter
    workspacePowerOffObserver = center.addObserver(
      forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil,
      using: { [weak self] notification in
        self?.workspaceWillPowerOff(notification)
      })

    do {
      let host = try LinnetSettingsTransactionIPC.Host { [weak self] request, reply in
        DispatchQueue.main.async {
          self?.dataRequested(request, transactionReply: reply)
        }
      }
      try host.start()
      settingsTransactionHost = host
    } catch {
      settingsTransactionHost = nil
      print("Settings transaction IPC is unavailable: \(error)")
    }
    let notifCenter = DistributedNotificationCenter.default()
    notifCenter.addObserver(
      self,
      selector: #selector(inputSourceChanged(_:)),
      name: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    notifCenter.addObserver(
      self,
      selector: #selector(cloudSyncConfigurationChanged(_:)),
      name: LinnetSettingsContract.cloudSyncConfigurationDidChange,
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    notifCenter.addObserver(
      self,
      selector: #selector(cloudSyncNowRequested(_:)),
      name: LinnetSettingsContract.cloudSyncNowRequested,
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
  }
  func removeObservers() {
    if let workspacePowerOffObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspacePowerOffObserver)
      self.workspacePowerOffObserver = nil
    }
    settingsTransactionHost?.stop()
    settingsTransactionHost = nil
    let distributed = DistributedNotificationCenter.default()
    distributed.removeObserver(
      self,
      name: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil
    )
    distributed.removeObserver(
      self,
      name: LinnetSettingsContract.cloudSyncConfigurationDidChange,
      object: nil
    )
    distributed.removeObserver(
      self,
      name: LinnetSettingsContract.cloudSyncNowRequested,
      object: nil
    )
  }
  @objc private func cloudSyncConfigurationChanged(_: Notification) {
    DispatchQueue.main.async { [weak self] in self?.rimeSyncController.reload() }
  }
  @objc private func cloudSyncNowRequested(_: Notification) {
    DispatchQueue.main.async { [weak self] in self?.rimeSyncController.synchronizeNow() }
  }
}

extension SquirrelApplicationDelegate {
  func performRimeUserDataSync() -> LinnetRimeSyncOutcome {
    guard activeDataTransaction == nil, canAcceptRimeInput else { return .busy }
    let activeController = panel?.inputController
    if panel?.isVisible == true || activeController?.hasPendingRimeInput == true {
      return .busy
    }
    isRimeInputSuspended = true
    activeController?.prepareForRimeMaintenance()
    panel?.hide()
    // librime sync owns CleanupAllSessions. The warm session is the single
    // process-level preload owner; it never owns an application's composition,
    // caret, or candidate publication state. Retire its identifier before the
    // cleanup boundary so no stale session survives. Once sync finishes,
    // recreate only that resource owner before reopening input; every client
    // session continues to be created by its own InputMethodKit controller.
    warmRimeSession.retire()
    let synchronized = rimeAPI.sync_user_data()
    if synchronized {
      rimeAPI.join_maintenance_thread()
    }
    let resourcesReady = warmRimeSession.prepare(using: rimeAPI) != nil
    reopenRimeInput()
    return synchronized && resourcesReady ? .completed : .failed
  }
  // Finish the one current composition, close the input gate, then invalidate
  // every controller's Rime generation. Controllers recover on their next key.
  private func invalidateRimeSessions() {
    if let inputController = panel?.inputController {
      if canAcceptRimeInput {
        inputController.commitCurrentComposition()
      }
    }
    isRimeInputSuspended = true
    panel?.hide()
    warmRimeSession.retire()
    rimeAPI.cleanup_all_sessions()
  }
  // Tear down the runtime in the order librime-lua requires: destroy every
  // session while the Lua state is open, then finalize Registry/lua state.
  func shutdownRime() {
    guard isRimeRunning else {
      config?.close()
      return
    }
    staleSessionCleaner?.invalidate()
    staleSessionCleaner = nil
    invalidateRimeSessions()
    config?.close()
    rimeAPI.finalize()
    isRimeRunning = false
  }
  fileprivate func dataRequested(
    _ request: LinnetSettingsContract.DataRequest,
    transactionReply: @escaping LinnetSettingsTransactionIPC.Reply
  ) {
    currentTransactionReply = (request.transactionID, transactionReply)
    defer { currentTransactionReply = nil }
    switch request.command {
    case .pause:
      pauseForDataTransaction(request)
    case .activate:
      activateDataTransaction(request)
    case .activateLanguage:
      activateDataTransaction(request)
    case .cancel:
      cancelDataTransaction(request)
    case .diagnose:
      let health = runtimeHealth()
      reply(
        to: request.transactionID,
        status: health.state,
        code: .diagnosticsReady,
        detail: "Runtime diagnostics are available.",
        health: health
      )
    case .activateCore:
      activateInstalledCore(request)
    case .refresh:
      publishSettingsCandidate(request, scope: .appearance)
    case .reloadConfiguration:
      publishSettingsCandidate(request, scope: .configuration)
    }
  }

  /// The user may request an immediate Core replacement, but the Host alone
  /// owns the exit decision. Historical client applications must have really
  /// terminated; controller deinit and input-source switching are not accepted
  /// as connection-release evidence.
  private func activateInstalledCore(_ request: LinnetSettingsContract.DataRequest) {
    guard LinnetSettingsContract.requestCanContinue(request) else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .coreActivationRequesterUnavailable,
        detail: "The Core activation requester is unavailable."
      )
      return
    }
    let history = SquirrelInputController.coreActivationClientLedger.snapshot()
    let decision = coreActivationDecision(
      requesterPID: request.requesterPID,
      history: history
    )
    guard decision.isReady else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: coreActivationReplyCode(for: decision.blocker),
        detail: coreActivationDiagnostic(decision)
      )
      return
    }

    reply(
      to: request.transactionID,
      status: .terminating,
      code: .coreActivationAccepted,
      detail: "The explicit Core activation drain was accepted."
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      let finalHistory = SquirrelInputController.coreActivationClientLedger.snapshot()
      guard LinnetSettingsContract.requestCanContinue(request),
        finalHistory.generation == history.generation,
        coreActivationDecision(
          requesterPID: request.requesterPID,
          history: finalHistory
        ).isReady
      else { return }
      NSApp.terminate(nil)
    }
  }

  private func coreActivationDecision(
    requesterPID: Int32,
    history: LinnetInputClientLedger.Snapshot
  ) -> LinnetCoreActivationGate.Decision {
    let runningApplications = NSWorkspace.shared.runningApplications
      .filter { !$0.isTerminated }
      .map {
        LinnetCoreActivationGate.RunningApplication(
          processIdentifier: $0.processIdentifier,
          bundleIdentifier: $0.bundleIdentifier,
          displayName: $0.localizedName ?? $0.bundleIdentifier ?? "Unknown application"
        )
      }
    return LinnetCoreActivationGate.evaluate(
      inputSourceIsActive:
        SquirrelInstaller.currentInputSourceID() == SquirrelApp.bundleIdentifier,
      compositionIsActive:
        panel?.isVisible == true || panel?.inputController?.hasPendingRimeInput == true,
      dataTransactionIsActive: activeDataTransaction != nil,
      history: history,
      runningApplications: runningApplications,
      requesterPID: requesterPID
    )
  }

  private func coreActivationReplyCode(
    for blocker: LinnetSettingsContract.CoreActivationBlocker?
  ) -> LinnetSettingsContract.RuntimeReplyCode {
    switch blocker {
    case .inputSourceActive: .coreActivationInputSourceActive
    case .compositionActive: .coreActivationCompositionActive
    case .dataTransactionActive: .coreActivationDataTransactionActive
    case .applicationsStillRunning: .coreActivationApplicationsRunning
    case .unknownClient: .coreActivationUnknownClient
    case .requesterUnavailable, nil: .coreActivationRequesterUnavailable
    }
  }

  private func coreActivationDiagnostic(
    _ decision: LinnetCoreActivationGate.Decision
  ) -> String {
    guard !decision.applications.isEmpty else {
      return "The explicit Core activation drain is not safe."
    }
    return "Applications still connected during Core activation: "
      + decision.applications.joined(separator: ", ")
  }

  private enum SettingsPublicationScope: Equatable {
    case appearance
    case configuration
    var failureCode: LinnetSettingsContract.RuntimeReplyCode {
      switch self {
      case .appearance: .appearanceDeployFailed
      case .configuration: .configurationReloadFailed
      }
    }

    var successCode: LinnetSettingsContract.RuntimeReplyCode {
      switch self {
      case .appearance: .appearanceApplied
      case .configuration: .configurationApplied
      }
    }
  }

  private struct SettingsPublicationCandidate {
    let candidate: URL
    let live: URL
    let previous: LinnetSettingsDocumentStore.Snapshot
    let desired: LinnetSettingsDocumentStore.Snapshot
  }

  /// The only live settings publication owner. The document swap is the
  /// durable commit point; all YAML projections are rebuilt caches. A process
  /// exit after the swap is recovered by startRime() before input is accepted.
  private func publishSettingsCandidate(
    _ request: LinnetSettingsContract.DataRequest,
    scope: SettingsPublicationScope
  ) {
    guard let health = settingsPublicationHealth(request, scope: scope),
      let prepared = prepareSettingsPublication(request, scope: scope, health: health)
    else { return }
    let candidate = prepared.candidate
    let live = prepared.live
    let previous = prepared.previous
    let desired = prepared.desired
    let shouldExchange = desired.document != previous.document
    do {
      if shouldExchange {
        try LinnetSettingsDocumentStore.exchangeCandidateDocument(
          candidateDirectory: candidate,
          liveDirectory: live
        )
      }
      let published = try LinnetSettingsDocumentStore.snapshot(from: live)
      guard published.document == desired.document else {
        throw LinnetSettingsDocumentStore.Failure.malformedDocument
      }
      try LinnetSettingsProjectionRenderer.reconcile(
        document: published.document,
        to: live
      )
      guard activatePublishedSettings(scope) else {
        throw LinnetSettingsDocumentStore.Failure.malformedDocument
      }
      activeSettingsRevision = published.revision
      let activatedHealth = runtimeHealth()
      guard activatedHealth.state == .running else {
        throw LinnetSettingsDocumentStore.Failure.malformedDocument
      }
      reply(
        to: request.transactionID,
        status: .activated,
        code: scope.successCode,
        detail: "Settings document published and activated.",
        health: activatedHealth
      )
    } catch {
      guard shouldExchange,
        rollbackSettingsPublication(candidate: candidate, live: live, scope: scope)
      else {
        activeSettingsRevision = nil
        isRimeInputSuspended = true
        panel?.hide()
        reply(
          to: request.transactionID,
          status: .failed,
          code: .rollbackFailed,
          detail: "Settings activation failed and rollback could not be verified.",
          health: degradedHealth(phase: .recovering)
        )
        return
      }
      reply(
        to: request.transactionID,
        status: .failed,
        code: scope.failureCode,
        detail: "Settings activation failed; the previous document was restored.",
        health: runtimeHealth()
      )
    }
  }

  private func settingsPublicationHealth(
    _ request: LinnetSettingsContract.DataRequest,
    scope: SettingsPublicationScope
  ) -> LinnetSettingsContract.RuntimeHealth? {
    guard LinnetSettingsContract.requestCanContinue(request) else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .requesterUnavailable,
        detail: "The requester is unavailable or its deadline expired."
      )
      return nil
    }
    guard activeDataTransaction == nil else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .transactionBusy,
        detail: "Another settings transaction is active."
      )
      return nil
    }
    let health = runtimeHealth()
    guard canAcceptRimeInput, health.state == .running else {
      reply(
        to: request.transactionID,
        status: .failed,
        code: scope.failureCode,
        detail: "Settings cannot be applied while the input runtime is unavailable.",
        health: health
      )
      return nil
    }
    return health
  }

  private func prepareSettingsPublication(
    _ request: LinnetSettingsContract.DataRequest,
    scope: SettingsPublicationScope,
    health: LinnetSettingsContract.RuntimeHealth
  ) -> SettingsPublicationCandidate? {
    guard let candidate = request.candidate,
      let expectedRevision = request.expectedSettingsRevision,
      let live = runtimeDataSnapshot?.userDataDirectory,
      validateCandidate(
        candidate,
        live: live,
        candidateName: "configuration-candidate",
        transactionID: request.transactionID
      ),
      validConfigurationCandidate(candidate)
    else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .invalidCandidate,
        detail: "The settings candidate is invalid.",
        health: health
      )
      return nil
    }

    let previous: LinnetSettingsDocumentStore.Snapshot
    let desired: LinnetSettingsDocumentStore.Snapshot
    do {
      previous = try LinnetSettingsDocumentStore.snapshot(from: live)
      desired = try LinnetSettingsDocumentStore.snapshot(from: candidate)
    } catch {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .invalidCandidate,
        detail: "The settings candidate could not be decoded.",
        health: health
      )
      return nil
    }

    let acceptedRevision = previous.revision == expectedRevision
      || previous.revision == request.alternateSettingsRevision
    guard acceptedRevision else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .staleCandidate,
        detail: "The live settings document changed after this candidate was prepared.",
        health: health
      )
      return nil
    }
    if scope == .appearance {
      guard desired.document.input == previous.document.input,
        desired.document.english == previous.document.english,
        desired.document.appearance.livePanelProjection(
          over: previous.document.appearance) == desired.document.appearance
      else {
        reply(
          to: request.transactionID,
          status: .rejected,
          code: .invalidCandidate,
          detail: "The appearance candidate contains Apply-only settings.",
          health: health
        )
        return nil
      }
    }
    return .init(candidate: candidate, live: live, previous: previous, desired: desired)
  }

  private func rollbackSettingsPublication(
    candidate: URL,
    live: URL,
    scope: SettingsPublicationScope
  ) -> Bool {
    do {
      try LinnetSettingsDocumentStore.exchangeCandidateDocument(
        candidateDirectory: candidate,
        liveDirectory: live
      )
      let restored = try LinnetSettingsDocumentStore.snapshot(from: live)
      try LinnetSettingsProjectionRenderer.reconcile(
        document: restored.document,
        to: live
      )
      guard activatePublishedSettings(scope) else { return false }
      activeSettingsRevision = restored.revision
      return runtimeHealth().state == .running
    } catch {
      return false
    }
  }

  private func activatePublishedSettings(_ scope: SettingsPublicationScope) -> Bool {
    switch scope {
    case .appearance:
      let activeSchemaID = lastLoadedSchemaID
      config?.close()
      config = nil
      guard rimeAPI.deploy_config_file("squirrel.yaml", "config_version"),
        loadSettings()
      else { return false }
      if let activeSchemaID { loadSettings(for: activeSchemaID) }
      panel?.refreshAppearance()
      return true

    case .configuration:
      guard isRimeRunning,
        let live = runtimeDataSnapshot?.userDataDirectory,
        let settingsSnapshot = try? LinnetSettingsDocumentStore.snapshot(from: live),
        deployConfigurationReloadTargets()
      else { return false }
      invalidateRimeSessions()
      config?.close()
      config = nil

      guard loadSettings() else { return false }
      let selectedProfile = settingsSnapshot.document.input.chineseProfile

      // The typed Settings document is the sole profile intent owner.
      // The compiled schema is deployment output and must never select intent.
      // Readiness below only compares that intent with the fresh session,
      // so a stale or mismatched deployment fails before acknowledgement.
      guard let readinessSession = warmRimeSession.prepare(using: rimeAPI) else {
        return false
      }
      var activeSchemaBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      let readActiveSchema = activeSchemaBuffer.withUnsafeMutableBufferPointer { buffer in
        rimeAPI.get_current_schema(readinessSession, buffer.baseAddress, buffer.count)
      }
      let activeSchemaID = readActiveSchema ? String(cString: activeSchemaBuffer) : ""
      guard readActiveSchema, activeSchemaID == selectedProfile.schemaID else {
        warmRimeSession.discard(using: rimeAPI)
        return false
      }
      let asciiMode = rimeAPI.get_option(readinessSession, "ascii_mode")
      let schemaLabel = rimeAPI.get_state_label_abbreviated(
        readinessSession, "ascii_mode", asciiMode, true).asString
      loadSettings(for: activeSchemaID)
      panel?.refreshAppearance()
      reopenRimeInput()
      applyStatusIcon(asciiMode: asciiMode, schemaLabel: schemaLabel)
      return true
    }
  }

  private func validConfigurationCandidate(_ candidate: URL) -> Bool {
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: candidate,
      includingPropertiesForKeys: nil,
      options: []
    ), children.count == 1,
      children[0].lastPathComponent == LinnetSettingsDocumentStore.fileName
    else { return false }
    var info = stat()
    return lstat(children[0].path, &info) == 0
      && (info.st_mode & S_IFMT) == S_IFREG
      && info.st_uid == getuid()
  }

  private func deployConfigurationReloadTargets() -> Bool {
    for target in Self.configurationReloadTargets {
      let deployed = target.fileName.withCString { fileName in
        target.versionKey.withCString { versionKey in
          rimeAPI.deploy_config_file(fileName, versionKey)
        }
      }
      guard deployed else { return false }
    }
    return true
  }

}
