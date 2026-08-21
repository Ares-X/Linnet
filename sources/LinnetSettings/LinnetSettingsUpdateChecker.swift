import AppKit
import Foundation

/// Settings-only owner for the quiet, bounded update check. It consumes the
/// same verified Catalog used by language-data mutation and never installs a
/// Core package or touches the input-method runtime.
@MainActor
final class LinnetSettingsUpdateChecker: ObservableObject {
  @Published private(set) var availability: LinnetDataChannel.UpdateAvailability?
  @Published private(set) var active = false
  @Published private(set) var failed = false

  private let currentVersion: String
  private let currentBuild: UInt64
  private let service: LinnetDataChannel.Service
  private var edition: LinnetDataRegistry.Edition?
  private var installedPacks: [LinnetDataRegistry.ActivePack]
  private var task: Task<Void, Never>?
  private var cycle: UInt64 = 0

  init(
    currentVersion: String,
    currentBuild: UInt64,
    service: LinnetDataChannel.Service,
    edition: LinnetDataRegistry.Edition?,
    installedPacks: [LinnetDataRegistry.ActivePack]
  ) {
    self.currentVersion = currentVersion
    self.currentBuild = currentBuild
    self.service = service
    self.edition = edition
    self.installedPacks = installedPacks
    check()
  }

  func check() {
    startCheck(replacingCurrent: false)
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
}
