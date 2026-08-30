//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import Carbon
import InputMethodKit

final class SquirrelInputController: IMKInputController {
  static let keyRollOver = 50
  static var unknownAppCount: UInt = 0

  weak var activeClient: IMKTextInput?
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var modifierTransitions = SquirrelModifierTransitionState(hardwareFlags: [])
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
      let senderClient = sender as? IMKTextInput
    else { return false }
    activeClient = senderClient
    // A Settings data transaction can keep this controller alive after
    // cleanup_all_sessions + finalize. Pass input through until Host has
    // initialized a fresh runtime; a stale session ID is never queried.
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else { return false }
    let modifiers = event.modifierFlags

    if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
      handleCompositionMouseDown(
        event: event,
        client: senderClient)
      return false
    }

    guard ensureReadySession(for: senderClient) else { return false }

    if let app = senderClient.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }
    return dispatchReadyEvent(
      event,
      modifiers: modifiers)
  }

  /// Dispatches an event only after the active client and Rime lease have been
  /// validated by `handle`. It owns no activation or recovery fallback.
  private func dispatchReadyEvent(
    _ event: NSEvent,
    modifiers: NSEvent.ModifierFlags
  ) -> Bool {
    switch event.type {
    case .flagsChanged:
      for transition in modifierTransitions.transitions(
        keyCode: event.keyCode,
        modifiers: modifiers
      ) {
        _ = processKey(
          transition.keycode,
          modifiers: transition.modifiers)
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
          modifiers: rimeModifiers)
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
    guard let targetClient = sender as? IMKTextInput else { return false }
    activeClient = targetClient
    commitCompositionIfClickIsOutside(
      characterIndex: index,
      client: targetClient)
    // The click still belongs to the host application; committing composition
    // must never swallow its caret/selection action.
    return false
  }

  override func activateServer(_ sender: Any!) {
    guard let activatingClient = sender as? IMKTextInput else { return }
    inputModeIdentity = nil
    activeClient = activatingClient
    // This callback precedes the first event even when Rime is temporarily
    // suspended. Rebasing during recovery from the first flagsChanged event
    // would sample post-event hardware and swallow that Shift/Caps gesture.
    resetModifierEpoch()
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.unbind(controller: self)
      panel.bind(controller: self)
      panel.updateAppearance(client: activatingClient as? NSObjectProtocol)
    }
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      retireSessionLease()
      return
    }
    guard ensureReadySession(for: activatingClient) else { return }
    let configuredLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout")
    if let keyboardLayout = LinnetInputActivationPolicy.keyboardLayoutName(
      configured: configuredLayout) {
      activatingClient.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
    // Establish the silent activation baseline before any user gesture. The
    // next schema change is then real interaction feedback, not discovery.
    rimeUpdate()
    NSApp.squirrelAppDelegate.inputSourceDidActivate(session: session)
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.activeClient = client as? IMKTextInput
    super.init(server: server, delegate: delegate, client: client)
    createSession(client: activeClient)
  }

  override func deactivateServer(_ sender: Any!) {
    guard let deactivatingClient = sender as? IMKTextInput else { return }
    inputModeIdentity = nil
    clearChord()
    // Retire the old client before calling back into it. A synchronous native
    // activation triggered by the commit then becomes the sole new owner.
    activeClient = nil
    NSApp.squirrelAppDelegate.panel?.unbind(controller: self)
    commitRawComposition(to: deactivatingClient)
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide(controller: self)
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
    guard let targetClient = sender as? IMKTextInput else { return }
    commitActiveComposition(to: targetClient)
  }

  func commitCurrentComposition() {
    guard let targetClient = activeClient else { return }
    commitActiveComposition(to: targetClient)
  }

  override func menu() -> NSMenu! {
    NSApp.squirrelAppDelegate.makeInputMenu(actionTarget: self)
  }

  @objc func openSettings() {
    NSApp.squirrelAppDelegate.openSettings()
  }

  deinit {
    destroySession()
  }
}

extension SquirrelInputController {
  func currentSessionLease(
    matching expectedSession: RimeSessionId
  ) -> LinnetRimeSessionLease? {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput,
      activeClient != nil,
      let sessionLease,
      sessionLease.identifier == expectedSession,
      sessionLease.isCurrent(sessionExists: { rimeAPI.find_session($0) })
    else { return nil }
    return sessionLease
  }

  func ownsCurrentSession(
    _ expectedLease: LinnetRimeSessionLease
  ) -> Bool {
    NSApp.squirrelAppDelegate.canAcceptRimeInput &&
      activeClient != nil &&
      sessionLease == expectedLease &&
      expectedLease.isCurrent(sessionExists: { rimeAPI.find_session($0) })
  }

  private func handleCompositionMouseDown(
    event: NSEvent,
    client targetClient: IMKTextInput
  ) {
    let screenPoint = event.window?.convertPoint(
      toScreen: event.locationInWindow) ?? event.locationInWindow
    var insideMarkedRange = ObjCBool(false)
    let index = targetClient.characterIndex(
      for: screenPoint,
      tracking: kIMKNearestBoundaryMode,
      inMarkedRange: &insideMarkedRange)
    commitCompositionIfClickIsOutside(
      characterIndex: index,
      spatiallyInsideMarkedRange: insideMarkedRange.boolValue,
      client: targetClient)
  }

  private func commitCompositionIfClickIsOutside(
    characterIndex: Int,
    spatiallyInsideMarkedRange: Bool? = nil,
    client targetClient: IMKTextInput
  ) {
    let markedRange = targetClient.markedRange()
    guard LinnetInputActivationPolicy.shouldCommitCompositionForClick(
        characterIndex: characterIndex,
        markedRange: markedRange,
        spatiallyInsideMarkedRange: spatiallyInsideMarkedRange)
    else { return }
    commitActiveComposition(to: targetClient)
  }

  /// Starts a controller modifier epoch from persistent hardware state.
  /// Momentary flags belong to the prior activation or Rime session generation
  /// and must not suppress the first real transition in the new epoch.
  func resetModifierEpoch() {
    modifierTransitions.reset(
      from: CGEventSource.flagsState(.combinedSessionState))
  }

  /// Applies the recovered session's schema-dependent presentation before the
  /// triggering event, without reporting recovery itself as a mode switch.
  func synchronizeRecoveredInputMode() -> Bool {
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
      announcesTransition: false)
  }

  /// Owns both the live mode identity and every schema-dependent presentation
  /// projection. Callers choose only whether this real state transition should
  /// be announced; they never reimplement schema setup.
  func applyInputModeIdentity(
    _ currentIdentity: LinnetCandidatePresentation.InputModeIdentity,
    announcesTransition: Bool
  ) -> Bool {
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
        controller: self)
    }
    return modeLabel != nil
  }

  var hasPendingRimeInput: Bool {
    guard activeClient != nil,
      sessionIsCurrent(), let input = rimeAPI.get_input(session)
    else { return false }
    return input.pointee != 0
  }

  /// Touches only the current lease immediately before librime reaps orphaned
  /// sessions. It never creates a session or changes composition state.
  func refreshSessionLeaseForStaleCleanup() {
    guard activeClient != nil else { return }
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

  /// The single active-session exit. Rime owns raw-input semantics; the panel
  /// independently rejects a hide from a controller it no longer presents.
  private func commitActiveComposition(to targetClient: IMKTextInput) {
    clearChord()
    commitRawComposition(to: targetClient)
    NSApp.squirrelAppDelegate.panel?.hide(controller: self)
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    guard let updateClient = activeClient else { return }
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, sessionIsCurrent() else {
      retireSessionLease()
      clearChord()
      hidePalettes()
      return
    }
    rimeConsumeCommittedText(to: updateClient)

    var presentsModeTransition = false
    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      let liveSchemaID = status.schema_id.map { String(cString: $0) }
      if let liveSchemaID {
        let currentIdentity = LinnetCandidatePresentation.InputModeIdentity(
          schemaID: liveSchemaID,
          asciiMode: status.is_ascii_mode)
        let transition = applyInputModeIdentity(
          currentIdentity,
          announcesTransition: true)
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
        show(
          preedit: candidatePreview,
          selRange: NSRange(
            location: start.utf16Offset(in: candidatePreview),
            length: candidatePreview.utf16.distance(
              from: start, to: candidatePreview.endIndex)),
          caretPos: caretPos.utf16Offset(in: candidatePreview),
          client: updateClient)
      } else {
        if inlinePreedit {
          show(
            preedit: preedit,
            selRange: NSRange(
              location: start.utf16Offset(in: preedit),
              length: preedit.utf16.distance(from: start, to: end)),
            caretPos: caretPos.utf16Offset(in: preedit),
            client: updateClient)
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(
            preedit: preedit.isEmpty ? "" : "　",
            selRange: NSRange(location: 0, length: 0),
            caretPos: 0,
            client: updateClient)
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
          controller: self)
        return
      }
      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(
        preedit: inlinePreedit ? "" : preedit,
        selRange: selRange,
        caretPos: caretPos.utf16Offset(in: preedit),
        candidates: candidateSnapshot,
        client: updateClient)
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
    client expectedClient: IMKTextInput
  ) {
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
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
    expectedClient.setMarkedText(
      attrString,
      selectionRange: NSRange(location: caretPos, length: 0),
      replacementRange: .empty)
  }

  private func showPanel(
    preedit: String,
    selRange: NSRange,
    caretPos: Int,
    candidates: CandidateSnapshot,
    client expectedClient: IMKTextInput
  ) {
    var inputPos = NSRect()
    expectedClient.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.bind(controller: self)
      guard panel.inputController === self else { return }
      panel.updateAppearance(client: expectedClient as? NSObjectProtocol)
      panel.updatePosition(inputPos)
      _ = panel.update(
        preedit: preedit,
        selRange: selRange,
        caretPos: caretPos,
        candidates: candidates,
        highlighted: candidates.highlightedItemIndex,
        update: true,
        controller: self)
    }
  }
}
