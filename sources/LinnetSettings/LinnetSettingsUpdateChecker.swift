import AppKit
import Foundation

/// Settings-only owner for update visibility and post-install Core activation.
/// Package installation remains external; this owner only compares the
/// installed and running identities, then asks an idle Host to exit itself.
@MainActor
final class LinnetSettingsUpdateChecker: ObservableObject {
  enum RuntimeActivationState: Equatable {
    case checking
    case current(LinnetSettingsContract.ProductIdentity)
    case pending(
      running: LinnetSettingsContract.ProductIdentity,
      readiness: LinnetSettingsContract.CoreActivationReadiness,
      connectedClients: Int
    )
    case applying
    case applied(LinnetSettingsContract.ProductIdentity)
    case unavailable
    case failed
  }

  @Published private(set) var availability: LinnetDataChannel.UpdateAvailability?
  @Published private(set) var active = false
  @Published private(set) var failed = false
  @Published private(set) var runtimeActivationState: RuntimeActivationState = .checking

  private let currentVersion: String
  private let currentBuild: UInt64
  private let installedIdentity: LinnetSettingsContract.ProductIdentity?
  private let hostBundleURL: URL?
  private let hostBundleIdentifier: String?
  private let transactionRequester: LinnetSettingsTransactionRequesting
  private let service: LinnetDataChannel.Service
  private var edition: LinnetDataRegistry.Edition?
  private var installedPacks: [LinnetDataRegistry.ActivePack]
  private var task: Task<Void, Never>?
  private var runtimeTask: Task<Void, Never>?
  private var cycle: UInt64 = 0
  private var runtimeCycle: UInt64 = 0

  init(
    currentVersion: String,
    currentBuild: UInt64,
    service: LinnetDataChannel.Service,
    edition: LinnetDataRegistry.Edition?,
    installedPacks: [LinnetDataRegistry.ActivePack],
    bundle: Bundle = .main,
    transactionRequester: LinnetSettingsTransactionRequesting? = nil
  ) {
    self.currentVersion = currentVersion
    self.currentBuild = currentBuild
    self.service = service
    self.edition = edition
    self.installedPacks = installedPacks
    let host = LinnetSettingsContract.hostBundle(startingAt: bundle)
    installedIdentity = LinnetSettingsContract.productIdentity(startingAt: bundle)
    hostBundleURL = host?.bundleURL
    hostBundleIdentifier = host?.bundleIdentifier
    self.transactionRequester = transactionRequester
      ?? LinnetSettingsTransactionIPC.Client(startingAt: bundle)
    check()
  }

  func check() {
    startCheck(replacingCurrent: false)
    refreshRuntime()
  }

  func refreshRuntime() {
    runtimeTask?.cancel()
    runtimeCycle &+= 1
    let activeCycle = runtimeCycle
    runtimeActivationState = .checking
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

  func activateInstalledCore() {
    guard case .pending(_, let readiness, _) = runtimeActivationState,
      readiness == .ready,
      installedIdentity != nil,
      hostBundleURL != nil,
      hostBundleIdentifier != nil
    else { return }
    runtimeTask?.cancel()
    runtimeCycle &+= 1
    let activeCycle = runtimeCycle
    runtimeActivationState = .applying
    runtimeTask = Task { [weak self] in
      guard let self else { return }
      do {
        let reply = try await request(.activateCore, timeout: 4)
        guard reply.status == .terminating, reply.code == .coreActivationAccepted else {
          throw ActivationFailure.hostRejected
        }
        try await awaitHostExit()
        try await launchCanonicalHost()
        let health = try await awaitInstalledHost()
        finishRuntimeApplied(health, cycle: activeCycle)
      } catch is CancellationError {
        return
      } catch {
        finishRuntimeFailure(cycle: activeCycle)
      }
    }
  }

  private func startCheck(replacingCurrent: Bool) {
    guard service == .published, replacingCurrent || !active else { return }
    task?.cancel()
    cycle &+= 1
    let activeCycle = cycle
    active = true
    failed = false
    availability = nil
    let currentVersion = currentVersion
    let currentBuild = currentBuild
    let edition = edition
    let installedPacks = installedPacks
    task = Task.detached { [weak self] in
      do {
        let transport = LinnetSettingsDownloadTransport(source: .direct)
        let data = try await transport.downloadCatalog(
          at: LinnetSettingsDownloadSource.canonicalCatalogURL)
        try Task.checkCancellation()
        let catalog = try LinnetDataChannel.verifyPublished(data).catalog
        let result = catalog.updateAvailability(
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
    for _ in 0..<30 {
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

  private func awaitInstalledHost() async throws -> LinnetSettingsContract.RuntimeHealth {
    guard let installedIdentity else { throw ActivationFailure.missingInstalledHost }
    for _ in 0..<30 {
      try Task.checkCancellation()
      if let reply = try? await request(.diagnose, timeout: 1),
        let health = reply.health,
        health.productIdentity == installedIdentity {
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
    guard let installedIdentity, let health, let running = health.productIdentity else {
      runtimeActivationState = .unavailable
      return
    }
    if installedIdentity == running {
      runtimeActivationState = .current(running)
    } else {
      runtimeActivationState = .pending(
        running: running,
        readiness: health.coreActivationReadiness,
        connectedClients: health.connectedInputClientCount
      )
    }
  }

  private func finishRuntimeUnavailable(cycle activeCycle: UInt64) {
    guard activeCycle == runtimeCycle else { return }
    runtimeActivationState = .unavailable
    runtimeTask = nil
  }

  private func finishRuntimeApplied(
    _ health: LinnetSettingsContract.RuntimeHealth,
    cycle activeCycle: UInt64
  ) {
    guard activeCycle == runtimeCycle, let identity = health.productIdentity else { return }
    runtimeActivationState = .applied(identity)
    runtimeTask = nil
  }

  private func finishRuntimeFailure(cycle activeCycle: UInt64) {
    guard activeCycle == runtimeCycle else { return }
    runtimeActivationState = .failed
    runtimeTask = nil
  }

  private enum ActivationFailure: Error {
    case hostRejected
    case missingInstalledHost
    case hostDidNotExit
    case hostDidNotLaunch
  }
}
