import Darwin
import Foundation

/// The single Settings-side owner for personal data, learning data, legacy import,
/// portable archives, backup creation and restore candidate preparation.
actor SettingsDataCoordinator {
  enum Phase: String, CaseIterable, Equatable, Sendable {
    case preflight
    case pausing
    case snapshotting
    case staging
    case deploying
    case activating
    case verifying
    case cancelling
    case resuming
    case completed
    case cancelled
    case failed
  }

  enum CancellationCapability: Equatable, Sendable {
    case available
    case unavailable
  }

  struct OperationProgress: Equatable, Sendable {
    let phase: Phase
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
      case .chinese: RimeUserDataBridge.chineseSchema
      case .english: RimeUserDataBridge.englishSchema
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
    fileprivate let hallelujah: HallelujahSubstitutionImporter.PreparedSource?
    fileprivate let legacyUserDirectory: RimeUserDataBridge.PreparedUserDirectory?
  }

  struct PortableImportCandidate: Sendable {
    let categories: [LinnetBackupStore.Category]
    let recordCount: Int
    let appVersion: String
    let dataVersion: String
    fileprivate let archive: LinnetBackupStore.PortableArchive
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
    case importPortable(PortableImportCandidate, baseRevision: String)
    case restoreBackup(URL)
    case removeBackupRecord(LinnetBackupStore.BackupRecord)
    case clearLearning(Set<LearningDomain>)
    case diagnose
  }

  struct Diagnostics: Equatable, Sendable {
    enum Reachability: String, Equatable, Sendable {
      case running
      case paused
      case degraded
      case unreachable
    }

    let reachability: Reachability
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
        "backups=verified:\(verifiedBackupCount),incomplete:\(incompleteBackupCount),corrupt:\(corruptBackupCount)",
      ].joined(separator: "\n")
    }
  }

  struct Outcome: Sendable {
    let transactionID: UUID
    let backupDirectory: URL?
    let personalSnapshot: LinnetPersonalDataStore.Snapshot
    let personalEffect: PersonalEffect
    let documentEffect: DocumentEffect
    let importReport: HallelujahSubstitutionImporter.Report?
    let legacyImportedCount: Int
    let portableURL: URL?
    let diagnostics: Diagnostics?
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
      }
    }
  }

  private struct Environment {
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

  private enum PreparedOperation {
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
    case portable(LinnetBackupStore.PortableArchive, baseRevision: String)
    case restore(URL, LinnetBackupStore.BackupManifest)
    case removeBackup(LinnetBackupStore.BackupRecord)
    case clear(Set<LearningDomain>)
    case diagnose
  }

  /// How an apply must be executed. Personal dictionaries alone require the
  /// full backup/swap transaction; schema-owned document edits reload the
  /// already-written live configuration without touching learning data.
  private enum ApplyScope: Equatable {
    case appearanceOnly
    case configurationOnly
    case full
  }

  private let bundle: Bundle
  private let timeout: TimeInterval
  private let registryOverride: LinnetDataRegistry?
  private let transactionRequester: LinnetSettingsTransactionRequesting
  private let fileManager = FileManager.default
  private let bridge = RimeUserDataBridge()

  /// Read-only diagnostics and live appearance refreshes must not stall the
  /// Settings window when the input method is not running. Data mutations
  /// keep the full transaction timeout.
  private static let interactiveRequestTimeout: TimeInterval = 3
  private static let transactionRequestTimeout: TimeInterval = 300
  private static let configurationCandidateName = "configuration-candidate"

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

  func run(
    _ operation: DataOperation,
    progress: @escaping @Sendable (OperationProgress) -> Void = { _ in }
  ) async throws -> Outcome {
    let phaseProgress: @Sendable (Phase) -> Void = { phase in
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
        let data, let document, let basePersonalRevision,
        let baseDocumentRevision, .appearanceOnly):
        outcome = try await applyAppearance(
          data: data,
          document: document,
          basePersonalRevision: basePersonalRevision,
          baseDocumentRevision: baseDocumentRevision,
          environment: environment,
          personalEffect: personalEffect,
          progress: phaseProgress
        )
      case .apply(
        let data, let document, let basePersonalRevision,
        let baseDocumentRevision, .configurationOnly):
        outcome = try await applyConfiguration(
          data: data,
          document: document,
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
    } catch {
      phaseProgress(.failed)
      throw error
    }
  }

  static func operationProgress(
    for operation: DataOperation,
    phase: Phase
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
    case .publishAppearance, .exportPortable, .removeBackupRecord, .clearLearning, .diagnose:
      return .observed
    }
  }

  func activateLanguage(
    _ activation: LinnetDataRegistry.ActivationCandidate,
    progress: @escaping @Sendable (Phase) -> Void = { _ in }
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

extension SettingsDataCoordinator {
  private func prepare(_ operation: DataOperation) throws -> PreparedOperation {
    switch operation {
    case .publishAppearance(
      let appearance, let personalRevision, let documentRevision):
      guard !personalRevision.isEmpty, !documentRevision.isEmpty else {
        throw Failure.invalidOperation("empty revision")
      }
      let live = try liveUserDirectory()
      let snapshot = try LinnetPersonalDataStore.snapshot(from: live)
      var document = try liveDocument()
      document.appearance = appearance.livePanelProjection(over: document.appearance)
      return .apply(
        snapshot.data,
        document: document.normalized(),
        basePersonalRevision: personalRevision,
        baseDocumentRevision: documentRevision,
        scope: .appearanceOnly
      )
    case .applyConfiguration(
      let data, let document, let personalRevision, let documentRevision):
      guard !personalRevision.isEmpty, !documentRevision.isEmpty else {
        throw Failure.invalidOperation("empty revision")
      }
      let normalizedData = try LinnetPersonalDataStore.normalized(data)
      let normalizedDocument = document.normalized()
      return .apply(
        normalizedData,
        document: normalizedDocument,
        basePersonalRevision: personalRevision,
        baseDocumentRevision: documentRevision,
        scope: try applyScope(data: normalizedData, document: normalizedDocument)
      )
    case .importLegacy(let candidate):
      if let legacy = candidate.legacyUserDirectory {
        try RimeUserDataBridge.validatePreparedUserDirectory(legacy)
      }
      return .legacy(
        hallelujah: candidate.hallelujah,
        legacyUserDirectory: candidate.legacyUserDirectory
      )
    case .exportPortable(let categories, let destination):
      guard !categories.isEmpty else { throw Failure.invalidOperation("no export category") }
      guard destination.pathExtension == LinnetBackupStore.portableExtension else {
        throw Failure.invalidOperation("portable extension")
      }
      try requireWritableDestination(destination)
      return .export(categories, destination: destination)
    case .importPortable(let candidate, let revision):
      guard !revision.isEmpty else { throw Failure.invalidOperation("empty revision") }
      return .portable(candidate.archive, baseRevision: revision)
    case .restoreBackup(let backup):
      let manifest = try LinnetBackupStore.verifyBackup(at: backup)
      return .restore(backup, manifest)
    case .removeBackupRecord(let record):
      guard record.transactionID != nil else {
        throw Failure.invalidOperation("backup transaction identity")
      }
      if case .verified = record.state {
        throw Failure.invalidOperation("verified backup removal")
      }
      return .removeBackup(record)
    case .clearLearning(let domains):
      guard !domains.isEmpty else { throw Failure.invalidOperation("no learning domain") }
      return .clear(domains)
    case .diagnose:
      return .diagnose
    }
  }

  private func sourceExists(_ source: URL) throws -> Bool {
    guard source.isFileURL else { throw Failure.unsafePath(source.absoluteString) }
    var info = stat()
    if lstat(source.path, &info) == 0 { return true }
    if errno == ENOENT { return false }
    throw Failure.unsafePath(source.path)
  }

  private func exportPortable(
    categories: Set<LinnetBackupStore.Category>,
    destination: URL,
    environment: Environment,
    personalEffect: PersonalEffect,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Outcome {
    let transactionID = UUID()
    let scratch = fileManager.temporaryDirectory.appending(
      path: "DataExport-\(transactionID.uuidString)",
      directoryHint: .isDirectory
    )
    let learningDirectory = scratch.appending(path: "learning", directoryHint: .isDirectory)
    try ensureDirectory(scratch)
    try ensureDirectory(learningDirectory)
    defer { try? fileManager.removeItem(at: scratch) }

    var paused = false
    let deadline = Date().addingTimeInterval(Self.transactionRequestTimeout)
    do {
      progress(.pausing)
      try Task.checkCancellation()
      let pause = try await request(
        makeRequest(
          transactionID: transactionID,
          command: .pause,
          candidate: nil,
          deadline: deadline
        ),
        replyTimeout: try remainingTransactionTime(until: deadline),
        progress: progress
      )
      if pause.status == .cancelled { throw CancellationError() }
      guard pause.status == .paused else { throw Failure.requestFailed(pause.code) }
      paused = true
      try Task.checkCancellation()

      progress(.snapshotting)
      try requireDirectory(environment.live)
      let personal = try LinnetPersonalDataStore.snapshot(from: environment.live)
      let files = try bridge.snapshotCurrent(
        from: environment.live,
        to: learningDirectory,
        shared: environment.shared,
        product: environment.product
      )
      try Task.checkCancellation()
      var learning = try learningContents(files)
      for category in categories {
        if let schema = category.learningSchema, learning[schema] == nil {
          learning[schema] = emptyLearningExport(schema: schema)
        }
      }
      progress(.resuming)
      let resume = try await request(
        makeRequest(
          transactionID: transactionID,
          command: .cancel,
          candidate: nil,
          deadline: deadline
        ),
        replyTimeout: try remainingTransactionTime(until: deadline),
        progress: progress
      )
      guard resume.status == .cancelled else { throw Failure.requestFailed(resume.code) }
      paused = false

      progress(.staging)
      try Task.checkCancellation()
      let document = try LinnetBackupStore.encodePortable(
        personalData: personal.data,
        learning: learning,
        categories: categories,
        createdAt: Date(),
        appVersion: environment.appVersion,
        dataVersion: environment.dataVersion
      )
      try document.write(to: destination, options: .atomic)
      return Outcome(
        transactionID: transactionID,
        backupDirectory: nil,
        personalSnapshot: personal,
        personalEffect: personalEffect,
        documentEffect: .observed,
        importReport: nil,
        legacyImportedCount: 0,
        portableURL: destination,
        diagnostics: nil
      )
    } catch {
      let operationError = error
      if paused {
        progress(.cancelling)
        let resume = try await request(
          makeRequest(
            transactionID: transactionID,
            command: .cancel,
            candidate: nil,
            deadline: deadline
          ),
          replyTimeout: try remainingTransactionTime(until: deadline),
          progress: progress
        )
        guard resume.status == .cancelled else {
          throw Failure.requestFailed(resume.code)
        }
      }
      throw operationError
    }
  }

  private func mutate(
    _ operation: PreparedOperation,
    environment: Environment,
    personalEffect: PersonalEffect,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Outcome {
    let transactionID = UUID()
    let deadline = Date().addingTimeInterval(Self.transactionRequestTimeout)
    let transaction = environment.transactionsRoot.appending(
      path: transactionID.uuidString,
      directoryHint: .isDirectory
    )
    let backupTransaction = environment.backupsRoot.appending(
      path: transactionID.uuidString,
      directoryHint: .isDirectory
    )
    var backupCommitted = false
    var paused = false
    do {
      progress(.pausing)
      try Task.checkCancellation()
      let pause = try await request(
        makeRequest(
          transactionID: transactionID,
          command: .pause,
          candidate: nil,
          deadline: deadline
        ),
        replyTimeout: try remainingTransactionTime(until: deadline),
        progress: progress
      )
      if pause.status == .cancelled { throw CancellationError() }
      guard pause.status == .paused else { throw Failure.requestFailed(pause.code) }
      paused = true
      try Task.checkCancellation()

      progress(.snapshotting)
      try requireDirectory(environment.live)
      try requireDirectory(environment.live.deletingLastPathComponent())
      try ensureDirectory(environment.transactionsRoot)
      try ensureDirectory(environment.backupsRoot)
      try requireSameVolume(environment.live, environment.transactionsRoot)
      let observedPersonal = try LinnetPersonalDataStore.snapshot(from: environment.live)
      let observedDocument: LinnetSettingsDocumentStore.Snapshot?
      switch operation {
      case .apply(
        _, _, let basePersonalRevision, let baseDocumentRevision, _):
        let documentSnapshot = try LinnetSettingsDocumentStore.snapshot(
          from: environment.live)
        try requireRevision(basePersonalRevision, current: observedPersonal.revision)
        try requireRevision(baseDocumentRevision, current: documentSnapshot.revision)
        observedDocument = documentSnapshot
      case .portable(_, let baseRevision):
        try requireRevision(baseRevision, current: observedPersonal.revision)
        observedDocument = nil
      default:
        observedDocument = nil
      }

      let backup = backupTransaction.appending(path: "backup", directoryHint: .isDirectory)
      let stableBackup = backup.appending(path: "stable", directoryHint: .isDirectory)
      let learningBackup = backup.appending(
        path: "user-dictionaries",
        directoryHint: .isDirectory
      )
      let inputs = transaction.appending(path: "inputs", directoryHint: .isDirectory)
      let candidate = transaction.appending(path: "candidate", directoryHint: .isDirectory)
      try environment.registry.beginPersonalScratch(transactionID: transactionID)
      for directory in [backupTransaction, backup, stableBackup, learningBackup, inputs, candidate] {
        try ensureDirectory(directory)
      }

      let currentPersonal = try LinnetBackupStore.snapshotStable(
        from: environment.live,
        to: stableBackup
      )
      guard currentPersonal.revision == observedPersonal.revision else {
        throw Failure.staleRevision(
          expected: observedPersonal.revision,
          actual: currentPersonal.revision
        )
      }
      if let observedDocument {
        let currentDocument = try LinnetSettingsDocumentStore.snapshot(from: stableBackup)
        try requireRevision(observedDocument.revision, current: currentDocument.revision)
      }
      let currentLearningFiles = try bridge.snapshotCurrent(
        from: environment.live,
        to: learningBackup,
        shared: environment.shared,
        product: environment.product
      )
      var protectedTransactions: Set<UUID> = [transactionID]
      if case .restore(_, let sourceManifest) = operation {
        protectedTransactions.insert(sourceManifest.transactionID)
      }
      _ = try LinnetBackupStore.commitBackup(
        backupDirectory: backup,
        backupID: UUID(),
        transactionID: transactionID,
        operation: try backupOperation(operation),
        createdAt: Date(),
        appVersion: environment.appVersion,
        dataVersion: environment.dataVersion,
        transactionsRoot: environment.backupsRoot,
        keepingMostRecent: environment.maximumVerifiedBackups,
        preserving: protectedTransactions
      )
      backupCommitted = true
      try Task.checkCancellation()
      progress(.staging)

      var imports = currentLearningFiles.map {
        RimeUserDataBridge.LearningImport(schema: $0.schema, file: $0.file)
      }
      var report: HallelujahSubstitutionImporter.Report?
      var legacyImportedCount = 0
      var materializedPersonal: LinnetPersonalData?
      var materializedDocument: LinnetSettingsDocument?

      switch operation {
      case .apply(let data, let document, _, _, _):
        try LinnetBackupStore.copyStable(from: stableBackup, to: candidate)
        materializedPersonal = data
        materializedDocument = document

      case .legacy(let hallelujah, let legacyDirectory):
        try LinnetBackupStore.copyStable(from: stableBackup, to: candidate)
        if let legacyDirectory {
          let legacyInputs = inputs.appending(path: "legacy-rime", directoryHint: .isDirectory)
          try ensureDirectory(legacyInputs)
          let legacy = try bridge.snapshotLegacy(
            from: legacyDirectory,
            to: legacyInputs,
            shared: environment.shared,
            product: environment.product
          )
          legacyImportedCount = legacy.importedRows
          imports =
            legacy.files.map {
              .init(schema: $0.schema, file: $0.file)
            } + imports
        }
        if let hallelujah {
          report = try HallelujahSubstitutionImporter.merge(
            hallelujah,
            destinationTable: candidate.appending(
              path: LinnetPersonalDataStore.expansionsFile
            ),
            timeout: try remainingTransactionTime(until: deadline)
          )
        }

      case .portable(let archive, _):
        try LinnetBackupStore.copyStable(from: stableBackup, to: candidate)
        let replacement = try LinnetBackupStore.replacement(
          currentPersonalData: currentPersonal.data,
          currentLearning: try learningContents(currentLearningFiles),
          archive: archive
        )
        materializedPersonal = replacement.personalData
        imports = try stagedLearningImports(
          replacement.learning,
          at: inputs.appending(path: "portable", directoryHint: .isDirectory)
        )

      case .restore(let sourceBackup, let preflightManifest):
        let verified = try LinnetBackupStore.verifyBackup(at: sourceBackup)
        guard verified == preflightManifest else {
          throw Failure.invalidOperation("backup changed during restore")
        }
        try LinnetBackupStore.copyStable(
          from: sourceBackup.appending(path: "stable", directoryHint: .isDirectory),
          to: candidate
        )
        imports = try learningImports(
          from: sourceBackup.appending(
            path: "user-dictionaries", directoryHint: .isDirectory),
          manifest: verified
        )

      case .removeBackup:
        throw Failure.invalidOperation("backup removal mutation")

      case .clear(let domains):
        try LinnetBackupStore.copyStable(from: stableBackup, to: candidate)
        let cleared = Set(domains.map(\.schema))
        imports.removeAll { cleared.contains($0.schema) }

      case .export:
        throw Failure.invalidOperation("export mutation")
      case .diagnose:
        throw Failure.invalidOperation("diagnose mutation")
      }

      let runtimeDocument = try materializedDocument
        ?? LinnetSettingsDocumentStore.load(from: candidate)
      let runtimePersonal = try materializedPersonal
        ?? LinnetPersonalDataStore.load(from: candidate)
      try LinnetSettingsDocumentStore.write(runtimeDocument, to: candidate)
      try LinnetPersonalDataStore.writePersonalFiles(runtimePersonal, to: candidate)
      try LinnetPersonalDataStore.writeRuntimeSettings(runtimePersonal, to: candidate)
      try LinnetSettingsProjectionRenderer.reconcile(document: runtimeDocument, to: candidate)
      let finalPersonal = try LinnetPersonalDataStore.snapshot(from: candidate)
      let finalDocument = try LinnetSettingsDocumentStore.snapshot(from: candidate)
      let documentEffect: DocumentEffect
      switch operation {
      case .apply:
        documentEffect = .submittedDraft(finalDocument)
      case .restore:
        documentEffect = .externalReplacement(finalDocument)
      default:
        documentEffect = .observed
      }
      try Task.checkCancellation()
      progress(.deploying)
      try bridge.deploy(
        candidate: candidate,
        shared: environment.shared,
        product: environment.product,
        imports: imports,
        substitutionProbe: report?.smokeProbe
      )
      try Task.checkCancellation()
      progress(.activating)
      let activation = try await request(
        makeRequest(
          transactionID: transactionID,
          command: .activate,
          candidate: candidate,
          deadline: deadline
        ),
        replyTimeout: try remainingTransactionTime(until: deadline),
        progress: progress
      )
      if activation.status == .rolledBack {
        paused = false
        try? fileManager.removeItem(at: transaction)
        throw Failure.requestFailed(activation.code)
      }
      if activation.status == .failed {
        paused = false
        throw Failure.requestFailed(activation.code)
      }
      guard activation.status == .activated else {
        throw Failure.requestFailed(activation.code)
      }
      paused = false
      try? fileManager.removeItem(at: transaction)
      return Outcome(
        transactionID: transactionID,
        backupDirectory: backup,
        personalSnapshot: finalPersonal,
        personalEffect: personalEffect,
        documentEffect: documentEffect,
        importReport: report,
        legacyImportedCount: legacyImportedCount,
        portableURL: nil,
        diagnostics: nil
      )
    } catch {
      let operationError = error
      var backupCleanupError: Error?
      if !backupCommitted,
        fileManager.fileExists(atPath: backupTransaction.path)
      {
        do {
          try LinnetBackupStore.discardIncompleteBackup(
            transactionID: transactionID,
            in: environment.backupsRoot
          )
        } catch {
          backupCleanupError = error
        }
      }
      if paused {
        progress(.cancelling)
        let resume = try await request(
          makeRequest(
            transactionID: transactionID,
            command: .cancel,
            candidate: nil,
            deadline: deadline
          ),
          replyTimeout: try remainingTransactionTime(until: deadline),
          progress: progress
        )
        guard resume.status == .cancelled else {
          throw Failure.requestFailed(resume.code)
        }
        let transaction = environment.transactionsRoot.appending(
          path: transactionID.uuidString,
          directoryHint: .isDirectory
        )
        try? fileManager.removeItem(at: transaction)
      }
      if let backupCleanupError { throw backupCleanupError }
      throw operationError
    }
  }

  private func diagnose(
    environment: Environment,
    personalEffect: PersonalEffect
  ) async throws -> Outcome {
    let transactionID = UUID()
    let personal = try LinnetPersonalDataStore.snapshot(from: environment.live)
    let backups = try LinnetBackupStore.listBackups(in: environment.backupsRoot)
    let reply = try? await request(
      makeRequest(
        transactionID: transactionID,
        command: .diagnose,
        candidate: nil,
        deadline: Date().addingTimeInterval(Self.interactiveRequestTimeout)
      ),
      replyTimeout: Self.interactiveRequestTimeout,
      progress: { _ in }
    )
    let health = reply?.health
    let reachability: Diagnostics.Reachability
    switch health?.state {
    case .running: reachability = .running
    case .paused: reachability = .paused
    case .degraded: reachability = .degraded
    default: reachability = .unreachable
    }
    var verified = 0
    var incomplete = 0
    var corrupt = 0
    for backup in backups {
      switch backup.state {
      case .verified: verified += 1
      case .incomplete: incomplete += 1
      case .corrupt: corrupt += 1
      }
    }
    let settingsVersion =
      (try? LinnetSettingsDocumentStore.load(from: environment.live))?.schemaVersion
      ?? LinnetSettingsDocument.currentSchemaVersion
    let diagnostics = Diagnostics(
      reachability: reachability,
      runtime: health,
      productName: environment.product,
      appVersion: environment.appVersion,
      dataVersion: environment.dataVersion,
      settingsVersion: settingsVersion,
      customWordCount: personal.data.customWords.count,
      disabledWordCount: personal.data.disabledWords.count,
      expansionCount: personal.data.expansions.count,
      verifiedBackupCount: verified,
      incompleteBackupCount: incomplete,
      corruptBackupCount: corrupt
    )
    return Outcome(
      transactionID: transactionID,
      backupDirectory: nil,
      personalSnapshot: personal,
      personalEffect: personalEffect,
      documentEffect: .observed,
      importReport: nil,
      legacyImportedCount: 0,
      portableURL: nil,
      diagnostics: diagnostics
    )
  }

  private func removeBackup(
    _ record: LinnetBackupStore.BackupRecord,
    environment: Environment,
    personalEffect: PersonalEffect,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Outcome {
    guard let transactionID = record.transactionID else {
      throw Failure.invalidOperation("backup transaction identity")
    }
    try Task.checkCancellation()
    let personal = try LinnetPersonalDataStore.snapshot(from: environment.live)
    progress(.staging)
    var protected = Set<UUID>()
    // Transactions/<UUID> is the current-operation owner for both language
    // and personal scratch. Active.transactionID can outlive its transaction
    // directory after a committed language update, so it must not make an
    // unrelated backup record permanently undeletable.
    let liveTransaction = environment.transactionsRoot.appending(
      path: transactionID.uuidString, directoryHint: .isDirectory)
    var info = stat()
    if lstat(liveTransaction.path, &info) == 0 {
      protected.insert(transactionID)
    } else if errno != ENOENT {
      throw Failure.unsafePath(liveTransaction.path)
    }
    try LinnetBackupStore.removeNonverifiedBackup(
      record, in: environment.backupsRoot, preserving: protected)
    progress(.verifying)
    let refreshed = try? await diagnose(
      environment: environment, personalEffect: personalEffect)
    return Outcome(
      transactionID: transactionID,
      backupDirectory: nil,
      personalSnapshot: refreshed?.personalSnapshot ?? personal,
      personalEffect: personalEffect,
      documentEffect: .observed,
      importReport: nil,
      legacyImportedCount: 0,
      portableURL: nil,
      diagnostics: refreshed?.diagnostics
    )
  }
}

extension SettingsDataCoordinator {
  /// The document currently in the live user directory, or the default
  /// document when none exists.
  private func liveDocument() throws -> LinnetSettingsDocument {
    let userDirectory = try liveUserDirectory()
    return try LinnetSettingsDocumentStore.load(from: userDirectory)
  }

  private func liveUserDirectory() throws -> URL {
    guard
      let directory = registryOverride?.userDataDirectory
        ?? LinnetSettingsContract.hostUserDirectory(startingAt: bundle)
    else { throw Failure.unavailable }
    return directory
  }

  /// Classifies an apply against the two source owners. Personal dictionary
  /// changes take the full backup/swap path. Document-only schema changes use
  /// the live configuration reload, while panel-safe appearance remains the
  /// smallest path.
  private func applyScope(
    data: LinnetPersonalData,
    document: LinnetSettingsDocument
  ) throws -> ApplyScope {
    let currentDocument = try liveDocument().normalized()
    guard let live = try? liveUserDirectory(),
      let snapshot = try? LinnetPersonalDataStore.snapshot(from: live)
    else {
      return .full
    }
    guard snapshot.revision == (try LinnetPersonalDataStore.revision(for: data)) else {
      return .full
    }
    if document.appearance.livePanelProjection(over: currentDocument.appearance)
      == document.appearance,
      currentDocument.input == document.input,
      currentDocument.english == document.english
    {
      return .appearanceOnly
    }
    return .configurationOnly
  }

  /// Document-only apply stages one canonical document. Host owns the atomic
  /// live exchange, projection reconciliation, deployment, and rollback.
  private func applyConfiguration(
    data: LinnetPersonalData,
    document: LinnetSettingsDocument,
    basePersonalRevision: String,
    baseDocumentRevision: String,
    environment: Environment,
    personalEffect: PersonalEffect,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Outcome {
    let transactionID = UUID()
    try requireDirectory(environment.live)
    let current = try LinnetPersonalDataStore.snapshot(from: environment.live)
    let currentDocument = try LinnetSettingsDocumentStore.snapshot(from: environment.live)
    try requireRevision(basePersonalRevision, current: current.revision)
    try requireRevision(baseDocumentRevision, current: currentDocument.revision)
    try Task.checkCancellation()

    progress(.staging)
    let candidate = try stageConfigurationCandidate(
      transactionID: transactionID,
      document: document,
      environment: environment
    )
    defer { try? fileManager.removeItem(at: candidate.deletingLastPathComponent()) }
    let candidateRevision = try LinnetSettingsDocumentStore.snapshot(from: candidate).revision
    var requestAttempted = false
    do {
      try Task.checkCancellation()
      progress(.activating)
      requestAttempted = true
      try await reloadConfigurationRuntime(
        transactionID: transactionID,
        candidate: candidate,
        expectedSettingsRevision: currentDocument.revision,
        alternateSettingsRevision: nil,
        progress: progress
      )
    } catch {
      let operationError = error
      if requestAttempted {
        do {
          try await restoreConfigurationRuntime(
            document: currentDocument.document,
            baseRevision: currentDocument.revision,
            appliedRevision: candidateRevision,
            environment: environment,
            progress: progress
          )
        } catch {
          throw Failure.configurationRestoreFailed
        }
      }
      throw operationError
    }

    let committedDocument = try LinnetSettingsDocumentStore.snapshot(from: environment.live)
    return Outcome(
      transactionID: transactionID,
      backupDirectory: nil,
      personalSnapshot: try LinnetPersonalDataStore.snapshot(from: environment.live),
      personalEffect: personalEffect,
      documentEffect: .submittedDraft(committedDocument),
      importReport: nil,
      legacyImportedCount: 0,
      portableURL: nil,
      diagnostics: nil
    )
  }

  /// Lightweight appearance apply uses the same atomic document publication
  /// boundary while Host limits deployment to squirrel.yaml.
  private func applyAppearance(
    data: LinnetPersonalData,
    document: LinnetSettingsDocument,
    basePersonalRevision: String,
    baseDocumentRevision: String,
    environment: Environment,
    personalEffect: PersonalEffect,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Outcome {
    let transactionID = UUID()
    try requireDirectory(environment.live)
    let current = try LinnetPersonalDataStore.snapshot(from: environment.live)
    let currentDocument = try LinnetSettingsDocumentStore.snapshot(from: environment.live)
    try requireRevision(basePersonalRevision, current: current.revision)
    try requireRevision(baseDocumentRevision, current: currentDocument.revision)
    try Task.checkCancellation()

    progress(.staging)
    let candidate = try stageConfigurationCandidate(
      transactionID: transactionID,
      document: document,
      environment: environment
    )
    defer { try? fileManager.removeItem(at: candidate.deletingLastPathComponent()) }
    let candidateRevision = try LinnetSettingsDocumentStore.snapshot(from: candidate).revision
    var refreshAttempted = false
    do {
      try Task.checkCancellation()
      progress(.activating)
      refreshAttempted = true
      try await refreshAppearanceRuntime(
        transactionID: transactionID,
        candidate: candidate,
        expectedSettingsRevision: currentDocument.revision,
        progress: progress
      )
    } catch {
      let operationError = error
      if refreshAttempted {
        do {
          try await restoreConfigurationRuntime(
            document: currentDocument.document,
            baseRevision: currentDocument.revision,
            appliedRevision: candidateRevision,
            environment: environment,
            progress: progress
          )
        } catch {
          throw Failure.appearanceRestoreFailed
        }
      }
      throw operationError
    }
    let committedDocument = try LinnetSettingsDocumentStore.snapshot(from: environment.live)
    let documentEffect: DocumentEffect =
      personalEffect == .submittedDraft
      ? .submittedDraft(committedDocument)
      : .submittedAppearance(committedDocument)
    return Outcome(
      transactionID: transactionID,
      backupDirectory: nil,
      personalSnapshot: try LinnetPersonalDataStore.snapshot(from: environment.live),
      personalEffect: personalEffect,
      documentEffect: documentEffect,
      importReport: nil,
      legacyImportedCount: 0,
      portableURL: nil,
      diagnostics: nil
    )
  }

  private func stageConfigurationCandidate(
    transactionID: UUID,
    document: LinnetSettingsDocument,
    environment: Environment
  ) throws -> URL {
    try ensureDirectory(environment.transactionsRoot)
    try requireSameVolume(environment.live, environment.transactionsRoot)
    try environment.registry.beginPersonalScratch(transactionID: transactionID)
    let candidate = environment.transactionsRoot
      .appending(path: transactionID.uuidString, directoryHint: .isDirectory)
      .appending(path: Self.configurationCandidateName, directoryHint: .isDirectory)
    try ensureDirectory(candidate)
    try LinnetSettingsDocumentStore.write(document, to: candidate)
    return candidate
  }

  private func restoreConfigurationRuntime(
    document: LinnetSettingsDocument,
    baseRevision: String,
    appliedRevision: String,
    environment: Environment,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws {
    let transactionID = UUID()
    let candidate = try stageConfigurationCandidate(
      transactionID: transactionID,
      document: document,
      environment: environment
    )
    defer { try? fileManager.removeItem(at: candidate.deletingLastPathComponent()) }
    try await reloadConfigurationRuntime(
      transactionID: transactionID,
      candidate: candidate,
      expectedSettingsRevision: baseRevision,
      alternateSettingsRevision: appliedRevision,
      progress: progress
    )
  }

  /// A refresh is accepted only after Host has atomically published the
  /// candidate document and reports that exact revision as active.
  private func refreshAppearanceRuntime(
    transactionID: UUID,
    candidate: URL,
    expectedSettingsRevision: String,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws {
    let desiredRevision = try LinnetSettingsDocumentStore.snapshot(from: candidate).revision
    let refresh = try await request(
      makeRequest(
        transactionID: transactionID,
        command: .refresh,
        candidate: candidate,
        deadline: Date().addingTimeInterval(Self.interactiveRequestTimeout),
        expectedSettingsRevision: expectedSettingsRevision
      ),
      replyTimeout: Self.interactiveRequestTimeout,
      progress: progress
    )
    guard refresh.status == .activated,
      refresh.health?.activeSettingsRevision == desiredRevision
    else {
      throw Failure.requestFailed(refresh.code)
    }
  }

  private func reloadConfigurationRuntime(
    transactionID: UUID,
    candidate: URL,
    expectedSettingsRevision: String,
    alternateSettingsRevision: String?,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws {
    let desiredRevision = try LinnetSettingsDocumentStore.snapshot(from: candidate).revision
    let reload = try await request(
      makeRequest(
        transactionID: transactionID,
        command: .reloadConfiguration,
        candidate: candidate,
        deadline: Date().addingTimeInterval(Self.interactiveRequestTimeout),
        expectedSettingsRevision: expectedSettingsRevision,
        alternateSettingsRevision: alternateSettingsRevision
      ),
      replyTimeout: Self.interactiveRequestTimeout,
      progress: progress
    )
    guard reload.status == .activated,
      reload.health?.activeSettingsRevision == desiredRevision
    else {
      throw Failure.requestFailed(reload.code)
    }
  }

  private func environment() throws -> Environment {
    guard let host = LinnetSettingsContract.hostBundle(startingAt: bundle),
      let product = host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
      !product.isEmpty,
      let registry = registryOverride ?? LinnetSettingsContract.dataRegistry(startingAt: bundle),
      let snapshot = try? registry.runtimeSnapshot()
    else {
      throw Failure.unavailable
    }
    let appVersion =
      (host.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      ?? (host.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
      ?? "development"
    return Environment(
      registry: registry,
      shared: snapshot.sharedDataDirectory,
      product: product,
      live: snapshot.userDataDirectory,
      transactionsRoot: snapshot.transactionsDirectory,
      backupsRoot: snapshot.backupsDirectory,
      mutationLease: registry.settingsMutationLeaseURL,
      appVersion: appVersion,
      dataVersion: snapshot.state.dataVersion,
      maximumVerifiedBackups: LinnetSettingsContract.backupRetentionPolicy(
        startingAt: bundle
      ).maximumVerifiedBackups
    )
  }

  private func mutationRequiresLease(_ operation: DataOperation) -> Bool {
    switch operation {
    case .exportPortable, .diagnose:
      false
    case .publishAppearance, .applyConfiguration, .importLegacy,
      .importPortable, .restoreBackup, .removeBackupRecord, .clearLearning:
      true
    }
  }

  private func backupOperation(
    _ operation: PreparedOperation
  ) throws -> LinnetBackupStore.BackupOperation {
    switch operation {
    case .apply: .applyPersonalData
    case .legacy: .importLegacy
    case .portable: .importPortable
    case .restore: .restore
    case .removeBackup: throw Failure.invalidOperation("backup removal backup")
    case .clear: .clearLearning
    case .export: throw Failure.invalidOperation("export backup")
    case .diagnose: throw Failure.invalidOperation("diagnostics backup")
    }
  }

  private func learningContents(
    _ files: [RimeUserDataBridge.LearningFile]
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    for item in files {
      guard RimeUserDataBridge.learningSchemas.contains(item.schema),
        result[item.schema] == nil
      else {
        throw Failure.invalidOperation("learning snapshot schema")
      }
      let data = try LinnetBackupStore.readBoundedRegularFile(
        item.file, limit: LinnetBackupStore.maximumLearningBytes)
      guard let contents = String(data: data, encoding: .utf8) else {
        throw LinnetBackupStore.Failure.invalidDocument(item.file.lastPathComponent)
      }
      result[item.schema] = contents
    }
    return result
  }

  private func stagedLearningImports(
    _ learning: [String: String],
    at directory: URL
  ) throws -> [RimeUserDataBridge.LearningImport] {
    guard Set(learning.keys).isSubset(of: RimeUserDataBridge.learningSchemas) else {
      throw Failure.invalidOperation("learning replacement schema")
    }
    try ensureDirectory(directory)
    return try learning.keys.sorted().map { schema in
      guard let contents = learning[schema] else {
        throw Failure.invalidOperation("learning replacement schema")
      }
      let file = directory.appending(path: "\(schema).txt")
      try contents.write(to: file, atomically: true, encoding: .utf8)
      return .init(schema: schema, file: file)
    }
  }

  private func learningImports(
    from directory: URL,
    manifest: LinnetBackupStore.BackupManifest
  ) throws
    -> [RimeUserDataBridge.LearningImport]
  {
    try requireDirectory(directory)
    let prefix = "user-dictionaries/"
    return try manifest.artifacts.compactMap { artifact in
      guard artifact.path.hasPrefix(prefix) else { return nil }
      let name = String(artifact.path.dropFirst(prefix.count))
      let file = directory.appending(path: name)
      try requireRegularFile(file)
      let schema: String
      switch name {
      case "\(RimeUserDataBridge.chineseSchema).txt":
        schema = RimeUserDataBridge.chineseSchema
      case "\(RimeUserDataBridge.englishSchema).txt":
        schema = RimeUserDataBridge.englishSchema
      default:
        throw Failure.invalidOperation("restore learning schema")
      }
      return .init(schema: schema, file: file)
    }.sorted { $0.schema < $1.schema }
  }

  private func requireRevision(_ expected: String, current: String) throws {
    guard expected == current else {
      throw Failure.staleRevision(expected: expected, actual: current)
    }
  }

  private func emptyLearningExport(schema: String) -> String {
    """
    # Rime user dictionary export
    #@/db_name\t\(schema)
    #@/db_type\tuserdb
    """ + "\n"
  }

  private func makeRequest(
    transactionID: UUID,
    command: LinnetSettingsContract.DataCommand,
    candidate: URL?,
    deadline: Date,
    expectedActiveRevision: LinnetDataRegistry.ActiveRevision? = nil,
    expectedSettingsRevision: String? = nil,
    alternateSettingsRevision: String? = nil
  ) -> LinnetSettingsContract.DataRequest {
    .init(
      transactionID: transactionID,
      command: command,
      candidate: candidate,
      requesterPID: getpid(),
      deadline: deadline,
      expectedActiveGeneration: expectedActiveRevision?.generation,
      expectedActiveStateSHA256: expectedActiveRevision?.stateSHA256,
      expectedSettingsRevision: expectedSettingsRevision,
      alternateSettingsRevision: alternateSettingsRevision
    )
  }

  private func request(
    _ request: LinnetSettingsContract.DataRequest,
    replyTimeout: TimeInterval,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> LinnetSettingsContract.RuntimeReply {
    // A cancelled caller still waits for the pause terminal. The operation then
    // sends an ordered cancel and only reports cancellation after Squirrel
    // acknowledges that the original runtime resumed.
    do {
      return try await transactionRequester.request(
        request,
        timeout: replyTimeout
      ) { reply in
        if reply.status == .verifying, request.command == .activate {
          progress(.verifying)
        }
      }
    } catch LinnetSettingsTransactionIPC.Failure.timedOut {
      throw Failure.timedOut
    } catch is LinnetSettingsTransactionIPC.Failure {
      throw Failure.unavailable
    }
  }

  private func remainingTransactionTime(until deadline: Date) throws -> TimeInterval {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { throw Failure.timedOut }
    return remaining
  }

  private func ensureDirectory(_ url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
      try requireDirectory(url)
      return
    }
    guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
      throw Failure.unsafePath(url.path)
    }
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try requireDirectory(url)
  }

  private func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.unsafePath(url.path)
    }
  }

  private func requireRegularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw Failure.unsafePath(url.path)
    }
  }

  private func requireWritableDestination(_ url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try requireDirectory(parent)
    guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
      throw Failure.unsafePath(url.path)
    }
    if fileManager.fileExists(atPath: url.path) { try requireRegularFile(url) }
  }

  private func requireSameVolume(_ first: URL, _ second: URL) throws {
    var one = stat()
    var two = stat()
    guard stat(first.path, &one) == 0,
      stat(second.path, &two) == 0,
      one.st_dev == two.st_dev
    else {
      throw Failure.unsafePath("cross-volume transaction")
    }
  }
}
