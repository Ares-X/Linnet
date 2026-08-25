import AppKit
import InputMethodKit
import UserNotifications

extension SquirrelApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    print("\(SquirrelApp.productName) is quitting.")
    return .terminateNow
  }
}

extension SquirrelApplicationDelegate {
  func beginInputActivation(
    controller: SquirrelInputController,
    client: IMKTextInput
  ) -> LinnetInputActivationRegistry.Token? {
    if SquirrelInstaller.currentInputSourceID() == SquirrelApp.bundleIdentifier {
      inputActivationRegistry.sourceDidTurnOn()
    }
    return inputActivationRegistry.begin(controller: controller, client: client) { [weak self] closed in
      self?.retireClosedInputActivation(closed)
    }
  }

  @discardableResult
  func finishInputActivation(
    controller: SquirrelInputController,
    client: IMKTextInput
  ) -> Bool {
    guard let closed = inputActivationRegistry.closeNative(
      controller: controller, client: client)
    else { return false }
    retireClosedInputActivation(closed)
    return true
  }

  @discardableResult
  func finishInputActivation(
    token: LinnetInputActivationRegistry.Token?
  ) -> Bool {
    guard let token, let closed = inputActivationRegistry.close(token) else {
      return false
    }
    retireClosedInputActivation(closed)
    return true
  }

  @discardableResult
  func finishInputSourceActivations() -> Bool {
    inputActivationRegistry.sourceDidTurnOff { [weak self] closed in
      self?.retireClosedInputActivation(closed)
    }
  }

  @discardableResult
  func terminateInputActivations() -> Bool {
    inputActivationRegistry.terminate { [weak self] closed in
      self?.retireClosedInputActivation(closed)
    }
  }

  private func retireClosedInputActivation(
    _ closed: LinnetInputActivationRegistry.ClosedActivation
  ) {
    (closed.controller as? SquirrelInputController)?.activationDidClose(
      closed.token,
      client: closed.client as? IMKTextInput)
  }

  func showStatusMessage(
    msgTextLong: String?,
    msgTextShort: String?,
    session: RimeSessionId
  ) {
    guard canAcceptRimeInput,
      !(msgTextLong ?? "").isEmpty || !(msgTextShort ?? "").isEmpty,
      let activationToken = inputActivationRegistry.currentToken,
      let controller = inputActivationRegistry.currentController(
        as: SquirrelInputController.self),
      controller.currentSessionLease(
        matching: session,
        activationToken: activationToken) != nil
    else { return }
    panel?.updateStatus(
      long: msgTextLong ?? "",
      short: msgTextShort ?? "",
      activationToken: activationToken)
  }

  func updateStatusIcon(session: RimeSessionId) {
    guard canAcceptRimeInput,
      let activationToken = inputActivationRegistry.currentToken,
      let controller = inputActivationRegistry.currentController(
        as: SquirrelInputController.self),
      let sessionLease = controller.currentSessionLease(
        matching: session,
        activationToken: activationToken)
    else { return }
    let asciiMode = rimeAPI.get_option(sessionLease.identifier, "ascii_mode")
    let schemaLabel = rimeAPI.get_state_label_abbreviated(
      sessionLease.identifier, "ascii_mode", asciiMode, true).asString
    DispatchQueue.main.async { [weak self, weak controller] in
      guard let self, let controller,
        controller.ownsCurrentSession(
          sessionLease, activationToken: activationToken)
      else { return }
      applyStatusIcon(asciiMode: asciiMode, schemaLabel: schemaLabel)
    }
  }

  func inputSourceDidActivate(
    activationToken: LinnetInputActivationRegistry.Token,
    session: RimeSessionId
  ) {
    guard inputActivationRegistry.isCurrent(activationToken) else { return }
    updateStatusIcon(session: session)
    setStatusItemVisibility(inputSourceIsActive: true)
  }

  func refreshStatusItem() {
    if showStatusIcon, statusItem == nil {
      setupStatusItem()
    } else if !showStatusIcon, let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      button.toolTip = SquirrelApp.productName
    }
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
    applyStatusIcon(asciiMode: false, schemaLabel: nil)
    updateStatusItemVisibility()
  }

  func applyStatusIcon(asciiMode: Bool, schemaLabel: String?) {
    let label = if let schemaLabel, !schemaLabel.isEmpty {
      schemaLabel
    } else {
      asciiMode ? "A" : "中"
    }
    currentModeLabel = label
    guard let button = statusItem?.button else { return }
    button.title = label
    button.toolTip = "\(SquirrelApp.productName) · \(label)"
    button.setAccessibilityLabel("\(SquirrelApp.productName), \(label)")
  }

  private func updateStatusItemVisibility() {
    setStatusItemVisibility(
      inputSourceIsActive:
        SquirrelInstaller.currentInputSourceID() == SquirrelApp.bundleIdentifier)
  }

  private func setStatusItemVisibility(inputSourceIsActive: Bool) {
    statusItem?.isVisible = showStatusIcon && inputSourceIsActive
  }

  @objc func inputSourceChanged(_: Notification) {
    guard let currentInputSourceID = SquirrelInstaller.currentInputSourceID() else { return }
    let inputSourceIsActive =
      currentInputSourceID == SquirrelApp.bundleIdentifier
    setStatusItemVisibility(inputSourceIsActive: inputSourceIsActive)
    if inputSourceIsActive {
      inputActivationRegistry.sourceDidTurnOn()
      return
    }
    // macOS may omit deactivateServer when another process selects an input
    // source through TIS. The process-wide owner closes the exact activation.
    finishInputSourceActivations()
  }

  // MARK: input menu

  // The same menu backs the input source menu (SquirrelInputController
  // .menu()) and the status-bar indicator's click menu.
  func makeInputMenu(actionTarget: AnyObject) -> NSMenu {
    let menu = NSMenu()
    for item in inputMenuItems(actionTarget: actionTarget) {
      menu.addItem(item)
    }
    return menu
  }

  private func inputMenuItems(actionTarget: AnyObject) -> [NSMenuItem] {
    let mode = NSMenuItem(
      title: "\(NSLocalizedString("Input mode", comment: "Menu status")): \(currentModeLabel)",
      action: nil,
      keyEquivalent: "")
    mode.isEnabled = false
    let settings = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openSettings), keyEquivalent: "")
    settings.target = actionTarget
    return [mode, .separator(), settings]
  }

  @objc func openSettings() {
    let settingsURL = Bundle.main.bundleURL
      .appending(path: "Contents/Applications/Settings.app", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: settingsURL.path) else {
      Self.showMessage(msgText: "Settings are unavailable in this build.")
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(
      at: settingsURL,
      configuration: configuration
    ) { _, error in
      if error != nil {
        Self.showMessage(msgText: "Settings could not be opened.")
      }
    }
  }

  static func showMessage(msgText: String?) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .provisional]) { _, error in
      if let error = error {
        print("User notification authorization error: \(error.localizedDescription)")
      }
    }
    center.getNotificationSettings { settings in
      if (settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional) && settings.alertSetting == .enabled {
        let content = UNMutableNotificationContent()
        content.title = SquirrelApp.productName
        if let msgText = msgText {
          content.subtitle = msgText
        }
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
          identifier: Self.notificationIdentifier, content: content, trigger: nil)
        center.add(request) { error in
          if let error = error {
            print("User notification request error: \(error.localizedDescription)")
          }
        }
      }
    }
  }

}

extension RimeStringSlice {
  var asString: String? {
    guard let str else { return nil }
    let data = Data(bytes: UnsafeRawPointer(str), count: Int(length))
    return String(data: data, encoding: .utf8)
  }
}

func notificationHandler(
  contextObject: UnsafeMutableRawPointer?, sessionId: RimeSessionId,
  messageTypeC: UnsafePointer<CChar>?, messageValueC: UnsafePointer<CChar>?
) {
  guard let contextObject else { return }
  let delegate = Unmanaged<SquirrelApplicationDelegate>.fromOpaque(contextObject)
    .takeUnretainedValue()

  let messageType = messageTypeC.map { String(cString: $0) }
  let messageValue = messageValueC.map { String(cString: $0) }
  if messageType == "deploy" {
    switch messageValue {
    case "start":
      SquirrelApplicationDelegate.showMessage(
        msgText: NSLocalizedString("deploy_start", comment: ""))
    case "success":
      SquirrelApplicationDelegate.showMessage(
        msgText: NSLocalizedString("deploy_success", comment: ""))
    case "failure":
      SquirrelApplicationDelegate.showMessage(
        msgText: NSLocalizedString("deploy_failure", comment: ""))
    default:
      break
    }
    return
  }
  if messageType == "option" {
    let state = messageValue?.first != "!"
    let optionName: String?
    if state {
      optionName = messageValue
    } else if let messageValue, !messageValue.isEmpty {
      optionName = String(messageValue.dropFirst())
    } else {
      optionName = nil
    }
    if let optionName = optionName {
      optionName.withCString { name in
        let shortLabel = delegate.rimeAPI.get_state_label_abbreviated(
          sessionId, name, state, true).asString
        let longLabel = delegate.rimeAPI.get_state_label_abbreviated(
          sessionId, name, state, false).asString
        if optionName == "ascii_mode" { delegate.updateStatusIcon(session: sessionId) }
        if delegate.enableNotifications, optionName != "ascii_mode" {
          delegate.showStatusMessage(
            msgTextLong: longLabel,
            msgTextShort: shortLabel,
            session: sessionId)
        }
      }
    }
    return
  }

  if messageType == "schema" {
    delegate.updateStatusIcon(session: sessionId)
  }
}

extension SquirrelApplicationDelegate: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    for item in inputMenuItems(actionTarget: self) {
      menu.addItem(item)
    }
  }
}

extension NSApplication {
  var squirrelAppDelegate: SquirrelApplicationDelegate {
    guard let delegate = self.delegate as? SquirrelApplicationDelegate else {
      SquirrelApp.configurationFailure("The application delegate contract is unavailable")
    }
    return delegate
  }
}
