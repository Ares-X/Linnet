import AppKit
import InputMethodKit
import UserNotifications

extension SquirrelApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    print("\(SquirrelApp.productName) is quitting.")
    return .terminateNow
  }

  func workspaceWillPowerOff(_: Notification) {
    print("Finalizing before logging out.")
    shutdownRime()
  }

  func rimeVersion() -> String {
    guard let value = rimeAPI.get_version() else { return "unknown" }
    return String(cString: value)
  }

  func coreActivationState(dataTransactionActive: Bool) -> (
    readiness: LinnetSettingsContract.CoreActivationReadiness,
    connectedClientCount: Int
  ) {
    let connectedClientCount = SquirrelInputController.connectedInputClientCount
    return (
      LinnetSettingsContract.coreActivationReadiness(
        inputSourceIsActive: SquirrelInstaller.currentInputSourceID() == SquirrelApp.bundleIdentifier,
        connectedInputClientCount: connectedClientCount,
        dataTransactionActive: dataTransactionActive
      ),
      connectedClientCount
    )
  }

  func activateInstalledCore(_ request: LinnetSettingsContract.DataRequest) {
    guard LinnetSettingsContract.requestCanContinue(request) else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .requesterUnavailable,
        detail: "The requester is unavailable or its deadline expired."
      )
      return
    }
    let health = runtimeHealth()
    guard health.coreActivationReadiness == .ready else {
      reply(
        to: request.transactionID,
        status: .rejected,
        code: .coreActivationBlocked,
        detail: "The input runtime is still in use.",
        health: health
      )
      return
    }
    reply(
      to: request.transactionID,
      status: .terminating,
      code: .coreActivationAccepted,
      detail: "The inactive Host accepted Core activation.",
      health: health
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard LinnetSettingsContract.requestCanContinue(request),
        self?.runtimeHealth().coreActivationReadiness == .ready
      else { return }
      NSApp.terminate(nil)
    }
  }
}

extension SquirrelApplicationDelegate {
  func showStatusMessage(
    msgTextLong: String?,
    msgTextShort: String?,
    session: RimeSessionId
  ) {
    guard canAcceptRimeInput,
      !(msgTextLong ?? "").isEmpty || !(msgTextShort ?? "").isEmpty,
      let controller = panel?.inputController,
      controller.currentSessionLease(matching: session) != nil
    else { return }
    panel?.updateStatus(
      long: msgTextLong ?? "",
      short: msgTextShort ?? "",
      controller: controller)
  }

  func updateStatusIcon(session: RimeSessionId) {
    guard canAcceptRimeInput,
      let controller = panel?.inputController,
      let sessionLease = controller.currentSessionLease(matching: session)
    else { return }
    let asciiMode = rimeAPI.get_option(sessionLease.identifier, "ascii_mode")
    let schemaLabel = rimeAPI.get_state_label_abbreviated(
      sessionLease.identifier, "ascii_mode", asciiMode, true).asString
    DispatchQueue.main.async { [weak self, weak controller] in
      guard let self, let controller,
        panel?.inputController === controller,
        controller.ownsCurrentSession(sessionLease)
      else { return }
      applyStatusIcon(asciiMode: asciiMode, schemaLabel: schemaLabel)
    }
  }

  func inputSourceDidActivate(session: RimeSessionId) {
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
    DispatchQueue.main.async { [weak self] in
      self?.updateStatusItemVisibility()
      self?.finalizeStrandedComposition()
    }
  }

  // macOS may omit deactivateServer when another process selects an input
  // source through TIS. Defer until the native transition settles, then close
  // only the token that was active before the switch. Native activateServer
  // remains the sole authority for admitting the returned input source.
  private func finalizeStrandedComposition() {
    guard SquirrelInstaller.currentInputSourceID() != SquirrelApp.bundleIdentifier else {
      return
    }
    guard let inputController = panel?.inputController,
      let activeClient = inputController.activeClient
    else { return }
    inputController.deactivateServer(activeClient)
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
