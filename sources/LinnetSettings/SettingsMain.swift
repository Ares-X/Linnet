//
//  SettingsMain.swift
//  Native, offline settings surface embedded in the input-method bundle.
//  The window has four tabs: Appearance, Input, Dictionary, and Data & Updates.
//  Smart English belongs to the Input tab.
//  Theme, typeface, and size are published immediately. Candidate count,
//  layouts, input, English, and personal-data changes remain explicit Apply
//  Changes operations.
//

import AppKit
import Combine
import os
import SwiftUI
import UniformTypeIdentifiers

private let settingsModelLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "Linnet.Settings",
  category: "Model"
)

@MainActor
final class SettingsModel: ObservableObject {
  @Published var selectedTab = 0
  @Published var backupRetentionPolicy: LinnetSettingsContract.BackupRetentionPolicy
  @Published var configuration: SettingsConfigurationSession {
    didSet {
      if oldValue.personalDraft != configuration.personalDraft {
        schedulePersonalValidation()
      }
    }
  }
  @Published var exportCategories = Set(LinnetBackupStore.Category.allCases)
  @Published var status: SettingsPresentationStatus = .ready
  @Published private(set) var activeOperation: SettingsActiveOperation?
  @Published private(set) var backupHistory: SettingsBackupHistoryState
  @Published private(set) var legacyImportState: SettingsLegacyImportState
  @Published private(set) var personalValidation: LinnetPersonalDataValidation
  @Published private(set) var personalValidationPending = false
  @Published private(set) var portableInspectionActive = false
  @Published private(set) var diagnostics: SettingsDataCoordinator.Diagnostics?
  @Published var installedPacks: [LinnetDataRegistry.ActivePack]
  @Published var dataEdition: LinnetDataRegistry.Edition?
  @Published var grammarModelStatus: GrammarModelStatus = .checking
  @Published var packDownloadProgress: Double = 0
  @Published var languageDataUpdateTarget: SettingsLanguageDataUpdateTarget?
  @Published var downloadSourceMode = LinnetSettingsDownloadSource.Mode.github
  @Published var downloadMirrorPrefix = ""
  @Published var activeDownloadSource: LinnetSettingsDownloadSource? = .direct
  @Published var downloadSourceFailure: LinnetSettingsDownloadSource.Failure?
  @Published private(set) var appearancePublishActive = false
  @Published private(set) var cloudSyncEnabled = false
  @Published private(set) var cloudSyncLocation: LinnetCloudSyncLocation?
  @Published private(set) var cloudSyncPreparing = false
  @Published var cloudSyncStatus: LinnetSettingsContract.CloudSyncStatus?
  @Published var cloudRecoveryRepairConfirmationRequired = false
  @Published var languageDataRepairTarget: SettingsLanguageDataUpdateTarget?

  let productName: String
  @Published private(set) var dataServicesAvailable: Bool
  let updateChecker: LinnetSettingsUpdateChecker

  let coordinator: SettingsDataCoordinator
  let dataRegistry: LinnetDataRegistry?
  let userDirectory: URL?
  private let backupsRoot: URL?
  private let hallelujahDatabase: URL?
  private let legacyRimeDirectory: URL?
  private var operationTask: Task<Void, Never>?
  var packDownloadTask: Task<Void, Never>?
  private var appearanceDebounceTask: Task<Void, Never>?
  private var appearancePublishTask: Task<Void, Never>?
  private var backupRefreshTask: Task<Void, Never>?
  private var legacyInspectionTask: Task<Void, Never>?
  private var updateObservation: AnyCancellable?
  private let personalValidationExecutor = SettingsPersonalValidationExecutor()
  private var pendingAppearance: LinnetSettingsDocument.Appearance?
  private var initialStatePrepared = false

  init(bundle: Bundle = .main) {
    let host = LinnetSettingsContract.hostBundle(startingAt: bundle)
    productName =
      host?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? "Input Method"
    let registry = LinnetSettingsContract.dataRegistry(startingAt: bundle)
    dataRegistry = registry
    installedPacks = []
    dataEdition = nil
    dataServicesAvailable = false
    updateChecker = LinnetSettingsUpdateChecker(
      edition: nil, installedPacks: [], bundle: bundle)
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
      settingsModelLogger.error(
        "Personal settings could not be loaded: \(error.localizedDescription, privacy: .private)"
      )
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
      settingsModelLogger.error(
        "Settings document could not be loaded: \(error.localizedDescription, privacy: .private)"
      )
    }
    let initialConfiguration = SettingsConfigurationSession(
      document: loadedDocument,
      personal: personalSnapshot,
      servicesAvailable: false
    )
    configuration = initialConfiguration
    personalValidation = .valid(initialConfiguration.personalDraft)
    legacyImportState = .unavailable
    cloudSyncEnabled = LinnetSettingsContract.cloudSyncEnabled(startingAt: bundle)
    cloudSyncStatus = LinnetSettingsContract.cloudSyncStatus(startingAt: bundle)
    schedulePersonalValidation()
    updateObservation = updateChecker.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }
}

extension SettingsModel {
  func prepareInitialState() async {
    guard !initialStatePrepared else { return }
    initialStatePrepared = true
    updateChecker.refreshRuntime()
    let registry = dataRegistry
    let snapshot = await Task.detached(priority: .userInitiated) {
      registry.flatMap { try? $0.runtimeSnapshot() }
    }.value
    dataServicesAvailable = snapshot != nil
    installedPacks = snapshot?.state.packs ?? []
    dataEdition = snapshot?.state.edition
    configuration.setServicesAvailable(dataServicesAvailable)
    legacyImportState = dataServicesAvailable ? .checking : .unavailable
    detectGrammarModel()
    updateChecker.refreshInstalledData(edition: dataEdition, packs: installedPacks)
    if cloudSyncEnabled, cloudSyncLocation == nil, !cloudSyncPreparing {
      cloudSyncPreparing = true
      defer { cloudSyncPreparing = false }
      do {
        cloudSyncLocation = try await coordinator.prepareCloudSyncLocation()
      } catch {
        settingsModelLogger.error(
          "The Linnet iCloud Drive folder is unavailable: \(error.localizedDescription, privacy: .private)"
        )
      }
    }
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
        settingsModelLogger.error(
          "Legacy import inspection failed: \(error.localizedDescription, privacy: .private)"
        )
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

  func setCloudSyncEnabled(_ enabled: Bool) async {
    guard !operationActive, !cloudSyncPreparing else { return }
    cloudSyncPreparing = true
    defer { cloudSyncPreparing = false }
    if enabled {
      do {
        let location = try await coordinator.prepareCloudSyncLocation()
        guard !Task.isCancelled else { return }
        guard LinnetSettingsContract.setCloudSyncEnabled(true) else {
          status = .operationFailed(.unavailable)
          return
        }
        cloudSyncEnabled = true
        cloudSyncLocation = location
        try await coordinator.reloadLearningSyncConfiguration()
        status = .cloudSyncEnabled
      } catch {
        settingsModelLogger.error(
          "Linnet iCloud Drive folder is unavailable: \(error.localizedDescription, privacy: .private)"
        )
        status = .operationFailed(.unavailable)
      }
    } else {
      guard LinnetSettingsContract.setCloudSyncEnabled(false) else {
        status = .operationFailed(.unavailable)
        return
      }
      cloudSyncEnabled = false
      cloudSyncLocation = nil
      do {
        try await coordinator.reloadLearningSyncConfiguration()
      } catch {
        settingsModelLogger.error(
          "Learning sync configuration reload failed: \(error.localizedDescription, privacy: .private)"
        )
        status = .operationFailed(presentationFailure(error))
        return
      }
      status = .cloudSyncDisabled
    }
  }

  func synchronizeLearningNow() {
    guard cloudSyncLocation != nil, !operationActive, !cloudSyncPreparing else { return }
    cloudSyncPreparing = true
    Task { [weak self] in
      guard let self else { return }
      defer {
        self.cloudSyncPreparing = false
        self.cloudSyncStatus = LinnetSettingsContract.cloudSyncStatus()
      }
      do {
        let completed = try await self.coordinator.synchronizeLearningNow()
        self.status = completed ? .cloudSyncCompleted : .cloudSyncDeferred
      } catch {
        settingsModelLogger.error(
          "Immediate learning sync request failed: \(error.localizedDescription, privacy: .private)"
        )
        self.status = .operationFailed(self.presentationFailure(error))
      }
    }
  }
  func uploadCloudBackupArchive(repair: Bool = false) {
    guard let cloudFolder = cloudSyncLocation?.folder, !operationActive else { return }
    run(
      .cloudBackup,
      operation: .exportCloudRecovery(
        categories: Set(LinnetBackupStore.Category.allCases),
        cloudFolder: cloudFolder,
        repair: repair
      )
    ) { outcome in
      guard let recovery = outcome.cloudRecovery else { return .operationFailed(.unknown) }
      return switch recovery.kind {
      case .uploaded: .cloudBackupUploaded(recovery.verifiedAt)
      case .unchanged: .cloudBackupUnchanged(recovery.verifiedAt)
      }
    }
  }

  func inspectCloudBackupArchive() async -> SettingsDataCoordinator.PortableImportCandidate? {
    guard configuration.canPersist, !operationActive, !portableInspectionActive,
      let cloudFolder = cloudSyncLocation?.folder
    else {
      status = .operationFailed(.unavailable)
      return nil
    }
    portableInspectionActive = true
    status = .operationProgress(.portableImport, .preflight)
    defer { portableInspectionActive = false }
    do {
      guard let candidate = try await coordinator.inspectCloudRecovery(in: cloudFolder) else {
        status = .operationFailed(.unavailable)
        return nil
      }
      status = .ready
      return candidate
    } catch SettingsDataCoordinator.Failure.cancelled {
      status = .operationCancelled; return nil
    } catch {
      settingsModelLogger.error(
        "Cloud recovery inspection failed: \(error.localizedDescription, privacy: .private)"
      )
      status = .operationFailed(presentationFailure(error))
      return nil
    }
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
      status = .operationCancelled; return nil
    } catch {
      settingsModelLogger.error(
        "Portable import inspection failed: \(error.localizedDescription, privacy: .private)"
      )
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
      let documentTicket = configuration.makeDocumentTicket() {
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
    run(.clearLearning, operation: .clearLearning(domains)) { _ in .learningCleared }
  }

  func refreshDiagnostics() {
    run(.diagnostics, operation: .diagnose) { [weak self] outcome in
      self?.diagnostics = outcome.diagnostics
      return outcome.diagnostics?.reachability == .unreachable ? .diagnosticsUnreachable : .diagnosticsRefreshed
    }
  }

  func cancelActiveOperation() {
    guard activeOperation?.cancellable == true else { return }
    activeOperation?.cancellationAvailable = false
    activeOperation?.cancellationRequested = true
    status = .cancellingOperation
    operationTask?.cancel()
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
    let acceptance = SettingsOperationAcceptanceContext(
      personalTicket: personalTicket,
      documentTicket: documentTicket,
      recoveryAfterCommit: recoveryAfterCommit
    )
    operationTask = Task { [weak self] in
      guard let self else { return }
      let acceptedForCompletion = await perform(
        kind,
        operation: operation,
        acceptance: acceptance,
        success: success
      )
      refreshBackups()
      activeOperation = nil
      operationTask = nil
      startPendingAppearancePublish()
      completion?(acceptedForCompletion && !pendingChanges)
    }
  }

  private func perform(
    _ kind: SettingsOperationKind,
    operation: SettingsDataCoordinator.DataOperation,
    acceptance: SettingsOperationAcceptanceContext,
    success: @escaping @MainActor (SettingsDataCoordinator.Outcome) -> SettingsPresentationStatus
  ) async -> Bool {
    do {
      let outcome = try await coordinator.run(operation) { [weak self] update in
        Task { @MainActor [weak self] in self?.setProgress(update, for: kind) }
      }
      return present(
        outcome,
        for: kind,
        acceptance: acceptance,
        success: success
      )
    } catch SettingsDataCoordinator.Failure.staleRevision {
      presentStaleOperation()
    } catch SettingsDataCoordinator.Failure.cancelled {
      status = .operationCancelled
    } catch SettingsDataCoordinator.Failure.cloudRecoveryRepairRequired {
      cloudRecoveryRepairConfirmationRequired = true
      status = .cloudBackupRepairRequired
    } catch {
      settingsModelLogger.error(
        "Settings operation failed: \(error.localizedDescription, privacy: .private)"
      )
      status = kind == .removeBackup
        ? .backupRecordRemovalFailed
        : .operationFailed(presentationFailure(error))
    }
    return false
  }

  private func present(
    _ outcome: SettingsDataCoordinator.Outcome,
    for kind: SettingsOperationKind,
    acceptance: SettingsOperationAcceptanceContext,
    success: @escaping @MainActor (SettingsDataCoordinator.Outcome) -> SettingsPresentationStatus
  ) -> Bool {
    switch accept(
      outcome,
      personalTicket: acceptance.personalTicket,
      documentTicket: acceptance.documentTicket,
      recoveryAfterCommit: acceptance.recoveryAfterCommit
    ) {
    case .accepted:
      if kind == .apply { cancelPendingAppearancePublish() }
      status = success(outcome)
      return true
    case .conflict:
      status = .configurationConflict
    case .rejected:
      status = .operationFailed(.invalidOperation)
    }
    return false
  }

  /// Apply and Discard are terminal for work queued by the live appearance
  /// path. Keeping cancellation and payload removal together prevents a stale
  /// debounce wake-up from publishing after either terminal transition.
  private func cancelPendingAppearancePublish() {
    appearanceDebounceTask?.cancel()
    appearanceDebounceTask = nil
    pendingAppearance = nil
  }

  func startPendingAppearancePublish() {
    appearanceDebounceTask = nil
    guard let context = pendingAppearancePublishContext() else { return }

    pendingAppearance = nil
    appearancePublishActive = true
    status = .publishingAppearance
    appearancePublishTask = Task { [weak self] in
      guard let self else { return }
      do {
        let outcome = try await coordinator.run(
          .publishAppearance(
            appearance: context.appearance,
            basePersonalRevision: context.personalRevision,
            baseDocumentRevision: context.documentTicket.baselineRevision)
        )
        guard case .submittedAppearance(let snapshot) = outcome.documentEffect,
          configuration.acceptAppearanceCommit(snapshot, ticket: context.documentTicket)
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
        presentStaleAppearancePublish()
      } catch SettingsDataCoordinator.Failure.cancelled {
        if let baseline = configuration.documentBaseline {
          pendingAppearance = configuration.documentDraft.appearance.livePanelProjection(
            over: baseline.appearance)
        }
      } catch {
        settingsModelLogger.error(
          "Candidate appearance publish failed: \(error.localizedDescription, privacy: .private)"
        )
        status = .appearanceFailed(presentationFailure(error))
      }
      appearancePublishActive = false
      appearancePublishTask = nil
      startPendingAppearancePublish()
    }
  }

  private func pendingAppearancePublishContext() -> (
    appearance: LinnetSettingsDocument.Appearance,
    personalRevision: String,
    documentTicket: SettingsConfigurationSession.DocumentTicket
  )? {
    guard appearancePublishTask == nil else { return nil }
    guard operationTask == nil else { return nil }
    guard !packDownloadActive else { return nil }
    guard configuration.canPersist else { return nil }
    guard let appearance = pendingAppearance else { return nil }
    guard let baseline = configuration.documentBaseline else { return nil }
    guard let personalRevision = configuration.personalBaselineRevision else { return nil }
    guard let documentTicket = configuration.makeDocumentTicket() else { return nil }
    guard appearance != baseline.appearance else {
      pendingAppearance = nil
      return nil
    }
    return (appearance, personalRevision, documentTicket)
  }

  private func presentStaleAppearancePublish() {
    let observation = observeCurrentConfiguration()
    if configuration.canPersist,
      observation == .reloaded || observation == .unchanged,
      let baseline = configuration.documentBaseline {
      pendingAppearance = configuration.documentDraft.appearance.livePanelProjection(
        over: baseline.appearance)
      status = .appearanceStaleRetry
    } else if observation == .conflict {
      status = .configurationConflict
    } else {
      status = .operationFailed(.invalidOperation)
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

  private func accept(
    _ outcome: SettingsDataCoordinator.Outcome,
    personalTicket: SettingsConfigurationSession.PersonalTicket?,
    documentTicket: SettingsConfigurationSession.DocumentTicket?,
    recoveryAfterCommit: Bool
  ) -> SettingsOutcomeAcceptance {
    if let result = outcome.diagnostics { diagnostics = result }
    if recoveryAfterCommit {
      guard case .externalReplacement = outcome.personalEffect,
        case .externalReplacement = outcome.documentEffect,
        recoverConfiguration(using: outcome.personalSnapshot)
      else { return .rejected }
      return .accepted
    }

    let personalAcceptance = acceptPersonalEffect(outcome, ticket: personalTicket)
    guard personalAcceptance != .rejected else { return .rejected }
    let documentAcceptance = acceptDocumentEffect(outcome, ticket: documentTicket)
    guard documentAcceptance != .rejected else { return .rejected }
    return personalAcceptance == .conflict || documentAcceptance == .conflict
      ? .conflict : .accepted
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
      settingsModelLogger.error(
        "Restored settings could not be loaded: \(error.localizedDescription, privacy: .private)"
      )
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
        settingsModelLogger.error("Backups could not be read within the bounded history contract.")
      }
      backupRefreshTask = nil
    }
  }

}
