import Darwin
import Foundation

extension SettingsDataCoordinator {
  func prepare(_ operation: DataOperation) throws -> PreparedOperation {
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
    case .exportCloudRecovery(let categories, let cloudFolder, let repair):
      guard !categories.isEmpty else { throw Failure.invalidOperation("no export category") }
      try requireDirectory(cloudFolder)
      return .cloudRecovery(categories, cloudFolder: cloudFolder, repair: repair)
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

  func sourceExists(_ source: URL) throws -> Bool {
    guard source.isFileURL else { throw Failure.unsafePath(source.absoluteString) }
    var info = stat()
    if lstat(source.path, &info) == 0 { return true }
    if errno == ENOENT { return false }
    throw Failure.unsafePath(source.path)
  }

  func exportPortable(
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
      let files = try bridge.exportPortableLearning(
        from: environment.live,
        to: learningDirectory,
        shared: environment.shared,
        product: environment.product,
        schemas: Set(categories.compactMap(\.learningSchema))
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
        backupDirectory: nil,
        personalSnapshot: personal,
        personalEffect: personalEffect,
        documentEffect: .observed,
        importReport: nil,
        legacyImportedCount: 0,
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

  /// Stages the existing portable external format only locally, then delegates
  /// cloud object publication to the immutable recovery archive owner.
  func exportCloudRecovery(
    categories: Set<LinnetBackupStore.Category>,
    cloudFolder: URL,
    repair: Bool,
    environment: Environment,
    personalEffect: PersonalEffect,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Outcome {
    let scratch = fileManager.temporaryDirectory.appending(
      path: "CloudRecoveryExport-\(UUID().uuidString)", directoryHint: .isDirectory)
    try ensureDirectory(scratch)
    defer { try? fileManager.removeItem(at: scratch) }
    let portable = scratch.appending(
      path: "recovery.\(LinnetBackupStore.portableExtension)", directoryHint: .notDirectory)
    let snapshot = try await exportPortable(
      categories: categories,
      destination: portable,
      environment: environment,
      personalEffect: personalEffect,
      progress: progress)
    let recovery = try LinnetCloudRecoveryArchive.publish(
      portable: Data(contentsOf: portable), in: cloudFolder, repair: repair)
    return .init(
      backupDirectory: snapshot.backupDirectory,
      personalSnapshot: snapshot.personalSnapshot,
      personalEffect: snapshot.personalEffect,
      documentEffect: snapshot.documentEffect,
      importReport: snapshot.importReport,
      legacyImportedCount: snapshot.legacyImportedCount,
      diagnostics: snapshot.diagnostics,
      cloudRecovery: recovery)
  }

  struct MutationContext {
    let transactionID: UUID
    let deadline: Date
    let transaction: URL
    let backupTransaction: URL
  }

  struct MutationSnapshot {
    let backup: URL
    let currentPersonal: LinnetPersonalDataStore.Snapshot
  }

  struct MutationMaterialization {
    let candidate: URL
    let imports: [RimeUserDataBridge.LearningImport]
    let report: HallelujahSubstitutionImporter.Report?
    let legacyImportedCount: Int
    let finalPersonal: LinnetPersonalDataStore.Snapshot
    let documentEffect: DocumentEffect
  }

  func snapshotMutation(
    _ operation: PreparedOperation,
    environment: Environment,
    context: MutationContext
  ) throws -> MutationSnapshot {
    try requireDirectory(environment.live)
    try requireDirectory(environment.live.deletingLastPathComponent())
    try ensureDirectory(environment.transactionsRoot)
    try ensureDirectory(environment.backupsRoot)
    try requireSameVolume(environment.live, environment.transactionsRoot)
    try requireSameVolume(environment.live, environment.backupsRoot)
    let observedPersonal = try LinnetPersonalDataStore.snapshot(from: environment.live)
    let observedDocument: LinnetSettingsDocumentStore.Snapshot?
    switch operation {
    case .apply(_, _, let basePersonalRevision, let baseDocumentRevision, _):
      let documentSnapshot = try LinnetSettingsDocumentStore.snapshot(from: environment.live)
      try requireRevision(basePersonalRevision, current: observedPersonal.revision)
      try requireRevision(baseDocumentRevision, current: documentSnapshot.revision)
      observedDocument = documentSnapshot
    case .portable(_, let baseRevision):
      try requireRevision(baseRevision, current: observedPersonal.revision)
      observedDocument = nil
    default:
      observedDocument = nil
    }

    let backup = context.backupTransaction.appending(
      path: "backup", directoryHint: .isDirectory)
    let stableBackup = backup.appending(path: "stable", directoryHint: .isDirectory)
    let learningBackup = backup.appending(
      path: "user-dictionaries", directoryHint: .isDirectory)
    let inputs = context.transaction.appending(path: "inputs", directoryHint: .isDirectory)
    let candidate = context.transaction.appending(path: "candidate", directoryHint: .isDirectory)
    try environment.registry.beginPersonalScratch(transactionID: context.transactionID)
    for directory in [
      context.backupTransaction, backup, stableBackup, learningBackup, inputs, candidate
    ] {
      try ensureDirectory(directory)
    }

    let currentPersonal = try LinnetBackupStore.snapshotStable(
      from: environment.live, to: stableBackup)
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
    try LinnetBackupStore.cloneLearningDictionaries(from: environment.live, to: learningBackup)
    var protectedTransactions: Set<UUID> = [context.transactionID]
    if case .restore(_, let sourceManifest) = operation {
      protectedTransactions.insert(sourceManifest.transactionID)
    }
    _ = try LinnetBackupStore.commitBackup(.init(
      backupDirectory: backup,
      backupID: UUID(),
      transactionID: context.transactionID,
      operation: try backupOperation(operation),
      createdAt: Date(),
      appVersion: environment.appVersion,
      dataVersion: environment.dataVersion,
      transactionsRoot: environment.backupsRoot,
      maximumVerifiedBackups: environment.maximumVerifiedBackups,
      protectedTransactionIDs: protectedTransactions
    ))
    return .init(
      backup: backup,
      currentPersonal: currentPersonal
    )
  }

  func materializeMutation(
    _ operation: PreparedOperation,
    environment: Environment,
    context: MutationContext,
    snapshot: MutationSnapshot
  ) throws -> MutationMaterialization {
    let stableBackup = snapshot.backup.appending(path: "stable", directoryHint: .isDirectory)
    let inputs = context.transaction.appending(path: "inputs", directoryHint: .isDirectory)
    let candidate = context.transaction.appending(path: "candidate", directoryHint: .isDirectory)
    var imports: [RimeUserDataBridge.LearningImport] = []
    var report: HallelujahSubstitutionImporter.Report?
    var legacyImportedCount = 0
    var materializedPersonal: LinnetPersonalData?
    var materializedDocument: LinnetSettingsDocument?

    if case .restore = operation {
      // The selected backup, not current live learning, owns restore contents.
    } else {
      try LinnetBackupStore.copyStable(from: stableBackup, to: candidate)
      try LinnetBackupStore.cloneLearningDictionaries(
        from: snapshot.backup.appending(path: "user-dictionaries", directoryHint: .isDirectory),
        to: candidate)
    }
    switch operation {
    case .apply(let data, let document, _, _, _):
      materializedPersonal = data
      materializedDocument = document
    case .legacy(let hallelujah, let legacyDirectory):
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
        imports = legacy.files.map {
          .init(schema: $0.schema, file: $0.file)
        }
      }
      if let hallelujah {
        report = try HallelujahSubstitutionImporter.merge(
          hallelujah,
          destinationTable: candidate.appending(path: LinnetPersonalDataStore.expansionsFile),
          timeout: try remainingTransactionTime(until: context.deadline)
        )
      }
    case .portable(let archive, _):
      let replacement = try LinnetBackupStore.replacement(
        currentPersonalData: snapshot.currentPersonal.data,
        archive: archive
      )
      materializedPersonal = replacement.personalData
      try removeCandidateLearning(Set(replacement.learning.keys), from: candidate)
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
      let learning = sourceBackup.appending(path: "user-dictionaries", directoryHint: .isDirectory)
      if verified.formatVersion == LinnetBackupStore.backupFormatVersion {
        try LinnetBackupStore.cloneLearningDictionaries(from: learning, to: candidate)
      } else {
        imports = try legacyBackupLearningImports(from: learning, manifest: verified)
      }
    case .clear(let domains):
      try removeCandidateLearning(Set(domains.map(\.schema)), from: candidate)
    case .removeBackup:
      throw Failure.invalidOperation("backup removal mutation")
    case .export:
      throw Failure.invalidOperation("export mutation")
    case .cloudRecovery:
      throw Failure.invalidOperation("cloud recovery mutation")
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
    case .apply: documentEffect = .submittedDraft(finalDocument)
    case .restore: documentEffect = .externalReplacement(finalDocument)
    default: documentEffect = .observed
    }
    return .init(
      candidate: candidate,
      imports: imports,
      report: report,
      legacyImportedCount: legacyImportedCount,
      finalPersonal: finalPersonal,
      documentEffect: documentEffect
    )
  }

  func recoverMutationFailure(
    _ operationError: Error,
    backupCommitted: Bool,
    paused: Bool,
    environment: Environment,
    context: MutationContext,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Never {
    var backupCleanupError: Error?
    if !backupCommitted,
      fileManager.fileExists(atPath: context.backupTransaction.path) {
      do {
        try LinnetBackupStore.discardIncompleteBackup(
          transactionID: context.transactionID,
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
          transactionID: context.transactionID,
          command: .cancel,
          candidate: nil,
          deadline: context.deadline
        ),
        replyTimeout: try remainingTransactionTime(until: context.deadline),
        progress: progress
      )
      guard resume.status == .cancelled else {
        throw Failure.requestFailed(resume.code)
      }
      try? fileManager.removeItem(at: context.transaction)
    }
    if let backupCleanupError { throw backupCleanupError }
    throw operationError
  }

  func mutate(
    _ operation: PreparedOperation,
    environment: Environment,
    personalEffect: PersonalEffect,
    progress: @escaping @Sendable (Phase) -> Void
  ) async throws -> Outcome {
    let transactionID = UUID()
    let deadline = Date().addingTimeInterval(Self.transactionRequestTimeout)
    let context = MutationContext(
      transactionID: transactionID,
      deadline: deadline,
      transaction: environment.transactionsRoot.appending(
        path: transactionID.uuidString, directoryHint: .isDirectory),
      backupTransaction: environment.backupsRoot.appending(
        path: transactionID.uuidString, directoryHint: .isDirectory)
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
      let snapshot = try snapshotMutation(operation, environment: environment, context: context)
      backupCommitted = true
      try Task.checkCancellation()
      progress(.staging)

      let materialized = try materializeMutation(
        operation,
        environment: environment,
        context: context,
        snapshot: snapshot
      )
      try Task.checkCancellation()
      // Personal edits are already format-validated local source files. Host is
      // the only live Rime activation owner and compiles those files after the
      // atomic swap. Running a second ten-schema deploy in Settings made a
      // local edit slower and introduced an unrelated failure boundary.
      switch operation {
      case .apply:
        break
      default:
        progress(.deploying)
        try bridge.deploy(
          candidate: materialized.candidate,
          shared: environment.shared,
          product: environment.product,
          imports: materialized.imports,
          substitutionProbe: materialized.report?.smokeProbe
        )
      }
      try Task.checkCancellation()
      progress(.activating)
      let activation = try await request(
        makeRequest(
          transactionID: transactionID,
          command: .activate,
          candidate: materialized.candidate,
          deadline: deadline
        ),
        replyTimeout: try remainingTransactionTime(until: deadline),
        progress: progress
      )
      if activation.status == .rolledBack {
        paused = false
        try? fileManager.removeItem(at: context.transaction)
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
      try? fileManager.removeItem(at: context.transaction)
      return Outcome(
        backupDirectory: snapshot.backup,
        personalSnapshot: materialized.finalPersonal,
        personalEffect: personalEffect,
        documentEffect: materialized.documentEffect,
        importReport: materialized.report,
        legacyImportedCount: materialized.legacyImportedCount,
        diagnostics: nil
      )
    } catch {
      try await recoverMutationFailure(
        error,
        backupCommitted: backupCommitted,
        paused: paused,
        environment: environment,
        context: context,
        progress: progress
      )
    }
  }

  func diagnose(
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
    let reachability: SettingsRuntimeReachability
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
      backupDirectory: nil,
      personalSnapshot: personal,
      personalEffect: personalEffect,
      documentEffect: .observed,
      importReport: nil,
      legacyImportedCount: 0,
      diagnostics: diagnostics
    )
  }

  func removeBackup(
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
      backupDirectory: nil,
      personalSnapshot: refreshed?.personalSnapshot ?? personal,
      personalEffect: personalEffect,
      documentEffect: .observed,
      importReport: nil,
      legacyImportedCount: 0,
      diagnostics: refreshed?.diagnostics
    )
  }
}
