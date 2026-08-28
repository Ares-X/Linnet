import AppKit
import Foundation

/// Settings-only owner for update visibility. Package installation replaces
/// files on disk; the running InputMethodKit Host and its client connections
/// remain untouched until macOS next starts Linnet normally.
@MainActor
final class LinnetSettingsUpdateChecker: ObservableObject {
  enum RuntimeVersionState: Equatable {
    case checking
    case current(LinnetSettingsContract.ProductIdentity)
    case pending(
      installed: LinnetSettingsContract.ProductIdentity,
      running: LinnetSettingsContract.ProductIdentity
    )
    case unavailable
  }

  @Published private(set) var availability: LinnetDataChannel.UpdateAvailability?
  @Published private(set) var active = false
  @Published private(set) var failed = false
  @Published private(set) var runtimeVersionState: RuntimeVersionState = .checking

  private let currentVersion: String
  private let currentBuild: UInt64
  private let installedIdentity: LinnetSettingsContract.ProductIdentity?
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
    installedIdentity = LinnetSettingsContract.productIdentity(startingAt: bundle)
    self.transactionRequester = transactionRequester
      ?? LinnetSettingsTransactionIPC.Client(startingAt: bundle)
  }

  func check() {
    startCheck(replacingCurrent: false)
    refreshRuntime()
  }

  func refreshRuntime() {
    runtimeTask?.cancel()
    runtimeCycle &+= 1
    let activeCycle = runtimeCycle
    runtimeVersionState = .checking
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
      runtimeVersionState = .unavailable
      return
    }
    if installedIdentity == running {
      runtimeVersionState = .current(running)
    } else {
      runtimeVersionState = .pending(installed: installedIdentity, running: running)
    }
  }

  private func finishRuntimeUnavailable(cycle activeCycle: UInt64) {
    guard activeCycle == runtimeCycle else { return }
    runtimeVersionState = .unavailable
    runtimeTask = nil
  }
}
