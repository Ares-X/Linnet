import Foundation
import os
import SwiftUI

private let linnetLanguageDataLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "Linnet.Settings",
  category: "LanguageData"
)

@MainActor
extension SettingsModel {
  enum GrammarModelStatus: Equatable {
    case checking
    case ltsActive
    case missing

    var label: LocalizedStringKey {
      switch self {
      case .checking: return "Detecting grammar model…"
      case .ltsActive: return "Wanxiang LTS grammar data (about 420 MB) — Active"
      case .missing: return "Model data missing"
      }
    }
  }

  var packDownloadCancellable: Bool {
    languageDataUpdateTarget != nil && packDownloadTask != nil
  }

  var languageDataUpdatesAvailable: Bool {
    dataServicesAvailable && configuredDownloadSource != nil
  }

  var downloadSourceConfigured: Bool { configuredDownloadSource != nil }
  var downloadSourceEditorDisabled: Bool { operationActive }
  var downloadMirrorIsValid: Bool {
    (try? LinnetSettingsDownloadSource.customMirror(prefix: downloadMirrorPrefix)) != nil
  }

  var downloadSourceNeedsSave: Bool {
    downloadSourceMode == .customMirror && downloadMirrorIsValid
      && configuredDownloadSource == nil
  }

  var canUseDownloadMirror: Bool {
    !downloadSourceEditorDisabled && downloadSourceNeedsSave
  }

  func detectGrammarModel() {
    grammarModelStatus = installedPacks.contains(where: { $0.kind == .lts })
      ? .ltsActive : .missing
  }

  func updateLanguageData() {
    downloadLanguageData(.currentEdition)
  }

  func installCompleteOfflineData() {
    downloadLanguageData(.completeOffline)
  }

  func selectDownloadSourceMode(_ mode: LinnetSettingsDownloadSource.Mode) {
    guard !downloadSourceEditorDisabled else { return }
    downloadSourceMode = mode
    switch mode {
    case .github:
      LinnetSettingsDownloadSource.save(.direct)
      activeDownloadSource = .direct
      downloadSourceFailure = nil
    case .publicMirror:
      LinnetSettingsDownloadSource.save(.publicMirror)
      activeDownloadSource = .publicMirror
      downloadSourceFailure = nil
    case .customMirror:
      refreshDownloadMirrorValidation()
    }
  }

  func updateDownloadMirrorPrefix(_ value: String) {
    guard !downloadSourceEditorDisabled else { return }
    downloadMirrorPrefix = value
    if downloadSourceMode == .customMirror { refreshDownloadMirrorValidation() }
  }

  func useDownloadMirror() {
    guard !downloadSourceEditorDisabled else { return }
    do {
      let source = try LinnetSettingsDownloadSource.customMirror(prefix: downloadMirrorPrefix)
      LinnetSettingsDownloadSource.save(source)
      downloadSourceMode = .customMirror
      downloadMirrorPrefix = source.mirrorPrefixString ?? downloadMirrorPrefix
      activeDownloadSource = source
      downloadSourceFailure = nil
    } catch let failure as LinnetSettingsDownloadSource.Failure {
      downloadSourceFailure = failure
    } catch {
      downloadSourceFailure = .invalidMirrorPrefix
    }
  }

  var configuredDownloadSource: LinnetSettingsDownloadSource? {
    guard let activeDownloadSource, activeDownloadSource.mode == downloadSourceMode else {
      return nil
    }
    switch downloadSourceMode {
    case .github:
      return activeDownloadSource
    case .publicMirror:
      return activeDownloadSource == .publicMirror ? activeDownloadSource : nil
    case .customMirror:
      guard let draft = try? LinnetSettingsDownloadSource.customMirror(
        prefix: downloadMirrorPrefix),
        draft == activeDownloadSource
      else { return nil }
      return activeDownloadSource
    }
  }

  private func refreshDownloadMirrorValidation() {
    do {
      _ = try LinnetSettingsDownloadSource.customMirror(prefix: downloadMirrorPrefix)
      downloadSourceFailure = nil
    } catch let failure as LinnetSettingsDownloadSource.Failure {
      downloadSourceFailure = failure
    } catch {
      downloadSourceFailure = .invalidMirrorPrefix
    }
  }

  func downloadLanguageData(_ target: SettingsLanguageDataUpdateTarget, allowCompleteRepair: Bool = false) {
    guard languageDataUpdatesAvailable, !packDownloadActive, !operationActive else {
      if !languageDataUpdatesAvailable { finishLanguageDataUpdate(target, failure: .unavailable) }
      return
    }
    guard let registry = dataRegistry, let downloadSource = configuredDownloadSource else {
      finishLanguageDataUpdate(target, failure: .unavailable)
      return
    }
    languageDataUpdateTarget = target
    languageDataRepairTarget = nil
    packDownloadProgress = 0
    setLanguageDataUpdateState(target, .downloading)
    let coordinator = coordinator
    let catalogURL = updateChecker.updateChannel.catalogURL
    packDownloadTask = Task.detached { [weak self, registry, downloadSource, coordinator, catalogURL] in
      do {
        try registry.prepareMutableDirectories()
        let lease = try await LinnetSettingsMutationLease.acquire(
          at: registry.settingsMutationLeaseURL, timeout: 300)
        defer { _ = lease }
        try Task.checkCancellation()
        let transport = LinnetSettingsDownloadTransport(source: downloadSource)
        let catalogData = try await transport.downloadCatalog(at: catalogURL)
        try Task.checkCancellation()
        await self?.setLanguageDataUpdateState(target, .verifying)
        let catalog = try registry.verifyDataChannel(catalogData)
        let snapshot = try registry.runtimeSnapshot()
        let requestedEdition: LinnetDataRegistry.Edition = target == .completeOffline
          ? .full : snapshot.state.edition
        guard let selected = catalog.catalog.activationSet(for: requestedEdition) else {
          throw LinnetDataRegistry.Failure.invalidActiveState
        }
        let update = try registry.beginDataChannelUpdate(
          accepting: catalog, edition: requestedEdition, allowCompleteRepair: allowCompleteRepair)
        let downloadDirectory = update.downloadDirectory
        defer { try? registry.cancelDataChannelUpdate(transactionID: update.transactionID) }
        var targetPacks: [LinnetDataRegistry.ActivePack] = []
        for artifact in selected.packs {
          try Task.checkCancellation()
          let installed = snapshot.state.packs.first { $0.kind == artifact.kind }
          let transfer = artifact.transfer(from: installed, allowCompleteRepair: allowCompleteRepair)
          let url: URL, bytes: UInt64
          switch transfer {
          case .current(let pack):
            targetPacks.append(pack)
            continue
          case .delta(let delta, _): (url, bytes) = (delta.url, delta.bytes)
          case .complete: (url, bytes) = (artifact.url, artifact.bytes)
          case .requiresCompleteRepair: throw LinnetDataChannel.Failure.completeRepairRequired
          }
          let package = downloadDirectory.appending(
            path: url.lastPathComponent)
          do {
            await self?.setLanguageDataUpdateState(target, .downloading)
            try await transport.downloadArtifact(from: url, expectedBytes: bytes, to: package)
            try Task.checkCancellation()
            await self?.setLanguageDataUpdateState(target, .verifying)
            let staged = try registry.verifyAndStagePack(
              package: package, artifact: artifact, transfer: transfer,
              allowCompleteRepair: allowCompleteRepair)
            targetPacks.append(staged)
          } catch {
            try Task.checkCancellation()
            switch transfer {
            case .delta:
              linnetLanguageDataLogger.error(
                "Language-data delta failed: \(error.localizedDescription, privacy: .private)"
              )
              throw LinnetDataChannel.Failure.completeRepairRequired
            default: throw error
            }
          }
          await self?.setPackDownloadProgress(
            Double(targetPacks.count) / Double(selected.packs.count))
          try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let activation = try registry.prepareDataChannelUpdate(update, target: targetPacks)
        await self?.beginLanguageDataActivation(target)
        try Task.checkCancellation()
        try await coordinator.activateLanguage(activation)
        await self?.finishLanguageDataUpdate(target)
      } catch LinnetDataChannel.Failure.completeRepairRequired {
        await self?.finishLanguageDataRepairRequest(target)
      } catch is CancellationError {
        await self?.finishPackDownloadCancellation(target)
      } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
        await self?.finishPackDownloadCancellation(target)
      } catch {
        linnetLanguageDataLogger.error(
          "Language-data catalog update failed: \(error.localizedDescription, privacy: .private)"
        )
        await self?.finishLanguageDataUpdate(
          target, failure: Self.packUpdateFailure(for: error))
      }
    }
  }

  private func finishLanguageDataRepairRequest(_ target: SettingsLanguageDataUpdateTarget) {
    finishLanguageDataUpdate(target, failure: .verificationFailed)
    languageDataRepairTarget = target
  }

  private func setPackDownloadProgress(_ progress: Double) {
    packDownloadProgress = progress
  }

  private func setLanguageDataUpdateState(
    _ target: SettingsLanguageDataUpdateTarget,
    _ state: SettingsPresentationPackState
  ) {
    guard languageDataUpdateTarget == target else { return }
    status = .pack(target.presentationPack, state)
  }

  private func beginLanguageDataActivation(_ target: SettingsLanguageDataUpdateTarget) {
    guard languageDataUpdateTarget == target else { return }
    packDownloadTask = nil
    status = .pack(target.presentationPack, .activating)
  }

  nonisolated private static func packUpdateFailure(
    for error: Error
  ) -> SettingsPresentationPackState {
    if error is SettingsDataCoordinator.Failure { return .activationFailed }
    if let leaseFailure = error as? LinnetSettingsMutationLease.Failure {
      return leaseFailure == .timedOut ? .busy : .storageFailed
    }
    if let transportFailure = error as? LinnetSettingsDownloadTransport.Failure {
      return packUpdateFailure(for: transportFailure)
    }
    if let urlError = error as? URLError {
      return packUpdateFailure(for: urlError)
    }
    let failure = error as NSError
    if isPackUpdateStorageFailure(failure) { return .storageFailed }
    return .verificationFailed
  }

  nonisolated private static func packUpdateFailure(
    for failure: LinnetSettingsDownloadTransport.Failure
  ) -> SettingsPresentationPackState {
    switch failure {
    case .unsafeDestination, .destinationExists, .storage: return .storageFailed
    case .invalidURL, .invalidResponse, .httpStatus: return .updateServiceUnavailable
    case .unsupportedContentEncoding, .invalidContentLength, .responseTooLarge,
      .lengthMismatch: return .verificationFailed
    case .invalidConfiguration: return .downloadFailed
    }
  }

  nonisolated private static func packUpdateFailure(
    for error: URLError
  ) -> SettingsPresentationPackState {
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff,
      .dataNotAllowed: return .offline
    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
      .badServerResponse, .resourceUnavailable, .fileDoesNotExist:
      return .updateServiceUnavailable
    default: return .downloadFailed
    }
  }

  nonisolated private static func isPackUpdateStorageFailure(_ failure: NSError) -> Bool {
    guard failure.domain == NSCocoaErrorDomain else { return false }
    let storageCodes = Set([
      CocoaError.Code.fileWriteOutOfSpace.rawValue,
      CocoaError.Code.fileWriteNoPermission.rawValue,
      CocoaError.Code.fileWriteVolumeReadOnly.rawValue
    ])
    return storageCodes.contains(failure.code)
  }

  func finishLanguageDataUpdate(
    _ target: SettingsLanguageDataUpdateTarget,
    failure: SettingsPresentationPackState? = nil
  ) {
    guard languageDataUpdateTarget == target || languageDataUpdateTarget == nil else { return }
    if let failure {
      status = .pack(target.presentationPack, failure)
    } else {
      packDownloadProgress = 1
      if let snapshot = try? dataRegistry?.runtimeSnapshot() {
        installedPacks = snapshot.state.packs
        dataEdition = snapshot.state.edition
      }
      status = .pack(target.presentationPack, .active(version: nil))
    }
    detectGrammarModel()
    languageDataUpdateTarget = nil
    packDownloadTask = nil
    startPendingAppearancePublish()
    if failure == nil {
      updateChecker.refreshInstalledData(edition: dataEdition, packs: installedPacks)
    }
  }

  func cancelLanguagePackDownload() {
    guard packDownloadCancellable, let target = languageDataUpdateTarget else { return }
    status = .pack(target.presentationPack, .cancelling)
    packDownloadTask?.cancel()
  }

  func finishPackDownloadCancellation(_ target: SettingsLanguageDataUpdateTarget) {
    guard languageDataUpdateTarget == target else { return }
    packDownloadProgress = 0
    languageDataUpdateTarget = nil
    packDownloadTask = nil
    detectGrammarModel()
    status = .pack(target.presentationPack, .cancelled)
    startPendingAppearancePublish()
  }
}
