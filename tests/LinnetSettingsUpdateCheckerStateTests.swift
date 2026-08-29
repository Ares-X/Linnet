import Darwin
import Foundation

@main
struct LinnetSettingsUpdateCheckerStateTests {
  @MainActor static func main() async {
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
      unidentified == .restartRequired(installed),
      "an identity-free Host bypassed the one safe restart boundary"
    )
    require(
      unidentified.activationIdentities == nil,
      "an identity-free Host became eligible for immediate activation"
    )
    require(
      LinnetSettingsUpdateChecker.RuntimeVersionState.resolved(
        installed: later,
        health: health(productIdentity: nil)
      ) == .unavailable(installed: later),
      "the one-release identity-free Host bridge leaked into 0.1.11"
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
      await waitUntil("identity-free Host did not require a normal restart") {
        checker.runtimeVersionState == .restartRequired(installed)
      }
      require(
        requester.commands == [.diagnose],
        "runtime refresh triggered Core activation without user confirmation"
      )

      checker.activateInstalledCore()
      require(
        checker.runtimeVersionState == .restartRequired(installed)
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

      // Remove this table with the 0.1.9 blocker wire cases when the minimum
      // Core becomes 0.1.10 for the public 0.1.11 release.
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

  private struct BundleFixture {
    let root: URL
    let settings: Bundle
  }

  private static func makeBundleFixture(
    identity: LinnetSettingsContract.ProductIdentity
  ) throws -> BundleFixture {
    let root = FileManager.default.temporaryDirectory.appending(
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
