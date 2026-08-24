import Darwin
import Foundation

@main
struct SettingsContractTests {
  private static let backupRetentionPolicyKey = "backup.retention_policy"
  private static let cloudSyncEnabledKey = "cloud_sync.enabled_v1"
  private static let legacyCloudSyncFolderBookmarkKey = "cloud_sync.folder_bookmark_v1"
  private static let cloudSyncLastAttemptKey = "cloud_sync.last_attempt_v1"

  static func main() {
    do {
      testPinyinReverseLookupExamples()
      try inTemporaryBundleTree { host, settings, hostIdentifier, productName in
        testHostDerivation(host: host, settings: settings)
        testSuitePersistence(host: host, settings: settings, hostIdentifier: hostIdentifier)
        testInvalidStoredValueFallsBack(
          settings: settings,
          hostIdentifier: hostIdentifier
        )
        testUserDirectoryDerivation(settings: settings, productName: productName)
        testDataTransactionContract(
          settings: settings,
          hostIdentifier: hostIdentifier,
          productName: productName
        )
      }
      print("SettingsContractTests: PASS")
    } catch {
      fail("unexpected error: \(error)")
    }
  }

  private static func testPinyinReverseLookupExamples() {
    let expected: [LinnetSettingsContract.ChineseProfile: String] = [
      .natural: "srfa",
      .fullPinyin: "suanfa",
      .flypy: "srfa",
      .microsoft: "srfa",
      .sogou: "srfa",
      .abc: "spfa",
      .ziguang: "slfa",
      .jiajia: "scfa",
    ]
    guard Dictionary(
      uniqueKeysWithValues: LinnetSettingsContract.ChineseProfile.allCases.map {
        ($0, $0.reverseLookupExampleCode)
      }) == expected
    else {
      fail("a Settings reverse-lookup example diverged from its selected profile")
    }
  }

  private static func testHostDerivation(host: Bundle, settings: Bundle) {
    guard let derivedFromHost = LinnetSettingsContract.hostBundle(startingAt: host),
      let derivedFromSettings = LinnetSettingsContract.hostBundle(startingAt: settings),
      derivedFromHost.bundleURL.standardizedFileURL == host.bundleURL.standardizedFileURL,
      derivedFromSettings.bundleURL.standardizedFileURL == host.bundleURL.standardizedFileURL
    else {
      fail("the nested Settings bundle did not derive its input-method host")
    }
  }

  private static func testSuitePersistence(
    host: Bundle,
    settings: Bundle,
    hostIdentifier: String
  ) {
    guard let defaults = UserDefaults(suiteName: hostIdentifier) else {
      fail("could not create the host preference suite")
    }
    defaults.removePersistentDomain(forName: hostIdentifier)
    defer {
      defaults.removePersistentDomain(forName: hostIdentifier)
      defaults.synchronize()
    }

    guard LinnetSettingsContract.englishSchemaID == "linnet_en",
      LinnetSettingsContract.backupRetentionPolicy(startingAt: settings) == .keepLatest30,
      LinnetSettingsContract.BackupRetentionPolicy.keepLatest10.maximumVerifiedBackups == 10,
      LinnetSettingsContract.BackupRetentionPolicy.keepLatest30.maximumVerifiedBackups == 30,
      LinnetSettingsContract.BackupRetentionPolicy.keepLatest100.maximumVerifiedBackups == 100
    else {
      fail("an empty host suite did not use the product defaults")
    }
    guard LinnetSettingsContract.setBackupRetentionPolicy(
        .keepLatest30,
        startingAt: settings
      ),
      defaults.string(forKey: backupRetentionPolicyKey) == "latest_30",
      LinnetSettingsContract.backupRetentionPolicy(startingAt: host) == .keepLatest30
    else {
      fail("the backup policy did not share the host suite")
    }
    let attemptedAt = Date(timeIntervalSince1970: 12_345)
    guard !LinnetSettingsContract.cloudSyncEnabled(startingAt: host),
      LinnetSettingsContract.setCloudSyncEnabled(true, startingAt: settings),
      defaults.bool(forKey: cloudSyncEnabledKey),
      LinnetSettingsContract.cloudSyncEnabled(startingAt: host),
      LinnetSettingsContract.setCloudSyncLastAttempt(attemptedAt, startingAt: settings),
      defaults.object(forKey: cloudSyncLastAttemptKey) as? Date == attemptedAt,
      LinnetSettingsContract.cloudSyncLastAttempt(startingAt: host) == attemptedAt,
      LinnetSettingsContract.setCloudSyncEnabled(false, startingAt: settings),
      !defaults.bool(forKey: cloudSyncEnabledKey)
    else {
      fail("the cloud sync enabled state did not share the host suite")
    }

    defaults.removeObject(forKey: cloudSyncEnabledKey)
    defaults.set(Data("legacy-bookmark".utf8), forKey: legacyCloudSyncFolderBookmarkKey)
    guard LinnetSettingsContract.cloudSyncEnabled(startingAt: settings),
      defaults.bool(forKey: cloudSyncEnabledKey),
      defaults.object(forKey: legacyCloudSyncFolderBookmarkKey) == nil
    else {
      fail("the legacy folder selection did not migrate to the product-owned location")
    }
  }

  private static func testInvalidStoredValueFallsBack(
    settings: Bundle,
    hostIdentifier: String
  ) {
    guard let defaults = UserDefaults(suiteName: hostIdentifier) else {
      fail("could not reopen the host preference suite")
    }
    defaults.set("all", forKey: backupRetentionPolicyKey)
    guard defaults.synchronize(),
      LinnetSettingsContract.backupRetentionPolicy(startingAt: settings) == .keepLatest30
    else {
      fail("invalid backup retention did not use the product default")
    }
    defaults.removePersistentDomain(forName: hostIdentifier)
    defaults.synchronize()
  }

  private static func testUserDirectoryDerivation(settings: Bundle, productName: String) {
    guard let actual = LinnetSettingsContract.hostUserDirectory(startingAt: settings)
    else {
      fail("the host user directory could not be derived")
    }
    guard let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      fail("Application Support could not be derived")
    }
    let expected = applicationSupport
      .appending(component: productName, directoryHint: .isDirectory)
      .appending(component: "UserData", directoryHint: .isDirectory)
    guard actual.standardizedFileURL == expected.standardizedFileURL else {
      fail("the host user directory is not derived from the host display name")
    }
  }

  private static func testDataTransactionContract(
    settings: Bundle,
    hostIdentifier _: String,
    productName: String
  ) {
    guard let userDirectory = LinnetSettingsContract.hostUserDirectory(startingAt: settings),
      let transactionsRoot = LinnetSettingsContract.dataTransactionsRoot(startingAt: settings),
      transactionsRoot == userDirectory.deletingLastPathComponent().appending(
        component: "Transactions", directoryHint: .isDirectory)
    else {
      fail("data transaction roots are not derived from the host contract")
    }

    let transactionID = UUID()
    let candidate = transactionsRoot.appending(component: transactionID.uuidString)
      .appending(component: "candidate", directoryHint: .isDirectory)
    let configurationCandidate = transactionsRoot.appending(component: transactionID.uuidString)
      .appending(component: "configuration-candidate", directoryHint: .isDirectory)
    let requesterPID = getpid()
    let deadline = Date(
      timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 120
    )
    let activeDigest = String(repeating: "a", count: 64)
    let settingsDigest = String(repeating: "b", count: 64)
    let replacementSettingsDigest = String(repeating: "c", count: 64)
    let expectedPause = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .pause,
      candidate: nil,
      requesterPID: requesterPID,
      deadline: deadline
    )
    let expectedActivate = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .activate,
      candidate: candidate,
      requesterPID: requesterPID,
      deadline: deadline
    )
    let expectedReload = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .reloadConfiguration,
      candidate: configurationCandidate,
      requesterPID: requesterPID,
      deadline: deadline,
      expectedSettingsRevision: settingsDigest
    )
    let expectedLanguage = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .activateLanguage,
      candidate: candidate,
      requesterPID: requesterPID,
      deadline: deadline,
      expectedActiveGeneration: 7,
      expectedActiveStateSHA256: activeDigest
    )
    let reply = LinnetSettingsContract.RuntimeReply(
      transactionID: transactionID,
      status: .running,
      code: .diagnosticsReady,
      detail: "fixture running",
      health: .init(
        state: .running,
        phase: .running,
        rimeVersion: "1.16.0",
        smartEnglishAvailable: true,
        octagramAvailable: true,
        availableSchemaCount: 9,
        requiredSchemaCount: 9,
        activeSettingsRevision: settingsDigest))
    guard LinnetSettingsContract.validDataRequest(expectedPause),
      LinnetSettingsContract.validDataRequest(expectedActivate),
      LinnetSettingsContract.validDataRequest(expectedReload),
      LinnetSettingsContract.validDataRequest(expectedLanguage),
      LinnetSettingsContract.validRuntimeReply(reply),
      LinnetSettingsContract.requestCanContinue(expectedPause),
      LinnetSettingsContract.requesterIsAlive(requesterPID),
      !LinnetSettingsContract.requestCanContinue(
        .init(
          transactionID: transactionID,
          command: .pause,
          candidate: nil,
          requesterPID: requesterPID,
          deadline: Date.distantPast
        )
      )
    else {
      fail("requester liveness or deadline validation failed")
    }

    let missingCandidate = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .activate,
      candidate: nil,
      requesterPID: requesterPID,
      deadline: deadline)
    let missingCAS = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .activateLanguage,
      candidate: candidate,
      requesterPID: requesterPID,
      deadline: deadline)
    let invalidPause = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .pause,
      candidate: candidate,
      requesterPID: requesterPID,
      deadline: deadline)
    let invalidReload = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .reloadConfiguration,
      candidate: nil,
      requesterPID: requesterPID,
      deadline: deadline)
    let invalidRefreshWithoutCAS = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .refresh,
      candidate: configurationCandidate,
      requesterPID: requesterPID,
      deadline: deadline)
    let validRecoveryReload = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .reloadConfiguration,
      candidate: configurationCandidate,
      requesterPID: requesterPID,
      deadline: deadline,
      expectedSettingsRevision: settingsDigest,
      alternateSettingsRevision: replacementSettingsDigest)
    let invalidRecoveryRefresh = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .refresh,
      candidate: configurationCandidate,
      requesterPID: requesterPID,
      deadline: deadline,
      expectedSettingsRevision: settingsDigest,
      alternateSettingsRevision: replacementSettingsDigest)
    guard !LinnetSettingsContract.validDataRequest(missingCandidate),
      !LinnetSettingsContract.validDataRequest(missingCAS),
      !LinnetSettingsContract.validDataRequest(invalidPause),
      !LinnetSettingsContract.validDataRequest(invalidReload),
      !LinnetSettingsContract.validDataRequest(invalidRefreshWithoutCAS),
      LinnetSettingsContract.validDataRequest(validRecoveryReload),
      !LinnetSettingsContract.validDataRequest(invalidRecoveryRefresh)
    else {
      fail("invalid command and candidate combinations were accepted")
    }
  }

  private static func inTemporaryBundleTree(
    _ body: (Bundle, Bundle, String, String) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "LinnetSettingsContractTests-\(UUID().uuidString)", isDirectory: true)
    let hostURL = directory.appendingPathComponent("Host.app", isDirectory: true)
    let settingsURL =
      hostURL
      .appendingPathComponent("Contents/Applications/Settings.app", isDirectory: true)
    let hostIdentifier = "io.github.linnet.tests.\(UUID().uuidString)"
    let productName = "Linnet Contract Test"
    defer { try? FileManager.default.removeItem(at: directory) }

    try writeInfoPlist(
      at: hostURL,
      values: [
        "CFBundleDisplayName": productName,
        "CFBundleExecutable": "Host",
        "CFBundleIdentifier": hostIdentifier,
        "CFBundleName": "Host",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0.0",
        "InputMethodConnectionName": "Linnet_Test_Connection",
      ]
    )
    try writeInfoPlist(
      at: settingsURL,
      values: [
        "CFBundleDisplayName": "Linnet Contract Test Settings",
        "CFBundleExecutable": "Settings",
        "CFBundleIdentifier": "\(hostIdentifier).settings",
        "CFBundleName": "Settings",
        "CFBundlePackageType": "APPL",
      ]
    )

    guard let host = Bundle(url: hostURL), let settings = Bundle(url: settingsURL) else {
      throw TestFailure.invalidFixture
    }
    try body(host, settings, hostIdentifier, productName)
  }

  private static func writeInfoPlist(at bundleURL: URL, values: [String: Any]) throws {
    let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
    try data.write(to: contents.appendingPathComponent("Info.plist"))
  }

  private enum TestFailure: Error {
    case invalidFixture
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("SettingsContractTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}
