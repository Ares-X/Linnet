import AppKit
import Foundation
import os

private let linnetUpdateLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "Linnet.Settings",
  category: "Update"
)

protocol LinnetCorePackageDownloading: Sendable {
  func download(
    _ core: LinnetDataChannel.Core,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL
}

/// Downloads the Catalog-owned Core package through Settings' existing byte
/// transfer boundary, then verifies the exact Catalog size and SHA-256 before
/// exposing the file to the user.
struct LinnetCorePackageDownloader: LinnetCorePackageDownloading {
  private let downloadsDirectory: URL?

  init(downloadsDirectory: URL? = nil) {
    self.downloadsDirectory = downloadsDirectory
  }

  func download(
    _ core: LinnetDataChannel.Core,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let root = try resolvedDownloadsDirectory()
    let directory = root.appending(
      path: "\(core.sha256)-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let destination = directory.appending(
      path: core.packageURL.lastPathComponent,
      directoryHint: .notDirectory
    )
    let transport = LinnetSettingsDownloadTransport(source: .direct)
    try await transport.downloadArtifact(
      from: core.packageURL,
      expectedBytes: core.bytes,
      to: destination,
      progress: progress
    )
    try LinnetDataChannel.verifyDownloadedArtifact(
      bytes: core.bytes, sha256: core.sha256, at: destination)
    return destination
  }

  private func resolvedDownloadsDirectory() throws -> URL {
    if let downloadsDirectory { return downloadsDirectory }
    guard let downloads = FileManager.default.urls(
      for: .downloadsDirectory,
      in: .userDomainMask
    ).first else { throw Failure.missingDownloadsDirectory }
    return downloads.appending(path: "Linnet Core Updates", directoryHint: .isDirectory)
  }

  private enum Failure: Error {
    case missingDownloadsDirectory
  }
}

/// Settings owns update visibility and the user-requested Core activation
/// orchestration. The running Host remains the sole exit-safety authority.
@MainActor
final class LinnetSettingsUpdateChecker: ObservableObject {
  enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case preview

    static let defaultsKey = "Linnet.Settings.UpdateChannel.v1"

    var id: String { rawValue }

    var catalogURL: URL {
      switch self {
      case .stable:
        LinnetSettingsDownloadSource.canonicalCatalogURL
      case .preview:
        URL(
          string:
            "https://raw.githubusercontent.com/Ares-X/Linnet/preview-channel/Linnet-Data-Channel.json"
        )!
      }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
      guard let rawValue = defaults.string(forKey: defaultsKey),
        let channel = Self(rawValue: rawValue)
      else { return .stable }
      return channel
    }

    func save(to defaults: UserDefaults = .standard) {
      defaults.set(rawValue, forKey: Self.defaultsKey)
    }
  }

  enum RuntimeVersionState: Equatable {
    case checking(installed: LinnetSettingsContract.ProductIdentity?)
    case current(LinnetSettingsContract.ProductIdentity)
    case pending(
      installed: LinnetSettingsContract.ProductIdentity,
      running: LinnetSettingsContract.ProductIdentity
    )
    case applying(
      installed: LinnetSettingsContract.ProductIdentity,
      running: LinnetSettingsContract.ProductIdentity
    )
    case blocked(
      installed: LinnetSettingsContract.ProductIdentity,
      running: LinnetSettingsContract.ProductIdentity,
      issue: LinnetSettingsContract.CoreActivationBlocker
    )
    case applied(LinnetSettingsContract.ProductIdentity)
    case unsupported(
      installed: LinnetSettingsContract.ProductIdentity,
      running: LinnetSettingsContract.ProductIdentity
    )
    case failed(
      installed: LinnetSettingsContract.ProductIdentity,
      running: LinnetSettingsContract.ProductIdentity
    )
    case unavailable(installed: LinnetSettingsContract.ProductIdentity?)

    static func resolved(
      installed: LinnetSettingsContract.ProductIdentity?,
      health: LinnetSettingsContract.RuntimeHealth?
    ) -> Self {
      guard let installed else { return .unavailable(installed: nil) }
      guard let health else { return .unavailable(installed: installed) }
      guard let running = health.productIdentity else {
        return .unavailable(installed: installed)
      }
      return installed == running
        ? .current(running)
        : .pending(installed: installed, running: running)
    }

    var activationIdentities: (
      installed: LinnetSettingsContract.ProductIdentity,
      running: LinnetSettingsContract.ProductIdentity
    )? {
      switch self {
      case .pending(let installed, let running),
        .blocked(let installed, let running, _),
        .failed(let installed, let running):
        (installed, running)
      default:
        nil
      }
    }
  }

  enum CoreDownloadState: Equatable {
    case idle
    case downloading(core: LinnetDataChannel.Core, progress: Double)
    case ready(core: LinnetDataChannel.Core, file: URL)
    case failed(core: LinnetDataChannel.Core)
  }

  @Published private(set) var availability: LinnetDataChannel.UpdateAvailability?
  @Published private(set) var active = false
  @Published private(set) var failed = false
  @Published private(set) var installedIdentity: LinnetSettingsContract.ProductIdentity?
  @Published private(set) var runtimeVersionState: RuntimeVersionState =
    .checking(installed: nil)
  @Published private(set) var updateChannel: UpdateChannel
  @Published private(set) var coreDownloadState: CoreDownloadState = .idle

  var activationInProgress: Bool {
    if case .applying = runtimeVersionState { return true }
    return false
  }

  var coreDownloadInProgress: Bool {
    if case .downloading = coreDownloadState { return true }
    return false
  }

  private let identityBundle: Bundle
  private let hostBundleURL: URL?
  private let hostBundleIdentifier: String?
  private let transactionRequester: LinnetSettingsTransactionRequesting
  private let updateDefaults: UserDefaults
  private let coreDownloader: any LinnetCorePackageDownloading
  private let revealCorePackage: (URL) -> Void
  private var edition: LinnetDataRegistry.Edition?
  private var installedPacks: [LinnetDataRegistry.ActivePack]
  private var task: Task<Void, Never>?
  private var runtimeTask: Task<Void, Never>?
  private var coreDownloadTask: Task<Void, Never>?
  private var cycle: UInt64 = 0
  private var runtimeCycle: UInt64 = 0
  private var coreDownloadCycle: UInt64 = 0

  init(
    edition: LinnetDataRegistry.Edition?,
    installedPacks: [LinnetDataRegistry.ActivePack],
    bundle: Bundle = .main,
    transactionRequester: LinnetSettingsTransactionRequesting? = nil,
    updateDefaults: UserDefaults = .standard,
    coreDownloader: any LinnetCorePackageDownloading = LinnetCorePackageDownloader(),
    revealCorePackage: @escaping (URL) -> Void = {
      NSWorkspace.shared.activateFileViewerSelecting([$0])
    }
  ) {
    identityBundle = bundle
    installedIdentity = nil
    self.edition = edition
    self.installedPacks = installedPacks
    let host = LinnetSettingsContract.hostBundle(startingAt: bundle)
    hostBundleURL = host?.bundleURL
    hostBundleIdentifier = host?.bundleIdentifier
    self.updateDefaults = updateDefaults
    self.coreDownloader = coreDownloader
    self.revealCorePackage = revealCorePackage
    updateChannel = UpdateChannel.load(from: updateDefaults)
    self.transactionRequester = transactionRequester
      ?? LinnetSettingsTransactionIPC.Client(startingAt: bundle)
    refreshInstalledIdentity()
    runtimeVersionState = .checking(installed: installedIdentity)
  }

  func check() {
    startCheck(replacingCurrent: false)
    refreshRuntime()
  }

  func setUpdateChannel(_ channel: UpdateChannel) {
    guard channel != updateChannel else { return }
    task?.cancel()
    cycle &+= 1
    active = false
    failed = false
    availability = nil
    resetCoreDownload()
    updateChannel = channel
    channel.save(to: updateDefaults)
    startCheck(replacingCurrent: true)
  }

  func refreshRuntime() {
    guard !activationInProgress else { return }
    refreshInstalledIdentity()
    runtimeTask?.cancel()
    runtimeCycle &+= 1
    let activeCycle = runtimeCycle
    runtimeVersionState = .checking(installed: installedIdentity)
    runtimeTask = Task { [weak self] in
      guard let self else { return }
      do {
        let reply = try await request(.diagnose, timeout: 3)
        guard !Task.isCancelled else { return }
        finishRuntime(reply.health, cycle: activeCycle)
      } catch is CancellationError {
        return
      } catch {
        finishRuntimeUnavailable(cycle: activeCycle)
      }
    }
  }
}

extension LinnetSettingsUpdateChecker {
  func activateInstalledCore() {
    refreshInstalledIdentity()
    guard let identities = runtimeVersionState.activationIdentities,
      installedIdentity == identities.installed,
      hostBundleURL != nil,
      hostBundleIdentifier != nil
    else { return }
    runtimeTask?.cancel()
    runtimeCycle &+= 1
    let activeCycle = runtimeCycle
    runtimeVersionState = .applying(
      installed: identities.installed,
      running: identities.running
    )
    runtimeTask = Task { [weak self] in
      guard let self else { return }
      var hostAcceptedActivation = false
      do {
        let reply = try await request(.activateCore, timeout: 4)
        guard !Task.isCancelled else { return }
        if let issue = coreActivationIssue(for: reply.code) {
          finishRuntimeTransition(
            .blocked(
              installed: identities.installed,
              running: identities.running,
              issue: issue
            ),
            cycle: activeCycle
          )
          return
        }
        guard reply.status == .terminating,
          reply.code == .coreActivationAccepted
        else {
          finishRuntimeTransition(
            .unsupported(installed: identities.installed, running: identities.running),
            cycle: activeCycle
          )
          return
        }
        hostAcceptedActivation = true
        try await awaitHostExit()
        try await launchCanonicalHost()
        let health = try await awaitInstalledHost(identity: identities.installed)
        finishRuntimeApplied(health, cycle: activeCycle)
      } catch is CancellationError {
        return
      } catch {
        if hostAcceptedActivation {
          finishRuntimeTransition(
            .failed(installed: identities.installed, running: identities.running),
            cycle: activeCycle
          )
        } else {
          finishRuntimeTransition(
            .unsupported(installed: identities.installed, running: identities.running),
            cycle: activeCycle
          )
        }
      }
    }
  }

  private func startCheck(replacingCurrent: Bool) {
    guard !activationInProgress, replacingCurrent || !active else { return }
    refreshInstalledIdentity()
    task?.cancel()
    cycle &+= 1
    let activeCycle = cycle
    active = true
    failed = false
    availability = nil
    guard let installedIdentity else {
      active = false
      task = nil
      return
    }
    let currentVersion = installedIdentity.version
    let currentBuild = installedIdentity.build
    let currentRevision = installedIdentity.revision
    let edition = edition
    let installedPacks = installedPacks
    let catalogURL = updateChannel.catalogURL
    task = Task.detached { [weak self] in
      do {
        let transport = LinnetSettingsDownloadTransport(source: .direct)
        let data = try await transport.downloadCatalog(at: catalogURL)
        try Task.checkCancellation()
        let catalog = try LinnetDataChannel.verifyPublished(data).catalog
        let result = try catalog.updateAvailability(
          currentVersion: currentVersion, currentBuild: currentBuild,
          currentRevision: currentRevision,
          edition: edition, installedPacks: installedPacks)
        await self?.finish(result, cycle: activeCycle)
      } catch is CancellationError {
        await self?.finishCancellation(cycle: activeCycle)
      } catch {
        linnetUpdateLogger.error(
          "Update check failed: \(error.localizedDescription, privacy: .private)"
        )
        await self?.finishFailure(cycle: activeCycle)
      }
    }
  }

  @discardableResult
  private func refreshInstalledIdentity()
    -> LinnetSettingsContract.ProductIdentity? {
    let identity = LinnetSettingsContract.productIdentity(startingAt: identityBundle)
    installedIdentity = identity
    return identity
  }

  func refreshInstalledData(
    edition: LinnetDataRegistry.Edition?,
    packs: [LinnetDataRegistry.ActivePack]
  ) {
    self.edition = edition
    installedPacks = packs
    startCheck(replacingCurrent: true)
  }

  func downloadCoreUpdate(_ core: LinnetDataChannel.Core) {
    if case .ready(let readyCore, let file) = coreDownloadState,
      readyCore == core {
      revealCorePackage(file)
      return
    }
    if case .downloading(let downloadingCore, _) = coreDownloadState,
      downloadingCore == core {
      return
    }
    coreDownloadTask?.cancel()
    coreDownloadCycle &+= 1
    let activeCycle = coreDownloadCycle
    coreDownloadState = .downloading(core: core, progress: 0)
    coreDownloadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let file = try await coreDownloader.download(core) { [weak self] progress in
          Task { @MainActor [weak self] in
            self?.recordCoreDownloadProgress(
              progress, core: core, cycle: activeCycle)
          }
        }
        guard !Task.isCancelled, activeCycle == coreDownloadCycle else { return }
        coreDownloadState = .ready(core: core, file: file)
        coreDownloadTask = nil
        revealCorePackage(file)
      } catch is CancellationError {
        guard activeCycle == coreDownloadCycle else { return }
        coreDownloadState = .idle
        coreDownloadTask = nil
      } catch {
        guard activeCycle == coreDownloadCycle else { return }
        coreDownloadState = .failed(core: core)
        coreDownloadTask = nil
      }
    }
  }

  func cancelCoreDownload() {
    resetCoreDownload()
  }

  func showDownloadedCoreUpdate() {
    guard case .ready(_, let file) = coreDownloadState else { return }
    revealCorePackage(file)
  }

  private func recordCoreDownloadProgress(
    _ progress: Double,
    core: LinnetDataChannel.Core,
    cycle activeCycle: UInt64
  ) {
    guard activeCycle == coreDownloadCycle,
      case .downloading(let downloadingCore, _) = coreDownloadState,
      downloadingCore == core
    else { return }
    coreDownloadState = .downloading(
      core: core,
      progress: min(1, max(0, progress))
    )
  }

  private func resetCoreDownload() {
    coreDownloadTask?.cancel()
    coreDownloadTask = nil
    coreDownloadCycle &+= 1
    coreDownloadState = .idle
  }

  private func request(
    _ command: LinnetSettingsContract.DataCommand,
    timeout: TimeInterval
  ) async throws -> LinnetSettingsContract.RuntimeReply {
    try await transactionRequester.request(
      .init(
        transactionID: UUID(),
        command: command,
        candidate: nil,
        requesterPID: getpid(),
        deadline: Date().addingTimeInterval(timeout)
      ),
      timeout: timeout,
      onProgress: { _ in }
    )
  }

  private func awaitHostExit() async throws {
    guard let hostBundleIdentifier else { throw ActivationFailure.missingInstalledHost }
    for _ in 0..<50 {
      try Task.checkCancellation()
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: hostBundleIdentifier)
      if running.isEmpty { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw ActivationFailure.hostDidNotExit
  }

  private func launchCanonicalHost() async throws {
    guard let hostBundleURL else { throw ActivationFailure.missingInstalledHost }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.allowsRunningApplicationSubstitution = false
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(
        at: hostBundleURL,
        configuration: configuration
      ) { application, error in
        if let error {
          continuation.resume(throwing: error)
        } else if application == nil {
          continuation.resume(throwing: ActivationFailure.hostDidNotLaunch)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private func awaitInstalledHost(
    identity: LinnetSettingsContract.ProductIdentity
  ) async throws -> LinnetSettingsContract.RuntimeHealth {
    for _ in 0..<80 {
      try Task.checkCancellation()
      if let reply = try? await request(.diagnose, timeout: 1),
        let health = reply.health,
        health.productIdentity == identity,
        health.state == .running, health.phase == .running {
        return health
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw ActivationFailure.hostDidNotLaunch
  }

  private func finish(
    _ result: LinnetDataChannel.UpdateAvailability,
    cycle activeCycle: UInt64
  ) {
    guard activeCycle == cycle else { return }
    if case .core(let core) = result {
      switch coreDownloadState {
      case .downloading(let downloadingCore, _), .ready(let downloadingCore, _),
        .failed(let downloadingCore):
        if downloadingCore != core { resetCoreDownload() }
      case .idle:
        break
      }
    } else {
      resetCoreDownload()
    }
    availability = result
    active = false
    failed = false
    task = nil
  }

  private func finishCancellation(cycle activeCycle: UInt64) {
    guard activeCycle == cycle else { return }
    active = false
    task = nil
  }

  private func finishFailure(cycle activeCycle: UInt64) {
    guard activeCycle == cycle else { return }
    availability = nil
    active = false
    failed = true
    task = nil
  }

  private func finishRuntime(
    _ health: LinnetSettingsContract.RuntimeHealth?,
    cycle activeCycle: UInt64
  ) {
    guard activeCycle == runtimeCycle else { return }
    runtimeTask = nil
    runtimeVersionState = .resolved(installed: installedIdentity, health: health)
  }

  private func finishRuntimeUnavailable(cycle activeCycle: UInt64) {
    guard activeCycle == runtimeCycle else { return }
    runtimeVersionState = .unavailable(installed: installedIdentity)
    runtimeTask = nil
  }

  private func coreActivationIssue(
    for code: LinnetSettingsContract.RuntimeReplyCode
  ) -> LinnetSettingsContract.CoreActivationBlocker? {
    // The legacy blockers below are consumed before Host acceptance,
    // so they cannot enter process observation, Host exit, launch, or success.
    // SettingsContract owns their removal condition; published 0.1.10 still
    // emits the legacy unknown-client code for unavailable TIS state.
    switch code {
    case .coreActivationInputSourceActive: .inputSourceActive
    case .coreActivationInputSourceUnavailable: .inputSourceUnavailable
    case .coreActivationCompositionActive: .compositionActive
    case .coreActivationDataTransactionActive: .dataTransactionActive
    case .coreActivationApplicationsRunning: .applicationsStillRunning
    case .coreActivationUnknownClient: .unknownClient
    case .coreActivationRequesterUnavailable: .requesterUnavailable
    default: nil
    }
  }

  @discardableResult
  private func finishRuntimeTransition(
    _ state: RuntimeVersionState,
    cycle activeCycle: UInt64
  ) -> Bool {
    guard activeCycle == runtimeCycle else { return false }
    runtimeVersionState = state
    runtimeTask = nil
    return true
  }

  private func finishRuntimeApplied(
    _ health: LinnetSettingsContract.RuntimeHealth,
    cycle activeCycle: UInt64
  ) {
    guard let identity = health.productIdentity,
      finishRuntimeTransition(.applied(identity), cycle: activeCycle)
    else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      NSApp.terminate(nil)
    }
  }

  private enum ActivationFailure: Error {
    case missingInstalledHost
    case hostDidNotExit
    case hostDidNotLaunch
  }
}
