import Darwin
import Foundation

@main
struct LinnetSettingsUpdateCheckerStateTests {
  @MainActor static func main() async {
    for code: URLError.Code in [.notConnectedToInternet, .timedOut, .networkConnectionLost,
                               .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
      require(LinnetSettingsUpdateChecker.CheckFailure(URLError(code)) == .network,
              "connection failure lost its network diagnosis")
    }
    require(LinnetSettingsUpdateChecker.CheckFailure(
      LinnetDataChannel.Failure.conflictingPack(.english)) == .conflictingPack,
      "pack conflict was reported as a network failure")
    require(LinnetSettingsUpdateChecker.CheckFailure(
      LinnetDataChannel.Failure.invalidCatalog("JSON")) == .invalidCatalog,
      "invalid catalog lost its diagnosis")
    require(LinnetSettingsUpdateChecker.CheckFailure(
      LinnetSettingsDownloadTransport.Failure.httpStatus(503)) == .unavailable,
      "server failure was misreported as a local network problem")
    require(LinnetSettingsUpdateChecker.CheckFailure(
      URLError(.serverCertificateUntrusted)) == .unavailable,
      "certificate failure was misreported as an offline device")
    let defaultsSuite = "LinnetSettingsUpdateChannelTests-\(UUID().uuidString)"
    guard let updateDefaults = UserDefaults(suiteName: defaultsSuite) else {
      fail("could not create isolated update-channel defaults")
    }
    defer { updateDefaults.removePersistentDomain(forName: defaultsSuite) }
    require(
      LinnetSettingsUpdateChecker.UpdateChannel.load(from: updateDefaults) == .stable,
      "a fresh installation did not default to the stable update channel"
    )
    LinnetSettingsUpdateChecker.UpdateChannel.preview.save(to: updateDefaults)
    require(
      LinnetSettingsUpdateChecker.UpdateChannel.load(from: updateDefaults) == .preview,
      "the Preview channel selection was not persisted"
    )
    require(
      LinnetSettingsUpdateChecker.UpdateChannel.stable.catalogURL.absoluteString
        == "https://raw.githubusercontent.com/Ares-X/Linnet/data-channel/Linnet-Data-Channel.json"
        && LinnetSettingsUpdateChecker.UpdateChannel.preview.catalogURL.absoluteString
          == "https://raw.githubusercontent.com/Ares-X/Linnet/preview-channel/Linnet-Data-Channel.json",
      "Stable and Preview do not own their exact Catalog endpoints"
    )
    updateDefaults.set("nightly", forKey: LinnetSettingsUpdateChecker.UpdateChannel.defaultsKey)
    require(
      LinnetSettingsUpdateChecker.UpdateChannel.load(from: updateDefaults) == .stable,
      "an unknown update channel did not fail closed to Stable"
    )

    let installed = identity(version: "0.1.10", build: 69, revision: "a")
    let older = identity(version: "0.1.9", build: 68, revision: "b")
    let later = identity(version: "0.1.11", build: 70, revision: "c")

    let unavailableHost = LinnetSettingsUpdateChecker.RuntimeVersionState.resolved(
      installed: installed,
      health: nil
    )
    require(
      unavailableHost == .unavailable(installed: installed),
      "a missing Host health response became activatable"
    )
    require(
      unavailableHost.activationIdentities == nil,
      "an unavailable Host exposed Core activation identities"
    )
    require(
      LinnetSettingsUpdateChecker.RuntimeVersionState.resolved(
        installed: nil,
        health: health(productIdentity: older)
      ) == .unavailable(installed: nil),
      "a missing installed product identity became activatable"
    )

    let unidentified = LinnetSettingsUpdateChecker.RuntimeVersionState.resolved(
      installed: installed,
      health: health(productIdentity: nil)
    )
    require(
      unidentified == .unavailable(installed: installed),
      "an identity-free Host did not fail closed"
    )
    require(
      unidentified.activationIdentities == nil,
      "an identity-free Host became eligible for Core activation"
    )
    require(
      LinnetSettingsUpdateChecker.RuntimeVersionState.resolved(
        installed: later,
        health: health(productIdentity: nil)
      ) == .unavailable(installed: later),
      "an identity-free Host inferred its runtime identity from 0.1.11 files"
    )

    require(
      LinnetSettingsUpdateChecker.RuntimeVersionState.resolved(
        installed: installed,
        health: health(productIdentity: installed)
      ) == .current(installed),
      "the installed Host no longer resolves as current"
    )
    require(
      LinnetSettingsUpdateChecker.RuntimeVersionState.resolved(
        installed: installed,
        health: health(productIdentity: older)
      ) == .pending(installed: installed, running: older),
      "a known older Host no longer exposes the installed update"
    )

    do {
      let fixture = try makeBundleFixture(identity: installed)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let requester = RuntimeRequester(health: health(productIdentity: nil))
      let checker = LinnetSettingsUpdateChecker(
        edition: nil,
        installedPacks: [],
        bundle: fixture.settings,
        transactionRequester: requester
      )
      require(
        checker.installedIdentity == installed
          && checker.runtimeVersionState == .checking(installed: installed),
        "the strict installed Core identity is not the sole initial update owner"
      )

      checker.refreshRuntime()
      await waitUntil("identity-free Host did not fail closed") {
        checker.runtimeVersionState == .unavailable(installed: installed)
      }
      require(
        requester.commands == [.diagnose],
        "runtime refresh triggered Core activation without user confirmation"
      )

      checker.activateInstalledCore()
      require(
        checker.runtimeVersionState == .unavailable(installed: installed)
          && requester.commands == [.diagnose],
        "identity-free Host received an unsafe Core activation request"
      )

      let unavailableRequester = UnavailableRuntimeRequester()
      let unavailableChecker = LinnetSettingsUpdateChecker(
        edition: nil,
        installedPacks: [],
        bundle: fixture.settings,
        transactionRequester: unavailableRequester
      )
      unavailableChecker.refreshRuntime()
      await waitUntil("a failed Host request discarded the installed identity") {
        unavailableChecker.runtimeVersionState == .unavailable(installed: installed)
      }
      require(
        unavailableChecker.runtimeVersionState.activationIdentities == nil,
        "a failed Host request became eligible for immediate activation"
      )

      let activatingRequester = RuntimeRequester(health: health(productIdentity: older))
      let activatingChecker = LinnetSettingsUpdateChecker(
        edition: nil, installedPacks: [], bundle: fixture.settings,
        transactionRequester: activatingRequester)
      activatingChecker.refreshRuntime()
      await waitUntil("known running Core did not expose the update") {
        activatingChecker.runtimeVersionState == .pending(installed: installed, running: older)
      }
      activatingChecker.activateInstalledCore()
      activatingChecker.refreshRuntime()
      require(
        activatingChecker.runtimeVersionState == .applying(installed: installed, running: older),
        "a read-only refresh cancelled a user-requested Core activation"
      )
      activatingChecker.check()
      require(!activatingChecker.active, "Core activation allowed an unrelated network refresh")
      await waitUntil("protected activation did not finish its original Host request") {
        activatingChecker.runtimeVersionState == .blocked(
          installed: installed, running: older, issue: .inputSourceActive)
      }
      require(activatingRequester.commands == [.diagnose, .activateCore],
        "refresh replaced the activation request instead of preserving its lifecycle")

      // The wire contract also covers published 0.1.10's unknown-TIS producer;
      // SettingsContract owns the supported-Host removal condition.
      let legacyBlockers: [(
        code: LinnetSettingsContract.RuntimeReplyCode,
        issue: LinnetSettingsContract.CoreActivationBlocker
      )] = [
        (.coreActivationApplicationsRunning, .applicationsStillRunning),
        (.coreActivationUnknownClient, .unknownClient),
      ]
      for legacy in legacyBlockers {
        let legacyRequester = RuntimeRequester(
          health: health(productIdentity: older),
          activationReplyCode: legacy.code)
        let legacyChecker = LinnetSettingsUpdateChecker(
          edition: nil,
          installedPacks: [],
          bundle: fixture.settings,
          transactionRequester: legacyRequester)
        legacyChecker.refreshRuntime()
        await waitUntil("0.1.9 Host identity did not expose the installed Core update") {
          legacyChecker.runtimeVersionState == .pending(
            installed: installed,
            running: older)
        }
        legacyChecker.activateInstalledCore()
        let expected = LinnetSettingsUpdateChecker.RuntimeVersionState.blocked(
          installed: installed,
          running: older,
          issue: legacy.issue)
        await waitUntil("0.1.9 blocker did not map to a fail-closed Settings prompt") {
          legacyChecker.runtimeVersionState == expected
        }
        require(
          legacyChecker.runtimeVersionState == expected &&
            legacyChecker.runtimeVersionState != .applied(installed) &&
            legacyRequester.commands == [.diagnose, .activateCore],
          "0.1.9 blocker \(legacy.code.rawValue) entered Host lifecycle or success"
        )
      }

      let core = LinnetDataChannel.Core(
        version: "0.1.11", build: 87,
        revision: String(repeating: "d", count: 40),
        bytes: 6_479_740,
        sha256: String(repeating: "e", count: 64),
        artifactFormat: .appArchive,
        artifactURL: URL(
          string:
            "https://github.com/Ares-X/Linnet/releases/download/core-v0.1.11/Linnet-0.1.11-arm64-Core.linnetcore"
        )!,
        releaseURL: URL(
          string: "https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.11")!
      )
      let downloaded = fixture.root.appending(
        path: "Linnet-0.1.11-arm64-Core.linnetcore",
        directoryHint: .notDirectory)
      let prepared = LinnetPreparedCoreUpdate(
        core: core,
        baseIdentity: installed,
        installedApp: fixture.root.appending(path: "Linnet.app"),
        stagingRoot: fixture.root.appending(path: ".linnet-core-update.fixture"),
        candidateApp: fixture.root.appending(path: ".linnet-core-update.fixture/Linnet.payload"),
        baseSHA256: String(repeating: "a", count: 64),
        targetSHA256: String(repeating: "b", count: 64))
      var revealed: [URL] = []
      let mirrorSource = try LinnetSettingsDownloadSource.customMirror(
        prefix: "https://mirror.example.com/")
      let downloadChecker = LinnetSettingsUpdateChecker(
        edition: nil, installedPacks: [], bundle: fixture.settings,
        transactionRequester: requester,
        coreDownloader: StubCoreDownloader(destination: downloaded, expectedSource: mirrorSource),
        coreInstaller: StubCoreInstaller(prepared: prepared),
        revealCorePackage: { revealed.append($0) })
      downloadChecker.downloadCoreUpdate(core, source: mirrorSource)
      await waitUntil("verified Core download did not become ready") {
        downloadChecker.coreDownloadState == .ready(core: core, update: prepared)
      }
      require(
        revealed.isEmpty,
        "the verified App archive was exposed to Finder or Installer"
      )

      let applyingRequester = RuntimeRequester(health: health(productIdentity: installed))
      let applyingChecker = LinnetSettingsUpdateChecker(
        edition: nil, installedPacks: [], bundle: fixture.settings,
        transactionRequester: applyingRequester,
        coreDownloader: StubCoreDownloader(destination: downloaded),
        coreInstaller: StubCoreInstaller(prepared: prepared))
      applyingChecker.refreshRuntime()
      await waitUntil("current Host identity was not ready for an online Core update") {
        applyingChecker.runtimeVersionState == .current(installed)
      }
      applyingChecker.downloadCoreUpdate(core, source: .direct)
      await waitUntil("online Core candidate was not prepared") {
        applyingChecker.coreDownloadState == .ready(core: core, update: prepared)
      }
      applyingChecker.applyDownloadedCoreUpdate()
      await waitUntil("Host blocker was not preserved for the online Core update") {
        applyingChecker.coreDownloadState == .blocked(
          core: core, update: prepared, issue: .inputSourceActive)
      }
      require(
        applyingRequester.commands == [.diagnose, .activateCore],
        "online Core activation bypassed or duplicated the Host exit owner"
      )

      let legacyCore = LinnetDataChannel.Core(
        version: core.version, build: core.build, revision: core.revision,
        bytes: core.bytes, sha256: core.sha256,
        artifactFormat: .installerPackage,
        artifactURL: URL(
          string:
            "https://github.com/Ares-X/Linnet/releases/download/core-v0.1.11/Linnet-0.1.11-arm64-Core-community-beta.pkg"
        )!,
        releaseURL: core.releaseURL)
      let legacyPackage = fixture.root.appending(
        path: "Linnet-0.1.11-arm64-Core-community-beta.pkg")
      let legacyChecker = LinnetSettingsUpdateChecker(
        edition: nil, installedPacks: [], bundle: fixture.settings,
        transactionRequester: requester,
        coreDownloader: StubCoreDownloader(destination: legacyPackage),
        coreInstaller: StubCoreInstaller(prepared: prepared),
        revealCorePackage: { revealed.append($0) })
      legacyChecker.downloadCoreUpdate(legacyCore, source: .direct)
      await waitUntil("bridge PKG did not retain its explicit legacy state") {
        legacyChecker.coreDownloadState == .installerPackage(
          core: legacyCore, file: legacyPackage)
      }
      legacyChecker.showDownloadedCoreUpdate()
      require(
        revealed == [legacyPackage],
        "the temporary bridge PKG did not require an explicit Installer action"
      )

      let failedDownloadChecker = LinnetSettingsUpdateChecker(
        edition: nil, installedPacks: [], bundle: fixture.settings,
        transactionRequester: requester,
        coreDownloader: StubCoreDownloader(destination: nil),
        coreInstaller: StubCoreInstaller(prepared: prepared),
        revealCorePackage: { _ in fail("a failed Core download was revealed") })
      failedDownloadChecker.downloadCoreUpdate(core, source: .direct)
      await waitUntil("failed Core download did not publish its terminal state") {
        failedDownloadChecker.coreDownloadState == .failed(core: core)
      }

      if ProcessInfo.processInfo.environment["LINNET_CORE_DOWNLOAD_LIVE"] == "1" {
        let catalogData = try await LinnetSettingsDownloadTransport(
          source: .direct
        ).downloadCatalog(
          at: LinnetSettingsUpdateChecker.UpdateChannel.stable.catalogURL)
        let publishedCore = try LinnetDataChannel.verifyPublished(catalogData).catalog.core
        let liveRoot = fixture.root.appending(
          path: "Live Core Download", directoryHint: .isDirectory)
        let liveFile = try await LinnetCoreDownloader(
          downloadsDirectory: liveRoot
        ).download(publishedCore, source: .direct, progress: { _ in })
        try LinnetDataChannel.verifyDownloadedArtifact(
          bytes: publishedCore.bytes,
          sha256: publishedCore.sha256,
          at: liveFile)
      }

    } catch {
      fail("unexpected fixture error: \(error)")
    }

    print("LinnetSettingsUpdateCheckerStateTests: PASS")
  }

  private final class RuntimeRequester:
    LinnetSettingsTransactionRequesting, @unchecked Sendable
  {
    private let lock = NSLock()
    private let health: LinnetSettingsContract.RuntimeHealth
    private let activationReplyCode: LinnetSettingsContract.RuntimeReplyCode
    private var recordedCommands: [LinnetSettingsContract.DataCommand] = []

    init(
      health: LinnetSettingsContract.RuntimeHealth,
      activationReplyCode: LinnetSettingsContract.RuntimeReplyCode =
        .coreActivationInputSourceActive
    ) {
      self.health = health
      self.activationReplyCode = activationReplyCode
    }

    var commands: [LinnetSettingsContract.DataCommand] {
      lock.withLock { recordedCommands }
    }

    func request(
      _ request: LinnetSettingsContract.DataRequest,
      timeout _: TimeInterval,
      onProgress _: @escaping @Sendable (LinnetSettingsContract.RuntimeReply) -> Void
    ) async throws -> LinnetSettingsContract.RuntimeReply {
      lock.withLock { recordedCommands.append(request.command) }
      if request.command == .diagnose {
        return .init(
          transactionID: request.transactionID,
          status: .running,
          code: .diagnosticsReady,
          detail: "Runtime diagnostics are available.",
          health: health
        )
      }
      return .init(
        transactionID: request.transactionID,
        status: .rejected,
        code: activationReplyCode,
        detail: "Core activation remains blocked.",
        health: nil
      )
    }
  }

  private final class UnavailableRuntimeRequester:
    LinnetSettingsTransactionRequesting, @unchecked Sendable
  {
    func request(
      _: LinnetSettingsContract.DataRequest,
      timeout _: TimeInterval,
      onProgress _: @escaping @Sendable (LinnetSettingsContract.RuntimeReply) -> Void
    ) async throws -> LinnetSettingsContract.RuntimeReply {
      throw Failure.unavailable
    }

    private enum Failure: Error { case unavailable }
  }

  private struct StubCoreDownloader: LinnetCoreDownloading {
    let destination: URL?
    var expectedSource: LinnetSettingsDownloadSource = .direct

    func download(
      _ core: LinnetDataChannel.Core,
      source: LinnetSettingsDownloadSource,
      progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
      require(source == expectedSource, "Core ignored the selected download source")
      progress(0.5)
      guard let destination else { throw Failure.rejected }
      progress(1)
      return destination
    }

    private enum Failure: Error { case rejected }
  }

  private struct StubCoreInstaller: LinnetCoreUpdateInstalling {
    let prepared: LinnetPreparedCoreUpdate

    func prepare(
      _: LinnetDataChannel.Core,
      artifact _: URL,
      installedApp _: URL
    ) async throws -> LinnetPreparedCoreUpdate {
      prepared
    }

    func exchange(_: LinnetPreparedCoreUpdate) async throws { }
    func discard(_: LinnetPreparedCoreUpdate) async { }
    func removeStaleUpdates(beside _: URL) async { }
  }

  private struct BundleFixture {
    let root: URL
    let settings: Bundle
  }

  private static func makeBundleFixture(
    identity: LinnetSettingsContract.ProductIdentity
  ) throws -> BundleFixture {
    let root = LinnetTestScratch.directory.appending(
      path: "LinnetSettingsUpdateCheckerTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let hostURL = root.appending(path: "Linnet.app", directoryHint: .isDirectory)
    let settingsURL = hostURL.appending(
      path: "Contents/Applications/Settings.app", directoryHint: .isDirectory)
    try writeInfoPlist(
      to: hostURL,
      values: [
        "CFBundleDisplayName": "Linnet",
        "CFBundleExecutable": "Linnet",
        "CFBundleIdentifier": "io.github.ares-x.inputmethod.Linnet",
        "CFBundleName": "Linnet",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": identity.version,
        "CFBundleVersion": String(identity.build),
        "InputMethodConnectionName": "Linnet_Test_Connection",
      ]
    )
    try writeInfoPlist(
      to: settingsURL,
      values: [
        "CFBundleDisplayName": "Linnet Settings",
        "CFBundleExecutable": "Settings",
        "CFBundleIdentifier": "io.github.ares-x.inputmethod.Linnet.settings",
        "CFBundleName": "Settings",
        "CFBundlePackageType": "APPL",
      ]
    )
    let releaseDirectory = hostURL.appending(
      path: "Contents/Resources/LinnetRelease", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: releaseDirectory, withIntermediateDirectories: true)
    let versionData = try JSONSerialization.data(withJSONObject: [
      "version": identity.version,
      "build": String(identity.build),
      "source": ["candidate_revision": identity.revision],
    ])
    try versionData.write(to: releaseDirectory.appending(path: "VERSION.json"))
    guard let settings = Bundle(url: settingsURL) else { throw FixtureFailure.invalidBundle }
    return .init(root: root, settings: settings)
  }

  private static func writeInfoPlist(
    to bundleURL: URL,
    values: [String: Any]
  ) throws {
    let contents = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: values, format: .xml, options: 0)
    try data.write(to: contents.appending(path: "Info.plist"))
  }

  @MainActor private static func waitUntil(
    _ message: String,
    condition: () -> Bool
  ) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    fail(message)
  }

  private static func identity(
    version: String,
    build: UInt64,
    revision: Character
  ) -> LinnetSettingsContract.ProductIdentity {
    .init(version: version, build: build, revision: String(repeating: revision, count: 40))
  }

  private static func health(
    productIdentity: LinnetSettingsContract.ProductIdentity?
  ) -> LinnetSettingsContract.RuntimeHealth {
    .init(
      productIdentity: productIdentity,
      state: .running,
      phase: .running,
      rimeVersion: "1.17.0",
      smartEnglishAvailable: true,
      octagramAvailable: true,
      availableSchemaCount: 9,
      requiredSchemaCount: 9,
      activeTransactionID: nil,
      activeSettingsRevision: String(repeating: "c", count: 64)
    )
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    guard condition() else {
      fputs("LinnetSettingsUpdateCheckerStateTests: FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  private static func fail(_ message: String) -> Never {
    fputs("LinnetSettingsUpdateCheckerStateTests: FAIL: \(message)\n", stderr)
    exit(1)
  }

  private enum FixtureFailure: Error { case invalidBundle }
}
