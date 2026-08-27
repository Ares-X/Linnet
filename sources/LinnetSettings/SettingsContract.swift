//
//  SettingsContract.swift
//  Shared by the input method and its embedded Settings application.
//

import Darwin
import Foundation

enum LinnetSettingsContract {
  static let englishSchemaID = "linnet_en"

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

    /// A presentation-only, reviewed example for the same canonical word in
    /// every profile. Runtime decoding remains owned by the active Rime Prism.
    var reverseLookupExampleCode: String {
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
    /// Gracefully exits an inactive Host so the already-installed Core can be
    /// launched from its canonical bundle. The Host alone decides readiness.
    case activateCore = "activate_core"
    /// Atomically publishes a candidate settings document whose differences
    /// are limited to the panel-live appearance subset, then reconciles and
    /// redeploys squirrel.yaml without rebuilding dictionaries.
    case refresh
    /// Atomically publishes a candidate settings document, reconciles all
    /// derived config files, and reloads the fixed schema configuration set.
    case reloadConfiguration = "reload_configuration"
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
    case coreActivationBlocked = "core_activation_blocked"
  }

  struct ProductIdentity: Codable, Equatable, Sendable {
    let version: String
    let build: UInt64
    let revision: String
  }

  enum CoreActivationReadiness: String, Codable, Equatable, Sendable {
    case ready
    case inputSourceActive = "input_source_active"
    case inputClientConnected = "input_client_connected"
    case dataTransactionActive = "data_transaction_active"
  }

  struct RuntimeHealth: Codable, Equatable, Sendable {
    let productIdentity: ProductIdentity?
    let coreActivationReadiness: CoreActivationReadiness
    let connectedInputClientCount: Int
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

    init(
      transactionID: UUID,
      command: DataCommand,
      candidate: URL?,
      requesterPID: Int32,
      deadline: Date,
      expectedActiveGeneration: Int? = nil,
      expectedActiveStateSHA256: String? = nil,
      expectedSettingsRevision: String? = nil,
      alternateSettingsRevision: String? = nil
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
  static let cloudSyncConfigurationDidChange = Notification.Name(
    "io.github.ares-x.inputmethod.Linnet.cloud-sync-configuration-v1")
  static let cloudSyncNowRequested = Notification.Name(
    "io.github.ares-x.inputmethod.Linnet.cloud-sync-now-v1")

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
    _ = defaults.synchronize()
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
    return defaults.synchronize()
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
    return defaults.synchronize()
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

  static func hostUserDirectory(startingAt bundle: Bundle = .main) -> URL? {
    dataRegistry(startingAt: bundle)?.userDataDirectory
  }

  static func dataTransactionsRoot(startingAt bundle: Bundle = .main) -> URL? {
    dataRegistry(startingAt: bundle)?.transactionsDirectory
  }

  static func backupsRoot(startingAt bundle: Bundle = .main) -> URL? {
    dataRegistry(startingAt: bundle)?.backupsDirectory
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
    guard let host = hostBundle(startingAt: bundle),
      let version = host.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      !version.isEmpty,
      let buildText = host.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      let build = UInt64(buildText), build > 0,
      let data = try? Data(contentsOf: host.bundleURL.appending(
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

  static func coreActivationReadiness(
    inputSourceIsActive: Bool,
    connectedInputClientCount: Int,
    dataTransactionActive: Bool
  ) -> CoreActivationReadiness {
    if dataTransactionActive { return .dataTransactionActive }
    if inputSourceIsActive { return .inputSourceActive }
    if connectedInputClientCount > 0 { return .inputClientConnected }
    return .ready
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
      && health.connectedInputClientCount >= 0
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
    if command == .activateCore {
      return expectedGeneration == nil && expectedDigest == nil
    }
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
    return UserDefaults(suiteName: identifier)
  }

}
