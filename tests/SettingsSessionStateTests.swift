import Darwin
import Foundation

@main
struct SettingsSessionStateTests {
  @MainActor
  static func main() async {
    testDocumentStoreRevisions()
    testReadiness()
    testDiscardPendingChanges()
    testDocumentCommits()
    testAppearanceCommits()
    testObservedSnapshots()
    testCommittedSnapshots()
    testBackupHistory()
    await testValidationExecutor()
    print("SettingsSessionStateTests: PASS")
  }

  private static func testDiscardPendingChanges() {
    let baseline = LinnetSettingsDocument.default
    let personal = snapshot("Saved", revision: "r1")
    var session = SettingsConfigurationSession(
      document: documentSnapshot(baseline), personal: personal, servicesAvailable: true)
    session.documentDraft.input.traditionalChinese = true
    session.documentDraft.input.pinyinReverseTrigger = .verticalBar
    session.personalDraft.customWords = [
      .init(value: "temporary", code: "temporary")
    ]
    guard session.pendingChanges else {
      fail("the close-protection fixture did not begin with pending changes")
    }
    session.discardPendingChanges()
    guard !session.pendingChanges,
      session.documentDraft == baseline,
      session.personalDraft == personal.data
    else {
      fail("discarding pending Settings changes did not restore both canonical baselines")
    }
  }

  private static func testDocumentStoreRevisions() {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "linnet-document-revision-\(UUID().uuidString)", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }

      let absent = try LinnetSettingsDocumentStore.snapshot(from: root)
      let absentAgain = try LinnetSettingsDocumentStore.snapshot(from: root)
      guard absent == absentAgain else { fail("missing document revision was not deterministic") }

      try LinnetSettingsDocumentStore.write(absent.document, to: root)
      let present = try LinnetSettingsDocumentStore.snapshot(from: root)
      guard present.document == absent.document, present.revision != absent.revision else {
        fail("missing and present document identities collapsed")
      }

      let compact = try JSONEncoder().encode(present.document)
      try compact.write(
        to: root.appending(path: LinnetSettingsDocumentStore.fileName), options: .atomic)
      let reformatted = try LinnetSettingsDocumentStore.snapshot(from: root)
      guard reformatted.document == present.document,
        reformatted.revision != present.revision
      else { fail("persistent document revision ignored exact-byte replacement") }

      var changed = reformatted.document
      changed.input.traditionalChinese.toggle()
      try LinnetSettingsDocumentStore.write(changed, to: root)
      let changedSnapshot = try LinnetSettingsDocumentStore.snapshot(from: root)
      guard changedSnapshot.document == changed,
        changedSnapshot.revision != reformatted.revision
      else { fail("document content change did not advance its revision") }
    } catch {
      fail("document revision fixture failed: \(error)")
    }
  }

  private static func testDocumentCommits() {
    let personal = snapshot("Saved", revision: "r1")
    let baseline = LinnetSettingsDocument.default
    var submitted = baseline
    submitted.appearance.fontPoint += 1
    var committed = submitted
    committed.appearance.fontPoint += 1

    var accepted = SettingsConfigurationSession(
      document: documentSnapshot(baseline), personal: personal, servicesAvailable: true)
    accepted.documentDraft = submitted
    guard let acceptedTicket = accepted.makeDocumentTicket(),
      accepted.acceptDocumentCommit(
        documentSnapshot(committed, revision: "d1"), ticket: acceptedTicket) == .accepted,
      accepted.documentBaseline == committed, accepted.documentDraft == committed,
      !accepted.documentDirty
    else { fail("a committed document did not advance the baseline and draft") }

    var pending = SettingsConfigurationSession(
      document: documentSnapshot(baseline), personal: personal, servicesAvailable: true)
    pending.documentDraft = submitted
    guard let pendingTicket = pending.makeDocumentTicket() else {
      fail("document ticket unavailable")
    }
    var laterDraft = submitted
    laterDraft.appearance.fontPoint += 2
    pending.documentDraft = laterDraft
    guard pending.acceptDocumentCommit(
      documentSnapshot(committed, revision: "d1"), ticket: pendingTicket)
      == .pendingEditsPreserved,
      pending.documentBaseline == committed, pending.documentDraft == laterDraft,
      pending.documentDirty
    else { fail("a document commit overwrote edits made during apply") }

    guard pending.acceptDocumentCommit(
      documentSnapshot(baseline, revision: "d2"), ticket: pendingTicket)
      == .rejectedStaleTicket,
      pending.documentBaseline == committed, pending.documentDraft == laterDraft
    else { fail("a stale document CAS ticket was accepted") }

    var replacement = SettingsConfigurationSession(
      document: documentSnapshot(baseline), personal: personal, servicesAvailable: true)
    guard let replacementTicket = replacement.makeDocumentTicket() else {
      fail("replacement document ticket unavailable")
    }
    replacement.documentDraft = submitted
    guard replacement.acceptDocumentCommit(
      documentSnapshot(committed, revision: "d1"),
      kind: .externalReplacement, ticket: replacementTicket) == .conflict,
      replacement.documentDraft == submitted,
      replacement.externalDocumentConflict?.document == committed,
      replacement.hasExternalConflict, !replacement.canPersist
    else { fail("an external document replacement overwrote a pending draft") }

    guard replacement.resolveExternalConflictKeepingPending(),
      replacement.documentBaseline == committed,
      replacement.documentDraft == submitted,
      replacement.documentDirty, replacement.canPersist
    else { fail("keeping a document draft did not advance its external baseline") }

    let unreadable = SettingsConfigurationSession(
      document: nil, personal: personal, servicesAvailable: true)
    let unavailable = SettingsConfigurationSession(
      document: documentSnapshot(baseline), personal: personal, servicesAvailable: false)
    guard unreadable.makeDocumentTicket() == nil,
      unavailable.makeDocumentTicket() == nil
    else { fail("an unready session issued a document commit ticket") }
  }

  private static func testAppearanceCommits() {
    let personal = snapshot("Saved", revision: "r1")
    let baseline = LinnetSettingsDocument.default
    var committed = baseline.appearance
    committed.fontPoint += 2
    committed.themeFamily = .clayTiles
    committed.themeMode = .dark
    committed.fontPreset = .book
    committed.chineseCandidateLayout = .vertical
    committed.englishCandidateLayout = .vertical
    committed.candidateBrowsingMode = .scrollingOnly
    committed.pageSize = 9

    var ready = SettingsConfigurationSession(
      document: documentSnapshot(baseline), personal: personal, servicesAvailable: true)
    ready.documentDraft.appearance = committed
    ready.documentDraft.appearance.fontPoint += 1
    ready.documentDraft.appearance.themeMode = .light
    ready.documentDraft.appearance.pageSize = 7
    let laterDraft = ready.documentDraft
    guard let appearanceTicket = ready.makeDocumentTicket(),
      ready.acceptAppearanceCommit(
        documentSnapshot(
          {
            var value = baseline
            value.appearance = committed.livePanelProjection(over: baseline.appearance)
            return value
          }(),
          revision: "d1"),
        ticket: appearanceTicket),
      ready.documentBaseline?.appearance.fontPoint == committed.fontPoint,
      ready.documentBaseline?.appearance.themeFamily == committed.themeFamily,
      ready.documentBaseline?.appearance.themeMode == committed.themeMode,
      ready.documentBaseline?.appearance.fontPreset == committed.fontPreset,
      ready.documentBaseline?.appearance.chineseCandidateLayout
        == baseline.appearance.chineseCandidateLayout,
      ready.documentBaseline?.appearance.englishCandidateLayout
        == baseline.appearance.englishCandidateLayout,
      ready.documentBaseline?.appearance.candidateBrowsingMode
        == baseline.appearance.candidateBrowsingMode,
      ready.documentBaseline?.appearance.pageSize == baseline.appearance.pageSize,
      ready.documentDraft == laterDraft
    else { fail("a live appearance commit changed draft or an Apply-only appearance field") }

    var unreadable = SettingsConfigurationSession(
      document: nil, personal: personal, servicesAvailable: true)
    let unreadableDraft = unreadable.documentDraft
    var unavailable = SettingsConfigurationSession(
      document: documentSnapshot(baseline), personal: personal, servicesAvailable: false)
    let unavailableTicket = SettingsConfigurationSession.DocumentTicket(
      baselineRevision: "d0", submittedDraft: baseline)
    guard !unreadable.acceptAppearanceCommit(
      documentSnapshot(baseline, revision: "d1"), ticket: unavailableTicket),
      unreadable.documentBaseline == nil, unreadable.documentDraft == unreadableDraft,
      !unavailable.acceptAppearanceCommit(
        documentSnapshot(baseline, revision: "d1"), ticket: unavailableTicket),
      unavailable.documentBaseline == baseline
    else { fail("an unready session accepted a live appearance commit") }
  }

  private static func testReadiness() {
    let baseline = snapshot("Saved", revision: "r1")
    var ready = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: true)
    guard ready.readiness == .ready, ready.canEdit, ready.canPersist,
      ready.personalBaselineRevision == "r1", !ready.pendingChanges
    else { fail("a fully loaded session was not ready") }
    ready.markSourceUnreadable()
    guard ready.readiness == .sourceUnreadable, !ready.canEdit, !ready.canPersist else {
      fail("a later source read failure did not persist as a configuration blocker")
    }

    let personalFailure = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: nil, servicesAvailable: true)
    let documentFailure = SettingsConfigurationSession(
      document: nil, personal: baseline, servicesAvailable: true)
    guard personalFailure.readiness == .sourceUnreadable,
      documentFailure.readiness == .sourceUnreadable,
      !personalFailure.canEdit, !personalFailure.canPersist,
      personalFailure.personalBaselineRevision == nil
    else { fail("an unreadable source exposed an editable fallback") }

    let unavailable = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: false)
    guard unavailable.readiness == .servicesUnavailable,
      !unavailable.canEdit, !unavailable.canPersist,
      unavailable.personalBaselineRevision == "r1"
    else { fail("unavailable data services exposed writable configuration") }
  }

  private static func testObservedSnapshots() {
    let baseline = snapshot("Saved", revision: "r1")
    let remote = snapshot("Remote", revision: "r2")
    var session = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: true)
    session.personalDraft.customWords.append(.init(value: "Local", code: "local"))
    let local = session.personalDraft
    guard session.observePersonal(baseline) == .unchanged,
      session.personalDraft == local
    else { fail("an unchanged observation rewrote the personal draft") }

    guard session.observePersonal(remote) == .conflict,
      session.personalDraft == local, !session.canPersist,
      session.externalPersonalConflict?.revision == "r2"
    else { fail("an external observation did not preserve a dirty draft") }

    var reloaded = session
    guard reloaded.resolveExternalConflictByReloading(),
      reloaded.personalDraft == remote.data,
      reloaded.personalBaselineRevision == "r2", reloaded.canPersist
    else { fail("explicit conflict reload did not adopt canonical data") }

    guard session.resolveExternalConflictKeepingPending(),
      session.personalDraft == local,
      session.personalBaselineRevision == "r2", session.personalDataDirty,
      session.canPersist
    else { fail("keep-pending did not retain the local draft") }

    var clean = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: true)
    guard clean.observePersonal(remote) == .reloaded,
      clean.personalDraft == remote.data, clean.personalBaselineRevision == "r2"
    else { fail("a clean draft did not follow externally committed data") }
  }

  private static func testCommittedSnapshots() {
    let baseline = snapshot("Saved", revision: "r1")
    let committed = snapshot("Committed", revision: "r2")
    var accepted = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: true)
    guard let acceptedTicket = accepted.makePersonalTicket(),
      accepted.acceptPersonalCommit(
        committed, kind: .submittedDraft, ticket: acceptedTicket) == .accepted,
      accepted.personalDraft == committed.data,
      accepted.personalBaselineRevision == "r2"
    else { fail("a matching submitted draft was not accepted") }

    var pending = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: true)
    guard let pendingTicket = pending.makePersonalTicket() else { fail("ticket unavailable") }
    pending.personalDraft.customWords.append(.init(value: "Later", code: "later"))
    let laterDraft = pending.personalDraft
    guard pending.acceptPersonalCommit(
      committed, kind: .submittedDraft, ticket: pendingTicket) == .pendingEditsPreserved,
      pending.personalDraft == laterDraft,
      pending.personalBaselineRevision == "r2", pending.personalDataDirty
    else { fail("post-submit edits were not preserved") }

    var replacement = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: true)
    guard let replacementTicket = replacement.makePersonalTicket() else {
      fail("replacement ticket unavailable")
    }
    replacement.personalDraft.customWords.append(.init(value: "Local", code: "local"))
    let localDraft = replacement.personalDraft
    guard replacement.acceptPersonalCommit(
      committed, kind: .externalReplacement, ticket: replacementTicket) == .conflict,
      replacement.personalDraft == localDraft,
      replacement.externalPersonalConflict?.revision == "r2"
    else { fail("an external replacement overwrote concurrent edits") }

    var stale = SettingsConfigurationSession(
      document: documentSnapshot(.default), personal: baseline, servicesAvailable: true)
    guard let staleTicket = stale.makePersonalTicket(),
      stale.observePersonal(committed) == .reloaded,
      stale.acceptPersonalCommit(
        snapshot("Newer", revision: "r3"), kind: .submittedDraft, ticket: staleTicket)
        == .rejectedStaleTicket,
      stale.personalBaselineRevision == "r2"
    else { fail("a stale personal CAS ticket was accepted") }
  }

  private static func testBackupHistory() {
    var unavailable = SettingsBackupHistoryState(rootAvailable: false)
    guard unavailable == .unavailable, !unavailable.isAuthoritativelyEmpty else {
      fail("an unavailable backup root presented as empty")
    }

    var history = SettingsBackupHistoryState(rootAvailable: true)
    guard history == .loading(previous: []), !history.isAuthoritativelyEmpty else {
      fail("backup loading presented as empty")
    }
    history.finishLoading([])
    guard history == .loaded([]), history.isAuthoritativelyEmpty else {
      fail("a successful empty read was not authoritative")
    }
    history.failLoading()
    guard history == .failed(previous: []), !history.isAuthoritativelyEmpty else {
      fail("a failed backup read presented as empty")
    }

    let record = LinnetBackupStore.BackupRecord(
      transactionDirectory: URL(fileURLWithPath: "/tmp/transaction"),
      backupDirectory: URL(fileURLWithPath: "/tmp/transaction/backup"),
      transactionID: nil,
      state: .incomplete,
      transactionIdentity: nil)
    history.finishLoading([record])
    history.beginLoading()
    guard history == .loading(previous: [record]) else {
      fail("refresh did not preserve the last verified backup view")
    }
    history.failLoading()
    guard history == .failed(previous: [record]), !history.isAuthoritativelyEmpty else {
      fail("backup failure discarded the previous verified view")
    }
    unavailable.beginLoading()
    guard unavailable == .loading(previous: []) else {
      fail("a repaired backup root could not begin loading")
    }
  }

  @MainActor
  private static func testValidationExecutor() async {
    let recorder = ValidationRecorder()
    let executor = SettingsPersonalValidationExecutor { data, checkCancellation in
      recorder.begin()
      defer { recorder.end() }
      for _ in 0..<200 {
        try checkCancellation()
        recorder.step()
        usleep(500)
      }
      return .valid(data)
    }
    var completed: [String] = []
    func draft(_ value: String) -> LinnetPersonalData {
      .init(customWords: [.init(value: value, code: value.lowercased())], disabledWords: [], expansions: [])
    }
    executor.submit(draft("First")) { validation in
      completed.append(validation.normalized?.customWords.first?.value ?? "")
    }
    await waitUntil { recorder.started > 0 }
    executor.submit(draft("Second")) { validation in
      completed.append(validation.normalized?.customWords.first?.value ?? "")
    }
    executor.submit(draft("Latest")) { validation in
      completed.append(validation.normalized?.customWords.first?.value ?? "")
    }
    await waitUntil { completed.count == 1 }
    guard completed == ["Latest"], recorder.maximumActive == 1,
      recorder.cancelledWorkObserved
    else { fail("personal validation was not latest-only and serial") }
    executor.cancel()
  }

  @MainActor
  private static func waitUntil(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    _ predicate: () -> Bool
  ) async {
    let started = DispatchTime.now().uptimeNanoseconds
    while !predicate() {
      if DispatchTime.now().uptimeNanoseconds - started >= timeoutNanoseconds {
        fail("timed out waiting for validation executor")
      }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private static func snapshot(
    _ value: String,
    revision: String
  ) -> LinnetPersonalDataStore.Snapshot {
    .init(
      data: .init(
        customWords: [.init(value: value, code: value.lowercased())],
        disabledWords: [],
        expansions: []),
      revision: revision)
  }

  private static func documentSnapshot(
    _ document: LinnetSettingsDocument,
    revision: String = "d0"
  ) -> LinnetSettingsDocumentStore.Snapshot {
    .init(document: document, revision: revision)
  }

  private static func fail(_ message: String) -> Never {
    fputs("SettingsSessionStateTests: \(message)\n", stderr)
    exit(1)
  }
}

private final class ValidationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var maximum = 0
  private var starts = 0
  private var stepsByRun: [Int] = []

  var started: Int { locked { starts } }
  var maximumActive: Int { locked { maximum } }
  var cancelledWorkObserved: Bool { locked { stepsByRun.contains { $0 < 200 } } }

  func begin() {
    locked {
      active += 1
      starts += 1
      maximum = max(maximum, active)
      stepsByRun.append(0)
    }
  }

  func step() {
    locked { stepsByRun[stepsByRun.count - 1] += 1 }
  }

  func end() {
    locked { active -= 1 }
  }

  @discardableResult
  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
