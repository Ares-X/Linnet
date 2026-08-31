import Darwin
import Foundation

extension SettingsDataCoordinator {
  /// The document currently in the live user directory, or the default
  /// document when none exists.
  func liveDocument() throws -> LinnetSettingsDocument {
    let userDirectory = try liveUserDirectory()
    return try LinnetSettingsDocumentStore.load(from: userDirectory)
  }

  func liveUserDirectory() throws -> URL {
    guard
      let directory = registryOverride?.userDataDirectory
        ?? LinnetSettingsContract.dataRegistry(startingAt: bundle)?.userDataDirectory
    else { throw Failure.unavailable }
    return directory
  }

  /// Classifies an apply against the two source owners. Personal dictionary
  /// changes take the full backup/swap path. Document-only schema changes use
  /// the live configuration reload, while panel-safe appearance remains the
  /// smallest path.
  func applyScope(
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
      currentDocument.english == document.english {
      return .appearanceOnly
    }
    return .configurationOnly
  }

  /// Document-only apply stages one canonical document. Host owns the atomic
  /// live exchange, projection reconciliation, deployment, and rollback.
  func applyConfiguration(
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
      backupDirectory: nil,
      personalSnapshot: try LinnetPersonalDataStore.snapshot(from: environment.live),
      personalEffect: personalEffect,
      documentEffect: .submittedDraft(committedDocument),
      importReport: nil,
      legacyImportedCount: 0,
      diagnostics: nil
    )
  }

  /// Lightweight appearance apply uses the same atomic document publication
  /// boundary while Host limits deployment to squirrel.yaml.
  func applyAppearance(
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
      backupDirectory: nil,
      personalSnapshot: try LinnetPersonalDataStore.snapshot(from: environment.live),
      personalEffect: personalEffect,
      documentEffect: documentEffect,
      importReport: nil,
      legacyImportedCount: 0,
      diagnostics: nil
    )
  }

  func stageConfigurationCandidate(
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

  func restoreConfigurationRuntime(
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
  func refreshAppearanceRuntime(
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

  func reloadConfigurationRuntime(
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

  func environment() throws -> Environment {
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

  func mutationRequiresLease(_ operation: DataOperation) -> Bool {
    switch operation {
    case .exportPortable, .exportCloudRecovery, .diagnose:
      false
    case .publishAppearance, .applyConfiguration, .importLegacy,
      .importPortable, .restoreBackup, .removeBackupRecord, .clearLearning:
      true
    }
  }

  func backupOperation(
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
    case .cloudRecovery: throw Failure.invalidOperation("cloud recovery backup")
    case .diagnose: throw Failure.invalidOperation("diagnostics backup")
    }
  }

  func learningContents(
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

  func stagedLearningImports(
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

  /// Only explicitly imported v2/v3 backups use the old portable table codec.
  func legacyBackupLearningImports(
    from directory: URL,
    manifest: LinnetBackupStore.BackupManifest
  ) throws
    -> [RimeUserDataBridge.LearningImport] {
    guard [LinnetBackupStore.legacyBackupFormatVersion, LinnetBackupStore.tableBackupFormatVersion]
      .contains(manifest.formatVersion)
    else { throw Failure.invalidOperation("legacy backup learning version") }
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

  func removeCandidateLearning(_ schemas: Set<String>, from candidate: URL) throws {
    guard schemas.isSubset(of: RimeUserDataBridge.learningSchemas) else {
      throw Failure.invalidOperation("learning replacement schema")
    }
    for schema in schemas {
      let database = candidate.appending(path: "\(schema).userdb", directoryHint: .isDirectory)
      var info = stat()
      if lstat(database.path, &info) != 0 {
        guard errno == ENOENT else { throw Failure.unsafePath(database.path) }
        continue
      }
      try requireDirectory(database)
      try FileManager.default.removeItem(at: database)
    }
  }

  func requireRevision(_ expected: String, current: String) throws {
    guard expected == current else {
      throw Failure.staleRevision(expected: expected, actual: current)
    }
  }

  func emptyLearningExport(schema: String) -> String {
    """
    # Rime user dictionary export
    #@/db_name\t\(schema)
    #@/db_type\tuserdb
    """ + "\n"
  }

  func makeRequest(
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

  func request(
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

  func remainingTransactionTime(until deadline: Date) throws -> TimeInterval {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { throw Failure.timedOut }
    return remaining
  }

  func ensureDirectory(_ url: URL) throws {
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

  func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.unsafePath(url.path)
    }
  }

  func requireRegularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw Failure.unsafePath(url.path)
    }
  }

  func requireWritableDestination(_ url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try requireDirectory(parent)
    guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
      throw Failure.unsafePath(url.path)
    }
    if fileManager.fileExists(atPath: url.path) { try requireRegularFile(url) }
  }

  func requireSameVolume(_ first: URL, _ second: URL) throws {
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
