//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  static let keyRollOver = 50
  static var unknownAppCount: UInt = 0

  weak var client: IMKTextInput?
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var modifierTransitions = SquirrelModifierTransitionState(hardwareFlags: [])
  private var activationToken: LinnetInputActivationRegistry.Token?
  var readyActivationToken: LinnetInputActivationRegistry.Token?
  var sessionLease: LinnetRimeSessionLease?
  var session: RimeSessionId { sessionLease?.identifier ?? 0 }
  private var inputModeIdentity: LinnetCandidatePresentation.InputModeIdentity?
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  var chordKeyCount: Int = 0
  var chordTimer: Timer?
  var chordDuration: TimeInterval = 0
  var currentApp: String = ""

  // InputMethodKit ingress; stateful decisions remain in their typed owners.
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event,
      let senderClient = sender as? IMKTextInput,
      let inputToken = activeInputToken,
      inputActivationIsCurrent(inputToken, client: senderClient)
    else { return false }
    // A Settings data transaction can keep this controller alive after
    // cleanup_all_sessions + finalize. Pass input through until Host has
    // initialized a fresh runtime; a stale session ID is never queried.
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else { return false }
    let modifiers = event.modifierFlags

    if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
      handleCompositionMouseDown(
        event: event,
        client: senderClient,
        activationToken: inputToken)
      return false
    }

    guard ensureReadySession(for: inputToken),
      inputActivationIsCurrent(inputToken, client: senderClient)
    else { return false }

    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }
    return dispatchReadyEvent(
      event,
      modifiers: modifiers,
      activationToken: inputToken)
  }

  /// Dispatches an event only after the active client and Rime lease have been
  /// validated by `handle`. It owns no activation or recovery fallback.
  private func dispatchReadyEvent(
    _ event: NSEvent,
    modifiers: NSEvent.ModifierFlags,
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Bool {
    switch event.type {
    case .flagsChanged:
      for transition in modifierTransitions.transitions(
        keyCode: event.keyCode,
        modifiers: modifiers
      ) {
        _ = processKey(
          transition.keycode,
          modifiers: transition.modifiers,
          activationToken: activationToken)
      }
      rimeUpdate()
      return false

    case .keyDown:
      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // translate osx keyevents to rime keyevents; special physical keys do
      // not require a client-provided character payload.
      let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(
        keycode: keyCode, keychar: keyChars?.first,
        shift: modifiers.contains(.shift), caps: modifiers.contains(.capsLock))
      if rimeKeycode != UInt32(XK_VoidSymbol) {
        let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
        let handled = processKey(
          rimeKeycode,
          modifiers: rimeModifiers,
          activationToken: activationToken)
        rimeUpdate()
        return handled
      }
      return false

    default:
      return false
    }
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    return Int(NSEvent.EventTypeMask.Element(
      arrayLiteral: .keyDown, .flagsChanged,
      .leftMouseDown, .rightMouseDown, .otherMouseDown).rawValue)
  }

  override func mouseDown(
    onCharacterIndex index: Int,
    coordinate point: NSPoint,
    withModifier flags: Int,
    continueTracking keepTracking: UnsafeMutablePointer<ObjCBool>!,
    client sender: Any!
  ) -> Bool {
    keepTracking?.pointee = false
    guard let inputToken = activeInputToken,
      let targetClient = sender as? IMKTextInput,
      inputActivationIsCurrent(inputToken, client: targetClient)
    else { return false }
    commitCompositionIfClickIsOutside(
      characterIndex: index,
      client: targetClient,
      activationToken: inputToken)
    // The click still belongs to the host application; committing composition
    // must never swallow its caret/selection action.
    return false
  }

  override func activateServer(_ sender: Any!) {
    guard let activatingClient = sender as? IMKTextInput,
      let activationToken = NSApp.squirrelAppDelegate.beginInputActivation(
        controller: self, client: activatingClient)
    else { return }
    self.activationToken = activationToken
    readyActivationToken = nil
    inputModeIdentity = nil
    client = activatingClient
    // This callback precedes the first event even when Rime is temporarily
    // suspended. Rebasing during recovery from the first flagsChanged event
    // would sample post-event hardware and swallow that Shift/Caps gesture.
    resetModifierEpoch()
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.bind(controller: self, activationToken: activationToken)
      panel.updateAppearance(client: client as? NSObjectProtocol)
    }
    guard inputActivationIsCurrent(activationToken) else { return }
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      retireSessionLease()
      return
    }
    guard ensureReadySession(for: activationToken) else { return }
    let configuredLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout")
    if let keyboardLayout = LinnetInputActivationPolicy.keyboardLayoutName(
      configured: configuredLayout) {
      activatingClient.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    guard inputActivationIsCurrent(activationToken) else { return }
    preedit = ""
    // Establish the silent activation baseline before any user gesture. The
    // next schema change is then real interaction feedback, not discovery.
    rimeUpdate()
    guard inputActivationIsCurrent(activationToken) else { return }
    NSApp.squirrelAppDelegate.inputSourceDidActivate(
      activationToken: activationToken,
      session: session)
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    super.init(server: server, delegate: delegate, client: client)
    createSession()
  }

  override func deactivateServer(_ sender: Any!) {
    guard let deactivatingClient = sender as? IMKTextInput else { return }
    NSApp.squirrelAppDelegate.finishInputActivation(
      controller: self, client: deactivatingClient)
  }

  func activationDidClose(
    _ token: LinnetInputActivationRegistry.Token,
    client closingClient: IMKTextInput?
  ) {
    guard activationToken == token else { return }
    activationToken = nil
    readyActivationToken = nil
    inputModeIdentity = nil
    clearChord()
    NSApp.squirrelAppDelegate.panel?.unbind(
      controller: self, activationToken: token)
    commitRawComposition(to: closingClient)
    // insertText can synchronously re-enter activateServer for a new client.
    // The retiring generation must not clear that replacement client.
    if activationToken == nil {
      client = nil
    }
  }

  override func hidePalettes() {
    if let activationToken {
      NSApp.squirrelAppDelegate.panel?.hide(
        controller: self, activationToken: activationToken)
    }
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    guard let inputToken = activeInputToken,
      let targetClient = sender as? IMKTextInput,
      inputActivationIsCurrent(inputToken, client: targetClient)
    else { return }
    commitActiveComposition(
      to: targetClient,
      activationToken: inputToken)
  }

  func commitCurrentComposition() {
    guard let inputToken = activeInputToken,
      let targetClient = client,
      inputActivationIsCurrent(inputToken, client: targetClient)
    else { return }
    commitActiveComposition(
      to: targetClient,
      activationToken: inputToken)
  }

  override func menu() -> NSMenu! {
    NSApp.squirrelAppDelegate.makeInputMenu(actionTarget: self)
  }

  @objc func openSettings() {
    NSApp.squirrelAppDelegate.openSettings()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    NSApp.squirrelAppDelegate.finishInputActivation(token: activationToken)
    destroySession()
  }
}

extension SquirrelInputController {
  var activeInputToken: LinnetInputActivationRegistry.Token? {
    guard let activationToken, inputActivationIsCurrent(activationToken)
    else { return nil }
    return activationToken
  }

  func inputActivationIsCurrent(
    _ token: LinnetInputActivationRegistry.Token,
    client expectedClient: IMKTextInput? = nil
  ) -> Bool {
    let registry = NSApp.squirrelAppDelegate.inputActivationRegistry
    if let expectedClient {
      return registry.isCurrent(
        token, controller: self, client: expectedClient)
    }
    return registry.isCurrent(token, controller: self)
  }

  func currentSessionLease(
    matching expectedSession: RimeSessionId,
    activationToken: LinnetInputActivationRegistry.Token
  ) -> LinnetRimeSessionLease? {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput,
      inputActivationIsCurrent(activationToken),
      let sessionLease,
      sessionLease.identifier == expectedSession,
      sessionLease.isCurrent(sessionExists: { rimeAPI.find_session($0) })
    else { return nil }
    return sessionLease
  }

  func ownsCurrentSession(
    _ expectedLease: LinnetRimeSessionLease,
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Bool {
    NSApp.squirrelAppDelegate.canAcceptRimeInput &&
      inputActivationIsCurrent(activationToken) &&
      sessionLease == expectedLease &&
      expectedLease.isCurrent(sessionExists: { rimeAPI.find_session($0) })
  }

  private func handleCompositionMouseDown(
    event: NSEvent,
    client targetClient: IMKTextInput,
    activationToken: LinnetInputActivationRegistry.Token
  ) {
    let screenPoint = event.window?.convertPoint(
      toScreen: event.locationInWindow) ?? event.locationInWindow
    var insideMarkedRange = ObjCBool(false)
    let index = targetClient.characterIndex(
      for: screenPoint,
      tracking: kIMKNearestBoundaryMode,
      inMarkedRange: &insideMarkedRange)
    guard inputActivationIsCurrent(activationToken, client: targetClient)
    else { return }
    commitCompositionIfClickIsOutside(
      characterIndex: index,
      spatiallyInsideMarkedRange: insideMarkedRange.boolValue,
      client: targetClient,
      activationToken: activationToken)
  }

  private func commitCompositionIfClickIsOutside(
    characterIndex: Int,
    spatiallyInsideMarkedRange: Bool? = nil,
    client targetClient: IMKTextInput,
    activationToken: LinnetInputActivationRegistry.Token
  ) {
    let markedRange = targetClient.markedRange()
    guard inputActivationIsCurrent(activationToken, client: targetClient),
      LinnetInputActivationPolicy.shouldCommitCompositionForClick(
        characterIndex: characterIndex,
        markedRange: markedRange,
        spatiallyInsideMarkedRange: spatiallyInsideMarkedRange)
    else { return }
    commitActiveComposition(
      to: targetClient,
      activationToken: activationToken)
  }

  /// Starts a controller modifier epoch from persistent hardware state.
  /// Momentary flags belong to the prior activation or Rime session generation
  /// and must not suppress the first real transition in the new epoch.
  func resetModifierEpoch() {
    modifierTransitions.reset(
      from: CGEventSource.flagsState(.combinedSessionState))
  }

  /// Reconciles only the ASCII mode previously owned by physical Caps Lock.
  /// App-specific or schema-specific ASCII choices remain authoritative when
  /// Caps Lock is off.
  func synchronizeCapsLockBaseline() {
    guard sessionIsCurrent() else { return }
    let property = LinnetInputActivationPolicy.capsLockOwnershipProperty
    var ownershipValue = [CChar](repeating: 0, count: 2)
    let previouslyOwned = property.withCString { propertyName in
      ownershipValue.withUnsafeMutableBufferPointer { buffer in
        rimeAPI.get_property(
          session, propertyName, buffer.baseAddress, buffer.count)
      }
    }
    let hardwareFlags = CGEventSource.flagsState(.combinedSessionState)
    let baseline = LinnetInputActivationPolicy.capsLockBaseline(
      capsLockActive: hardwareFlags.contains(.maskAlphaShift),
      previouslyOwnedAsciiMode: previouslyOwned)
    if let asciiMode = baseline.asciiMode,
      rimeAPI.get_option(session, "ascii_mode") != asciiMode {
      rimeAPI.set_option(session, "ascii_mode", asciiMode)
    }
    guard previouslyOwned || baseline.ownsAsciiMode else { return }
    property.withCString { propertyName in
      (baseline.ownsAsciiMode ? "1" : "").withCString { value in
        rimeAPI.set_property(session, propertyName, value)
      }
    }
  }

  /// Applies the recovered session's schema-dependent presentation before the
  /// triggering event, without reporting recovery itself as a mode switch.
  func synchronizeRecoveredInputMode(
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Bool {
    guard sessionIsCurrent() else { return false }
    var status = RimeStatus_stdbool.rimeStructInit()
    guard rimeAPI.get_status(session, &status) else { return false }
    defer { _ = rimeAPI.free_status(&status) }
    guard let schemaID = status.schema_id.map({ String(cString: $0) }),
      !schemaID.isEmpty
    else { return false }
    let currentIdentity = LinnetCandidatePresentation.InputModeIdentity(
      schemaID: schemaID,
      asciiMode: status.is_ascii_mode)
    return applyInputModeIdentity(
      currentIdentity,
      activationToken: activationToken,
      announcesTransition: false) != nil
  }

  /// Owns both the live mode identity and every schema-dependent presentation
  /// projection. Callers choose only whether this real state transition should
  /// be announced; they never reimplement schema setup.
  func applyInputModeIdentity(
    _ currentIdentity: LinnetCandidatePresentation.InputModeIdentity,
    activationToken: LinnetInputActivationRegistry.Token,
    announcesTransition: Bool
  ) -> Bool? {
    let previousIdentity = inputModeIdentity
    let modeLabel = announcesTransition
      ? LinnetCandidatePresentation.inputModeTransitionLabel(
        previous: previousIdentity,
        current: currentIdentity)
      : nil
    let schemaChanged = previousIdentity?.schemaID != currentIdentity.schemaID
    inputModeIdentity = currentIdentity
    if schemaChanged {
      NSApp.squirrelAppDelegate.loadSettings(for: currentIdentity.schemaID)
      guard inputActivationIsCurrent(activationToken) else { return nil }
      if let panel = NSApp.squirrelAppDelegate.panel {
        inlinePreedit =
          (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) ||
          rimeAPI.get_option(session, "inline")
        inlineCandidate =
          panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
        rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
      }
    }
    if let modeLabel, let panel = NSApp.squirrelAppDelegate.panel {
      panel.updateStatus(
        long: modeLabel,
        short: modeLabel,
        activationToken: activationToken)
    }
    return modeLabel != nil
  }

  var hasPendingRimeInput: Bool {
    guard activeInputToken != nil,
      sessionIsCurrent(), let input = rimeAPI.get_input(session)
    else { return false }
    return input.pointee != 0
  }

  /// Touches only the current lease immediately before librime reaps orphaned
  /// sessions. It never creates a session or changes composition state.
  func refreshSessionLeaseForStaleCleanup() {
    guard activeInputToken != nil else { return }
    _ = sessionIsCurrent()
  }

  /// Rime's upstream synchronization owns session cleanup. Retire this
  /// controller's stale generation before that maintenance boundary.
  func prepareForRimeMaintenance() {
    retireSessionLease()
    preedit = ""
    clearChord()
    hidePalettes()
  }
}

extension SquirrelInputController {

  private func rimeConsumeCommittedText(to targetClient: IMKTextInput?) {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, sessionIsCurrent() else { return }
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text), to: targetClient)
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  private func commitRawComposition(to targetClient: IMKTextInput?) {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      retireSessionLease()
      clearChord()
      return
    }
    guard sessionIsCurrent() else { return }
    _ = rimeAPI.commit_raw_input(session)
    rimeConsumeCommittedText(to: targetClient)
  }

  /// The single active-session exit. Rime owns raw-input semantics; after a
  /// client callback, the originating activation must still be current before
  /// its candidate or passive prediction panel may be hidden.
  private func commitActiveComposition(
    to targetClient: IMKTextInput,
    activationToken: LinnetInputActivationRegistry.Token
  ) {
    guard inputActivationIsCurrent(activationToken, client: targetClient)
    else { return }
    clearChord()
    commitRawComposition(to: targetClient)
    guard inputActivationIsCurrent(activationToken, client: targetClient)
    else { return }
    NSApp.squirrelAppDelegate.panel?.hide(
      controller: self,
      activationToken: activationToken)
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    guard let updateToken = activeInputToken else { return }
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, sessionIsCurrent() else {
      retireSessionLease()
      clearChord()
      hidePalettes()
      return
    }
    rimeConsumeCommittedText(to: client)
    guard inputActivationIsCurrent(updateToken) else { return }

    var presentsModeTransition = false
    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      let liveSchemaID = status.schema_id.map { String(cString: $0) }
      if let liveSchemaID {
        let currentIdentity = LinnetCandidatePresentation.InputModeIdentity(
          schemaID: liveSchemaID,
          asciiMode: status.is_ascii_mode)
        guard let transition = applyInputModeIdentity(
          currentIdentity,
          activationToken: updateToken,
          announcesTransition: true)
        else {
          _ = rimeAPI.free_status(&status)
          return
        }
        presentsModeTransition = transition
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""
      guard let selectionStart = Int(exactly: ctx.composition.sel_start),
        let selectionEnd = Int(exactly: ctx.composition.sel_end),
        let cursor = Int(exactly: ctx.composition.cursor_pos),
        let geometry = LinnetPreeditGeometry.resolve(
          in: preedit,
          selectionStartUTF8Offset: selectionStart,
          selectionEndUTF8Offset: selectionEnd,
          cursorUTF8Offset: cursor)
      else {
        _ = rimeAPI.free_context(&ctx)
        hidePalettes()
        return
      }
      let start = geometry.selectionStart
      let end = geometry.selectionEnd
      let caretPos = geometry.cursor

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let committedPreviewEndUTF8Offset = candidatePreview.utf8.count
        if inlinePreedit {
          // The selected prefix is shared by preedit and commit preview; keep
          // the untranslated suffix that follows a caret moved into the code.
          if caretPos >= end && caretPos < preedit.endIndex {
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        guard let previewGeometry = LinnetPreeditGeometry.resolveCandidatePreview(
          in: candidatePreview,
          selectionStartUTF8Offset: selectionStart,
          cursorUTF8Offset: cursor,
          committedPreviewEndUTF8Offset: committedPreviewEndUTF8Offset)
        else {
          _ = rimeAPI.free_context(&ctx)
          hidePalettes()
          return
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$. The geometry owner validates the shared
        // prefix and resolves fresh indices in the final preview string.
        let start = previewGeometry.selectionStart
        let caretPos = previewGeometry.cursor
        guard show(
          preedit: candidatePreview,
          selRange: NSRange(
            location: start.utf16Offset(in: candidatePreview),
            length: candidatePreview.utf16.distance(
              from: start, to: candidatePreview.endIndex)),
          caretPos: caretPos.utf16Offset(in: candidatePreview),
          activationToken: updateToken)
        else {
          _ = rimeAPI.free_context(&ctx)
          return
        }
      } else {
        if inlinePreedit {
          guard show(
            preedit: preedit,
            selRange: NSRange(
              location: start.utf16Offset(in: preedit),
              length: preedit.utf16.distance(from: start, to: end)),
            caretPos: caretPos.utf16Offset(in: preedit),
            activationToken: updateToken)
          else {
            _ = rimeAPI.free_context(&ctx)
            return
          }
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          guard show(
            preedit: preedit.isEmpty ? "" : "　",
            selRange: NSRange(location: 0, length: 0),
            caretPos: 0,
            activationToken: updateToken)
          else {
            _ = rimeAPI.free_context(&ctx)
            return
          }
        }
      }

      // Update candidates. Rime owns the active page and candidate order;
      // disclosure may only read a bounded absolute slice from that page.
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let expansionRequested =
        NSApp.squirrelAppDelegate.panel?.candidateExpansionRequested ?? false
      guard let candidateSnapshot = LinnetRimeCandidateSnapshotBuilder.build(
        context: ctx,
        labels: labels,
        expansionRequested: expansionRequested,
        session: session,
        rimeAPI: rimeAPI)
      else {
        _ = rimeAPI.free_context(&ctx)
        hidePalettes()
        return
      }
      if preedit.isEmpty,
        candidateSnapshot.items.isEmpty,
        !presentsModeTransition {
        _ = rimeAPI.free_context(&ctx)
        NSApp.squirrelAppDelegate.panel?.handlePassiveEmptyUpdate(
          controller: self,
          activationToken: updateToken)
        return
      }
      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      guard showPanel(
        preedit: inlinePreedit ? "" : preedit,
        selRange: selRange,
        caretPos: caretPos.utf16Offset(in: preedit),
        candidates: candidateSnapshot,
        activationToken: updateToken)
      else {
        _ = rimeAPI.free_context(&ctx)
        return
      }
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  private func commit(string: String, to targetClient: IMKTextInput?) {
    guard let targetClient else { return }
    let forceMarkedText =
      sessionIsCurrent() &&
      rimeAPI.get_option(session, "force_marked_text_for_direct_commit")
    let beginsMarkedText = forceMarkedText && preedit.isEmpty && !string.isEmpty
    preedit = ""

    // Some NSTextInputClient implementations accept a direct Rime commit only
    // after a marked-text phase. This is the upstream Squirrel opt-in path;
    // ordinary clients keep the standard direct insert.
    if beginsMarkedText {
      let markedText = NSMutableAttributedString(string: string)
      targetClient.setMarkedText(
        markedText,
        selectionRange: NSRange(location: markedText.length, length: 0),
        replacementRange: .empty
      )
    }

    targetClient.insertText(string, replacementRange: .empty)
  }

  private func show(
    preedit: String,
    selRange: NSRange,
    caretPos: Int,
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Bool {
    guard let client,
      inputActivationIsCurrent(activationToken, client: client)
    else {
      return false
    }
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return true
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(
        forStyle: kTSMHiliteConvertedText,
        at: NSRange(location: 0, length: start)
      ) as? [NSAttributedString.Key: Any] ?? [:]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(
      forStyle: kTSMHiliteSelectedRawText,
      at: remainingRange
    ) as? [NSAttributedString.Key: Any] ?? [:]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
    guard inputActivationIsCurrent(activationToken, client: client) else {
      return false
    }
    return true
  }

  private func showPanel(
    preedit: String,
    selRange: NSRange,
    caretPos: Int,
    candidates: CandidateSnapshot,
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Bool {
    guard let client,
      inputActivationIsCurrent(activationToken, client: client)
    else {
      return false
    }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    guard inputActivationIsCurrent(activationToken, client: client) else {
      return false
    }
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.bind(controller: self, activationToken: activationToken)
      panel.updateAppearance(client: client as? NSObjectProtocol)
      guard inputActivationIsCurrent(activationToken, client: client) else {
        return false
      }
      panel.updatePosition(inputPos)
      guard panel.update(
        preedit: preedit,
        selRange: selRange,
        caretPos: caretPos,
        candidates: candidates,
        highlighted: candidates.highlightedItemIndex,
        update: true,
        activationToken: activationToken)
      else { return false }
    }
    guard inputActivationIsCurrent(activationToken, client: client) else {
      return false
    }
    return true
  }
}
