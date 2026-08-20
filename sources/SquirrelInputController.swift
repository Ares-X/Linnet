//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCount: UInt = 0

  struct CandidateItem: Equatable {
    let absoluteIndex: Int
    let page: Int
    let indexOnPage: Int
    let text: String
    let comment: String
    let selectionLabel: String?
  }

  struct CandidateSnapshot: Equatable {
    let items: [CandidateItem]
    let currentPage: Int
    let pageSize: Int
    let highlightedItemIndex: Int
    let isLastPage: Bool
    let canExpand: Bool
    let isExpanded: Bool
  }

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    // A Settings data transaction can keep this controller alive after
    // cleanup_all_sessions + finalize. Pass input through until Host has
    // initialized a fresh runtime; a stale session ID is never queried.
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    self.client ?= sender as? IMKTextInput
    guard ensureSession() else { return false }

    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }
    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // Match current Squirrel: some remote tools publish flagsChanged with a
      // non-modifier keyCode, so derive the changed modifier at this boundary.
      var keyCode = event.keyCode
      if !SquirrelKeycode.modifierKeycodes.contains(keyCode) {
        guard let inferred = SquirrelKeycode.inferModifierKeycode(from: changes) else {
          lastModifiers = modifiers
          rimeUpdate()
          handled = true
          break
        }
        keyCode = inferred
      }
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(
        keycode: keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // translate osx keyevents to rime keyevents; special physical keys do
      // not require a client-provided character payload.
      let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(
        keycode: keyCode, keychar: keyChars?.first,
        shift: modifiers.contains(.shift), caps: modifiers.contains(.capsLock))
      if rimeKeycode != UInt32(XK_VoidSymbol) {
        let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
        handled = processKey(rimeKeycode, modifiers: rimeModifiers)
        rimeUpdate()
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(absoluteIndex: Int) -> Bool {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput,
      session != 0,
      absoluteIndex >= 0
    else { return false }
    let success = rimeAPI.select_candidate(session, absoluteIndex)
    if success {
      rimeUpdate()
    }
    return success
  }

  /// Rebuilds the current candidate snapshot after a panel-only interaction,
  /// such as expanding or collapsing disclosure. It never edits Rime input.
  func refreshCandidatePresentation() {
    rimeUpdate()
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, session != 0 else { return false }
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, session != 0 else { return false }
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  /// Starts a controller modifier epoch from persistent hardware state.
  /// Momentary flags belong to the prior activation or Rime session generation
  /// and must not suppress the first real transition in the new epoch.
  func resetModifierEpoch() {
    lastModifiers = SquirrelKeycode.activationModifierBaseline(
      from: CGEventSource.flagsState(.combinedSessionState))
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.inputController = self
      panel.updateAppearance(client: client as? NSObjectProtocol)
    }
    // Activation itself has no flagsChanged event. Reset even while the Host
    // is suspended: this controller can remain active when runtime recovery
    // reopens the input gate without another activation callback.
    resetModifierEpoch()
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      session = 0
      return
    }
    guard ensureSession() else { return }
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
    // Establish the silent activation baseline before any user gesture. The
    // next schema change is then real interaction feedback, not discovery.
    rimeUpdate()
    NSApp.squirrelAppDelegate.inputSourceDidActivate(session: session)
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    createSession()
  }

  override func deactivateServer(_ sender: Any!) {
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    hidePalettes()
    let panel = NSApp.squirrelAppDelegate.panel
    if panel?.inputController === self {
      panel?.inputController = nil
      panel?.updateAppearance(client: nil)
    }
    commitComposition(sender)
    if !NSApp.squirrelAppDelegate.canAcceptRimeInput {
      session = 0
      clearChord()
    }
    client = nil
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
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
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      session = 0
      clearChord()
      return
    }
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    NSApp.squirrelAppDelegate.makeInputMenu(actionTarget: self)
  }

  @objc func openSettings() {
    NSApp.squirrelAppDelegate.openSettings()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      session = 0
      clearChord()
      return
    }
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      session = 0
      return
    }
    let app = client?.bundleIdentifier() ?? {
      Self.unknownAppCount &+= 1
      return "UnknownApp\(Self.unknownAppCount)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  /// Keeps one live librime generation behind every InputMethodKit callback.
  /// Configuration reload invalidates all engine sessions while controllers
  /// survive, so activation and the first key must share this recovery owner.
  func ensureSession() -> Bool {
    if session != 0, rimeAPI.find_session(session) { return true }
    createSession()
    return session != 0
  }

  func updateAppOptions() {
    guard session != 0, !currentApp.isEmpty else { return }
    for (key, value) in NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) ?? [:] {
      print("set app option: \(key) = \(value)")
      rimeAPI.set_option(session, key, value)
    }
  }

  func destroySession() {
    defer { clearChord() }
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      session = 0
      return
    }
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, session != 0 else { return false }

    if let shortcut = printablePagingKey(rimeKeycode),
      (rimeModifiers & ~kLockMask.rawValue) == 0,
      let action = printablePagingAction(shortcut)
    {
      return rimeAPI.change_page(
        session,
        action == .pageUp)
    }

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      // with vertical text, arrow keys may behave differently.
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  private func printablePagingKey(
    _ rimeKeycode: UInt32
  ) -> LinnetCandidatePresentation.PrintablePagingKey? {
    switch Int32(rimeKeycode) {
    case XK_minus: .minus
    case XK_equal: .equal
    case XK_bracketleft: .leftBracket
    case XK_bracketright: .rightBracket
    default: nil
    }
  }

  private func printablePagingAction(
    _ shortcut: LinnetCandidatePresentation.PrintablePagingKey
  ) -> LinnetCandidatePresentation.CandidateControlAction? {
    var context = RimeContext_stdbool.rimeStructInit()
    guard rimeAPI.get_context(session, &context) else { return nil }
    defer { _ = rimeAPI.free_context(&context) }
    guard let page = Int(exactly: context.menu.page_no),
      let candidateCount = Int(exactly: context.menu.num_candidates)
    else { return nil }
    return LinnetCandidatePresentation.printablePagingAction(
      key: shortcut,
      hasModifiers: false,
      hasActiveInput: context.composition.length > 0,
      currentPage: page,
      isLastPage: context.menu.is_last_page,
      candidateCount: candidateCount)
  }

  func rimeConsumeCommittedText() {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, session != 0 else { return }
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  func candidateSnapshot(
    context: RimeContext_stdbool,
    labels: [String],
    expansionRequested: Bool
  ) -> CandidateSnapshot? {
    guard let currentPage = Int(exactly: context.menu.page_no),
      let pageSize = Int(exactly: context.menu.page_size),
      let currentCount = Int(exactly: context.menu.num_candidates),
      let highlightedOnPage = Int(exactly: context.menu.highlighted_candidate_index),
      pageSize > 0,
      currentCount >= 0,
      highlightedOnPage >= 0,
      let expandedBounds = LinnetCandidatePresentation.expandedCandidateRange(
        page: currentPage, pageSize: pageSize)
    else { return nil }

    let hasActiveInput = context.composition.length > 0
    let pageStart = expandedBounds.lowerBound
    var compactItems = [CandidateItem]()
    compactItems.reserveCapacity(currentCount)
    for indexOnPage in 0..<currentCount {
      let candidate = context.menu.candidates[indexOnPage]
      compactItems.append(CandidateItem(
        absoluteIndex: pageStart + indexOnPage,
        page: currentPage,
        indexOnPage: indexOnPage,
        text: candidate.text.map { String(cString: $0) } ?? "",
        comment: candidate.comment.map { String(cString: $0) } ?? "",
        selectionLabel: hasActiveInput
          ? candidateSelectionLabel(at: indexOnPage, labels: labels) : nil
      ))
    }
    let compactHighlighted = min(highlightedOnPage, max(0, compactItems.count - 1))
    let compact = CandidateSnapshot(
      items: compactItems,
      currentPage: currentPage,
      pageSize: pageSize,
      highlightedItemIndex: compactHighlighted,
      isLastPage: context.menu.is_last_page,
      canExpand: !context.menu.is_last_page,
      isExpanded: false)
    guard expansionRequested,
      let iteratorStart = Int32(exactly: expandedBounds.lowerBound)
    else { return compact }

    var iterator = RimeCandidateListIterator()
    guard rimeAPI.candidate_list_from_index(session, &iterator, iteratorStart) else {
      return compact
    }
    defer { rimeAPI.candidate_list_end(&iterator) }

    var expandedItems = [CandidateItem]()
    expandedItems.reserveCapacity(expandedBounds.count)
    while expandedItems.count < expandedBounds.count,
      rimeAPI.candidate_list_next(&iterator)
    {
      let absoluteIndex = Int(iterator.index)
      guard expandedBounds.contains(absoluteIndex) else { break }
      let page = absoluteIndex / pageSize
      let indexOnPage = absoluteIndex % pageSize
      expandedItems.append(CandidateItem(
        absoluteIndex: absoluteIndex,
        page: page,
        indexOnPage: indexOnPage,
        text: iterator.candidate.text.map { String(cString: $0) } ?? "",
        comment: iterator.candidate.comment.map { String(cString: $0) } ?? "",
        selectionLabel: page == currentPage && hasActiveInput
          ? candidateSelectionLabel(at: indexOnPage, labels: labels) : nil
      ))
    }
    let highlightedAbsolute = pageStart + highlightedOnPage
    guard !expandedItems.isEmpty,
      let expandedHighlighted = expandedItems.firstIndex(where: {
        $0.absoluteIndex == highlightedAbsolute
      })
    else { return compact }
    return CandidateSnapshot(
      items: expandedItems,
      currentPage: currentPage,
      pageSize: pageSize,
      highlightedItemIndex: expandedHighlighted,
      isLastPage: context.menu.is_last_page,
      canExpand: !context.menu.is_last_page,
      isExpanded: true)
  }

  func candidateSelectionLabel(at index: Int, labels: [String]) -> String {
    if labels.count > 1, labels.indices.contains(index) {
      return labels[index]
    }
    if let customLabels = labels.first, labels.count == 1,
      index >= 0, index < customLabels.count
    {
      return String(customLabels[customLabels.index(customLabels.startIndex, offsetBy: index)])
    }
    return String(index + 1)
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput, session != 0 else {
      session = 0
      clearChord()
      hidePalettes()
      return
    }
    // print("[DEBUG] rimeUpdate")
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      let liveSchemaID = status.schema_id.map { String(cString: $0) }
      // enable schema specific ui style
      if let liveSchemaID, schemaId == "" || schemaId != liveSchemaID {
        let modeLabel = LinnetCandidatePresentation.inputModeTransitionLabel(
          previousSchemaID: schemaId.isEmpty ? nil : schemaId,
          currentSchemaID: liveSchemaID)
        schemaId = liveSchemaID
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        // inline preedit
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          // if not inline, embed soft cursor in preedit string
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
        if let modeLabel, let panel = NSApp.squirrelAppDelegate.panel {
          panel.updateStatus(long: modeLabel, short: modeLabel)
        }
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
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
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
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
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
      guard let candidateSnapshot = candidateSnapshot(
        context: ctx,
        labels: labels,
        expansionRequested: expansionRequested)
      else {
        _ = rimeAPI.free_context(&ctx)
        hidePalettes()
        return
      }

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(
        preedit: inlinePreedit ? "" : preedit,
        selRange: selRange,
        caretPos: caretPos.utf16Offset(in: preedit),
        candidates: candidateSnapshot)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }

    let forceMarkedText =
      session != 0 &&
      rimeAPI.get_option(session, "force_marked_text_for_direct_commit")

    // Some NSTextInputClient implementations accept a direct Rime commit only
    // after a marked-text phase. This is the upstream Squirrel opt-in path;
    // ordinary clients keep the standard direct insert.
    if forceMarkedText && preedit.isEmpty && !string.isEmpty {
      let markedText = NSMutableAttributedString(string: string)
      client.setMarkedText(
        markedText,
        selectionRange: NSRange(location: markedText.length, length: 0),
        replacementRange: .empty
      )
    }

    // print("[DEBUG] commitString: \(string)")
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
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
  }

  func showPanel(
    preedit: String,
    selRange: NSRange,
    caretPos: Int,
    candidates: CandidateSnapshot
  ) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.updateAppearance(client: client as? NSObjectProtocol)
      panel.updatePosition(inputPos)
      panel.inputController = self
      panel.update(
        preedit: preedit,
        selRange: selRange,
        caretPos: caretPos,
        candidates: candidates,
        highlighted: candidates.highlightedItemIndex,
        update: true)
    }
  }
}
