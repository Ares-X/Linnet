//
//  SettingsContract.swift
//  Shared by the input method and its embedded Settings application.
//

import Darwin
import Foundation

enum LinnetSettingsContract {
  static let expandedCandidateCountRange = 5...7
  static let horizontalExpandedGridRange = 3...5

  static let englishSchemaID = "linnet_en"
  /// The durable native learning-data logical view required before a Host may
  /// pause and release its database to Settings. This is not an app ABI.
  static let nativeLearningDataVersion: UInt = 1

  enum ChineseProfile: String, Codable, CaseIterable, Equatable, Sendable {
    case fullPinyin = "full_pinyin"
    case natural
    case flypy
    case microsoft
    case sogou
    case abc
    case ziguang
    case jiajia

    var schemaID: String {
      switch self {
      case .natural: "linnet_zh"
      case .fullPinyin: "linnet_zh_pinyin"
      case .flypy: "linnet_zh_flypy"
      case .microsoft: "linnet_zh_mspy"
      case .sogou: "linnet_zh_sogou"
      case .abc: "linnet_zh_abc"
      case .ziguang: "linnet_zh_ziguang"
      case .jiajia: "linnet_zh_jiajia"
      }
    }

    /// A reviewed ordinary spelling for the same canonical word in every
    /// profile. Settings uses it as an example; runtime readiness uses it to
    /// traverse the selected Prism and dictionaries without committing text.
    var representativeInputCode: String {
      switch self {
      case .natural, .flypy, .microsoft, .sogou: "srfa"
      case .fullPinyin: "suanfa"
      case .abc: "spfa"
      case .ziguang: "slfa"
      case .jiajia: "scfa"
      }
    }

    init?(schemaID: String) {
      guard let profile = Self.allCases.first(where: { $0.schemaID == schemaID }) else {
        return nil
      }
      self = profile
    }

  }

  enum BackupRetentionPolicy: String, CaseIterable, Equatable, Sendable {
    case keepLatest10 = "latest_10"
    case keepLatest30 = "latest_30"
    case keepLatest100 = "latest_100"

    var maximumVerifiedBackups: Int {
      switch self {
      case .keepLatest10: 10
      case .keepLatest30: 30
      case .keepLatest100: 100
      }
    }
  }

  enum DataCommand: String, Codable, Equatable, Sendable {
    case pause
    case activate
    case activateLanguage = "activate_language"
    case cancel
    case diagnose
    /// User-requested replacement of an installed Core. The running Host may
    /// accept only after Linnet is inactive, composition and data mutation are
    /// idle, and the requesting Settings process is still alive.
    case activateCore = "activate_core"
    /// Atomically publishes a candidate settings document whose differences
    /// are limited to the panel-live appearance subset, then reconciles and
    /// redeploys squirrel.yaml without rebuilding dictionaries.
    case refresh
    /// Atomically publishes a candidate settings document, reconciles all
    /// derived config files, and reloads the fixed schema configuration set.
    case reloadConfiguration = "reload_configuration"
    /// Reloads the Host-owned learning synchronization schedule after the
    /// shared preference changes. No Rime database work runs in Settings.
    case reloadLearningSync = "reload_learning_sync"
    /// Runs one immediate Host-owned incremental learning synchronization and
    /// returns only after the Host has a terminal attempt result.
    case synchronizeLearning = "synchronize_learning"
  }

  enum RuntimeStatus: String, Codable, Equatable, Sendable {
    case running
    case paused
    case degraded
    case verifying
    case activated
    case cancelled
    case rolledBack
    case rejected
    case failed
    case terminating
  }

  enum RuntimePhase: String, Codable, Equatable, Sendable {
    case running
    case paused
    case activating
    case verifying
    case recovering
  }

  /// Stable transport meaning for Settings. `detail` remains diagnostic-only
  /// and must never become user-visible presentation text.
  enum RuntimeReplyCode: String, Codable, Equatable, Sendable {
    case diagnosticsReady = "diagnostics_ready"
    case requesterUnavailable = "requester_unavailable"
    case transactionBusy = "transaction_busy"
    case appearanceDeployFailed = "appearance_deploy_failed"
    case appearanceApplied = "appearance_applied"
    case configurationReloadFailed = "configuration_reload_failed"
    case configurationApplied = "configuration_applied"
    case cancelledBeforePause = "cancelled_before_pause"
    case runtimePaused = "runtime_paused"
    case operationNotCancellable = "operation_not_cancellable"
    case runtimeResumeFailed = "runtime_resume_failed"
    case runtimeResumed = "runtime_resumed"
    case invalidCandidate = "invalid_candidate"
    case staleCandidate = "stale_candidate"
    case activationFailedRuntimeResumed = "activation_failed_runtime_resumed"
    case activationFailedRuntimeUnavailable = "activation_failed_runtime_unavailable"
    case verificationStarted = "verification_started"
    case activationVerified = "activation_verified"
    case activationRolledBack = "activation_rolled_back"
    case rollbackFailed = "rollback_failed"
    case deadlineExpired = "deadline_expired"
    case requesterExited = "requester_exited"
    case coreActivationAccepted = "core_activation_accepted"
    case coreActivationInputSourceActive = "core_activation_input_source_active"
    case coreActivationInputSourceUnavailable = "core_activation_input_source_unavailable"
    case coreActivationCompositionActive = "core_activation_composition_active"
    case coreActivationDataTransactionActive = "core_activation_data_transaction_active"
    /// Decode-only compatibility for published older Hosts, including 0.1.10's
    /// unknown-TIS reply. Retire with the fixtures only when every supported
    /// Host uses the current input-source-unavailable code and no legacy blocker.
    case coreActivationApplicationsRunning = "core_activation_applications_running"
    case coreActivationUnknownClient = "core_activation_unknown_client"
    case coreActivationRequesterUnavailable = "core_activation_requester_unavailable"
    case learningSyncConfigurationReloaded = "learning_sync_configuration_reloaded"
    case learningSyncCompleted = "learning_sync_completed"
    case learningSyncDeferred = "learning_sync_deferred"
    case learningSyncUnavailable = "learning_sync_unavailable"
    case learningSyncFailed = "learning_sync_failed"
  }

  enum CoreActivationBlocker: String, Codable, Equatable, Sendable {
    case inputSourceActive = "input_source_active"
    case inputSourceUnavailable = "input_source_unavailable"
    case compositionActive = "composition_active"
    case dataTransactionActive = "data_transaction_active"
    case applicationsStillRunning = "applications_still_running"
    case unknownClient = "unknown_client"
    case requesterUnavailable = "requester_unavailable"
  }

  struct ProductIdentity: Codable, Equatable, Sendable {
    let version: String
    let build: UInt64
    let revision: String
  }

  struct RuntimeHealth: Codable, Equatable, Sendable {
    let productIdentity: ProductIdentity?
    let state: RuntimeStatus
    let phase: RuntimePhase
    let rimeVersion: String
    let smartEnglishAvailable: Bool
    let octagramAvailable: Bool
    let availableSchemaCount: Int
    let requiredSchemaCount: Int
    let activeTransactionID: UUID?
    let activeSettingsRevision: String?
  }

  struct DataRequest: Codable, Equatable, Sendable {
    let transactionID: UUID
    let command: DataCommand
    let candidate: URL?
    let requesterPID: Int32
    let deadline: Date
    let expectedActiveGeneration: Int?
    let expectedActiveStateSHA256: String?
    let expectedSettingsRevision: String?
    /// Only a configuration recovery may accept the first operation's
    /// committed revision as an alternative to the original base revision.
    let alternateSettingsRevision: String?
    /// A missing value denotes a published Settings client that predates the
    /// durable native learning-data logical view declaration.
    let nativeLearningDataVersion: UInt?

    init(
      transactionID: UUID,
      command: DataCommand,
      candidate: URL?,
      requesterPID: Int32,
      deadline: Date,
      expectedActiveGeneration: Int? = nil,
      expectedActiveStateSHA256: String? = nil,
      expectedSettingsRevision: String? = nil,
      alternateSettingsRevision: String? = nil,
      nativeLearningDataVersion: UInt? = LinnetSettingsContract.nativeLearningDataVersion
    ) {
      self.transactionID = transactionID
      self.command = command
      self.candidate = candidate
      self.requesterPID = requesterPID
      self.deadline = deadline
      self.expectedActiveGeneration = expectedActiveGeneration
      self.expectedActiveStateSHA256 = expectedActiveStateSHA256
      self.expectedSettingsRevision = expectedSettingsRevision
      self.alternateSettingsRevision = alternateSettingsRevision
      self.nativeLearningDataVersion = nativeLearningDataVersion
    }
  }

  struct RuntimeReply: Codable, Equatable, Sendable {
    let transactionID: UUID
    let status: RuntimeStatus
    let code: RuntimeReplyCode
    let detail: String
    let health: RuntimeHealth?
  }

  private static let backupRetentionPolicyKey = "backup.retention_policy"
  private static let cloudSyncEnabledKey = "cloud_sync.enabled_v1"
  private static let legacyCloudSyncFolderBookmarkKey = "cloud_sync.folder_bookmark_v1"
  private static let cloudSyncLastAttemptKey = "cloud_sync.last_attempt_v1"
  private static let inputMethodConnectionKey = "InputMethodConnectionName"
  static func hostBundle(startingAt bundle: Bundle = .main) -> Bundle? {
    if isInputMethod(bundle) {
      return bundle
    }

    var cursor = bundle.bundleURL.deletingLastPathComponent()
    while cursor.pathComponents.count > 1 {
      if cursor.pathExtension == "app",
        let candidate = Bundle(url: cursor),
        isInputMethod(candidate) {
        return candidate
      }
      cursor.deleteLastPathComponent()
    }
    return nil
  }

  static func backupRetentionPolicy(
    startingAt bundle: Bundle = .main
  ) -> BackupRetentionPolicy {
    guard let defaults = hostDefaults(startingAt: bundle) else { return .keepLatest30 }
    guard let value = defaults.string(forKey: backupRetentionPolicyKey) else {
      return .keepLatest30
    }
    return BackupRetentionPolicy(rawValue: value) ?? .keepLatest30
  }

  @discardableResult
  static func setBackupRetentionPolicy(
    _ policy: BackupRetentionPolicy,
    startingAt bundle: Bundle = .main
  ) -> Bool {
    guard let defaults = hostDefaults(startingAt: bundle) else { return false }
    defaults.set(policy.rawValue, forKey: backupRetentionPolicyKey)
    return true
  }

  static func cloudSyncEnabled(
    startingAt bundle: Bundle = .main
  ) -> Bool {
    guard let defaults = hostDefaults(startingAt: bundle) else { return false }
    if defaults.object(forKey: cloudSyncEnabledKey) != nil {
      return defaults.bool(forKey: cloudSyncEnabledKey)
    }
    guard defaults.data(forKey: legacyCloudSyncFolderBookmarkKey) != nil else {
      return false
    }
    defaults.set(true, forKey: cloudSyncEnabledKey)
    defaults.removeObject(forKey: legacyCloudSyncFolderBookmarkKey)
    return true
  }

  @discardableResult
  static func setCloudSyncEnabled(
    _ enabled: Bool,
    startingAt bundle: Bundle = .main
  ) -> Bool {
    guard let defaults = hostDefaults(startingAt: bundle) else { return false }
    defaults.set(enabled, forKey: cloudSyncEnabledKey)
    defaults.removeObject(forKey: legacyCloudSyncFolderBookmarkKey)
    return true
  }

  static func cloudSyncLastAttempt(startingAt bundle: Bundle = .main) -> Date? {
    hostDefaults(startingAt: bundle)?.object(forKey: cloudSyncLastAttemptKey) as? Date
  }

  @discardableResult
  static func setCloudSyncLastAttempt(
    _ date: Date,
    startingAt bundle: Bundle = .main
  ) -> Bool {
    guard let defaults = hostDefaults(startingAt: bundle) else { return false }
    defaults.set(date, forKey: cloudSyncLastAttemptKey)
    return true
  }

  static func dataRegistry(startingAt bundle: Bundle = .main) -> LinnetDataRegistry? {
    guard let host = hostBundle(startingAt: bundle),
      let productName = host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
      !productName.isEmpty
    else {
      return nil
    }
    guard let coreVersion =
      (host.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      ?? (host.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
      !coreVersion.isEmpty
    else { return nil }
    return try? LinnetDataRegistry(productName: productName, coreVersion: coreVersion)
  }

  static func validDataRequest(_ request: DataRequest) -> Bool {
    request.requesterPID > 0 && request.deadline.timeIntervalSince1970.isFinite
      && validDataRequestShape(
        command: request.command,
        candidate: request.candidate,
        expectedGeneration: request.expectedActiveGeneration,
        expectedDigest: request.expectedActiveStateSHA256,
        expectedSettingsRevision: request.expectedSettingsRevision,
        alternateSettingsRevision: request.alternateSettingsRevision)
  }

  static func requesterIsAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
  }

  static func requestCanContinue(_ request: DataRequest, now: Date = Date()) -> Bool {
    request.deadline > now && requesterIsAlive(request.requesterPID)
  }
}

extension LinnetSettingsContract {
  static func productIdentity(startingAt bundle: Bundle = .main) -> ProductIdentity? {
    guard let host = hostBundle(startingAt: bundle) else { return nil }
    return productIdentity(at: host.bundleURL)
  }

  static func productIdentity(at hostURL: URL) -> ProductIdentity? {
    guard
      // Bundle caches Info.plist for the process lifetime. Installed identity
      // must read both files from disk; Host captures this result once at start.
      let infoData = try? Data(contentsOf: hostURL.appending(path: "Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(
        from: infoData, options: [], format: nil) as? [String: Any],
      let version = info["CFBundleShortVersionString"] as? String,
      !version.isEmpty,
      let buildText = info["CFBundleVersion"] as? String,
      let build = UInt64(buildText), build > 0,
      let data = try? Data(contentsOf: hostURL.appending(
        path: "Contents/Resources/LinnetRelease/VERSION.json")),
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      document["version"] as? String == version,
      document["build"] as? String == buildText,
      let source = document["source"] as? [String: Any],
      let revision = source["candidate_revision"] as? String,
      isRevision(revision)
    else { return nil }
    return .init(version: version, build: build, revision: revision)
  }

  static func validRuntimeReply(_ reply: RuntimeReply) -> Bool {
    guard !reply.detail.isEmpty else { return false }
    guard let health = reply.health else { return true }
    let validSettingsRevision: Bool
    if let activeSettingsRevision = health.activeSettingsRevision {
      validSettingsRevision = isSHA256(activeSettingsRevision)
    } else {
      validSettingsRevision = health.state == .degraded
    }
    let validProductIdentity = if let productIdentity = health.productIdentity {
      !productIdentity.version.isEmpty && productIdentity.build > 0
        && isRevision(productIdentity.revision)
    } else {
      true
    }
    return [.running, .paused, .degraded].contains(health.state)
      && validProductIdentity
      && !health.rimeVersion.isEmpty
      && health.availableSchemaCount >= 0
      && health.requiredSchemaCount > 0
      && health.availableSchemaCount <= health.requiredSchemaCount
      && validSettingsRevision
  }

  fileprivate static func validDataRequestShape(
    command: DataCommand,
    candidate: URL?,
    expectedGeneration: Int?,
    expectedDigest: String?,
    expectedSettingsRevision: String?,
    alternateSettingsRevision: String?
  ) -> Bool {
    guard (expectedGeneration == nil) == (expectedDigest == nil) else { return false }
    if let expectedGeneration, let expectedDigest,
      expectedGeneration <= 0 || !isSHA256(expectedDigest) {
      return false
    }
    let isConfiguration = command == .refresh || command == .reloadConfiguration
    if isConfiguration {
      guard candidate != nil,
        expectedGeneration == nil,
        expectedDigest == nil,
        let expectedSettingsRevision,
        isSHA256(expectedSettingsRevision)
      else { return false }
      if let alternateSettingsRevision {
        guard command == .reloadConfiguration,
          alternateSettingsRevision != expectedSettingsRevision,
          isSHA256(alternateSettingsRevision)
        else { return false }
      }
      return true
    }
    guard expectedSettingsRevision == nil, alternateSettingsRevision == nil else {
      return false
    }
    let requiresCandidate = command == .activate || command == .activateLanguage
    guard requiresCandidate == (candidate != nil) else { return false }
    return command == .activateLanguage
      ? expectedGeneration != nil
      : (command == .pause || expectedGeneration == nil)
  }

  fileprivate static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  fileprivate static func isRevision(_ value: String) -> Bool {
    value.count == 40 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  fileprivate static func isInputMethod(_ bundle: Bundle) -> Bool {
    bundle.object(forInfoDictionaryKey: inputMethodConnectionKey) != nil
  }

  fileprivate static func hostDefaults(startingAt bundle: Bundle) -> UserDefaults? {
    guard let identifier = hostBundle(startingAt: bundle)?.bundleIdentifier,
      !identifier.isEmpty
    else {
      return nil
    }
    return preferenceDefaults(
      hostIdentifier: identifier,
      runningIdentifier: Bundle.main.bundleIdentifier)
  }

  /// The Host's own preferences are its standard domain. Embedded Settings
  /// crosses the bundle boundary and therefore opens the Host-named suite.
  static func preferenceDefaults(
    hostIdentifier: String,
    runningIdentifier: String?
  ) -> UserDefaults? {
    if hostIdentifier == runningIdentifier {
      return .standard
    }
    return UserDefaults(suiteName: hostIdentifier)
  }

}

/// The single interpretation owner for optional HIToolbox selection evidence.
/// A missing or empty identifier is unknown, never proof that Linnet is inactive.
enum LinnetInputSourceSelection: Equatable, Sendable {
  case linnet
  case other
  case unknown

  static func classify(
    currentIdentifier: String?,
    linnetIdentifier: String
  ) -> Self {
    guard let currentIdentifier, !currentIdentifier.isEmpty else {
      return .unknown
    }
    return currentIdentifier == linnetIdentifier ? .linnet : .other
  }
}

/// Pure fail-closed decision owner for the explicit Core activation boundary.
/// Switching away from Linnet ends active input ownership; inactive client
/// processes do not need to exit before the Host replaces itself.
enum LinnetCoreActivationGate {
  enum Decision: Equatable, Sendable {
    case ready
    case blocked(LinnetSettingsContract.RuntimeReplyCode)

    var isReady: Bool { self == .ready }
  }

  static func evaluate(
    selectedInputSource: LinnetInputSourceSelection,
    compositionIsActive: Bool,
    dataTransactionIsActive: Bool,
    requesterIsAlive: Bool
  ) -> Decision {
    if dataTransactionIsActive {
      return .blocked(.coreActivationDataTransactionActive)
    }
    switch selectedInputSource {
    case .linnet:
      return .blocked(.coreActivationInputSourceActive)
    case .unknown:
      return .blocked(.coreActivationInputSourceUnavailable)
    case .other:
      break
    }
    if compositionIsActive {
      return .blocked(.coreActivationCompositionActive)
    }
    guard requesterIsAlive else {
      return .blocked(.coreActivationRequesterUnavailable)
    }
    return .ready
  }
}
