import AppKit
import Foundation

/// Settings owns update visibility and the user-requested Core activation
/// orchestration. The running Host remains the sole exit-safety authority.
@MainActor
final class LinnetSettingsUpdateChecker: ObservableObject {
  enum RuntimeVersionState: Equatable {
    /// One public compatibility bridge: an identity-free 0.1.9 Host can only
    /// defer to the installed 0.1.10 Core. Remove this constant, the
    /// `restartRequired` resolution branch, and its tests when 0.1.11 becomes
    /// the public update target.
    private static let identityFreeBridgeTargetVersion = "0.1.10"

    case checking(installed: LinnetSettingsContract.ProductIdentity?)
    case current(LinnetSettingsContract.ProductIdentity)
    case restartRequired(LinnetSettingsContract.ProductIdentity)
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
        return installed.version == identityFreeBridgeTargetVersion
          ? .restartRequired(installed)
          : .unavailable(installed: installed)
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

  @Published private(set) var availability: LinnetDataChannel.UpdateAvailability?
  @Published private(set) var active = false
  @Published private(set) var failed = false
  @Published private(set) var installedIdentity: LinnetSettingsContract.ProductIdentity?
  @Published private(set) var runtimeVersionState: RuntimeVersionState =
    .checking(installed: nil)

  var activationInProgress: Bool {
    if case .applying = runtimeVersionState { return true }
    return false
  }

  private let identityBundle: Bundle
  private let hostBundleURL: URL?
  private let hostBundleIdentifier: String?
  private let transactionRequester: LinnetSettingsTransactionRequesting
  private var edition: LinnetDataRegistry.Edition?
  private var installedPacks: [LinnetDataRegistry.ActivePack]
  private var task: Task<Void, Never>?
  private var runtimeTask: Task<Void, Never>?
  private var cycle: UInt64 = 0
  private var runtimeCycle: UInt64 = 0

  init(
    edition: LinnetDataRegistry.Edition?,
    installedPacks: [LinnetDataRegistry.ActivePack],
    bundle: Bundle = .main,
    transactionRequester: LinnetSettingsTransactionRequesting? = nil
  ) {
    identityBundle = bundle
    installedIdentity = nil
    self.edition = edition
    self.installedPacks = installedPacks
    let host = LinnetSettingsContract.hostBundle(startingAt: bundle)
    hostBundleURL = host?.bundleURL
    hostBundleIdentifier = host?.bundleIdentifier
    self.transactionRequester = transactionRequester
      ?? LinnetSettingsTransactionIPC.Client(startingAt: bundle)
    refreshInstalledIdentity()
    runtimeVersionState = .checking(installed: installedIdentity)
  }

  func check() {
    startCheck(replacingCurrent: false)
    refreshRuntime()
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
    let edition = edition
    let installedPacks = installedPacks
    task = Task.detached { [weak self] in
      do {
        let transport = LinnetSettingsDownloadTransport(source: .direct)
        let data = try await transport.downloadCatalog(
          at: LinnetSettingsDownloadSource.canonicalCatalogURL)
        try Task.checkCancellation()
        let catalog = try LinnetDataChannel.verifyPublished(data).catalog
        let result = try catalog.updateAvailability(
          currentVersion: currentVersion, currentBuild: currentBuild,
          edition: edition, installedPacks: installedPacks)
        await self?.finish(result, cycle: activeCycle)
      } catch is CancellationError {
        await self?.finishCancellation(cycle: activeCycle)
      } catch {
        print("Update check failed: \(error.localizedDescription)")
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

  func openCoreUpdate() {
    guard case .core(let core) = availability else { return }
    NSWorkspace.shared.open(core.releaseURL)
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
