import AppKit
import Darwin
import XCTest

final class SettingsUITests: XCTestCase {
  private let isolatedBundleIdentifier =
    "io.github.ares-x.inputmethod.Linnet.settings-ui-uat.settings"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testFourSettingsPagesRemainAlive() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    for name in ["Appearance", "Input", "Dictionary", "Data & Updates"] {
      clickTab(name, in: app)
      XCTAssertNotEqual(app.state, .notRunning, "Settings exited after opening \(name)")
    }
  }

  @MainActor
  func testColdHostOpenBringsSettingsToForeground() async throws {
    let settingsURL = settingsApplicationURL().resolvingSymlinksInPath().standardizedFileURL
    try await terminateIsolatedSettings(at: settingsURL)
    let runningApplication = try await openSettingsWithoutActivation(
      at: settingsURL)
    // The build also contains a standalone Settings.app with this bundle ID.
    // Observe the exact embedded app opened above, as launchSettings does.
    let app = XCUIApplication(url: settingsURL)
    defer { _ = runningApplication.terminate() }

    XCTAssertEqual(
      runningApplication.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
      settingsURL,
      "Host-like open substituted a different Settings bundle")

    for _ in 0..<50 where !runningApplication.isActive {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertTrue(
      runningApplication.isActive,
      "Settings did not activate itself after the Host opened it without activation")
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistence(timeout: 5),
      "No window for embedded Settings at \(settingsURL.path), "
        + "opened PID=\(runningApplication.processIdentifier), state=\(app.state.rawValue)")
    XCTAssertTrue(
      app.windows.firstMatch.isHittable,
      "Cold-opened Settings window is hidden behind another app")
  }

  @MainActor
  func testReopenRestoresMinimizedSettingsWindow() async throws {
    let app = try launchSettings()
    defer { app.terminate() }

    let window = app.windows.firstMatch
    let minimize = window.buttons["_XCUI:MinimizeWindow"]
    XCTAssertTrue(minimize.waitForExistence(timeout: 3))
    minimize.click()
    let minimized = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == false"),
      object: window)
    XCTAssertEqual(XCTWaiter.wait(for: [minimized], timeout: 3), .completed)

    try await reopenSettings(at: settingsApplicationURL())
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"),
      object: window)
    XCTAssertEqual(
      XCTWaiter.wait(for: [restored], timeout: 5),
      .completed,
      "Reopening Settings did not restore its minimized window to the foreground")
  }

  @MainActor
  func testReopenRaisesSettingsAboveControlledForegroundWindow() async throws {
    let app = try launchSettings()
    defer { app.terminate() }

    // Exercise a real second application, not a panel in background XCTRunner.
    let foregroundURL = Bundle.main.bundleURL.deletingLastPathComponent()
      .appending(path: "ForegroundFixture.app", directoryHint: .isDirectory)
    XCTAssertEqual(Bundle(url: foregroundURL)?.bundleIdentifier,
      "io.github.ares-x.inputmethod.Linnet.settings-ui-uat.foreground")
    let coveringApp = XCUIApplication(url: foregroundURL)
    coveringApp.launchEnvironment = app.launchEnvironment
    coveringApp.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    coveringApp.launch()
    defer { coveringApp.terminate() }
    XCTAssertTrue(coveringApp.windows.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(
      coveringApp.state, .runningForeground,
      "The separate foreground fixture did not become active")

    let settings = try XCTUnwrap(
      NSRunningApplication.runningApplications(
        withBundleIdentifier: isolatedBundleIdentifier
      ).first
    )
    let covered = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isActive == false"),
      object: settings
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [covered], timeout: 3),
      .completed,
      "The controlled fixture did not cover Settings"
    )

    try await reopenSettings(at: settingsApplicationURL())
    let raised = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isActive == true"),
      object: settings
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [raised], timeout: 5),
      .completed,
      "Reopening Settings did not activate it above another application"
    )
    XCTAssertTrue(
      app.windows.firstMatch.isHittable,
      "Reopened Settings remained hidden behind the controlled foreground window"
    )
  }

  @MainActor
  func testDeletingFocusedDictionaryRowsDoesNotCrash() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    clickTab("Dictionary", in: app)
    try exerciseFocusedDeletion(
      addLabel: "Add Custom words",
      fieldLabel: "Value",
      removeLabel: "Remove custom word",
      value: "Linnet UI test",
      in: app)
    try exerciseSingleFocusedDeletion(
      addLabel: "Add Custom words",
      fieldLabel: "code",
      removeLabel: "Remove custom word",
      value: "linnetui",
      in: app)
    try exerciseFocusedDeletion(
      addLabel: "Add Disabled English words",
      fieldLabel: "word",
      removeLabel: "Remove disabled word",
      value: "linnetuitest",
      in: app)
    try exerciseFocusedDeletion(
      addLabel: "Add Text Expander",
      fieldLabel: "Expansion",
      removeLabel: "Remove text expansion",
      value: "Linnet expansion test",
      in: app)
    try exerciseSingleFocusedDeletion(
      addLabel: "Add Text Expander",
      fieldLabel: "x;trigger",
      removeLabel: "Remove text expansion",
      value: "x;linnetui",
      in: app)
  }

  @MainActor
  func testAppearanceControlsAndPreviewRemainResponsive() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    clickTab("Appearance", in: app)

    for (identifier, label) in [
      ("paper_ledger", "Xuan"),
      ("moon_jade", "Moon"),
      ("sidecar_slate", "Slate"),
      ("clay_tiles", "Clay"),
      ("mist_jade", "Mist"),
      ("native_glass", "Glass"),
      ("ink_cinnabar", "Ink"),
    ] {
      let theme = app.descendants(matching: .any)[
        "settings.appearance.theme.\(identifier)"]
      try reveal(theme, named: label, in: app)
      theme.click()
      XCTAssertTrue(theme.isSelected, "Theme was not selected after clicking \(label)")
      XCTAssertNotEqual(app.state, .notRunning)
    }
    try selectEachSegmentedOption(
      ["System", "Light", "Dark"],
      identifier: "settings.appearance.mode",
      in: app)

    let fontSize = app.sliders["settings.appearance.fontSize"]
    try reveal(fontSize, named: "Candidate font size", in: app)
    for (position, expectedValue) in [(0.0, "12"), (0.5, "22"), (1.0, "32")] {
      fontSize.adjust(toNormalizedSliderPosition: position)
      XCTAssertEqual(String(describing: fontSize.value), "Optional(\(expectedValue))")
      XCTAssertNotEqual(app.state, .notRunning)
    }

    try selectEachPopUpOption([
      "System Default",
      "Avenir Next + Hiragino Sans GB",
      "Helvetica Neue + Heiti SC",
      "Iowan Old Style + Songti SC",
      "Charter + Songti SC",
    ], identifier: "settings.appearance.typeface", in: app)
    try selectEachSegmentedOption(
      ["3", "5", "7", "9"],
      identifier: "settings.appearance.pageSize",
      in: app)
    try selectEachSegmentedOption(
      ["Horizontal", "Vertical"],
      identifier: "settings.appearance.chineseLayout",
      in: app)
    try selectEachSegmentedOption(
      ["Horizontal", "Vertical"],
      identifier: "settings.appearance.englishLayout",
      in: app)
    try selectEachSegmentedOption(
      ["Scrolling only", "Expandable"],
      identifier: "settings.appearance.browsing",
      in: app)

    for (identifier, language) in [
      ("settings.appearance.preview.chinese.disclosure", "Chinese"),
      ("settings.appearance.preview.english.disclosure", "English"),
    ] {
      let disclosure = app.descendants(matching: .any)[identifier]
      try reveal(disclosure, named: "Show more \(language) candidates", in: app)
      disclosure.click()
      XCTAssertEqual(disclosure.label, "Show fewer candidates")
      disclosure.click()
      XCTAssertEqual(disclosure.label, "Show more candidates")
    }
  }

  @MainActor
  func testInputAndEnglishControlsRemainResponsive() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    clickTab("Input", in: app)
    try selectEachPopUpOption([
      "Natural Code",
      "Full Pinyin",
      "Flypy Double Pinyin",
      "Microsoft Double Pinyin",
      "Sogou Double Pinyin",
      "Intelligent ABC",
      "Ziguang Double Pinyin",
      "Jiajia Pinyin",
    ], in: app)
    try selectEachPopUpOption([
      "Enhanced learning (Recommended)",
      "Standard learning",
      "Turn off learning",
    ], in: app)
    try selectEachPopUpOption(["Semicolon (;)", "Vertical bar (|)"], in: app)
    for label in [
      "Suggest emoji candidates",
      "Output traditional Chinese by default",
      "Use English punctuation by default",
    ] {
      try clickCheckBox(label, in: app)
    }
    try clickCheckBox(
      "Prefer single characters in auxiliary-code lookup by default",
      in: app)

    for label in [
      "Show IPA pronunciation",
      "Show Chinese definitions",
      "Show Smart English context suggestions",
      "Suggest spelling corrections",
      "Capitalize sentence starts",
      "Learn from English selections",
      "Add a trailing space when Space accepts a candidate",
    ] {
      try clickCheckBox(label, in: app)
    }
    try selectEachPopUpOption([
      "Smart complete",
      "Navigate candidates",
      "Pass to application",
    ], in: app)

  }

  @MainActor
  func testCloseGuardKeepsAndDiscardsDraft() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    clickTab("Input", in: app)
    try clickCheckBox("Suggest emoji candidates", in: app)

    let close = app.buttons["_XCUI:CloseWindow"]
    XCTAssertTrue(close.waitForExistence(timeout: 3))
    close.click()
    let keepEditing = app.sheets.buttons["Keep Editing"].firstMatch
    XCTAssertTrue(keepEditing.waitForExistence(timeout: 3))
    keepEditing.click()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
    XCTAssertTrue(app.windows.firstMatch.isHittable)

    close.click()
    let discard = app.sheets.buttons["Discard Changes"].firstMatch
    XCTAssertTrue(discard.waitForExistence(timeout: 3))
    discard.click()
    let windowHidden = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == false"),
      object: app.windows.firstMatch)
    XCTAssertEqual(XCTWaiter.wait(for: [windowHidden], timeout: 3), .completed)
  }

  @MainActor
  func testDataControlsAndCancellationPathsRemainResponsive() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    clickTab("Data & Updates", in: app)

    let coreUpdate = app.descendants(matching: .any)["settings.data.coreUpdate"]
    try reveal(coreUpdate, named: "Core update", in: app)
    XCTAssertTrue(coreUpdate.exists, "The always-present Core update card is missing")
    let activationActions = app.buttons.matching(NSPredicate(
      format: "label IN %@",
      ["Apply Installed Update…", "Try Apply Again…"]))
    XCTAssertEqual(
      activationActions.count,
      1,
      "Core update must expose exactly one stable activation action")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.data.core.running"].exists,
      "Core update did not explicitly expose the running Core identity")
    XCTAssertTrue(
      app.descendants(matching: .any)["settings.data.core.installed"].exists,
      "Core update did not explicitly expose the installed Core identity")

    let checkAgain = app.buttons["Check Again"]
    try reveal(checkAgain, named: "Check Again", in: app)
    try waitUntilEnabled(checkAgain, timeout: 30)
    checkAgain.click()
    try waitUntilEnabled(checkAgain, timeout: 30)

    try selectEachPopUpOption([
      "GitHub (Direct)",
      "GH-Proxy Public Mirror (Third-party)",
    ], identifier: "settings.data.downloadSource", in: app)
    XCTAssertTrue(app.links["Open GH-Proxy Service Information"].exists)
    try selectEachPopUpOption(
      ["Custom Mirror…"],
      identifier: "settings.data.downloadSource",
      in: app)

    let mirror = app.textFields["Custom mirror base URL"]
    try replaceText(
      in: mirror,
      named: "Custom mirror base URL",
      with: "http://mirror.example.com/",
      in: app)
    XCTAssertEqual(mirror.value as? String, "http://mirror.example.com/")
    let useCustomMirror = app.buttons["Use Custom Mirror"]
    XCTAssertTrue(useCustomMirror.exists)
    XCTAssertFalse(useCustomMirror.isEnabled)
    try replaceText(
      in: mirror,
      named: "Custom mirror base URL",
      with: "https://mirror.example.com/",
      in: app)
    XCTAssertEqual(mirror.value as? String, "https://mirror.example.com/")
    try waitUntilEnabled(useCustomMirror, timeout: 3)
    useCustomMirror.click()
    XCTAssertNotEqual(app.state, .notRunning)
    try replaceText(
      in: mirror,
      named: "Custom mirror base URL",
      with: "https://second-mirror.example.com/",
      in: app)
    XCTAssertEqual(mirror.value as? String, "https://second-mirror.example.com/")
    try waitUntilEnabled(useCustomMirror, timeout: 3)
    try selectEachPopUpOption(
      ["GitHub (Direct)"],
      identifier: "settings.data.downloadSource",
      in: app)

    try expandDisclosure("Manual recovery & transfer", in: app)

    try selectEachPopUpOption([
      "Keep latest 10 verified backups",
      "Keep latest 30 verified backups",
      "Keep latest 100 verified backups",
    ], identifier: "settings.data.retention", in: app)

    for _ in 0..<2 {
      for label in [
        "Custom words",
        "Disabled words",
        "Text Expander",
        "Chinese learning",
        "English learning",
      ] {
        try clickCheckBox(label, in: app)
      }
    }

    let clearLearning = app.menuButtons["Clear Learning"]
    try reveal(clearLearning, named: "Clear Learning", in: app)
    for option in ["Chinese…", "English…", "Chinese and English…"] {
      clearLearning.click()
      let item = app.menuItems[option]
      XCTAssertTrue(item.waitForExistence(timeout: 3))
      item.click()
      try cancelConfirmation("Clear selected learning data?", in: app)
    }

    let importExisting = app.buttons["Import Existing"]
    if importExisting.exists, importExisting.isEnabled {
      try reveal(importExisting, named: "Import Existing", in: app)
      importExisting.click()
      try cancelConfirmation("Import existing Rime / Hallelujah data?", in: app)
    }

    try openAndCancelPanel(button: "Export…", title: "Export Linnet Data", in: app)
    try openAndCancelPanel(button: "Import…", title: "Import Linnet Data", in: app)

    let restore = app.buttons["Restore"].firstMatch
    if restore.exists, restore.isEnabled {
      try reveal(restore, named: "Restore", in: app)
      restore.click()
      try cancelConfirmation("Restore this verified backup?", in: app)
    }

    try expandDisclosure("Diagnostics", in: app)
    let refresh = app.buttons["Refresh"]
    try reveal(refresh, named: "Refresh", in: app)
    refresh.click()
    try waitUntilEnabled(refresh, timeout: 10)
    try openAndCancelPanel(button: "Save…", title: "Export Linnet Diagnostics", in: app)

    XCTAssertTrue(app.buttons["Update Language Data"].exists)
    try expandDisclosure("iCloud Drive sync", in: app)
    XCTAssertTrue(app.checkBoxes["Sync learned words with iCloud Drive"].exists)
    XCTAssertTrue(app.buttons["Sync Learning Now"].exists)
    XCTAssertTrue(app.buttons["Open Data Folder"].exists)
    XCTAssertTrue(app.buttons["Copy Report"].exists)

    let interfaceLanguage = app.popUpButtons["settings.interfaceLanguage"]
    XCTAssertTrue(interfaceLanguage.exists)
    XCTAssertTrue(
      app.windows.firstMatch.frame.contains(interfaceLanguage.frame),
      "Interface language is outside the Settings window: "
        + "window=\(app.windows.firstMatch.frame), control=\(interfaceLanguage.frame)")
    try selectEachPopUpOption([
      "Follow System",
      "简体中文",
      "English",
    ], identifier: "settings.interfaceLanguage", in: app)
    XCTAssertNotEqual(app.state, .notRunning)
  }

  @MainActor
  func testDataPageKeepsUpdatesVisibleAndProgressivelyDisclosesDataTools() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    clickTab("Data & Updates", in: app)

    let coreUpdate = app.descendants(matching: .any)["settings.data.coreUpdate"]
    try reveal(coreUpdate, named: "Core update", in: app)
    XCTAssertTrue(coreUpdate.exists, "The version and update controls are not always present")

    let rows: [(group: String, hiddenControl: XCUIElement)] = [
      ("iCloud Drive sync", app.buttons["Sync Learning Now"]),
      ("Manual recovery & transfer", app.buttons["Import Existing"]),
      ("Diagnostics", app.buttons["Copy Report"]),
    ]
    for row in rows {
      let disclosure = app.disclosureTriangles[row.group]
      try reveal(disclosure, named: row.group, in: app)
      XCTAssertFalse(
        row.hiddenControl.exists,
        "\(row.group) was expanded before the user requested it")
      try expandDisclosure(row.group, in: app)
      XCTAssertTrue(
        row.hiddenControl.waitForExistence(timeout: 3),
        "\(row.group) did not reveal its existing controls")
    }
  }

  @MainActor
  private func launchSettings() throws -> XCUIApplication {
    let isolatedHome = "/private/tmp/linnet-settings-ui-uat-active-\(getuid())"
    let isolatedHomeURL = URL(fileURLWithPath: isolatedHome, isDirectory: true)
      .standardizedFileURL
    XCTAssertNotEqual(
      isolatedHomeURL,
      FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
      "Settings UI tests must never use the real user home")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: isolatedHomeURL.appending(
        path: "Library/Application Support/Linnet/State/active.json").path))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: isolatedHomeURL.appending(
        path: "Library/Application Support/Linnet/UserData/linnet_settings.json").path))

    let settingsURL = settingsApplicationURL()
    let path = settingsURL.path
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: path),
      "Embedded Settings.app is missing at \(path)")
    XCTAssertEqual(
      Bundle(url: settingsURL)?.bundleIdentifier,
      isolatedBundleIdentifier,
      "Settings UI tests require the isolated UAT preference domain")

    let app = XCUIApplication(url: settingsURL)
    app.launchEnvironment["HOME"] = isolatedHome
    app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome
    app.launchArguments = [
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
    ]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    XCTAssertTrue(app.windows.firstMatch.isHittable, "Settings window is hidden behind another app")
    return app
  }

  private func settingsApplicationURL() -> URL {
    let productsDirectory = Bundle(for: SettingsUITests.self).bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return productsDirectory
      .appending(path: "Linnet.app", directoryHint: .isDirectory)
      .appending(path: "Contents/Applications/Settings.app", directoryHint: .isDirectory)
  }

  private func reopenSettings(at settingsURL: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.allowsRunningApplicationSubstitution = false
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(
        at: settingsURL,
        configuration: configuration
      ) { application, error in
        if let error {
          continuation.resume(throwing: error)
        } else if application == nil {
          continuation.resume(throwing: SettingsUIFailure.reopenFailed)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private func openSettingsWithoutActivation(
    at settingsURL: URL
  ) async throws -> NSRunningApplication {
    let isolatedHome = "/private/tmp/linnet-settings-ui-uat-active-\(getuid())"
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.allowsRunningApplicationSubstitution = false
    configuration.environment = [
      "HOME": isolatedHome,
      "CFFIXED_USER_HOME": isolatedHome,
    ]
    configuration.arguments = [
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_US",
    ]
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<NSRunningApplication, Error>) in
      NSWorkspace.shared.openApplication(
        at: settingsURL,
        configuration: configuration
      ) { application, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let application {
          continuation.resume(returning: application)
        } else {
          continuation.resume(throwing: SettingsUIFailure.reopenFailed)
        }
      }
    }
  }

  private func terminateIsolatedSettings(at settingsURL: URL) async throws {
    let exactApplications = {
      NSRunningApplication.runningApplications(
        withBundleIdentifier: self.isolatedBundleIdentifier
      ).filter {
        $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == settingsURL
      }
    }
    for application in exactApplications() {
      _ = application.terminate()
    }
    for _ in 0..<50 {
      if exactApplications().isEmpty {
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("The isolated Settings fixture was already running and did not terminate")
  }

  @MainActor
  private func clickTab(_ name: String, in app: XCUIApplication) {
    let candidates = [
      app.tabBars.buttons[name],
      app.radioButtons[name],
      app.buttons[name],
    ]
    for candidate in candidates where candidate.waitForExistence(timeout: 2) {
      candidate.click()
      return
    }
    XCTFail("Settings tab is unavailable: \(name)")
  }

  @MainActor
  private func expandDisclosure(_ name: String, in app: XCUIApplication) throws {
    let control = app.disclosureTriangles[name]
    try reveal(control, named: name, in: app)
    let before = XCTAttachment(screenshot: app.screenshot())
    before.name = "Before expanding \(name)"
    before.lifetime = .keepAlways
    add(before)
    // At this fixture's fixed system font, macOS 26's AX outline frame starts
    // 26 pt before the painted chevron (xcresult: frame x=43, arrow x=69).
    // The label center and frame.minX + height/2 both miss the actual control.
    let chevronInset: CGFloat = 26
    control.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
      .withOffset(CGVector(dx: chevronInset, dy: 0)).click()
    let expanded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == 1"), object: control)
    let result = XCTWaiter.wait(for: [expanded], timeout: 3)
    let value = control.value
    print("Disclosure \(name): value=\(String(describing: value)), "
      + "type=\(value.map { String(reflecting: type(of: $0)) } ?? "nil"), "
      + "frame=\(control.frame)")
    if result != .completed {
      print(app.debugDescription)
      let after = XCTAttachment(screenshot: app.screenshot())
      after.name = "After expanding \(name)"
      after.lifetime = .keepAlways
      add(after)
    }
    XCTAssertEqual(
      result, .completed,
      "Disclosure did not expand after clicking its chevron: \(name)")
  }

  @MainActor
  private func waitUntilEnabled(
    _ element: XCUIElement,
    timeout: TimeInterval
  ) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"),
      object: element)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Control did not become enabled: \(element)")
  }

  @MainActor
  private func replaceText(
    in field: XCUIElement,
    named name: String,
    with value: String,
    in app: XCUIApplication
  ) throws {
    try reveal(field, named: name, in: app)
    field.click()
    field.typeKey("a", modifierFlags: [.command])
    field.typeKey(.delete, modifierFlags: [])
    field.typeText(value)
  }

  @MainActor
  private func cancelConfirmation(
    _ title: String,
    in app: XCUIApplication
  ) throws {
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Missing confirmation: \(title)")
    XCTAssertTrue(
      sheet.descendants(matching: .any)[title].exists,
      "Unexpected confirmation sheet")
    let cancel = sheet.buttons["Cancel"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 3))
    cancel.click()
    XCTAssertFalse(sheet.waitForExistence(timeout: 3))
  }

  @MainActor
  private func openAndCancelPanel(
    button label: String,
    title: String,
    in app: XCUIApplication
  ) throws {
    let button = app.buttons[label]
    try reveal(button, named: label, in: app)
    try waitUntilEnabled(button, timeout: 10)
    button.click()
    let panel = app.dialogs.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 3), "Missing panel: \(title)")
    let cancel = panel.buttons["Cancel"].firstMatch
    XCTAssertTrue(
      cancel.waitForExistence(timeout: 3),
      "Unexpected file panel for: \(title)")
    cancel.click()
    XCTAssertFalse(panel.waitForExistence(timeout: 3))
  }

  @MainActor
  private func exerciseFocusedDeletion(
    addLabel: String,
    fieldLabel: String,
    removeLabel: String,
    value: String,
    in app: XCUIApplication
  ) throws {
    let add = app.buttons[addLabel]
    try reveal(add, named: addLabel, in: app)
    let fields = app.textFields.matching(NSPredicate(
      format: "placeholderValue == %@ OR label == %@ OR identifier == %@",
      fieldLabel,
      fieldLabel,
      fieldLabel))
    let removes = app.buttons.matching(NSPredicate(
      format: "label == %@ OR identifier == %@", removeLabel, removeLabel))
    let originalCount = fields.count
    let originalRemoveCount = removes.count

    for _ in 0..<3 { add.click() }
    XCTAssertEqual(fields.count, originalCount + 3)

    for offset in [1, 1, 0] {
      let focusedField = fields.element(boundBy: originalCount + offset)
      XCTAssertTrue(focusedField.waitForExistence(timeout: 3))
      focusedField.click()
      focusedField.typeText(value)

      let focusedRowRemove = removes.element(boundBy: originalRemoveCount + offset)
      XCTAssertTrue(focusedRowRemove.waitForExistence(timeout: 3))
      focusedRowRemove.click()
      app.typeKey(.tab, modifierFlags: [])
      app.typeKey(.tab, modifierFlags: [.shift])
      XCTAssertNotEqual(
        app.state,
        .notRunning,
        "Settings exited after removing a focused row")
    }
    XCTAssertEqual(fields.count, originalCount)

    for _ in 0..<6 { add.click() }
    while removes.count > originalRemoveCount {
      let addedRow = removes.element(boundBy: originalRemoveCount)
      XCTAssertTrue(addedRow.waitForExistence(timeout: 3))
      addedRow.click()
    }
    XCTAssertEqual(fields.count, originalCount)
  }

  @MainActor
  private func exerciseSingleFocusedDeletion(
    addLabel: String,
    fieldLabel: String,
    removeLabel: String,
    value: String,
    in app: XCUIApplication
  ) throws {
    let add = app.buttons[addLabel]
    try reveal(add, named: addLabel, in: app)
    let fields = app.textFields.matching(NSPredicate(
      format: "placeholderValue == %@ OR label == %@ OR identifier == %@",
      fieldLabel,
      fieldLabel,
      fieldLabel))
    let removes = app.buttons.matching(NSPredicate(
      format: "label == %@ OR identifier == %@", removeLabel, removeLabel))
    let originalFieldCount = fields.count
    let originalRemoveCount = removes.count

    add.click()
    let field = fields.element(boundBy: originalFieldCount)
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.click()
    field.typeText(value)
    let remove = removes.element(boundBy: originalRemoveCount)
    XCTAssertTrue(remove.waitForExistence(timeout: 3))
    remove.click()
    app.typeKey(.tab, modifierFlags: [])
    XCTAssertNotEqual(app.state, .notRunning)
    XCTAssertEqual(fields.count, originalFieldCount)
  }

  @MainActor
  private func selectEachPopUpOption(
    _ options: [String],
    identifier: String? = nil,
    in app: XCUIApplication
  ) throws {
    let predicate = NSPredicate(format: "value IN %@", options)
    for option in options {
      let popUp = identifier.map { app.popUpButtons[$0] }
        ?? app.popUpButtons.matching(predicate).firstMatch
      try reveal(popUp, named: identifier ?? option, in: app)
      XCTAssertTrue(popUp.isEnabled)
      // Expanded SwiftUI disclosures can report false isHittable for a visibly
      // exposed child. Verify the actual mouse/menu/value path, not that hint.
      popUp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
      let menuItem = app.menuItems[option]
      XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "Missing menu item: \(option)")
      menuItem.click()
      let selected = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", option), object: popUp)
      XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed,
        "The popup did not select \(option)")
      XCTAssertNotEqual(app.state, .notRunning, "Settings exited after choosing \(option)")
    }
  }

  @MainActor
  private func selectEachSegmentedOption(
    _ options: [String],
    identifier: String,
    in app: XCUIApplication
  ) throws {
    let container = app.descendants(matching: .any)[identifier]
    for option in options {
      let selected = container.descendants(matching: .radioButton)[option]
      try reveal(selected, named: option, in: app)
      selected.click()
      XCTAssertEqual(String(describing: selected.value), "Optional(1)")
      XCTAssertNotEqual(app.state, .notRunning)
    }
  }

  @MainActor
  private func clickCheckBox(
    _ label: String,
    in app: XCUIApplication
  ) throws {
    let checkBox = app.checkBoxes[label]
    try reveal(checkBox, named: label, in: app)
    let valueBeforeClick = String(describing: checkBox.value)
    checkBox.click()
    XCTAssertNotEqual(
      String(describing: checkBox.value),
      valueBeforeClick,
      "Settings did not change after toggling \(label)")
    XCTAssertNotEqual(app.state, .notRunning, "Settings exited after toggling \(label)")
  }

  @MainActor
  private func reveal(
    _ element: XCUIElement,
    named name: String,
    in app: XCUIApplication
  ) throws {
    let scrollView = app.scrollViews["settings.page.scroll"]
    for direction in [-1.0, 1.0] {
      for _ in 0..<12 {
        guard scrollView.exists else { break }
        let viewport = scrollView.frame.insetBy(dx: 0, dy: 12)
        let maximumStep = viewport.height / 2
        var deltaY = direction * maximumStep
        if element.exists {
          let frame = element.frame
          let hittable = element.isHittable
          if viewport.contains(frame) { return }
          print("Reveal \(name): frame=\(frame), viewport=\(viewport), hittable=\(hittable)")
          // Center the target instead of jumping over its visible interval.
          // Visibility belongs here; each interaction verifies its actual result.
          deltaY = min(max(viewport.midY - frame.midY, -maximumStep), maximumStep)
          if abs(deltaY) < 1 { break }
        }
        scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
      }
    }
    let viewport = scrollView.exists
      ? scrollView.frame.insetBy(dx: 0, dy: 12)
      : CGRect.null
    print(app.debugDescription)
    let state = element.exists
      ? "isEnabled=\(element.isEnabled), isHittable=\(element.isHittable), frame=\(element.frame)"
      : "element not found in the accessibility tree"
    XCTFail(
      "Settings control is unavailable: \(name); "
        + "\(state), viewport=\(viewport)")
  }

  private enum SettingsUIFailure: Error {
    case reopenFailed
  }
}
