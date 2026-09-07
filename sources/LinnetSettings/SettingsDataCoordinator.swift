import Foundation

/// The single Settings-side owner for personal data, learning data, legacy import,
/// portable archives, backup creation and restore candidate preparation.
actor SettingsDataCoordinator {
  enum CancellationCapability: Equatable, Sendable {
    case available
    case unavailable
  }

  struct OperationProgress: Equatable, Sendable {
    let phase: SettingsOperationPhase
    let cancellation: CancellationCapability
  }

  enum PersonalEffect: Equatable, Sendable {
    case observed
    case submittedDraft
    case externalReplacement
  }

  enum DocumentEffect: Equatable, Sendable {
    case observed
    case submittedDraft(LinnetSettingsDocumentStore.Snapshot)
    case submittedAppearance(LinnetSettingsDocumentStore.Snapshot)
    case externalReplacement(LinnetSettingsDocumentStore.Snapshot)
  }

  enum LearningDomain: String, CaseIterable, Hashable, Sendable {
    case chinese
    case english

    var schema: String {
      switch self {
      case .chinese: LinnetSettingsContract.chineseLearningDictionary
      case .english: LinnetSettingsContract.englishSchemaID
      }
    }
  }

  struct LegacyImportCandidate: Sendable {
    enum Source: String, CaseIterable, Hashable, Sendable {
      case hallelujah
      case rime
    }

    let sources: [Source]
    let substitutionCount: Int
    let recognizedLearningDictionaryCount: Int
    let hallelujah: HallelujahSubstitutionImporter.PreparedSource?
    let legacyUserDirectory: RimeUserDataBridge.PreparedUserDirectory?
  }

  struct PortableImportCandidate: Sendable {
    let categories: [LinnetBackupStore.Category]
    let recordCount: Int
    let appVersion: String
    let dataVersion: String
    let archive: LinnetBackupStore.PortableArchive
  }

  enum DataOperation: Sendable {
    /// Publishes only panel-safe appearance fields against the current live
    /// document. Schema-owned page size cannot travel on this path.
    case publishAppearance(
      appearance: LinnetSettingsDocument.Appearance,
      basePersonalRevision: String,
      baseDocumentRevision: String
    )
    case applyConfiguration(
      personal: LinnetPersonalData,
      document: LinnetSettingsDocument,
      basePersonalRevision: String,
      baseDocumentRevision: String
    )
    case importLegacy(LegacyImportCandidate)
    case exportPortable(
      categories: Set<LinnetBackupStore.Category>,
      destination: URL
    )
    case exportCloudRecovery(
      categories: Set<LinnetBackupStore.Category>,
      cloudFolder: URL,
      repair: Bool
    )
    case importPortable(PortableImportCandidate, baseRevision: String)
    case restoreBackup(URL)
    case removeBackupRecord(LinnetBackupStore.BackupRecord)
    case clearLearning(Set<LearningDomain>)
    case diagnose
  }

  struct Diagnostics: Equatable, Sendable {
    let reachability: SettingsRuntimeReachability
    let runtime: LinnetSettingsContract.RuntimeHealth?
    let productName: String
    let appVersion: String
    let dataVersion: String
    let settingsVersion: Int
    let customWordCount: Int
    let disabledWordCount: Int
    let expansionCount: Int
    let verifiedBackupCount: Int
    let incompleteBackupCount: Int
    let corruptBackupCount: Int

    var redactedReport: String {
      [
        "\(productName) diagnostics",
        "runtime=\(reachability.rawValue)",
        "runtime_phase=\(runtime?.phase.rawValue ?? "unreachable")",
        "rime_version=\(runtime?.rimeVersion ?? "unreachable")",
        "smart_english=\(runtime.map { String($0.smartEnglishAvailable) } ?? "unreachable")",
        "octagram=\(runtime.map { String($0.octagramAvailable) } ?? "unreachable")",
        "schemas=\(runtime.map { "\($0.availableSchemaCount)/\($0.requiredSchemaCount)" } ?? "unreachable")",
        "app_version=\(appVersion)",
        "data_version=\(dataVersion)",
        "settings_version=\(settingsVersion)",
        "personal_counts=custom:\(customWordCount),disabled:\(disabledWordCount),expansions:\(expansionCount)",
        "backups=verified:\(verifiedBackupCount),incomplete:\(incompleteBackupCount),corrupt:\(corruptBackupCount)"
      ].joined(separator: "\n")
    }
  }

  struct Outcome: Sendable {
    let backupDirectory: URL?
    let personalSnapshot: LinnetPersonalDataStore.Snapshot
    let personalEffect: PersonalEffect
    let documentEffect: DocumentEffect
    let importReport: HallelujahSubstitutionImporter.Report?
    let legacyImportedCount: Int
    let diagnostics: Diagnostics?
    let cloudRecovery: LinnetCloudRecoveryArchive.Outcome?

    init(
      backupDirectory: URL?,
      personalSnapshot: LinnetPersonalDataStore.Snapshot,
      personalEffect: PersonalEffect,
      documentEffect: DocumentEffect,
      importReport: HallelujahSubstitutionImporter.Report?,
      legacyImportedCount: Int,
      diagnostics: Diagnostics?,
      cloudRecovery: LinnetCloudRecoveryArchive.Outcome? = nil
    ) {
      self.backupDirectory = backupDirectory
      self.personalSnapshot = personalSnapshot
      self.personalEffect = personalEffect
      self.documentEffect = documentEffect
      self.importReport = importReport
      self.legacyImportedCount = legacyImportedCount
      self.diagnostics = diagnostics
      self.cloudRecovery = cloudRecovery
    }
  }

  enum Failure: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidOperation(String)
    case staleRevision(expected: String, actual: String)
    case unsafePath(String)
    case requestFailed(LinnetSettingsContract.RuntimeReplyCode)
    case appearanceRestoreFailed
    case configurationRestoreFailed
    case timedOut
    case cancelled
    case cloudRecoveryRepairRequired

    var errorDescription: String? {
      switch self {
      case .unavailable: String(localized: "Data services are unavailable.")
      case .invalidOperation(let detail): "Invalid data operation: \(detail)"
      case .staleRevision: "Personal data changed. Reload it before applying this operation."
      case .unsafePath(let path): "Unsafe data path: \(path)"
      case .requestFailed(let code): "The input method rejected the operation: \(code.rawValue)"
      case .appearanceRestoreFailed:
        "The previous candidate appearance could not be restored consistently."
      case .configurationRestoreFailed:
        "The previous runtime configuration could not be restored consistently."
      case .timedOut: "The input method did not reply in time."
      case .cancelled: "The data operation was cancelled."
      case .cloudRecoveryRepairRequired:
        "Cloud recovery needs explicit full-repair confirmation."
      }
    }
  }

  struct Environment {
    let registry: LinnetDataRegistry
    let shared: URL
    let product: String
    let live: URL
    let transactionsRoot: URL
    let backupsRoot: URL
    let mutationLease: URL
    let appVersion: String
    let dataVersion: String
    let maximumVerifiedBackups: Int
  }

  enum PreparedOperation {
    case apply(
      LinnetPersonalData,
      document: LinnetSettingsDocument,
      basePersonalRevision: String,
      baseDocumentRevision: String,
      scope: ApplyScope
    )
    case legacy(
      hallelujah: HallelujahSubstitutionImporter.PreparedSource?,
      legacyUserDirectory: RimeUserDataBridge.PreparedUserDirectory?
    )
    case export(Set<LinnetBackupStore.Category>, destination: URL)
    case cloudRecovery(
      Set<LinnetBackupStore.Category>, cloudFolder: URL, repair: Bool)
    case portable(LinnetBackupStore.PortableArchive, baseRevision: String)
    case restore(URL, LinnetBackupStore.BackupManifest)
    case removeBackup(LinnetBackupStore.BackupRecord)
    case clear(Set<LearningDomain>)
    case diagnose
  }

  /// How an apply must be executed. Personal dictionaries alone require the
  /// full backup/swap transaction; schema-owned document edits reload the
  /// already-written live configuration without touching learning data.
  enum ApplyScope: Equatable {
    case appearanceOnly
    case configurationOnly
    case full
  }

  let bundle: Bundle
  private let timeout: TimeInterval
  let registryOverride: LinnetDataRegistry?
  let transactionRequester: LinnetSettingsTransactionRequesting
  let fileManager = FileManager.default
  let bridge = RimeUserDataBridge()

  /// Read-only diagnostics and live appearance refreshes must not stall the
  /// Settings window when the input method is not running. Data mutations
  /// keep the full transaction timeout.
  static let interactiveRequestTimeout: TimeInterval = 3
  static let learningSyncRequestTimeout: TimeInterval = 65
  static let transactionRequestTimeout: TimeInterval = 300
  static let configurationCandidateName = "configuration-candidate"

  init(
    bundle: Bundle = .main,
    timeout: TimeInterval = 30,
    dataRegistry: LinnetDataRegistry? = nil,
    transactionRequester: LinnetSettingsTransactionRequesting? = nil
  ) {
    self.bundle = bundle
    self.timeout = timeout
    registryOverride = dataRegistry
    self.transactionRequester = transactionRequester
      ?? LinnetSettingsTransactionIPC.Client(startingAt: bundle)
  }

}

extension SettingsDataCoordinator {
  func inspectLegacy(
    hallelujahDatabase: URL?,
    legacyUserDirectory: URL?
  ) throws -> LegacyImportCandidate? {
    guard !Task.isCancelled else { throw Failure.cancelled }
    let hallelujah: HallelujahSubstitutionImporter.PreparedSource?
    do {
      if let database = hallelujahDatabase, try sourceExists(database) {
        hallelujah = try HallelujahSubstitutionImporter.prepare(
          sourceDatabase: database, timeout: timeout)
      } else {
        hallelujah = nil
      }
    } catch HallelujahSubstitutionImporter.Failure.deadlineExceeded {
      throw Failure.timedOut
    } catch is CancellationError {
      throw Failure.cancelled
    } catch let failure as HallelujahSubstitutionImporter.Failure {
      throw Failure.invalidOperation("Hallelujah import failed: \(failure)")
    }
    guard !Task.isCancelled else { throw Failure.cancelled }
    let legacy: RimeUserDataBridge.PreparedUserDirectory?
    do {
      if let directory = legacyUserDirectory, try sourceExists(directory) {
        let runtime = try environment()
        legacy = try bridge.prepareLegacyDirectory(
          directory,
          shared: runtime.shared,
          product: runtime.product
        )
      } else {
        legacy = nil
      }
    } catch let failure as RimeUserDataBridge.Failure {
      throw Failure.invalidOperation("Legacy Rime import failed: \(failure)")
    }
    guard !Task.isCancelled else { throw Failure.cancelled }
    let acceptedHallelujah = hallelujah.flatMap { $0.substitutionCount > 0 ? $0 : nil }
    let acceptedLegacy = legacy.flatMap { $0.recognizedDictionaryCount > 0 ? $0 : nil }
    guard acceptedHallelujah != nil || acceptedLegacy != nil else { return nil }
    return LegacyImportCandidate(
      sources: LegacyImportCandidate.Source.allCases.filter {
        $0 == .hallelujah ? acceptedHallelujah != nil : acceptedLegacy != nil
      },
      substitutionCount: acceptedHallelujah?.substitutionCount ?? 0,
      recognizedLearningDictionaryCount: acceptedLegacy?.recognizedDictionaryCount ?? 0,
      hallelujah: acceptedHallelujah,
      legacyUserDirectory: acceptedLegacy
    )
  }

  func inspectPortable(_ source: URL) throws -> PortableImportCandidate {
    guard !Task.isCancelled else { throw Failure.cancelled }
    let archive = try LinnetBackupStore.decodePortable(
      LinnetBackupStore.readBoundedRegularFile(
        source, limit: LinnetBackupStore.maximumPortableBytes
      )
    )
    guard !Task.isCancelled else { throw Failure.cancelled }
    return PortableImportCandidate(
      categories: archive.categories.sorted { $0.rawValue < $1.rawValue },
      recordCount: archive.personal.reduce(0) { $0 + $1.rowCount }
        + archive.learning.reduce(0) { $0 + $1.rowCount },
      appVersion: archive.appVersion,
      dataVersion: archive.dataVersion,
      archive: archive
    )
  }

  /// Filesystem preparation belongs to this actor, not the Settings UI executor.
  func prepareCloudSyncLocation() throws -> LinnetCloudSyncLocation {
    let location = try LinnetCloudSyncLocation.productLocation()
    _ = try location.prepareLearningDirectory()
    return location
  }

  /// Cloud recovery reconstruction can invoke rsync and read a full archive;
  /// it stays on this coordinator actor rather than the Settings main actor.
  func inspectCloudRecovery(
    in cloudFolder: URL
  ) throws -> PortableImportCandidate? {
    guard !Task.isCancelled else { throw Failure.cancelled }
    let scratch = fileManager.temporaryDirectory.appending(
      path: "CloudRecoveryInspect-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: scratch) }
    do {
      guard let materialized = try LinnetCloudRecoveryArchive.materializeLatest(
        in: cloudFolder, workspace: scratch)
      else { return nil }
      return try inspectPortable(materialized)
    } catch LinnetCloudRecoveryArchive.Failure.cloudItemUnavailable(_) {
      throw Failure.unavailable
    }
  }

  func run(
    _ operation: DataOperation,
    progress: @escaping @Sendable (OperationProgress) -> Void = { _ in }
  ) async throws -> Outcome {
    let phaseProgress: @Sendable (SettingsOperationPhase) -> Void = { phase in
      progress(Self.operationProgress(for: operation, phase: phase))
    }
    let personalEffect = Self.personalEffect(for: operation)
    phaseProgress(.preflight)
    do {
      let environment = try environment()
      let lease: LinnetSettingsMutationLease?
      if mutationRequiresLease(operation) {
        do {
          lease = try await LinnetSettingsMutationLease.acquire(
            at: environment.mutationLease, timeout: timeout)
        } catch LinnetSettingsMutationLease.Failure.timedOut {
          throw Failure.timedOut
        } catch LinnetSettingsMutationLease.Failure.unavailable {
          throw Failure.unavailable
        }
      } else {
        lease = nil
      }
      defer { _ = lease }
      let prepared = try prepare(operation)
      let outcome: Outcome
      switch prepared {
      case .export(let categories, let destination):
        outcome = try await exportPortable(
          categories: categories,
          destination: destination,
          environment: environment,
          personalEffect: personalEffect,
          progress: phaseProgress
        )
      case .cloudRecovery(let categories, let cloudFolder, let repair):
        outcome = try await exportCloudRecovery(
          categories: categories,
          cloudFolder: cloudFolder,
          repair: repair,
          environment: environment,
          personalEffect: personalEffect,
          progress: phaseProgress
        )
      case .diagnose:
        outcome = try await diagnose(
          environment: environment, personalEffect: personalEffect)
      case .removeBackup(let record):
        outcome = try await removeBackup(
          record,
          environment: environment,
          personalEffect: personalEffect,
          progress: phaseProgress
        )
      case .apply(
        _, let document, let basePersonalRevision,
        let baseDocumentRevision, let scope) where scope != .full:
        outcome = try await applyDocument(
          document: document,
          scope: scope,
          basePersonalRevision: basePersonalRevision,
          baseDocumentRevision: baseDocumentRevision,
          environment: environment,
          personalEffect: personalEffect,
          progress: phaseProgress
        )
      default:
        outcome = try await mutate(
          prepared,
          environment: environment,
          personalEffect: personalEffect,
          progress: phaseProgress
        )
      }
      phaseProgress(.completed)
      return outcome
    } catch is CancellationError {
      phaseProgress(.cancelled)
      throw Failure.cancelled
    } catch Failure.cancelled {
      phaseProgress(.cancelled)
      throw Failure.cancelled
    } catch HallelujahSubstitutionImporter.Failure.deadlineExceeded {
      phaseProgress(.failed)
      throw Failure.timedOut
    } catch let failure as HallelujahSubstitutionImporter.Failure {
      phaseProgress(.failed)
      throw Failure.invalidOperation("Hallelujah import failed: \(failure)")
    } catch LinnetCloudRecoveryArchive.Failure.needsConfirmedRepair {
      phaseProgress(.failed)
      throw Failure.cloudRecoveryRepairRequired
    } catch LinnetCloudRecoveryArchive.Failure.cloudItemUnavailable(_) {
      phaseProgress(.failed)
      throw Failure.unavailable
    } catch {
      phaseProgress(.failed)
      throw error
    }
  }

  static func operationProgress(
    for operation: DataOperation,
    phase: SettingsOperationPhase
  ) -> OperationProgress {
    let cancellation: CancellationCapability
    switch (operation, phase) {
    case (.applyConfiguration, .preflight), (.applyConfiguration, .pausing),
      (.importLegacy, .preflight), (.importLegacy, .pausing),
      (.importPortable, .preflight), (.importPortable, .pausing),
      (.restoreBackup, .preflight), (.restoreBackup, .pausing),
      (.clearLearning, .preflight), (.clearLearning, .pausing),
      (.publishAppearance, .preflight), (.publishAppearance, .staging),
      (.exportPortable, .preflight), (.exportPortable, .pausing),
      (.exportPortable, .snapshotting),
      (.exportCloudRecovery, .preflight), (.exportCloudRecovery, .pausing),
      (.exportCloudRecovery, .snapshotting),
      (.removeBackupRecord, .preflight):
      cancellation = .available
    default:
      cancellation = .unavailable
    }
    return OperationProgress(phase: phase, cancellation: cancellation)
  }

  static func personalEffect(for operation: DataOperation) -> PersonalEffect {
    switch operation {
    case .applyConfiguration:
      return .submittedDraft
    case .importLegacy, .importPortable, .restoreBackup:
      return .externalReplacement
    case .publishAppearance, .exportPortable, .exportCloudRecovery,
      .removeBackupRecord, .clearLearning, .diagnose:
      return .observed
    }
  }

  func activateLanguage(
    _ activation: LinnetDataRegistry.ActivationCandidate,
    progress: @escaping @Sendable (SettingsOperationPhase) -> Void = { _ in }
  ) async throws {
    let registry = registryOverride ?? LinnetSettingsContract.dataRegistry(startingAt: bundle)
    guard let registry else { throw Failure.unavailable }
    let transaction = registry.transactionsDirectory.appending(
      path: activation.transactionID.uuidString, directoryHint: .isDirectory)
    guard activation.directory.standardizedFileURL
      == transaction.appending(path: "language-active", directoryHint: .isDirectory)
        .standardizedFileURL
    else {
      throw Failure.unsafePath(activation.directory.path)
    }
    try requireDirectory(transaction)
    try requireDirectory(activation.directory)

    let deadline = Date().addingTimeInterval(Self.transactionRequestTimeout)
    var paused = false
    do {
      progress(.pausing)
      let pause = try await request(
        makeRequest(
          transactionID: activation.transactionID,
          command: .pause,
          candidate: nil,
          deadline: deadline,
          expectedActiveRevision: activation.expectedActiveRevision
        ),
        replyTimeout: try remainingTransactionTime(until: deadline),
        progress: progress
      )
      guard pause.status == .paused else { throw Failure.requestFailed(pause.code) }
      paused = true
      try Task.checkCancellation()
      progress(.activating)
      let reply = try await request(
        makeRequest(
          transactionID: activation.transactionID,
          command: .activateLanguage,
          candidate: activation.directory,
          deadline: deadline,
          expectedActiveRevision: activation.expectedActiveRevision
        ),
        replyTimeout: try remainingTransactionTime(until: deadline),
        progress: progress
      )
      switch reply.status {
      case .activated:
        paused = false
        progress(.completed)
      case .rolledBack:
        paused = false
        throw Failure.requestFailed(reply.code)
      case .failed:
        paused = false
        throw Failure.requestFailed(reply.code)
      default:
        throw Failure.requestFailed(reply.code)
      }
    } catch {
      let operationError = error
      var resumeError: Error?
      if paused {
        progress(.cancelling)
        do {
          let resume = try await request(
            makeRequest(
              transactionID: activation.transactionID,
              command: .cancel,
              candidate: nil,
              deadline: deadline
            ),
            replyTimeout: try remainingTransactionTime(until: deadline),
            progress: progress
          )
          if resume.status != .cancelled {
            resumeError = Failure.requestFailed(resume.code)
          }
        } catch {
          resumeError = error
        }
      }
      if let resumeError { throw resumeError }
      throw operationError
    }
  }
}
