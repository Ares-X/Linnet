//
//  SettingsMain.swift
//  Native, offline settings surface embedded in the input-method bundle.
//  The window is a five-tab surface: Appearance, Input, Dictionary, English,
//  Data.
//  Theme, typeface, and size are published immediately. Candidate count,
//  layouts, input, English, and personal-data changes remain explicit Apply
//  Changes operations.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class SettingsApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var model: SettingsModel?
  var interfaceLocale = Locale.autoupdatingCurrent

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    if model.operationActive {
      NSSound.beep()
      return .terminateCancel
    }
    guard model.pendingChanges else { return .terminateNow }
    if sender.windows.contains(where: { $0.attachedSheet != nil }) {
      return .terminateCancel
    }
    SettingsPendingChangesPrompt.present(
      for: sender.keyWindow ?? sender.windows.first(where: \.isVisible),
      canApply: model.canApplyChanges,
      locale: interfaceLocale
    ) { choice in
      switch choice {
      case .apply:
        model.applyConfiguration { accepted in
          sender.reply(toApplicationShouldTerminate: accepted)
        }
      case .discard:
        model.discardPendingChanges()
        sender.reply(toApplicationShouldTerminate: true)
      case .cancel:
        sender.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }
}

@main
struct LinnetSettingsApp: App {
  @NSApplicationDelegateAdaptor(SettingsApplicationDelegate.self)
  private var applicationDelegate

  var body: some Scene {
    WindowGroup {
      SettingsRootView()
        .frame(
          minWidth: LinnetSettingsLayoutMetrics.minimumWindowWidth,
          idealWidth: LinnetSettingsLayoutMetrics.defaultWindowWidth,
          minHeight: 660,
          idealHeight: 800)
    }
    .defaultSize(width: LinnetSettingsLayoutMetrics.defaultWindowWidth, height: 800)
    .windowResizability(.contentMinSize)
    .commands { CommandGroup(replacing: .newItem) {} }
  }
}

private enum SettingsInterfaceLanguage: String, CaseIterable {
  static let defaultsKey = "Linnet.Settings.InterfaceLanguage"

  case system
  case english
  case simplifiedChinese

  var locale: Locale {
    switch self {
    case .system: .autoupdatingCurrent
    case .english: Locale(identifier: "en")
    case .simplifiedChinese: Locale(identifier: "zh-Hans")
    }
  }
}

private extension SettingsPresentationSeverity {
  var footerColor: Color {
    switch self {
    case .informational: .secondary
    case .success: .green
    case .progress: .accentColor
    case .warning: .orange
    case .error: .red
    }
  }
}

struct SettingsActiveOperation: Equatable {
  let kind: SettingsOperationKind
  var phase: SettingsOperationPhase
  var cancellationAvailable: Bool
  var cancellationRequested: Bool

  var cancellable: Bool { cancellationAvailable && !cancellationRequested }
}

enum SettingsLegacyImportState {
  case unavailable
  case checking
  case none
  case compatible(SettingsDataCoordinator.LegacyImportCandidate)
  case failed
}

enum SettingsLanguageDataUpdateTarget: Equatable {
  case currentEdition
  case completeOffline

  var presentationPack: SettingsPresentationPack {
    self == .completeOffline ? .longTailDictionaries : .languageData
  }
}

@MainActor
final class SettingsModel: ObservableObject {
  @Published var backupRetentionPolicy: LinnetSettingsContract.BackupRetentionPolicy
  @Published var configuration: SettingsConfigurationSession {
    didSet {
      if oldValue.personalDraft != configuration.personalDraft {
        schedulePersonalValidation()
      }
    }
  }
  @Published var exportCategories = Set(LinnetBackupStore.Category.allCases)
  @Published private(set) var status: SettingsPresentationStatus = .ready
  @Published private(set) var activeOperation: SettingsActiveOperation?
  @Published private(set) var backupHistory: SettingsBackupHistoryState
  @Published private(set) var legacyImportState: SettingsLegacyImportState
  @Published private(set) var personalValidation: LinnetPersonalDataStore.Validation
  @Published private(set) var personalValidationPending = false
  @Published private(set) var portableInspectionActive = false
  @Published private(set) var diagnostics: SettingsDataCoordinator.Diagnostics?
  @Published private(set) var installedPacks: [LinnetDataRegistry.ActivePack]
  @Published private(set) var dataEdition: LinnetDataRegistry.Edition?
  @Published fileprivate(set) var grammarModelStatus: GrammarModelStatus = .checking
  @Published fileprivate(set) var packDownloadProgress: Double = 0
  @Published fileprivate(set) var languageDataUpdateTarget: SettingsLanguageDataUpdateTarget?
  @Published private(set) var downloadSourceMode = LinnetSettingsDownloadSource.Mode.github
  @Published private(set) var downloadMirrorPrefix = ""
  @Published private(set) var activeDownloadSource: LinnetSettingsDownloadSource? = .direct
  @Published private(set) var downloadSourceFailure: LinnetSettingsDownloadSource.Failure?
  @Published private(set) var appearancePublishActive = false

  let productName: String
  let appVersion: String
  let appBuild: UInt64
  let dataServicesAvailable: Bool
  let dataChannelService: LinnetDataChannel.Service
  let updateChecker: LinnetSettingsUpdateChecker

  private let coordinator: SettingsDataCoordinator
  private let dataRegistry: LinnetDataRegistry?
  let userDirectory: URL?
  private let backupsRoot: URL?
  private let hallelujahDatabase: URL?
  private let legacyRimeDirectory: URL?
  private var operationTask: Task<Void, Never>?
  private var packDownloadTask: Task<Void, Never>?
  private var appearanceDebounceTask: Task<Void, Never>?
  private var appearancePublishTask: Task<Void, Never>?
  private var backupRefreshTask: Task<Void, Never>?
  private var legacyInspectionTask: Task<Void, Never>?
  private let personalValidationExecutor = SettingsPersonalValidationExecutor()
  private var pendingAppearance: LinnetSettingsDocument.Appearance?

  var operationActive: Bool {
    activeOperation != nil || packDownloadActive || appearancePublishActive
  }
  var migrationAvailable: Bool {
    if case .compatible = legacyImportState { return true }
    return false
  }
  var documentDirty: Bool { configuration.documentDirty }
  var personalDataDirty: Bool { configuration.personalDataDirty }
  var pendingChanges: Bool { configuration.pendingChanges }
  var canApplyChanges: Bool {
    configuration.canPersist && !personalValidationPending
      && personalValidation.isValid && !operationActive && pendingChanges
  }
  var displayedStatus: SettingsPresentationStatus {
    switch configuration.readiness {
    case .ready: status
    case .sourceUnreadable: .settingsLoadFailed
    case .servicesUnavailable: .operationFailed(.unavailable)
    }
  }
  var packDownloadActive: Bool { languageDataUpdateTarget != nil }
  var packDownloadCancellable: Bool {
    languageDataUpdateTarget != nil && packDownloadTask != nil
  }
  var languageDataUpdatesAvailable: Bool {
    dataServicesAvailable && dataChannelService == .published
      && configuredDownloadSource != nil
  }
  var downloadSourceConfigured: Bool { configuredDownloadSource != nil }
  var downloadSourceEditorDisabled: Bool { operationActive }
  var downloadMirrorIsValid: Bool {
    (try? LinnetSettingsDownloadSource.customMirror(prefix: downloadMirrorPrefix)) != nil
  }
  var downloadSourceNeedsSave: Bool {
    downloadSourceMode == .customMirror && downloadMirrorIsValid
      && configuredDownloadSource == nil
  }
  var canUseDownloadMirror: Bool {
    !downloadSourceEditorDisabled && downloadSourceNeedsSave
  }
  var canRestoreBackup: Bool {
    dataServicesAvailable
      && (configuration.canPersist || configuration.readiness == .sourceUnreadable)
  }

  init(bundle: Bundle = .main) {
    let host = LinnetSettingsContract.hostBundle(startingAt: bundle)
    productName =
      host?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? "Input Method"
    appVersion =
      (host?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      ?? (host?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
      ?? "development"
    appBuild = UInt64(host?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    let registry = LinnetSettingsContract.dataRegistry(startingAt: bundle)
    dataRegistry = registry
    let runtimeSnapshot = registry.flatMap { try? $0.runtimeSnapshot() }
    installedPacks = runtimeSnapshot?.state.packs ?? []
    dataEdition = runtimeSnapshot?.state.edition
    dataServicesAvailable = runtimeSnapshot != nil
    dataChannelService = LinnetDataChannel.service
    updateChecker = LinnetSettingsUpdateChecker(
      currentVersion: appVersion, currentBuild: appBuild,
      service: dataChannelService, edition: runtimeSnapshot?.state.edition,
      installedPacks: runtimeSnapshot?.state.packs ?? [])
    let downloadPreference = LinnetSettingsDownloadSource.load()
    downloadSourceMode = downloadPreference.mode
    downloadMirrorPrefix = downloadPreference.mirrorPrefix
    activeDownloadSource = downloadPreference.source
    downloadSourceFailure = downloadPreference.failure
    backupRetentionPolicy = LinnetSettingsContract.backupRetentionPolicy(startingAt: bundle)
    coordinator = SettingsDataCoordinator(bundle: bundle)
    userDirectory = registry?.userDataDirectory
    backupsRoot = registry?.backupsDirectory
    backupHistory = SettingsBackupHistoryState(rootAvailable: backupsRoot != nil)
    let personalSnapshot: LinnetPersonalDataStore.Snapshot?
    do {
      personalSnapshot =
        try userDirectory.map(LinnetPersonalDataStore.snapshot)
        ?? LinnetPersonalDataStore.Snapshot(
          data: .empty,
          revision: try LinnetPersonalDataStore.revision(for: .empty)
        )
    } catch {
      personalSnapshot = nil
      print("Personal settings could not be loaded: \(error.localizedDescription)")
    }
    hallelujahDatabase = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first?
    .appending(path: "hallelujah", directoryHint: .isDirectory)
    .appending(path: "substitutions.sqlite3", directoryHint: .notDirectory)
    legacyRimeDirectory = FileManager.default.urls(
      for: .libraryDirectory,
      in: .userDomainMask
    ).first?.appending(path: "Rime", directoryHint: .isDirectory)
    let loadedDocument: LinnetSettingsDocumentStore.Snapshot?
    do {
      loadedDocument = try userDirectory.map(LinnetSettingsDocumentStore.snapshot)
        ?? LinnetSettingsDocumentStore.defaultSnapshot()
    } catch {
      loadedDocument = nil
      print("Settings document could not be loaded: \(error.localizedDescription)")
    }
    let initialConfiguration = SettingsConfigurationSession(
      document: loadedDocument,
      personal: personalSnapshot,
      servicesAvailable: dataServicesAvailable
    )
    configuration = initialConfiguration
    personalValidation = .valid(initialConfiguration.personalDraft)
    legacyImportState = dataServicesAvailable ? .checking : .unavailable
    detectGrammarModel()
    schedulePersonalValidation()
  }

  // MARK: — Grammar model management

  /// The current state of the Wanxiang LTS grammar model on this machine.
  enum GrammarModelStatus: Equatable {
    case checking        /// still probing the filesystem
    case ltsActive       /// Wanxiang LTS (420 MB) is the active pack
    case missing         /// recommended data is absent; no update was attempted

    var label: LocalizedStringKey {
      switch self {
      case .checking: return "Detecting grammar model…"
      case .ltsActive: return "Wanxiang LTS grammar data (about 420 MB) — Active"
      case .missing: return "Model data missing"
      }
    }
  }

  private func detectGrammarModel() {
    grammarModelStatus = installedPacks.contains(where: { $0.kind == .lts })
      ? .ltsActive : .missing
  }

  func updateLanguageData() {
    downloadLanguageData(.currentEdition)
  }

  func installCompleteOfflineData() {
    downloadLanguageData(.completeOffline)
  }

  func selectDownloadSourceMode(_ mode: LinnetSettingsDownloadSource.Mode) {
    guard !downloadSourceEditorDisabled else { return }
    downloadSourceMode = mode
    switch mode {
    case .github:
      LinnetSettingsDownloadSource.save(.direct)
      activeDownloadSource = .direct
      downloadSourceFailure = nil
    case .publicMirror:
      LinnetSettingsDownloadSource.save(.publicMirror)
      activeDownloadSource = .publicMirror
      downloadSourceFailure = nil
    case .customMirror:
      refreshDownloadMirrorValidation()
    }
  }

  func updateDownloadMirrorPrefix(_ value: String) {
    guard !downloadSourceEditorDisabled else { return }
    downloadMirrorPrefix = value
    if downloadSourceMode == .customMirror { refreshDownloadMirrorValidation() }
  }

  func useDownloadMirror() {
    guard !downloadSourceEditorDisabled else { return }
    do {
      let source = try LinnetSettingsDownloadSource.customMirror(prefix: downloadMirrorPrefix)
      LinnetSettingsDownloadSource.save(source)
      downloadSourceMode = .customMirror
      downloadMirrorPrefix = source.mirrorPrefixString ?? downloadMirrorPrefix
      activeDownloadSource = source
      downloadSourceFailure = nil
    } catch let failure as LinnetSettingsDownloadSource.Failure {
      downloadSourceFailure = failure
    } catch {
      downloadSourceFailure = .invalidMirrorPrefix
    }
  }

  private var configuredDownloadSource: LinnetSettingsDownloadSource? {
    guard let activeDownloadSource, activeDownloadSource.mode == downloadSourceMode else {
      return nil
    }
    switch downloadSourceMode {
    case .github:
      return activeDownloadSource
    case .publicMirror:
      return activeDownloadSource == .publicMirror ? activeDownloadSource : nil
    case .customMirror:
      guard let draft = try? LinnetSettingsDownloadSource.customMirror(
        prefix: downloadMirrorPrefix),
        draft == activeDownloadSource
      else { return nil }
      return activeDownloadSource
    }
  }

  private func refreshDownloadMirrorValidation() {
    do {
      _ = try LinnetSettingsDownloadSource.customMirror(prefix: downloadMirrorPrefix)
      downloadSourceFailure = nil
    } catch let failure as LinnetSettingsDownloadSource.Failure {
      downloadSourceFailure = failure
    } catch {
      downloadSourceFailure = .invalidMirrorPrefix
    }
  }

  private func downloadLanguageData(_ target: SettingsLanguageDataUpdateTarget) {
    guard languageDataUpdatesAvailable, !packDownloadActive, !operationActive else {
      if !languageDataUpdatesAvailable { finishLanguageDataUpdate(target, failure: .unavailable) }
      return
    }

    guard let registry = dataRegistry, let downloadSource = configuredDownloadSource,
      dataChannelService == .published
    else {
      finishLanguageDataUpdate(target, failure: .unavailable)
      return
    }
    languageDataUpdateTarget = target
    packDownloadProgress = 0
    setLanguageDataUpdateState(target, .downloading)
    let coordinator = coordinator
    packDownloadTask = Task.detached {
      [weak self, registry, downloadSource, coordinator] in
      do {
        try registry.prepareMutableDirectories()
        let lease = try await LinnetSettingsMutationLease.acquire(
          at: registry.settingsMutationLeaseURL, timeout: 300)
        defer { _ = lease }
        try Task.checkCancellation()
        let transport = LinnetSettingsDownloadTransport(source: downloadSource)
        let catalogData = try await transport.downloadCatalog(
          at: LinnetSettingsDownloadSource.canonicalCatalogURL)
        try Task.checkCancellation()
        await self?.setLanguageDataUpdateState(target, .verifying)
        let catalog = try registry.verifyDataChannel(catalogData)
        let snapshot = try registry.runtimeSnapshot()
        let requestedEdition: LinnetDataRegistry.Edition = target == .completeOffline
          ? .full : snapshot.state.edition
        guard let selected = catalog.catalog.activationSet(for: requestedEdition) else {
          throw LinnetDataRegistry.Failure.invalidActiveState
        }
        let update = try registry.beginDataChannelUpdate(
          accepting: catalog, edition: requestedEdition)
        let downloadDirectory = update.downloadDirectory
        defer {
          try? registry.cancelDataChannelUpdate(transactionID: update.transactionID)
        }
        var targetPacks: [LinnetDataRegistry.ActivePack] = []
        for artifact in selected.packs {
          try Task.checkCancellation()
          if let installed = snapshot.state.packs.first(where: { artifact.matches($0) }) {
            targetPacks.append(installed)
            continue
          }
          let package = downloadDirectory.appending(
            path: "\(artifact.kind.rawValue)-\(artifact.sequence)-\(artifact.contentSHA256).linnetpack")
          await self?.setLanguageDataUpdateState(target, .downloading)
          try await transport.downloadPack(artifact, to: package)
          try Task.checkCancellation()
          await self?.setLanguageDataUpdateState(target, .verifying)
          let staged = try registry.verifyAndStagePack(package: package, artifact: artifact)
          targetPacks.append(staged)
          await self?.setPackDownloadProgress(
            Double(targetPacks.count) / Double(selected.packs.count))
          try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let activation = try registry.prepareDataChannelUpdate(update, target: targetPacks)
        await self?.beginLanguageDataActivation(target)
        try Task.checkCancellation()
        try await coordinator.activateLanguage(activation)
        await self?.finishLanguageDataUpdate(target)
      } catch is CancellationError {
        await self?.finishPackDownloadCancellation(target)
      } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
        await self?.finishPackDownloadCancellation(target)
      } catch {
        print("Language-data catalog update failed: \(error.localizedDescription)")
        await self?.finishLanguageDataUpdate(
          target, failure: Self.packUpdateFailure(for: error))
      }
    }
  }

  @MainActor
  private func setPackDownloadProgress(_ progress: Double) {
    packDownloadProgress = progress
  }

  @MainActor
  private func setLanguageDataUpdateState(
    _ target: SettingsLanguageDataUpdateTarget,
    _ state: SettingsPresentationPackState
  ) {
    guard languageDataUpdateTarget == target else { return }
    status = .pack(target.presentationPack, state)
  }

  @MainActor
  private func beginLanguageDataActivation(_ target: SettingsLanguageDataUpdateTarget) {
    guard languageDataUpdateTarget == target else { return }
    // Activation can atomically swap live language data. Once this phase
    // begins, cancellation is no longer advertised as a safe user action;
    // Host health verification and rollback own the terminal result.
    packDownloadTask = nil
    status = .pack(target.presentationPack, .activating)
  }

  nonisolated private static func packUpdateFailure(
    for error: Error
  ) -> SettingsPresentationPackState {
    if error is SettingsDataCoordinator.Failure { return .activationFailed }
    if let leaseFailure = error as? LinnetSettingsMutationLease.Failure {
      return leaseFailure == .timedOut ? .busy : .storageFailed
    }
    if let transportFailure = error as? LinnetSettingsDownloadTransport.Failure {
      switch transportFailure {
      case .unsafeDestination, .destinationExists, .storage:
        return .storageFailed
      case .invalidURL, .invalidResponse, .httpStatus:
        return .updateServiceUnavailable
      case .unsupportedContentEncoding, .invalidContentLength, .responseTooLarge,
        .lengthMismatch:
        return .verificationFailed
      case .invalidConfiguration:
        return .downloadFailed
      }
    }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff,
        .dataNotAllowed:
        return .offline
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .badServerResponse, .resourceUnavailable, .fileDoesNotExist:
        return .updateServiceUnavailable
      default:
        return .downloadFailed
      }
    }
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain {
      let storageCodes = Set([
        CocoaError.Code.fileWriteOutOfSpace.rawValue,
        CocoaError.Code.fileWriteNoPermission.rawValue,
        CocoaError.Code.fileWriteVolumeReadOnly.rawValue,
      ])
      if storageCodes.contains(failure.code) { return .storageFailed }
    }
    return .verificationFailed
  }

  @MainActor
  fileprivate func finishLanguageDataUpdate(
    _ target: SettingsLanguageDataUpdateTarget,
    failure: SettingsPresentationPackState? = nil
  ) {
    guard languageDataUpdateTarget == target || languageDataUpdateTarget == nil else { return }
    if let failure {
      status = .pack(target.presentationPack, failure)
    } else {
      packDownloadProgress = 1
      if let snapshot = try? dataRegistry?.runtimeSnapshot() {
        installedPacks = snapshot.state.packs
        dataEdition = snapshot.state.edition
      }
      status = .pack(target.presentationPack, .active(version: nil))
    }
    detectGrammarModel()
    languageDataUpdateTarget = nil
    packDownloadTask = nil
    startPendingAppearancePublish()
    if failure == nil {
      updateChecker.refreshInstalledData(edition: dataEdition, packs: installedPacks)
    }
  }

  func cancelLanguagePackDownload() {
    guard packDownloadCancellable, let target = languageDataUpdateTarget else { return }
    status = .pack(target.presentationPack, .cancelling)
    packDownloadTask?.cancel()
  }

  fileprivate func finishPackDownloadCancellation(_ target: SettingsLanguageDataUpdateTarget) {
    guard languageDataUpdateTarget == target else { return }
    packDownloadProgress = 0
    languageDataUpdateTarget = nil
    packDownloadTask = nil
    detectGrammarModel()
    status = .pack(target.presentationPack, .cancelled)
    startPendingAppearancePublish()
  }

  // MARK: — End grammar model management

  func saveBackupRetentionPolicy() {
    status =
      LinnetSettingsContract.setBackupRetentionPolicy(backupRetentionPolicy)
      ? .backupRetentionSaved
      : .hostUnavailable
  }

  func openDataFolder() {
    guard let directory = userDirectory else {
      status = .dataFolderUnavailable
      return
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      NSWorkspace.shared.open(directory)
    } catch {
      status = .dataFolderOpenFailed
    }
  }

  func addCustomWord() {
    configuration.personalDraft.customWords.append(.init(value: "", code: ""))
  }
  func removeCustomWord(id: UUID) {
    configuration.personalDraft.customWords.removeAll { $0.id == id }
  }
  func addDisabledWord() { configuration.personalDraft.disabledWords.append("") }
  func removeDisabledWord(at index: Int) {
    guard configuration.personalDraft.disabledWords.indices.contains(index) else { return }
    configuration.personalDraft.disabledWords.remove(at: index)
  }
  func addExpansion() {
    configuration.personalDraft.expansions.append(.init(value: "", trigger: "x;"))
  }
  func removeExpansion(id: UUID) {
    configuration.personalDraft.expansions.removeAll { $0.id == id }
  }

  func reloadExternalChanges() {
    guard configuration.resolveExternalConflictByReloading() else { return }
    status = .ready
  }

  func keepPendingDrafts() {
    guard configuration.resolveExternalConflictKeepingPending() else { return }
    status = .ready
  }

  func personalValidationMessage(locale: Locale) -> String? {
    guard let issue = personalValidation.firstIssue else { return nil }
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let location: String
    switch issue.location {
    case .customWord(let id, let field):
      let row = configuration.personalDraft.customWords.firstIndex { $0.id == id }.map { $0 + 1 }
      let fieldName = switch field {
      case .value: chinese ? "词条" : "value"
      case .code: chinese ? "编码" : "code"
      }
      location = chinese ? "自定义词第 \(row ?? 0) 行的\(fieldName)" : "Custom word row \(row ?? 0) \(fieldName)"
    case .disabledWord(let index):
      location = chinese ? "禁用词第 \(index + 1) 行" : "Disabled word row \(index + 1)"
    case .expansion(let id, let field):
      let row = configuration.personalDraft.expansions.firstIndex { $0.id == id }.map { $0 + 1 }
      let fieldName = switch field {
      case .value: chinese ? "展开内容" : "expansion"
      case .trigger: chinese ? "触发码" : "trigger"
      }
      location = chinese ? "文本展开第 \(row ?? 0) 行的\(fieldName)" : "Text Expander row \(row ?? 0) \(fieldName)"
    case .collection(let collection):
      location = switch collection {
      case .customWords: chinese ? "自定义词" : "Custom words"
      case .disabledWords: chinese ? "禁用词" : "Disabled words"
      case .expansions: chinese ? "文本展开" : "Text Expander"
      }
    }
    let reason = switch issue.reason {
    case .missing: chinese ? "不能为空。" : "is required."
    case .invalid: chinese ? "格式无效。" : "has an invalid format."
    case .tooLarge: chinese ? "超过安全大小限制。" : "exceeds the safe size limit."
    case .duplicate: chinese ? "与另一行重复。" : "duplicates another row."
    case .tooMany: chinese ? "超过允许的行数。" : "has too many rows."
    }
    return chinese ? "\(location)\(reason)" : "\(location) \(reason)"
  }

  func legacyImportSummary(
    _ candidate: SettingsDataCoordinator.LegacyImportCandidate,
    locale: Locale
  ) -> String {
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let sourceNames = candidate.sources.map {
      switch $0 {
      case .hallelujah: "Hallelujah"
      case .rime: chinese ? "旧 Rime 用户词典" : "legacy Rime user dictionaries"
      }
    }.joined(separator: chinese ? "、" : ", ")
    if chinese {
      return "已验证来源：\(sourceNames)。将合并 \(candidate.substitutionCount) 条替换规则和 \(candidate.recognizedLearningDictionaryCount) 个已识别学习词典；操作前会自动备份当前状态。"
    }
    return "Verified sources: \(sourceNames). This will merge \(candidate.substitutionCount) substitutions and \(candidate.recognizedLearningDictionaryCount) recognized learning dictionaries after backing up the current state."
  }

  func portableImportSummary(
    _ candidate: SettingsDataCoordinator.PortableImportCandidate,
    locale: Locale
  ) -> String {
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let categories = candidate.categories.map { category in
      switch category {
      case .customWords: chinese ? "自定义词" : "Custom words"
      case .disabledWords: chinese ? "禁用词" : "Disabled words"
      case .textExpander: chinese ? "文本展开" : "Text Expander"
      case .chineseLearning: chinese ? "中文学习" : "Chinese learning"
      case .englishLearning: chinese ? "英文学习" : "English learning"
      }
    }.joined(separator: chinese ? "、" : ", ")
    if chinese {
      return "归档版本：应用 \(candidate.appVersion)，数据 \(candidate.dataVersion)。将替换：\(categories)（共 \(candidate.recordCount) 条记录）；其他类别保持不变，操作前会自动备份。"
    }
    return "Archive version: app \(candidate.appVersion), data \(candidate.dataVersion). Replace \(categories) (\(candidate.recordCount) records); preserve all other categories and back up the current state first."
  }

  private func schedulePersonalValidation() {
    let draft = configuration.personalDraft
    personalValidationPending = true
    personalValidationExecutor.submit(draft) { [weak self] result in
      guard let self, self.configuration.personalDraft == draft else { return }
      self.personalValidation = result
      self.personalValidationPending = false
    }
  }

  /// Coalesces continuous controls briefly, then publishes only the latest
  /// appearance through the existing lightweight Host refresh boundary.
  func publishAppearance(_ appearance: LinnetSettingsDocument.Appearance) {
    guard configuration.canPersist, let baseline = configuration.documentBaseline else { return }
    let projectedAppearance = appearance.livePanelProjection(over: baseline.appearance)
    guard projectedAppearance != baseline.appearance else {
      cancelPendingAppearancePublish()
      return
    }
    pendingAppearance = projectedAppearance
    appearanceDebounceTask?.cancel()
    appearanceDebounceTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 75_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.startPendingAppearancePublish()
    }
  }

  /// Applies the pending document and personal data through one revision-
  /// checked coordinator, which selects live config reload or a staged data
  /// transaction from the authoritative change scope.
  func applyConfiguration(completion: (@MainActor (Bool) -> Void)? = nil) {
    guard canApplyChanges,
      let personalTicket = configuration.makePersonalTicket(),
      let documentTicket = configuration.makeDocumentTicket()
    else {
      completion?(false)
      return
    }
    let stagedDocument = documentTicket.submittedDraft
    run(
      .apply,
      operation: .applyConfiguration(
        personal: personalTicket.submittedDraft,
        document: stagedDocument,
        basePersonalRevision: personalTicket.baselineRevision,
        baseDocumentRevision: documentTicket.baselineRevision
      ),
      personalTicket: personalTicket,
      documentTicket: documentTicket,
      completion: completion
    ) { outcome in
      return .applied(backupName: outcome.backupDirectory?.lastPathComponent)
    }
  }

  func discardPendingChanges() {
    cancelPendingAppearancePublish()
    configuration.discardPendingChanges()
  }

  var legacyImportCandidate: SettingsDataCoordinator.LegacyImportCandidate? {
    guard case .compatible(let candidate) = legacyImportState else { return nil }
    return candidate
  }

  func refreshLegacyImportCandidate() {
    guard dataServicesAvailable else {
      legacyImportState = .unavailable
      return
    }
    legacyInspectionTask?.cancel()
    legacyImportState = .checking
    let hallelujahDatabase = hallelujahDatabase
    let legacyRimeDirectory = legacyRimeDirectory
    legacyInspectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let candidate = try await coordinator.inspectLegacy(
          hallelujahDatabase: hallelujahDatabase,
          legacyUserDirectory: legacyRimeDirectory
        )
        guard !Task.isCancelled else { return }
        legacyImportState = candidate.map(SettingsLegacyImportState.compatible) ?? .none
      } catch SettingsDataCoordinator.Failure.cancelled {
        return
      } catch {
        guard !Task.isCancelled else { return }
        legacyImportState = .failed
        logDiagnostic(error, context: "Legacy import inspection failed")
      }
      legacyInspectionTask = nil
    }
  }

  func importExistingData(_ candidate: SettingsDataCoordinator.LegacyImportCandidate) {
    guard configuration.canPersist, let ticket = configuration.makePersonalTicket() else { return }
    run(
      .legacy,
      operation: .importLegacy(candidate),
      personalTicket: ticket
    ) { outcome in
      let substitutions = outcome.importReport?.importedCount ?? 0
      return .legacyImported(
        substitutions: substitutions,
        learningRecords: outcome.legacyImportedCount
      )
    }
  }

  func choosePortableExport(locale: Locale) {
    guard !exportCategories.isEmpty, !operationActive else { return }
    let panel = NSSavePanel()
    panel.title = SettingsFilePanelTitle.portableExport.text(
      productName: productName, locale: locale)
    panel.nameFieldStringValue = "\(productName)-Data.linnet-data"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [
      UTType(filenameExtension: LinnetBackupStore.portableExtension) ?? .data
    ]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    run(
      .portableExport,
      operation: .exportPortable(categories: exportCategories, destination: destination)
    ) { _ in .portableExported(productName: self.productName) }
  }

  func choosePortableImportSource(locale: Locale) -> URL? {
    guard !operationActive else { return nil }
    let panel = NSOpenPanel()
    panel.title = SettingsFilePanelTitle.portableImport.text(
      productName: productName, locale: locale)
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [
      UTType(filenameExtension: LinnetBackupStore.portableExtension) ?? .data
    ]
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  func inspectPortableImport(
    _ source: URL
  ) async -> SettingsDataCoordinator.PortableImportCandidate? {
    guard configuration.canPersist, !operationActive, !portableInspectionActive else { return nil }
    portableInspectionActive = true
    status = .operationProgress(.portableImport, .preflight)
    defer { portableInspectionActive = false }
    do {
      let candidate = try await coordinator.inspectPortable(source)
      status = .ready
      return candidate
    } catch SettingsDataCoordinator.Failure.cancelled {
      status = .operationCancelled
      return nil
    } catch {
      logDiagnostic(error, context: "Portable import inspection failed")
      status = .operationFailed(presentationFailure(error))
      return nil
    }
  }

  func importPortable(_ candidate: SettingsDataCoordinator.PortableImportCandidate) {
    guard !operationActive, let ticket = configuration.makePersonalTicket() else { return }
    run(
      .portableImport,
      operation: .importPortable(candidate, baseRevision: ticket.baselineRevision),
      personalTicket: ticket
    ) { _ in .portableImported }
  }

  func restore(_ record: LinnetBackupStore.BackupRecord) {
    guard case .verified = record.state, canRestoreBackup, !operationActive else { return }
    if let personalTicket = configuration.makePersonalTicket(),
      let documentTicket = configuration.makeDocumentTicket()
    {
      run(
        .restore,
        operation: .restoreBackup(record.backupDirectory),
        personalTicket: personalTicket,
        documentTicket: documentTicket
      ) { _ in
        .backupRestored
      }
      return
    }
    guard configuration.readiness == .sourceUnreadable else { return }
    run(
      .restore,
      operation: .restoreBackup(record.backupDirectory),
      recoveryAfterCommit: true
    ) { _ in
      .backupRestored
    }
  }

  func removeBackupRecord(_ record: LinnetBackupStore.BackupRecord) {
    guard !operationActive, record.transactionID != nil else { return }
    if case .verified = record.state { return }
    run(
      .removeBackup,
      operation: .removeBackupRecord(record)
    ) { _ in .backupRecordRemoved }
  }

  func clearLearning(_ domains: Set<SettingsDataCoordinator.LearningDomain>) {
    run(.clearLearning, operation: .clearLearning(domains)) { _ in
      .learningCleared
    }
  }

  func reveal(_ record: LinnetBackupStore.BackupRecord) {
    let target =
      FileManager.default.fileExists(atPath: record.backupDirectory.path)
      ? record.backupDirectory : record.transactionDirectory
    NSWorkspace.shared.activateFileViewerSelecting([target])
  }

  func refreshDiagnostics() {
    run(.diagnostics, operation: .diagnose) { [weak self] outcome in
      self?.diagnostics = outcome.diagnostics
      return outcome.diagnostics?.reachability == .unreachable
        ? .diagnosticsUnreachable
        : .diagnosticsRefreshed
    }
  }

  func copyDiagnostics() {
    guard let report = diagnostics?.redactedReport else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(report, forType: .string)
    status = .diagnosticsCopied
  }

  func saveDiagnostics(locale: Locale) {
    guard let report = diagnostics?.redactedReport else { return }
    let panel = NSSavePanel()
    panel.title = SettingsFilePanelTitle.diagnosticsExport.text(
      productName: productName, locale: locale)
    panel.nameFieldStringValue = "\(productName)-diagnostics.txt"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      try report.write(to: destination, atomically: true, encoding: .utf8)
      status = .diagnosticsSaved
    } catch {
      status = .diagnosticsSaveFailed
    }
  }

  func cancelActiveOperation() {
    guard activeOperation?.cancellable == true else { return }
    activeOperation?.cancellationAvailable = false
    activeOperation?.cancellationRequested = true
    status = .cancellingOperation
    operationTask?.cancel()
  }

  func categorySelected(_ category: LinnetBackupStore.Category) -> Binding<Bool> {
    Binding(
      get: { self.exportCategories.contains(category) },
      set: { selected in
        if selected {
          self.exportCategories.insert(category)
        } else {
          self.exportCategories.remove(category)
        }
      }
    )
  }

  private func run(
    _ kind: SettingsOperationKind,
    operation: SettingsDataCoordinator.DataOperation,
    personalTicket: SettingsConfigurationSession.PersonalTicket? = nil,
    documentTicket: SettingsConfigurationSession.DocumentTicket? = nil,
    recoveryAfterCommit: Bool = false,
    completion: (@MainActor (Bool) -> Void)? = nil,
    success: @escaping @MainActor (SettingsDataCoordinator.Outcome) -> SettingsPresentationStatus
  ) {
    guard operationTask == nil else { return }
    activeOperation = .init(
      kind: kind,
      phase: .preflight,
      cancellationAvailable: false,
      cancellationRequested: false
    )
    status = .operationProgress(kind, .preflight)
    operationTask = Task { [weak self] in
      guard let self else { return }
      var acceptedForCompletion = false
      do {
        let outcome = try await coordinator.run(operation) { [weak self] update in
          Task { @MainActor [weak self] in self?.setProgress(update, for: kind) }
        }
        switch accept(
          outcome,
          personalTicket: personalTicket,
          documentTicket: documentTicket,
          recoveryAfterCommit: recoveryAfterCommit
        ) {
        case .accepted:
          if kind == .apply {
            cancelPendingAppearancePublish()
          }
          status = success(outcome)
          acceptedForCompletion = true
        case .conflict:
          status = .configurationConflict
        case .rejected:
          status = .operationFailed(.invalidOperation)
        }
      } catch SettingsDataCoordinator.Failure.staleRevision {
        switch observeCurrentConfiguration() {
        case .reloaded:
          status = .staleDataReloaded
        case .conflict:
          status = .configurationConflict
        default:
          status = .operationFailed(.invalidOperation)
        }
      } catch SettingsDataCoordinator.Failure.cancelled {
        status = .operationCancelled
      } catch {
        logDiagnostic(error, context: "Settings operation failed")
        status = kind == .removeBackup
          ? .backupRecordRemovalFailed
          : .operationFailed(presentationFailure(error))
      }
      refreshBackups()
      activeOperation = nil
      operationTask = nil
      startPendingAppearancePublish()
      completion?(acceptedForCompletion && !pendingChanges)
    }
  }

  /// Apply and Discard are terminal for work queued by the live appearance
  /// path. Keeping cancellation and payload removal together prevents a stale
  /// debounce wake-up from publishing after either terminal transition.
  private func cancelPendingAppearancePublish() {
    appearanceDebounceTask?.cancel()
    appearanceDebounceTask = nil
    pendingAppearance = nil
  }

  private func startPendingAppearancePublish() {
    appearanceDebounceTask = nil
    guard appearancePublishTask == nil,
      operationTask == nil,
      !packDownloadActive,
      configuration.canPersist,
      let appearance = pendingAppearance,
      let baseline = configuration.documentBaseline,
      let personalRevision = configuration.personalBaselineRevision,
      let documentTicket = configuration.makeDocumentTicket()
    else { return }
    guard appearance != baseline.appearance else {
      pendingAppearance = nil
      return
    }

    pendingAppearance = nil
    appearancePublishActive = true
    status = .publishingAppearance
    appearancePublishTask = Task { [weak self] in
      guard let self else { return }
      do {
        let outcome = try await coordinator.run(
          .publishAppearance(
            appearance: appearance,
            basePersonalRevision: personalRevision,
            baseDocumentRevision: documentTicket.baselineRevision)
        )
        guard case .submittedAppearance(let snapshot) = outcome.documentEffect,
          configuration.acceptAppearanceCommit(snapshot, ticket: documentTicket)
        else {
          status = .configurationConflict
          appearancePublishActive = false
          appearancePublishTask = nil
          return
        }
        if pendingAppearance == nil {
          status = .appearanceLive
        }
      } catch SettingsDataCoordinator.Failure.staleRevision {
        let observation = observeCurrentConfiguration()
        if configuration.canPersist,
          observation == .reloaded || observation == .unchanged,
          let baseline = configuration.documentBaseline
        {
          pendingAppearance = configuration.documentDraft.appearance.livePanelProjection(
            over: baseline.appearance)
          status = .appearanceStaleRetry
        } else if observation == .conflict {
          status = .configurationConflict
        } else {
          status = .operationFailed(.invalidOperation)
        }
      } catch SettingsDataCoordinator.Failure.cancelled {
        if let baseline = configuration.documentBaseline {
          pendingAppearance = configuration.documentDraft.appearance.livePanelProjection(
            over: baseline.appearance)
        }
      } catch {
        logDiagnostic(error, context: "Candidate appearance publish failed")
        status = .appearanceFailed(presentationFailure(error))
      }
      appearancePublishActive = false
      appearancePublishTask = nil
      startPendingAppearancePublish()
    }
  }

  private func setProgress(
    _ update: SettingsDataCoordinator.OperationProgress,
    for kind: SettingsOperationKind
  ) {
    guard activeOperation?.kind == kind else { return }
    guard let presentationPhase = presentationPhase(update.phase) else { return }
    let cancellationRequested = activeOperation?.cancellationRequested ?? false
    activeOperation = .init(
      kind: kind,
      phase: presentationPhase,
      cancellationAvailable: update.cancellation == .available,
      cancellationRequested: cancellationRequested
    )
    if !cancellationRequested {
      status = .operationProgress(kind, presentationPhase)
    }
  }

  private enum OutcomeAcceptance {
    case accepted, conflict, rejected
  }

  private func accept(
    _ outcome: SettingsDataCoordinator.Outcome,
    personalTicket: SettingsConfigurationSession.PersonalTicket?,
    documentTicket: SettingsConfigurationSession.DocumentTicket?,
    recoveryAfterCommit: Bool
  ) -> OutcomeAcceptance {
    if let result = outcome.diagnostics { diagnostics = result }
    if recoveryAfterCommit {
      guard case .externalReplacement = outcome.personalEffect,
        case .externalReplacement = outcome.documentEffect,
        recoverConfiguration(using: outcome.personalSnapshot)
      else { return .rejected }
      return .accepted
    }

    var hasConflict = false
    switch outcome.personalEffect {
    case .observed:
      if configuration.observePersonal(outcome.personalSnapshot) == .conflict {
        hasConflict = true
      }
    case .submittedDraft:
      guard let personalTicket else { return .rejected }
      switch configuration.acceptPersonalCommit(
        outcome.personalSnapshot,
        kind: .submittedDraft,
        ticket: personalTicket
      ) {
      case .conflict: hasConflict = true
      case .rejectedStaleTicket: return .rejected
      case .accepted, .pendingEditsPreserved: break
      }
    case .externalReplacement:
      guard let personalTicket else { return .rejected }
      switch configuration.acceptPersonalCommit(
        outcome.personalSnapshot,
        kind: .externalReplacement,
        ticket: personalTicket
      ) {
      case .conflict: hasConflict = true
      case .rejectedStaleTicket: return .rejected
      case .accepted, .pendingEditsPreserved: break
      }
    }

    switch outcome.documentEffect {
    case .observed:
      break
    case .submittedDraft(let snapshot), .externalReplacement(let snapshot):
      guard let documentTicket else { return .rejected }
      let kind: SettingsConfigurationSession.DocumentCommitKind
      if case .externalReplacement = outcome.documentEffect {
        kind = .externalReplacement
      } else {
        kind = .submittedDraft
      }
      switch configuration.acceptDocumentCommit(
        snapshot, kind: kind, ticket: documentTicket
      ) {
      case .conflict: hasConflict = true
      case .rejectedStaleTicket: return .rejected
      case .accepted, .pendingEditsPreserved: break
      }
    case .submittedAppearance:
      return .rejected
    }
    return hasConflict ? .conflict : .accepted
  }

  private func observeCurrentConfiguration() -> SettingsConfigurationSession.ObservationResult? {
    guard let userDirectory else { return nil }
    do {
      let personalSnapshot = try LinnetPersonalDataStore.snapshot(from: userDirectory)
      let documentSnapshot = try LinnetSettingsDocumentStore.snapshot(from: userDirectory)
      let personal = configuration.observePersonal(personalSnapshot)
      let document = configuration.observeDocument(documentSnapshot)
      if personal == .conflict || document == .conflict { return .conflict }
      if personal == .reloaded || document == .reloaded { return .reloaded }
      if personal == .unchanged && document == .unchanged { return .unchanged }
      return .ignored
    } catch {
      configuration.markSourceUnreadable()
      logDiagnostic(error, context: "Personal data could not be reloaded")
      return nil
    }
  }

  private func recoverConfiguration(
    using personal: LinnetPersonalDataStore.Snapshot
  ) -> Bool {
    guard let userDirectory else { return false }
    do {
      let previousDraft = configuration.personalDraft
      let restored = SettingsConfigurationSession(
        document: try LinnetSettingsDocumentStore.snapshot(from: userDirectory),
        personal: personal,
        servicesAvailable: dataServicesAvailable
      )
      configuration = restored
      if previousDraft == restored.personalDraft {
        schedulePersonalValidation()
      }
      return configuration.readiness == .ready
    } catch {
      configuration.markSourceUnreadable()
      logDiagnostic(error, context: "Restored settings could not be loaded")
      return false
    }
  }

  func refreshBackups() {
    guard let backupsRoot else {
      backupHistory = .unavailable
      return
    }
    backupRefreshTask?.cancel()
    backupHistory.beginLoading()
    backupRefreshTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        Result { try LinnetBackupStore.listBackups(in: backupsRoot) }
      }.value
      guard !Task.isCancelled, let self else { return }
      switch result {
      case .success(let records):
        backupHistory.finishLoading(records)
      case .failure:
        // Preserve the last verified view. An unreadable or over-limit history
        // is unavailable, never authoritative evidence that no backups exist.
        backupHistory.failLoading()
        print("Backups could not be read within the bounded history contract.")
      }
      backupRefreshTask = nil
    }
  }

  private func presentationPhase(
    _ phase: SettingsDataCoordinator.Phase
  ) -> SettingsOperationPhase? {
    switch phase {
    case .preflight: .preflight
    case .pausing: .pausing
    case .snapshotting: .snapshotting
    case .staging: .staging
    case .deploying: .deploying
    case .activating: .activating
    case .verifying: .verifying
    case .cancelling: .cancelling
    case .resuming: .resuming
    case .completed, .cancelled, .failed: nil
    }
  }

  private func presentationFailure(_ error: Error) -> SettingsPresentationFailure {
    guard let failure = error as? SettingsDataCoordinator.Failure else { return .unknown }
    return switch failure {
    case .unavailable: .unavailable
    case .invalidOperation: .invalidOperation
    case .staleRevision: .staleHostState
    case .unsafePath: .unsafePath
    case .requestFailed(let code): presentationFailure(code)
    case .appearanceRestoreFailed: .appearanceRecoveryFailed
    case .configurationRestoreFailed: .configurationRecoveryFailed
    case .timedOut: .timedOut
    case .cancelled: .unknown
    }
  }

  private func presentationFailure(
    _ code: LinnetSettingsContract.RuntimeReplyCode
  ) -> SettingsPresentationFailure {
    return switch code {
    case .transactionBusy: .hostBusy
    case .appearanceDeployFailed: .deploymentFailed
    case .staleCandidate: .staleHostState
    default: .hostRejected
    }
  }

  private func logDiagnostic(_ error: Error, context: String) {
    print("\(context): \(error.localizedDescription)")
  }
}

private struct SettingsRootView: View {
  @StateObject private var model = SettingsModel()
  @AppStorage(SettingsInterfaceLanguage.defaultsKey)
  private var interfaceLanguageRawValue = SettingsInterfaceLanguage.system.rawValue
  @State private var pendingClear: Set<SettingsDataCoordinator.LearningDomain>?
  @State private var pendingPortableImport: SettingsDataCoordinator.PortableImportCandidate?
  @State private var pendingRestore: LinnetBackupStore.BackupRecord?
  @State private var pendingBackupRemoval: LinnetBackupStore.BackupRecord?
  @State private var pendingLegacyImport: SettingsDataCoordinator.LegacyImportCandidate?

  var body: some View {
    VStack(spacing: 0) {
      if model.configuration.hasExternalConflict {
        GroupBox("Settings data changed elsewhere") {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "Your unsaved drafts were preserved. Reload the current settings data, or keep your drafts and review them before applying."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
              Button("Reload Current Data") { model.reloadExternalChanges() }
              Button("Keep My Drafts") { model.keepPendingDrafts() }
            }
          }
          .padding(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      TabView {
        AppearanceTabView(model: model)
          .tabItem { Label("Appearance", systemImage: "paintbrush.pointed") }
        InputTabView(model: model)
          .tabItem { Label("Input", systemImage: "keyboard") }
        DictionaryTabView(model: model)
          .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
        EnglishTabView(model: model)
          .tabItem {
            Label {
              Text("English")
            } icon: {
              LinnetSettingsPageMarkView(mark: .latinABC, context: .tab)
                .font(.system(size: 10, weight: .bold))
            }
          }
        DataTabView(
          model: model,
          updateChecker: model.updateChecker,
          pendingClear: $pendingClear,
          pendingPortableImport: $pendingPortableImport,
          pendingRestore: $pendingRestore,
          pendingBackupRemoval: $pendingBackupRemoval,
          pendingLegacyImport: $pendingLegacyImport
        )
        .tabItem { Label("Data", systemImage: "internaldrive") }
      }
      Divider()
      footer
    }
    .task {
      model.refreshBackups()
      model.refreshLegacyImportCandidate()
      if model.diagnostics == nil { model.refreshDiagnostics() }
    }
    .confirmationDialog(
      "Import existing Rime / Hallelujah data?",
      isPresented: Binding(
        get: { pendingLegacyImport != nil },
        set: { if !$0 { pendingLegacyImport = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Import Existing", role: .destructive) {
        if let pendingLegacyImport { model.importExistingData(pendingLegacyImport) }
        pendingLegacyImport = nil
      }
      Button("Cancel", role: .cancel) { pendingLegacyImport = nil }
    } message: {
      if let pendingLegacyImport {
        Text(verbatim: model.legacyImportSummary(pendingLegacyImport, locale: interfaceLanguage.locale))
      }
    }
    .confirmationDialog(
      "Clear selected learning data?",
      isPresented: Binding(
        get: { pendingClear != nil },
        set: { if !$0 { pendingClear = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Clear Learning", role: .destructive) {
        if let pendingClear { model.clearLearning(pendingClear) }
        pendingClear = nil
      }
      Button("Cancel", role: .cancel) { pendingClear = nil }
    } message: {
      Text(
        "Personal words, disabled words, Text Expander, and English interaction settings are preserved. An automatic backup is created first."
      )
    }
    .confirmationDialog(
      "Replace categories from this portable archive?",
      isPresented: Binding(
        get: { pendingPortableImport != nil },
        set: { if !$0 { pendingPortableImport = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Import and Replace", role: .destructive) {
        if let pendingPortableImport { model.importPortable(pendingPortableImport) }
        pendingPortableImport = nil
      }
      Button("Cancel", role: .cancel) { pendingPortableImport = nil }
    } message: {
      if let pendingPortableImport {
        Text(verbatim: model.portableImportSummary(
          pendingPortableImport, locale: interfaceLanguage.locale))
      }
    }
    .confirmationDialog(
      "Restore this verified backup?",
      isPresented: Binding(
        get: { pendingRestore != nil },
        set: { if !$0 { pendingRestore = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Restore Backup", role: .destructive) {
        if let pendingRestore { model.restore(pendingRestore) }
        pendingRestore = nil
      }
      Button("Cancel", role: .cancel) { pendingRestore = nil }
    } message: {
      Text("The verified backup replaces current data. The current state is backed up first.")
    }
    .confirmationDialog(
      SettingsBackupRemovalCopy.title(locale: interfaceLanguage.locale),
      isPresented: Binding(
        get: { pendingBackupRemoval != nil },
        set: { if !$0 { pendingBackupRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(
        SettingsBackupRemovalCopy.confirmAction(locale: interfaceLanguage.locale),
        role: .destructive
      ) {
        if let pendingBackupRemoval { model.removeBackupRecord(pendingBackupRemoval) }
        pendingBackupRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingBackupRemoval = nil }
    } message: {
      Text(verbatim: SettingsBackupRemovalCopy.message(locale: interfaceLanguage.locale))
    }
    .background(SettingsWindowCloseGuard(model: model, locale: interfaceLanguage.locale))
    .onAppear {
      registerApplicationDelegate()
    }
    .onChange(of: interfaceLanguageRawValue) { _ in
      registerApplicationDelegate()
    }
    .environment(\.locale, interfaceLanguage.locale)
  }

  private var interfaceLanguage: SettingsInterfaceLanguage {
    SettingsInterfaceLanguage(rawValue: interfaceLanguageRawValue) ?? .system
  }

  private func registerApplicationDelegate() {
    guard let delegate = NSApp.delegate as? SettingsApplicationDelegate else { return }
    delegate.model = model
    delegate.interfaceLocale = interfaceLanguage.locale
  }

  private var interfaceLanguageBinding: Binding<SettingsInterfaceLanguage> {
    Binding(
      get: { interfaceLanguage },
      set: { interfaceLanguageRawValue = $0.rawValue }
    )
  }

  private var footer: some View {
    let presentation = model.displayedStatus.presentation(locale: interfaceLanguage.locale)
    return HStack(spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: presentation.systemImage)
          .accessibilityHidden(true)
        Text(verbatim: presentation.text)
          .font(.callout)
          .lineLimit(2)
          .help(presentation.text)
      }
      .foregroundStyle(presentation.severity.footerColor)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
      .accessibilityAddTraits(.updatesFrequently)
      Spacer()
      if let active = model.activeOperation {
        ProgressView().controlSize(.small)
        Text(
          SettingsPresentationStatus.operationProgress(active.kind, active.phase)
            .text(locale: interfaceLanguage.locale)
        )
          .font(.callout)
        Button("Cancel") { model.cancelActiveOperation() }
          .disabled(!active.cancellable)
      } else if model.packDownloadCancellable {
        ProgressView(value: model.packDownloadProgress)
          .frame(width: 80)
          .accessibilityLabel("Language data download")
          .accessibilityValue(
            Text(
              model.packDownloadProgress,
              format: .percent.precision(.fractionLength(0))))
        Button("Cancel Download") { model.cancelLanguagePackDownload() }
      }
      Picker(selection: interfaceLanguageBinding) {
        Text("Follow System").tag(SettingsInterfaceLanguage.system)
        Text(verbatim: "English").tag(SettingsInterfaceLanguage.english)
        Text(verbatim: "简体中文").tag(SettingsInterfaceLanguage.simplifiedChinese)
      } label: {
        Label("Language", systemImage: "globe")
      }
      .pickerStyle(.menu)
      .fixedSize()
      Button("Apply Changes") { model.applyConfiguration() }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canApplyChanges)
        .help(
          "Theme, font, and appearance mode save and apply to the candidate window live. Candidate count, candidate layouts, Input, English, and personal data require Apply Changes."
        )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }
}
