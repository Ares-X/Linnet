//
//  SquirrelApplicationDelegate.swift
//  Squirrel
//
//  Created by Leo Liu on 5/6/24.
//

import AppKit
import Darwin
import InputMethodKit
import UserNotifications

final class SquirrelApplicationDelegate: NSObject, NSApplicationDelegate {
  private struct ActiveDataTransaction {
    let transactionID: UUID
    let requesterPID: Int32
    let deadline: Date
    let expectedActiveGeneration: Int?
    let expectedActiveStateSHA256: String?
    var phase: LinnetSettingsContract.RuntimePhase
  }

  static var notificationIdentifier: String { "\(SquirrelApp.bundleIdentifier).notification" }
  // A requester picks its own transaction deadline; never let a far-future
  // deadline park the input runtime (or its cancellation marker) forever.
  private static let maximumDataTransactionDuration: TimeInterval = 300
  // librime keeps one session per client application and never reaps the
  // ones whose owner went away, so memory only grows. Recycle them
  // periodically; CleanupStaleSessions only destroys sessions idle beyond
  // Session::kLifeSpan.
  private static let staleSessionCleanupInterval: TimeInterval = 600
  // Direct config deployment is intentionally exhaustive and ordered. These
  // are the only compiled YAML files document-only Settings can affect; data
  // dictionaries stay outside this low-latency boundary.
  private static let configurationReloadTargets: [(fileName: String, versionKey: String)] = [
    (fileName: "default.yaml", versionKey: "config_version"),
    (fileName: "linnet_en.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh_pinyin.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh_flypy.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh_mspy.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh_sogou.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh_abc.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh_ziguang.schema.yaml", versionKey: "schema/version"),
    (fileName: "linnet_zh_jiajia.schema.yaml", versionKey: "schema/version"),
    (fileName: "squirrel.yaml", versionKey: "config_version")
  ]
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  var config: SquirrelConfig?
  var panel: SquirrelPanel?
  var enableNotifications = false
  var showStatusIcon = true
  var statusItem: NSStatusItem?
  var currentModeLabel = "中"
  private var activeSettingsRevision: String?
  private var activeDataTransaction: ActiveDataTransaction?
  private var transactionMonitor: DispatchSourceTimer?
  private var staleSessionCleaner: Timer?
  private let warmRimeSession = LinnetRimeWarmSession()
  private var workspacePowerOffObserver: NSObjectProtocol?
  private var settingsTransactionHost: LinnetSettingsTransactionIPC.Host?
  private var currentTransactionReply:
    (UUID, LinnetSettingsTransactionIPC.Reply)?
  private var lastLoadedSchemaID: String?
  private var cancelledBeforePause: [UUID: Date] = [:]
  // Runtime lifecycle guards for the pinned librime-lua lifetime patch:
  // isRimeRunning tracks one initialized runtime so RimeFinalize runs at most
  // once per startRime; isRimeInputSuspended is the single input gate across
  // finalization and fail-closed in-process configuration recovery.
  private(set) var isRimeRunning = false
  private(set) var isRimeInputSuspended = false
  var canAcceptRimeInput: Bool {
    isRimeRunning && !isRimeInputSuspended
  }
  // setupRime ran at most once per process; an explicit runtime retry needs to
  // know whether the traits/notification handler are already in place.
  private var runtimeDataSnapshot: LinnetDataRegistry.RuntimeSnapshot?
  private lazy var rimeSyncController = LinnetRimeSyncController(
    loadConfiguration: {
      let syncDirectory: URL?
      if LinnetSettingsContract.cloudSyncEnabled() {
        do {
          syncDirectory = try LinnetCloudSyncLocation.productLocation()
            .prepareLearningDirectory()
        } catch {
          syncDirectory = nil
          print("The Linnet iCloud Drive folder is unavailable: \(error.localizedDescription)")
        }
      } else {
        syncDirectory = nil
      }
      return .init(
        userDirectory: SquirrelApp.userDir,
        syncDirectory: syncDirectory,
        lastAttempt: LinnetSettingsContract.cloudSyncLastAttempt())
    },
    recordAttempt: { LinnetSettingsContract.setCloudSyncLastAttempt($0) },
    operation: { [weak self] in self?.performRimeUserDataSync() ?? .failed }
  )
  func applicationWillFinishLaunching(_ notification: Notification) {
    panel = SquirrelPanel(position: .zero)
    addObservers()
    refreshStatusItem()
    rimeSyncController.start()
  }
  deinit {
    removeObservers()
  }
}
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
    createDirIfNotExist(path: SquirrelApp.logDir)
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
  private func startReadyRuntime(fullCheck: Bool) -> Bool {
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
  private func removeObservers() {
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
  private func performRimeUserDataSync() -> LinnetRimeSyncOutcome {
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

  /// The only live settings publication owner. The document swap is the
  /// durable commit point; all YAML projections are rebuilt caches. A process
  /// exit after the swap is recovered by startRime() before input is accepted.
  private func publishSettingsCandidate(
    _ request: LinnetSettingsContract.DataRequest,
    scope: SettingsPublicationScope
  ) {
    guard LinnetSettingsContract.requestCanContinue(request) else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .requesterUnavailable,
        detail: "The requester is unavailable or its deadline expired."
      )
      return
    }
    guard activeDataTransaction == nil else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .transactionBusy,
        detail: "Another settings transaction is active."
      )
      return
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
      return
    }
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
      return
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
      return
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
      return
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
        return
      }
    }

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

  fileprivate func pauseForDataTransaction(_ request: LinnetSettingsContract.DataRequest) {
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

  fileprivate func cancelDataTransaction(_ request: LinnetSettingsContract.DataRequest) {
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

  fileprivate func activateDataTransaction(_ request: LinnetSettingsContract.DataRequest) {
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

  fileprivate func startTransactionMonitor() {
    transactionMonitor?.cancel()
    let monitor = DispatchSource.makeTimerSource(queue: .main)
    monitor.schedule(deadline: .now() + 1, repeating: 1)
    monitor.setEventHandler { [weak self] in self?.recoverAbandonedDataTransaction() }
    transactionMonitor = monitor
    monitor.resume()
  }

  fileprivate func clampedDeadline(_ deadline: Date) -> Date {
    min(deadline, Date().addingTimeInterval(Self.maximumDataTransactionDuration))
  }

  fileprivate func recoverAbandonedDataTransaction() {
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

  fileprivate func finishDataTransaction() {
    transactionMonitor?.cancel()
    transactionMonitor = nil
    activeDataTransaction = nil
  }

  fileprivate func resumeCurrentRuntime() -> LinnetSettingsContract.RuntimeHealth {
    guard startReadyRuntime(fullCheck: false) else {
      return degradedHealth(phase: .recovering)
    }
    return runtimeHealth()
  }

  func runtimeHealth() -> LinnetSettingsContract.RuntimeHealth {
    let activation = coreActivationState(dataTransactionActive: activeDataTransaction != nil)
    if let active = activeDataTransaction, active.phase == .paused {
      return .init(
        productIdentity: LinnetSettingsContract.productIdentity(),
        coreActivationReadiness: activation.readiness,
        connectedInputClientCount: activation.connectedClientCount,
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
      productIdentity: LinnetSettingsContract.productIdentity(),
      coreActivationReadiness: activation.readiness,
      connectedInputClientCount: activation.connectedClientCount,
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

  fileprivate var requiredSchemas: [String] {
    LinnetSettingsContract.ChineseProfile.allCases.map(\.schemaID)
      + [LinnetSettingsContract.englishSchemaID]
  }
  fileprivate func degradedHealth(
    phase: LinnetSettingsContract.RuntimePhase
  ) -> LinnetSettingsContract.RuntimeHealth {
    let activation = coreActivationState(dataTransactionActive: activeDataTransaction != nil)
    return .init(
      productIdentity: LinnetSettingsContract.productIdentity(),
      coreActivationReadiness: activation.readiness,
      connectedInputClientCount: activation.connectedClientCount,
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
  fileprivate func validateCandidate(
    _ candidate: URL,
    live: URL,
    candidateName: String,
    transactionID: UUID
  ) -> Bool {
    guard
      let transactionsRoot = LinnetSettingsContract.dataTransactionsRoot()?
        .standardizedFileURL
    else {
      return false
    }
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

  fileprivate func secureDirectory(_ directory: URL) -> Bool {
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid()
    else {
      return false
    }
    return (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
  }

  fileprivate func swapDirectories(_ first: URL, _ second: URL) -> Bool {
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

  fileprivate func createDirIfNotExist(path: URL) {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: path.path) {
      do {
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
      } catch {
        print("Error creating user data directory: \(path.path)")
      }
    }
  }
}
