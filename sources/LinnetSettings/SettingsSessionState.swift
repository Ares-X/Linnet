import Foundation

struct SettingsConfigurationSession: Equatable, Sendable {
  enum Readiness: Equatable, Sendable { case ready, sourceUnreadable, servicesUnavailable }
  enum ObservationResult: Equatable, Sendable { case unchanged, reloaded, conflict, ignored }
  enum DocumentCommitKind: Equatable, Sendable { case submittedDraft, externalReplacement }
  enum PersonalCommitKind: Equatable, Sendable { case submittedDraft, externalReplacement }
  enum PersonalCommitResult: Equatable, Sendable { case accepted, pendingEditsPreserved, conflict, rejectedStaleTicket }
  enum DocumentCommitResult: Equatable, Sendable {
    case accepted, pendingEditsPreserved, conflict, rejectedStaleTicket
  }
  struct DocumentTicket: Equatable, Sendable {
    let baselineRevision: String
    let submittedDraft: LinnetSettingsDocument
  }
  struct PersonalTicket: Equatable, Sendable {
    let baselineRevision: String
    let submittedDraft: LinnetPersonalData
  }
  private(set) var readiness: Readiness
  private(set) var documentBaseline: LinnetSettingsDocument?
  private(set) var documentBaselineRevision: String?
  var documentDraft: LinnetSettingsDocument
  private(set) var personalBaseline: LinnetPersonalDataStore.Snapshot?
  var personalDraft: LinnetPersonalData
  private(set) var externalDocumentConflict: LinnetSettingsDocumentStore.Snapshot?
  private(set) var externalPersonalConflict: LinnetPersonalDataStore.Snapshot?
  init(
    document: LinnetSettingsDocumentStore.Snapshot?,
    personal: LinnetPersonalDataStore.Snapshot?,
    servicesAvailable: Bool
  ) {
    documentBaseline = document?.document
    documentBaselineRevision = document?.revision
    documentDraft = document?.document ?? .default
    personalBaseline = personal
    personalDraft = personal?.data ?? .empty
    externalDocumentConflict = nil
    externalPersonalConflict = nil
    if document == nil || personal == nil {
      readiness = .sourceUnreadable
    } else if !servicesAvailable {
      readiness = .servicesUnavailable
    } else {
      readiness = .ready
    }
  }
  var canEdit: Bool { readiness == .ready }
  var canPersist: Bool {
    canEdit && !hasExternalConflict
  }
  var hasExternalConflict: Bool {
    externalDocumentConflict != nil || externalPersonalConflict != nil
  }
  var personalBaselineRevision: String? { personalBaseline?.revision }
  var documentDirty: Bool {
    guard let documentBaseline else { return false }
    return documentDraft != documentBaseline
  }
  var personalDataDirty: Bool {
    guard let personalBaseline else { return false }
    return personalDraft != personalBaseline.data
  }
  var pendingChanges: Bool { documentDirty || personalDataDirty }
  mutating func discardPendingChanges() {
    if let externalDocumentConflict {
      documentBaseline = externalDocumentConflict.document
      documentBaselineRevision = externalDocumentConflict.revision
      self.externalDocumentConflict = nil
    }
    if let externalPersonalConflict {
      personalBaseline = externalPersonalConflict
      self.externalPersonalConflict = nil
    }
    if let documentBaseline { documentDraft = documentBaseline }
    if let personalBaseline { personalDraft = personalBaseline.data }
  }
  mutating func markSourceUnreadable() {
    readiness = .sourceUnreadable
  }
  func makeDocumentTicket() -> DocumentTicket? {
    guard canPersist, let documentBaselineRevision else { return nil }
    return DocumentTicket(
      baselineRevision: documentBaselineRevision,
      submittedDraft: documentDraft)
  }
  mutating func acceptDocumentCommit(
    _ snapshot: LinnetSettingsDocumentStore.Snapshot,
    kind: DocumentCommitKind = .submittedDraft,
    ticket: DocumentTicket
  ) -> DocumentCommitResult {
    guard canEdit, documentBaselineRevision == ticket.baselineRevision else {
      return .rejectedStaleTicket
    }
    if kind == .externalReplacement && documentDirty {
      externalDocumentConflict = snapshot
      return .conflict
    }
    documentBaseline = snapshot.document
    documentBaselineRevision = snapshot.revision
    guard documentDraft == ticket.submittedDraft else {
      return .pendingEditsPreserved
    }
    documentDraft = snapshot.document
    externalDocumentConflict = nil
    return .accepted
  }
  mutating func acceptAppearanceCommit(
    _ snapshot: LinnetSettingsDocumentStore.Snapshot,
    ticket: DocumentTicket
  ) -> Bool {
    guard canEdit, documentBaselineRevision == ticket.baselineRevision else { return false }
    documentBaseline = snapshot.document
    documentBaselineRevision = snapshot.revision
    return true
  }
  func makePersonalTicket() -> PersonalTicket? {
    guard canPersist, let personalBaseline else { return nil }
    return PersonalTicket(
      baselineRevision: personalBaseline.revision,
      submittedDraft: personalDraft)
  }
  mutating func observePersonal(
    _ snapshot: LinnetPersonalDataStore.Snapshot
  ) -> ObservationResult {
    guard let personalBaseline else { return .ignored }
    guard snapshot.revision != personalBaseline.revision else { return .unchanged }
    if personalDraft == personalBaseline.data {
      self.personalBaseline = snapshot
      personalDraft = snapshot.data
      externalPersonalConflict = nil
      return .reloaded
    }
    externalPersonalConflict = snapshot
    return .conflict
  }
  mutating func observeDocument(
    _ snapshot: LinnetSettingsDocumentStore.Snapshot
  ) -> ObservationResult {
    guard let documentBaseline, let documentBaselineRevision else { return .ignored }
    guard snapshot.revision != documentBaselineRevision else { return .unchanged }
    if documentDraft == documentBaseline {
      self.documentBaseline = snapshot.document
      self.documentBaselineRevision = snapshot.revision
      documentDraft = snapshot.document
      externalDocumentConflict = nil
      return .reloaded
    }
    externalDocumentConflict = snapshot
    return .conflict
  }
  mutating func acceptPersonalCommit(
    _ snapshot: LinnetPersonalDataStore.Snapshot,
    kind: PersonalCommitKind,
    ticket: PersonalTicket
  ) -> PersonalCommitResult {
    guard canEdit, personalBaseline?.revision == ticket.baselineRevision else {
      return .rejectedStaleTicket
    }
    if kind == .externalReplacement && personalDataDirty {
      externalPersonalConflict = snapshot
      return .conflict
    }
    personalBaseline = snapshot
    if personalDraft == ticket.submittedDraft {
      personalDraft = snapshot.data
      externalPersonalConflict = nil
      return .accepted
    }
    if kind == .submittedDraft {
      return .pendingEditsPreserved
    }
    externalPersonalConflict = snapshot
    return .conflict
  }
  mutating func resolveExternalConflictByReloading() -> Bool {
    guard hasExternalConflict else { return false }
    if let externalDocumentConflict {
      documentBaseline = externalDocumentConflict.document
      documentBaselineRevision = externalDocumentConflict.revision
      documentDraft = externalDocumentConflict.document
      self.externalDocumentConflict = nil
    }
    if let externalPersonalConflict {
      personalBaseline = externalPersonalConflict
      personalDraft = externalPersonalConflict.data
      self.externalPersonalConflict = nil
    }
    return true
  }
  mutating func resolveExternalConflictKeepingPending() -> Bool {
    guard hasExternalConflict else { return false }
    if let externalDocumentConflict {
      documentBaseline = externalDocumentConflict.document
      documentBaselineRevision = externalDocumentConflict.revision
      self.externalDocumentConflict = nil
    }
    if let externalPersonalConflict {
      personalBaseline = externalPersonalConflict
      self.externalPersonalConflict = nil
    }
    return true
  }
}
enum SettingsBackupHistoryState: Equatable, Sendable {
  case unavailable
  case loading(previous: [LinnetBackupStore.BackupRecord])
  case loaded([LinnetBackupStore.BackupRecord])
  case failed(previous: [LinnetBackupStore.BackupRecord])
  init(rootAvailable: Bool) {
    self = rootAvailable ? .loading(previous: []) : .unavailable
  }
  var isAuthoritativelyEmpty: Bool {
    if case .loaded(let records) = self { return records.isEmpty }
    return false
  }
  mutating func beginLoading() {
    switch self {
    case .unavailable:
      self = .loading(previous: [])
    case .loading(let records), .failed(let records):
      self = .loading(previous: records)
    case .loaded(let records):
      self = .loading(previous: records)
    }
  }

  mutating func finishLoading(_ records: [LinnetBackupStore.BackupRecord]) {
    self = .loaded(records)
  }

  mutating func failLoading() {
    switch self {
    case .unavailable:
      self = .failed(previous: [])
    case .loading(let records), .failed(let records):
      self = .failed(previous: records)
    case .loaded(let records):
      self = .failed(previous: records)
    }
  }
}

/// Owns one cooperative personal-data validation worker. Rapid edits cancel
/// the active request and replace the single buffered request, so validation
/// never fans out into concurrent full-draft scans.
@MainActor
final class SettingsPersonalValidationExecutor {
  typealias Evaluator = @Sendable (
    LinnetPersonalData,
    LinnetPersonalDataStore.CancellationCheck
  ) throws -> LinnetPersonalDataStore.Validation
  typealias Completion = @MainActor @Sendable (LinnetPersonalDataStore.Validation) -> Void

  private final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }

    func check() throws {
      lock.lock()
      let shouldCancel = cancelled
      lock.unlock()
      if shouldCancel { throw CancellationError() }
    }
  }

  private struct Request: Sendable {
    let data: LinnetPersonalData
    let token: CancellationToken
    let completion: Completion
  }

  private let continuation: AsyncStream<Request>.Continuation
  private let stream: AsyncStream<Request>
  private let evaluator: Evaluator
  private var activeToken: CancellationToken?
  private var worker: Task<Void, Never>?

  init(
    evaluator: @escaping Evaluator = { data, checkCancellation in
      try LinnetPersonalDataStore.validate(
        data, checkCancellation: checkCancellation)
    }
  ) {
    var capturedContinuation: AsyncStream<Request>.Continuation?
    stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      capturedContinuation = $0
    }
    continuation = capturedContinuation!
    self.evaluator = evaluator
  }

  func submit(_ data: LinnetPersonalData, completion: @escaping Completion) {
    startWorkerIfNeeded()
    activeToken?.cancel()
    let token = CancellationToken()
    activeToken = token
    continuation.yield(Request(data: data, token: token, completion: completion))
  }

  func cancel() {
    activeToken?.cancel()
    activeToken = nil
  }

  private func startWorkerIfNeeded() {
    guard worker == nil else { return }
    let stream = stream
    let evaluator = evaluator
    worker = Task.detached(priority: .userInitiated) {
      for await request in stream {
        do {
          try request.token.check()
          let result = try evaluator(request.data) {
            try request.token.check()
            try Task.checkCancellation()
          }
          try request.token.check()
          try Task.checkCancellation()
          await request.completion(result)
        } catch is CancellationError {
          continue
        } catch {
          continue
        }
      }
    }
  }

  deinit {
    activeToken?.cancel()
    continuation.finish()
    worker?.cancel()
  }
}
