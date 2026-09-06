//
//  SquirrelApplicationDelegate.swift
//  Squirrel
//
//  Created by Leo Liu on 5/6/24.
//

import AppKit

final class SquirrelApplicationDelegate: NSObject, NSApplicationDelegate {
  struct ActiveDataTransaction {
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
  static let maximumDataTransactionDuration: TimeInterval = 300
  // librime keeps one session per client application and never reaps the
  // ones whose owner went away, so memory only grows. Recycle them
  // periodically; CleanupStaleSessions only destroys sessions idle beyond
  // Session::kLifeSpan.
  static let staleSessionCleanupInterval: TimeInterval = 600
  // Direct config deployment is intentionally exhaustive and ordered. These
  // are the only compiled YAML files document-only Settings can affect; data
  // dictionaries stay outside this low-latency boundary.
  static let configurationReloadTargets: [(fileName: String, versionKey: String)] = [
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
  var activeSettingsRevision: String?
  var activeDataTransaction: ActiveDataTransaction?
  var transactionMonitor: DispatchSourceTimer?
  var staleSessionCleaner: Timer?
  let warmRimeSession = LinnetRimeWarmSession()
  var workspacePowerOffObserver: NSObjectProtocol?
  var settingsTransactionHost: LinnetSettingsTransactionIPC.Host?
  /// The running identity belongs to this process lifetime. Reading the bundle
  /// again after a Core install would mix old executable state with new files.
  let processProductIdentity = LinnetSettingsContract.productIdentity()
  var currentTransactionReply:
    (UUID, LinnetSettingsTransactionIPC.Reply)?
  var lastLoadedSchemaID: String?
  var cancelledBeforePause: [UUID: Date] = [:]
  // Runtime lifecycle guards for the pinned librime-lua lifetime patch:
  // isRimeRunning tracks one initialized runtime so RimeFinalize runs at most
  // once per startRime; isRimeInputSuspended is the single input gate across
  // finalization and fail-closed in-process configuration recovery.
  var isRimeRunning = false
  var isRimeInputSuspended = false
  var canAcceptRimeInput: Bool {
    isRimeRunning && !isRimeInputSuspended
  }
  // setupRime ran at most once per process; an explicit runtime retry needs to
  // know whether the traits/notification handler are already in place.
  var runtimeDataSnapshot: LinnetDataRegistry.RuntimeSnapshot?
  lazy var rimeSyncController = LinnetRimeSyncController(
    loadConfiguration: {
      let syncDirectory: URL?
      if LinnetSettingsContract.cloudSyncEnabled() {
        syncDirectory = try LinnetCloudSyncLocation.productLocation()
          .prepareLearningDirectory()
      } else {
        syncDirectory = nil
      }
      return .init(
        syncDirectory: syncDirectory,
        lastAttempt: LinnetSettingsContract.cloudSyncLastAttempt())
    },
    recordAttempt: { LinnetSettingsContract.setCloudSyncLastAttempt($0) },
    recordResult: { LinnetSettingsContract.setCloudSyncResult($0.replyCode) },
    operation: { [weak self] directory in self?.performRimeUserDataSync(directory: directory) ?? .failed },
    cancelOperation: { [weak self] in _ = self?.rimeAPI.sync_user_data_step(nil) }
  )
  func applicationWillFinishLaunching(_ notification: Notification) {
    panel = SquirrelPanel(position: .zero)
    addObservers()
    refreshStatusItem()
  }
  deinit {
    removeObservers()
  }
}
