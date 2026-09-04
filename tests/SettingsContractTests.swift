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
      testCoreActivationGate()
      testHostPreferenceDomainSelection()
      try testLegacyRuntimeHealthWithoutIdentity()
      try testLegacyCoreActivationBlockerWireCodes()
      try testNativeLearningDataVersionWireCompatibility()
      try inTemporaryBundleTree { host, settings, hostIdentifier, productName in
        testHostDerivation(host: host, settings: settings)
        testProductIdentity(host: host, settings: settings)
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
        try testInstalledIdentityAfterUpdate(host: host, settings: settings)
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
        ($0, $0.representativeInputCode)
      }) == expected
    else {
      fail("a Settings reverse-lookup example diverged from its selected profile")
    }
  }

  private static func testCoreActivationGate() {
    guard LinnetInputSourceSelection.classify(
      currentIdentifier: "io.github.ares-x.inputmethod.Linnet",
      linnetIdentifier: "io.github.ares-x.inputmethod.Linnet") == .linnet,
      LinnetInputSourceSelection.classify(
        currentIdentifier: "unrelated.example",
        linnetIdentifier: "io.github.ares-x.inputmethod.Linnet") == .other,
      LinnetInputSourceSelection.classify(
        currentIdentifier: nil,
        linnetIdentifier: "io.github.ares-x.inputmethod.Linnet") == .unknown,
      LinnetInputSourceSelection.classify(
        currentIdentifier: "",
        linnetIdentifier: "io.github.ares-x.inputmethod.Linnet") == .unknown
    else {
      fail("optional HIToolbox evidence no longer preserves an unknown state")
    }

    guard LinnetCoreActivationGate.evaluate(
      selectedInputSource: .other,
      compositionIsActive: false,
      dataTransactionIsActive: false,
      requesterIsAlive: true
    ).isReady else {
      fail("inactive clients still blocked explicit Core activation")
    }

    let activeSource = LinnetCoreActivationGate.evaluate(
      selectedInputSource: .linnet,
      compositionIsActive: false,
      dataTransactionIsActive: false,
      requesterIsAlive: true
    )
    let activeComposition = LinnetCoreActivationGate.evaluate(
      selectedInputSource: .other,
      compositionIsActive: true,
      dataTransactionIsActive: false,
      requesterIsAlive: true
    )
    let activeTransaction = LinnetCoreActivationGate.evaluate(
      selectedInputSource: .other,
      compositionIsActive: false,
      dataTransactionIsActive: true,
      requesterIsAlive: true
    )
    let unknownSource = LinnetCoreActivationGate.evaluate(
      selectedInputSource: .unknown,
      compositionIsActive: false,
      dataTransactionIsActive: false,
      requesterIsAlive: true
    )
    guard unknownSource != .blocked(.coreActivationUnknownClient) else {
      fail("the current Host emitted a legacy unknown-client diagnosis for unavailable TIS state")
    }
    guard activeSource == .blocked(.coreActivationInputSourceActive),
      activeComposition == .blocked(.coreActivationCompositionActive),
      activeTransaction == .blocked(.coreActivationDataTransactionActive),
      unknownSource == .blocked(.coreActivationInputSourceUnavailable)
    else {
      fail("Core activation no longer fails closed at every Host mutation boundary")
    }

    guard LinnetCoreActivationGate.evaluate(
      selectedInputSource: .other,
      compositionIsActive: false,
      dataTransactionIsActive: false,
      requesterIsAlive: false
    ) == .blocked(.coreActivationRequesterUnavailable) else {
      fail("a missing Settings requester did not block Core activation")
    }
  }

  private static func testHostPreferenceDomainSelection() {
    let identifier = "io.github.linnet.tests.preferences.\(UUID().uuidString)"
    guard LinnetSettingsContract.preferenceDefaults(
      hostIdentifier: identifier,
      runningIdentifier: identifier
    ) === UserDefaults.standard else {
      fail("the running Host did not use its standard preference domain")
    }
    guard let embedded = LinnetSettingsContract.preferenceDefaults(
      hostIdentifier: identifier,
      runningIdentifier: "\(identifier).settings"
    ), embedded !== UserDefaults.standard else {
      fail("embedded Settings did not use the Host-named preference suite")
    }
    embedded.removePersistentDomain(forName: identifier)
  }

  private static func testLegacyRuntimeHealthWithoutIdentity() throws {
    let transactionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let document: [String: Any] = [
      "transactionID": transactionID.uuidString,
      "status": "running",
      "code": "diagnostics_ready",
      "detail": "Runtime diagnostics are available.",
      "health": [
        "productIdentity": NSNull(),
        "coreActivationReadiness": "ready",
        "connectedInputClientCount": 0,
        "state": "running",
        "phase": "running",
        "rimeVersion": "1.17.0",
        "smartEnglishAvailable": true,
        "octagramAvailable": true,
        "availableSchemaCount": 9,
        "requiredSchemaCount": 9,
        "activeTransactionID": NSNull(),
        "activeSettingsRevision": String(repeating: "a", count: 64),
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: document)
    let reply = try JSONDecoder().decode(
      LinnetSettingsContract.RuntimeReply.self, from: data)
    guard reply.transactionID == transactionID,
      reply.health?.productIdentity == nil,
      LinnetSettingsContract.validRuntimeReply(reply)
    else {
      fail("the shipped build60 identity-free health shape is no longer valid")
    }
  }

  /// Retain until the legacy producers, including published 0.1.10's
  /// unknown-TIS path, have left the supported Host range.
  private static func testLegacyCoreActivationBlockerWireCodes() throws {
    let fixtures: [(wireCode: String, code: LinnetSettingsContract.RuntimeReplyCode)] = [
      ("core_activation_applications_running", .coreActivationApplicationsRunning),
      ("core_activation_unknown_client", .coreActivationUnknownClient),
    ]
    for (index, fixture) in fixtures.enumerated() {
      let transactionID = UUID(
        uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 2))!
      let document: [String: Any] = [
        "transactionID": transactionID.uuidString,
        "status": "rejected",
        "code": fixture.wireCode,
        "detail": "Published 0.1.9 Host blocked Core activation.",
        "health": NSNull(),
      ]
      let data = try JSONSerialization.data(withJSONObject: document)
      let reply = try JSONDecoder().decode(
        LinnetSettingsContract.RuntimeReply.self,
        from: data)
      guard reply.transactionID == transactionID,
        reply.status == .rejected,
        reply.code == fixture.code,
        reply.health == nil,
        LinnetSettingsContract.validRuntimeReply(reply)
      else {
        fail("published 0.1.9 blocker wire code \(fixture.wireCode) changed meaning")
      }
    }
  }

  private static func testNativeLearningDataVersionWireCompatibility() throws {
    let legacy = LinnetSettingsContract.DataRequest(
      transactionID: UUID(), command: .pause, candidate: nil,
      requesterPID: getpid(), deadline: Date().addingTimeInterval(10),
      nativeLearningDataVersion: nil)
    let legacyData = try JSONEncoder().encode(legacy)
    let legacyDocument = try JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
    let decodedLegacy = try JSONDecoder().decode(
      LinnetSettingsContract.DataRequest.self, from: legacyData)
    let current = LinnetSettingsContract.DataRequest(
      transactionID: UUID(), command: .pause, candidate: nil,
      requesterPID: getpid(), deadline: Date().addingTimeInterval(10))
    let decodedCurrent = try JSONDecoder().decode(
      LinnetSettingsContract.DataRequest.self,
      from: JSONEncoder().encode(current))
    guard legacyDocument?["nativeLearningDataVersion"] == nil,
      decodedLegacy.nativeLearningDataVersion == nil,
      decodedCurrent == current,
      decodedCurrent.nativeLearningDataVersion
        == LinnetSettingsContract.nativeLearningDataVersion
    else {
      fail("native learning-data capability wire compatibility changed")
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

  private static func testProductIdentity(host: Bundle, settings: Bundle) {
    let expected = LinnetSettingsContract.ProductIdentity(
      version: "1.0.0",
      build: 7,
      revision: String(repeating: "a", count: 40)
    )
    guard LinnetSettingsContract.productIdentity(startingAt: host) == expected,
      LinnetSettingsContract.productIdentity(startingAt: settings) == expected
    else {
      fail("installed and running product identity did not share one bundle owner")
    }
  }

  private static func testInstalledIdentityAfterUpdate(host: Bundle, settings: Bundle) throws {
    let running = LinnetSettingsContract.productIdentity(startingAt: host)
    guard var info = host.infoDictionary, running?.build == 7 else {
      throw TestFailure.invalidFixture
    }
    // Keep the same Bundle instances alive, as Host and Settings do during an
    // update. Foundation caches Info.plist, while VERSION.json is read afresh.
    info["CFBundleShortVersionString"] = "1.0.1"
    info["CFBundleVersion"] = "8"
    try writeInfoPlist(at: host.bundleURL, values: info)
    let document: [String: Any] = [
      "version": "1.0.1", "build": "8",
      "source": ["candidate_revision": String(repeating: "b", count: 40)],
    ]
    let releaseURL = host.bundleURL.appendingPathComponent("Contents/Resources/LinnetRelease/VERSION.json")
    try JSONSerialization.data(withJSONObject: document).write(to: releaseURL, options: .atomic)
    let installed = LinnetSettingsContract.ProductIdentity(
      version: "1.0.1", build: 8, revision: String(repeating: "b", count: 40))
    guard LinnetSettingsContract.productIdentity(startingAt: settings) == installed,
      running?.build == 7 else {
      fail("an open Settings process lost the installed identity after a Core update")
    }
    // Missing and inconsistent on-disk metadata must still be rejected; a stale
    // Bundle cache is not a fallback source of installed product identity.
    info["CFBundleVersion"] = "9"
    try writeInfoPlist(at: host.bundleURL, values: info)
    guard LinnetSettingsContract.productIdentity(startingAt: settings) == nil else {
      fail("inconsistent installed product metadata was accepted")
    }
    try FileManager.default.removeItem(at: releaseURL)
    guard LinnetSettingsContract.productIdentity(startingAt: settings) == nil else {
      fail("missing installed product metadata was replaced with a cached identity")
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
    guard LinnetSettingsContract.backupRetentionPolicy(startingAt: settings) == .keepLatest30
    else {
      fail("invalid backup retention did not use the product default")
    }
    defaults.removePersistentDomain(forName: hostIdentifier)
  }

  private static func testUserDirectoryDerivation(settings: Bundle, productName: String) {
    guard let actual = LinnetSettingsContract.dataRegistry(startingAt: settings)?.userDataDirectory
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
    guard let registry = LinnetSettingsContract.dataRegistry(startingAt: settings) else {
      fail("the data transaction registry could not be derived")
    }
    let userDirectory = registry.userDataDirectory
    let transactionsRoot = registry.transactionsDirectory
    guard transactionsRoot == userDirectory.deletingLastPathComponent().appending(
        component: "Transactions", directoryHint: .isDirectory)
    else {
      fail("the data transaction root is not derived from the host contract")
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
        productIdentity: .init(
          version: "1.0.0", build: 7, revision: String(repeating: "a", count: 40)),
        state: .running,
        phase: .running,
        rimeVersion: "1.16.0",
        smartEnglishAvailable: true,
        octagramAvailable: true,
        availableSchemaCount: 9,
        requiredSchemaCount: 9,
        activeTransactionID: nil,
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
    let validCoreActivation = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .activateCore,
      candidate: nil,
      requesterPID: requesterPID,
      deadline: deadline)
    let invalidCoreActivation = LinnetSettingsContract.DataRequest(
      transactionID: transactionID,
      command: .activateCore,
      candidate: candidate,
      requesterPID: requesterPID,
      deadline: deadline)
    guard !LinnetSettingsContract.validDataRequest(missingCandidate),
      !LinnetSettingsContract.validDataRequest(missingCAS),
      !LinnetSettingsContract.validDataRequest(invalidPause),
      !LinnetSettingsContract.validDataRequest(invalidReload),
      !LinnetSettingsContract.validDataRequest(invalidRefreshWithoutCAS),
      LinnetSettingsContract.validDataRequest(validRecoveryReload),
      !LinnetSettingsContract.validDataRequest(invalidRecoveryRefresh),
      LinnetSettingsContract.validDataRequest(validCoreActivation),
      !LinnetSettingsContract.validDataRequest(invalidCoreActivation)
    else {
      fail("invalid command and candidate combinations were accepted")
    }
  }

  private static func inTemporaryBundleTree(
    _ body: (Bundle, Bundle, String, String) throws -> Void
  ) throws {
    let directory = LinnetTestScratch.directory
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
        "CFBundleVersion": "7",
        "InputMethodConnectionName": "Linnet_Test_Connection",
      ]
    )
    let releaseDirectory = hostURL.appendingPathComponent(
      "Contents/Resources/LinnetRelease", isDirectory: true)
    try FileManager.default.createDirectory(
      at: releaseDirectory, withIntermediateDirectories: true)
    let versionDocument: [String: Any] = [
      "version": "1.0.0",
      "build": "7",
      "source": ["candidate_revision": String(repeating: "a", count: 40)],
    ]
    let versionData = try JSONSerialization.data(withJSONObject: versionDocument)
    try versionData.write(to: releaseDirectory.appendingPathComponent("VERSION.json"))
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
