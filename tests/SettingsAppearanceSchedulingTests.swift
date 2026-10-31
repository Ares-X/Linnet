import AppKit
import Combine
import Darwin
import Foundation

/// Runs the real SettingsModel, coordinator and authenticated IPC client. The
/// helper is a separate process because the IPC owner rejects same-PID peers.
@main
struct SettingsAppearanceSchedulingTests {
  @MainActor
  static func main() async throws {
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--host" {
      try serve(
        bundleURL: URL(fileURLWithPath: CommandLine.arguments[2]),
        control: URL(fileURLWithPath: CommandLine.arguments[3]))
      return
    }
    let root = LinnetTestScratch.directory.appending(path: "appearance-scheduling")
    try directory(root)
    let product = "LT" + UUID().uuidString.prefix(8)
    let bundle = try makeBundle(at: root, product: String(product))
    guard let registry = LinnetSettingsContract.dataRegistry(startingAt: bundle) else {
      throw FixtureFailure(message: "fixture registry unavailable")
    }
    // The production model and IPC derive this unique product root themselves.
    // Only tiny fixture packs live here; the maintainer's product is untouched.
    defer {
      do {
        try registry.verifyCanonicalRoot()
        try FileManager.default.removeItem(at: registry.rootDirectory)
        try FileManager.default.removeItem(at: root)
      } catch { fail("fixture cleanup failed: \(error)") }
    }
    try makeRuntime(registry)
    let control = root.appending(path: "control")
    try directory(control)
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    helper.arguments = ["--host", bundle.bundleURL.path, control.path]
    try helper.run()
    defer {
      if helper.isRunning { helper.terminate() }
      helper.waitUntilExit()
    }
    try await wait("IPC helper did not start") { exists(control.appending(path: "ready")) }

    let model = SettingsModel(bundle: bundle)
    await model.prepareInitialState()
    try await wait("configuration did not become ready") {
      model.configuration.canPersist && !model.personalValidationPending
    }
    let live = registry.userDataDirectory
    var requests = 0
    var prematureLiveSuccess = false
    let observation = model.$status.sink { status in
      guard status == .appearanceLive, let baseline = model.configuration.documentBaseline else {
        return
      }
      if model.configuration.documentDraft.appearance.livePanelProjection(over: baseline.appearance)
        != baseline.appearance { prematureLiveSuccess = true }
    }
    defer { observation.cancel() }

    func select(_ font: Double) {
      model.configuration.documentDraft.appearance.fontPoint = font
      model.publishAppearance(model.configuration.documentDraft.appearance)
    }
    func nextRequest(_ command: LinnetSettingsContract.DataCommand) async throws {
      requests += 1
      let file = control.appending(path: "request-\(requests).json")
      try await wait("missing request \(requests) (\(command))") { exists(file) }
      let request = try JSONDecoder().decode(
        LinnetSettingsContract.DataRequest.self, from: Data(contentsOf: file))
      try require(request.command == command, "unexpected request \(request.command), wanted \(command)")
    }
    func release(_ action: String = "accept") throws {
      try Data(action.utf8).write(
        to: control.appending(path: "release-\(requests)"), options: .atomic)
    }
    func settled(_ font: Double) async throws {
      try await wait("appearance did not settle to \(font)") {
        !model.operationActive && model.status == .appearanceLive
          && model.configuration.documentBaseline?.appearance.fontPoint == font
      }
      let persisted = try LinnetSettingsDocumentStore.load(from: live)
      let host = try JSONDecoder().decode(
        LinnetSettingsDocument.self, from: Data(contentsOf: control.appending(path: "host.json")))
      try require(model.configuration.documentDraft.appearance.fontPoint == font
        && persisted.appearance.fontPoint == font && host.appearance.fontPoint == font,
        "draft, disk and fixture Host did not converge")
    }

    let a = model.configuration.documentDraft.appearance.fontPoint
    let b: Double = a == 23 ? 24 : 23
    let c: Double = 27
    // A -> B in flight -> A. The second A equals the old baseline.
    select(b)
    try await nextRequest(.refresh)
    select(a)
    try release()
    try await nextRequest(.refresh)
    try require(model.status != .appearanceLive, "B was reported as live while A remained pending")
    try release()
    try await settled(a)

    // Coalescing retains C rather than the B snapshot or intermediate values.
    select(b)
    try await nextRequest(.refresh)
    select(25)
    select(c)
    try release()
    try await nextRequest(.refresh)
    try release()
    try await settled(c)

    // An ordinary Apply must not erase a later panel-only selection. A later
    // input/page-size/layout draft must still wait for its own explicit Apply.
    model.configuration.documentDraft.input.capsLockUppercase.toggle()
    let appliedInput = model.configuration.documentDraft.input
    model.applyConfiguration()
    try await nextRequest(.reloadConfiguration)
    model.configuration.documentDraft.input.capsLockUppercase.toggle()
    model.configuration.documentDraft.appearance.pageSize = 9
    model.configuration.documentDraft.appearance.chineseCandidateLayout = .vertical
    model.configuration.documentDraft.appearance.englishCandidateLayout = .vertical
    model.configuration.documentDraft.appearance.candidateBrowsingMode = .scrollingOnly
    let appliedAppearance = model.configuration.documentBaseline!.appearance
    select(b)
    try release()
    try await nextRequest(.refresh)
    try release()
    try await settled(b)
    let afterApply = try LinnetSettingsDocumentStore.load(from: live)
    try require(afterApply.input == appliedInput, "live appearance published an Apply-only input draft")
    try require(afterApply.appearance.pageSize == appliedAppearance.pageSize
      && afterApply.appearance.chineseCandidateLayout == appliedAppearance.chineseCandidateLayout
      && afterApply.appearance.englishCandidateLayout == appliedAppearance.englishCandidateLayout
      && afterApply.appearance.candidateBrowsingMode == appliedAppearance.candidateBrowsingMode,
      "live appearance published Apply-only candidate fields")
    try require(model.pendingChanges, "Apply-only changes were discarded")
    model.discardPendingChanges()

    // Discard removes an unstarted debounce; an already active B still needs
    // compensation to the appearance the user retained when discarding.
    select(c)
    model.discardPendingChanges()
    try await Task.sleep(nanoseconds: 150_000_000)
    try require(!exists(control.appending(path: "request-\(requests + 1).json")),
      "Discard left an old debounce able to publish")
    select(c)
    try await nextRequest(.refresh)
    model.discardPendingChanges()
    try release()
    try await nextRequest(.refresh)
    try release()
    try await settled(b)

    // A rejected publication rolls back and reports failure without retrying
    // the same failed selection. A new intent can still publish normally.
    select(c)
    try await nextRequest(.refresh)
    try release("fail")
    try await nextRequest(.reloadConfiguration)
    try release()
    try await wait("appearance failure was not retained") {
      if case .appearanceFailed = model.status { return !model.operationActive }
      return false
    }
    try require(try LinnetSettingsDocumentStore.load(from: live).appearance.fontPoint == b,
      "failed publication did not preserve the live appearance")
    try require(!exists(control.appending(path: "request-\(requests + 1).json")),
      "failed appearance automatically retried")
    select(a)
    try await nextRequest(.refresh)
    try release()
    try await settled(a)

    // Cancel a full Apply at its supported paused boundary. Its personal
    // draft stays unapplied while a newer appearance still converges.
    model.configuration.personalDraft.customWords.append(.init(value: "fixture", code: "fixture"))
    try await wait("personal draft validation did not finish") { model.canApplyChanges }
    let personalBeforeCancel = try LinnetPersonalDataStore.snapshot(from: live)
    model.applyConfiguration()
    try await nextRequest(.pause)
    try await wait("paused Apply was not cancellable") {
      model.activeOperation?.cancellable == true
    }
    select(b)
    model.cancelActiveOperation()
    try release()
    try await nextRequest(.cancel)
    try release()
    try await nextRequest(.refresh)
    try release()
    try await settled(b)
    try require(try LinnetPersonalDataStore.snapshot(from: live) == personalBeforeCancel,
      "cancelled Apply committed its personal data")
    try require(model.configuration.personalDataDirty, "cancelled Apply erased its personal draft")
    model.discardPendingChanges()

    // External changes are a conflict, not permission to publish the draft.
    var external = try LinnetSettingsDocumentStore.load(from: live)
    external.appearance.fontPoint = c
    try LinnetSettingsDocumentStore.write(external, to: live)
    select(a)
    try await wait("external change was not retained as a conflict") {
      model.status == .configurationConflict && !model.operationActive
    }
    try require(model.configuration.hasExternalConflict,
      "external settings conflict was lost")
    try require(!exists(control.appending(path: "request-\(requests + 1).json")),
      "conflicting draft reached Host")
    model.discardPendingChanges()
    try require(model.configuration.documentDraft == external && !model.pendingChanges,
      "Discard did not accept the external baseline")
    try require(!prematureLiveSuccess, "live success was shown before the latest selection converged")
    print("SettingsAppearanceSchedulingTests: PASS")
  }

  private static func serve(bundleURL: URL, control: URL) throws {
    guard let bundle = Bundle(url: bundleURL),
      let registry = LinnetSettingsContract.dataRegistry(startingAt: bundle)
    else { fail("helper bundle unavailable") }
    var sequence = 0
    var active = try LinnetSettingsDocumentStore.load(from: registry.userDataDirectory)
    func health() throws -> LinnetSettingsContract.RuntimeHealth {
      .init(
        productIdentity: .init(version: "1.0.0", build: 1, revision: String(repeating: "a", count: 40)),
        state: .running, phase: .running, rimeVersion: "fixture", smartEnglishAvailable: true,
        octagramAvailable: true, availableSchemaCount: 9, requiredSchemaCount: 9,
        activeTransactionID: nil,
        activeSettingsRevision: try LinnetSettingsDocumentStore.snapshot(from: registry.userDataDirectory).revision)
    }
    let host = try LinnetSettingsTransactionIPC.Host(startingAt: bundle) { request, reply in
      do {
        if request.command == .diagnose {
          reply(.init(transactionID: request.transactionID, status: .running,
            code: .diagnosticsReady, detail: "fixture running", health: try health()))
          return
        }
        guard [.refresh, .reloadConfiguration, .pause, .cancel].contains(request.command)
        else { fail("unexpected helper command") }
        sequence += 1
        try JSONEncoder().encode(request).write(
          to: control.appending(path: "request-\(sequence).json"), options: .atomic)
        let release = control.appending(path: "release-\(sequence)")
        let deadline = Date().addingTimeInterval(5)
        while !exists(release), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        guard exists(release) else { fail("fixture reply was not released") }
        let action = try String(contentsOf: release, encoding: .utf8)
        if request.command == .pause || request.command == .cancel {
          let pausing = request.command == .pause
          reply(.init(transactionID: request.transactionID,
            status: pausing ? .paused : .cancelled,
            code: pausing ? .runtimePaused : .runtimeResumed,
            detail: "fixture pause/cancel", health: try health()))
          return
        }
        if action == "fail" {
          reply(.init(transactionID: request.transactionID, status: .failed,
            code: .appearanceDeployFailed, detail: "fixture rejected appearance", health: try health()))
          return
        }
        guard let candidate = request.candidate else { fail("missing fixture candidate") }
        active = try LinnetSettingsDocumentStore.load(from: candidate)
        try LinnetSettingsDocumentStore.write(active, to: registry.userDataDirectory)
        try JSONEncoder().encode(active).write(
          to: control.appending(path: "host.json"), options: .atomic)
        reply(.init(transactionID: request.transactionID, status: .activated,
          code: .activationVerified, detail: "fixture published settings", health: try health()))
      } catch { fail("IPC fixture failed: \(error)") }
    }
    try host.start()
    // Process.terminate() is the explicit handle owned by the test parent.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler {
      host.stop()
      exit(0)
    }
    termination.resume()
    try Data().write(to: control.appending(path: "ready"))
    withExtendedLifetime((host, termination)) { RunLoop.main.run() }
  }

  private static func makeBundle(at root: URL, product: String) throws -> Bundle {
    let app = root.appending(path: "Host.app")
    try directory(app.appending(path: "Contents"))
    let plist: [String: Any] = [
      "CFBundleDisplayName": product, "CFBundleExecutable": "Fixture",
      "CFBundleIdentifier": "io.github.linnet.appearance.\(product)",
      "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0.0",
      "InputMethodConnectionName": product,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: app.appending(path: "Contents/Info.plist"))
    guard let bundle = Bundle(url: app) else { fail("bundle unavailable") }
    return bundle
  }

  private static func makeRuntime(_ registry: LinnetDataRegistry) throws {
    let active = registry.activeSharedDataDirectory
    try directory(active.appending(path: "build"))
    var packs: [LinnetDataRegistry.ActivePack] = []
    let fixtureFiles: [(LinnetPackContract.Kind, [String])] = [
      (.chinese, ["default.yaml", "linnet_zh.dict.yaml", "linnet_zh.schema.yaml"]),
      (.english, ["linnet_en.schema.yaml"]), (.lts, ["wanxiang-lts-zh-hans.gram"]),
    ]
    for (kind, files) in fixtureFiles {
      let entries = files.sorted().map {
        LinnetPackContract.FileEntry(path: $0, bytes: UInt64($0.utf8.count),
          sha256: LinnetPackContract.sha256(Data($0.utf8)))
      }
      let manifest = LinnetPackContract.Manifest(
        format: LinnetPackContract.manifestFormat, product: LinnetPackContract.productIdentifier,
        packID: kind.packID, kind: kind, version: "fixture", sequence: 1, dataABI: 1,
        minCore: "1.0.0", contentSHA256: String(repeating: "a", count: 64),
        requires: kind == .lts ? [.init(kind: .chinese, dataABI: 1)] : [], files: entries)
      let bytes = try LinnetPackContract.canonicalManifestData(manifest)
      let pack = LinnetDataRegistry.activePack(
        from: manifest, manifestSHA256: LinnetPackContract.sha256(bytes))
      packs.append(pack)
      let installed = registry.rootDirectory.appending(path: pack.relativePath)
      try directory(installed)
      try bytes.write(to: installed.appending(path: "manifest.json"))
      for name in files {
        let file = installed.appending(path: name)
        try Data(name.utf8).write(to: file)
        try FileManager.default.createSymbolicLink(
          at: active.appending(path: name), withDestinationURL: file)
      }
    }
    try Data("grammar:\n  language: wanxiang-lts-zh-hans\n".utf8)
      .write(to: active.appending(path: "linnet_grammar_active.yaml"))
    try JSONEncoder().encode(LinnetDataRegistry.ActiveState(
      format: LinnetDataRegistry.stateFormat, edition: .standard, generation: 1,
      activeView: "Runtime/Active", packs: packs))
      .write(to: active.appending(path: "activation.json"))
    _ = try registry.runtimeSnapshot()
    try LinnetSettingsDocumentStore.write(.default, to: registry.userDataDirectory)
  }

  private static func directory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
  private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  @MainActor
  private static func wait(_ message: String, until ready: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !ready(), Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    try require(ready(), message)
  }
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw FixtureFailure(message: message) }
  }
  private struct FixtureFailure: Error { let message: String }
  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}
