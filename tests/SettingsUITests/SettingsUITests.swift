import Darwin
import XCTest

final class SettingsUITests: XCTestCase {
  private static var suiteHasFailed = false
  private let isolatedBundleIdentifier =
    "io.github.ares-x.inputmethod.Linnet.settings-ui-uat.settings"

  override func setUpWithError() throws {
    try XCTSkipIf(Self.suiteHasFailed, "Skipped after the first Settings UI failure")
    continueAfterFailure = false
  }

  override func record(_ issue: XCTIssue) {
    Self.suiteHasFailed = true
    super.record(issue)
  }

  @MainActor
  func testFiveSettingsPagesRemainAlive() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    for name in ["Appearance", "Chinese Input", "Smart English", "Dictionary", "Data"] {
      clickTab(name, in: app)
      XCTAssertNotEqual(app.state, .notRunning, "Settings exited after opening \(name)")
    }
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

    selectEachPopUpOption([
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

    clickTab("Chinese Input", in: app)
    selectEachPopUpOption([
      "Natural Code",
      "Full Pinyin",
      "Flypy Double Pinyin",
      "Microsoft Double Pinyin",
      "Sogou Double Pinyin",
      "Intelligent ABC",
      "Ziguang Double Pinyin",
      "Jiajia Pinyin",
    ], in: app)
    selectEachPopUpOption([
      "Enhanced learning (Recommended)",
      "Standard learning",
      "Turn off learning",
    ], in: app)
    selectEachPopUpOption(["Semicolon (;)", "Vertical bar (|)"], in: app)
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

    clickTab("Smart English", in: app)
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
    selectEachPopUpOption([
      "Smart complete",
      "Navigate candidates",
      "Pass to application",
    ], in: app)

  }

  @MainActor
  func testCloseGuardKeepsAndDiscardsDraft() throws {
    let app = try launchSettings()
    defer { app.terminate() }

    clickTab("Chinese Input", in: app)
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

    clickTab("Data", in: app)

    let checkAgain = app.buttons["Check Again"]
    try reveal(checkAgain, named: "Check Again", in: app)
    try waitUntilEnabled(checkAgain, timeout: 30)
    checkAgain.click()
    try waitUntilEnabled(checkAgain, timeout: 30)

    selectEachPopUpOption([
      "GitHub (Direct)",
      "GH-Proxy Public Mirror (Third-party)",
    ], identifier: "settings.data.downloadSource", in: app)
    XCTAssertTrue(app.links["Open GH-Proxy Service Information"].exists)
    selectEachPopUpOption(
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
    selectEachPopUpOption(
      ["GitHub (Direct)"],
      identifier: "settings.data.downloadSource",
      in: app)

    selectEachPopUpOption([
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

    let refresh = app.buttons["Refresh"]
    try reveal(refresh, named: "Refresh", in: app)
    refresh.click()
    try waitUntilEnabled(refresh, timeout: 10)
    try openAndCancelPanel(button: "Save…", title: "Export Linnet Diagnostics", in: app)

    XCTAssertTrue(app.buttons["Update Language Data"].exists)
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
    selectEachPopUpOption([
      "Follow System",
      "简体中文",
      "English",
    ], identifier: "settings.interfaceLanguage", in: app)
    XCTAssertNotEqual(app.state, .notRunning)
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

    let productsDirectory = Bundle(for: SettingsUITests.self).bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let settingsURL = productsDirectory
      .appending(path: "Linnet.app", directoryHint: .isDirectory)
      .appending(path: "Contents/Applications/Settings.app", directoryHint: .isDirectory)
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

  @MainActor
  private func clickTab(_ name: String, in app: XCUIApplication) {
    let tabLabel = name == "Smart English" ? "ABC" : name
    let candidates = [
      app.tabBars.buttons[tabLabel],
      app.radioButtons[tabLabel],
      app.buttons[tabLabel],
    ]
    for candidate in candidates where candidate.waitForExistence(timeout: 2) {
      candidate.click()
      return
    }
    XCTFail("Settings tab is unavailable: \(name)")
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
  ) {
    let predicate = NSPredicate(format: "value IN %@", options)
    for option in options {
      let popUp = identifier.map { app.popUpButtons[$0] }
        ?? app.popUpButtons.matching(predicate).firstMatch
      popUp.click()
      let menuItem = app.menuItems[option]
      XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "Missing menu item: \(option)")
      menuItem.click()
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
    for deltaY in [-600.0, 600.0] {
      for _ in 0..<12 {
        if element.exists, scrollView.exists {
          let viewport = scrollView.frame.insetBy(dx: 0, dy: 12)
          if element.isHittable, viewport.contains(element.frame) { return }
          scrollView.scroll(
            byDeltaX: 0,
            deltaY: element.frame.midY > viewport.midY ? -300 : 300)
        } else if scrollView.exists {
          scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
        }
      }
    }
    XCTFail("Settings control is unavailable: \(name)")
  }
}
