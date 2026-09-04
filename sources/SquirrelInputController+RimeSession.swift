//
//  SquirrelInputController+RimeSession.swift
//  Squirrel
//
//  Rime session-scoped input and candidate operations.
//

import InputMethodKit

extension SquirrelInputController {
  private static let candidateExpansionRequestProperty =
    "linnet/candidate_expansion_request_v1"

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

  func selectCandidate(absoluteIndex: Int) -> Bool {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput,
      activeClient != nil,
      sessionIsCurrent(),
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
    guard activeClient != nil else { return }
    rimeUpdate()
  }

  func page(up towardPreviousPage: Bool) -> Bool {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput,
      activeClient != nil, sessionIsCurrent()
    else { return false }
    let handled = rimeAPI.change_page(session, towardPreviousPage)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  private func onChordTimer(
    _: Timer,
    sessionLease: LinnetRimeSessionLease
  ) {
    guard activeClient != nil,
      self.sessionLease == sessionLease
    else { return }
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      retireSessionLease()
      clearChord()
      return
    }
    var processedKeys = false
    guard ownsCurrentSession(sessionLease)
    else {
      retireSessionLease()
      clearChord()
      return
    }
    if chordKeyCount > 0 {
      for index in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(
          sessionLease.identifier,
          Int32(chordKeyCodes[index]),
          Int32(chordModifiers[index] | kReleaseMask.rawValue))
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

  private func updateChord(
    keycode: UInt32,
    modifiers: UInt32
  ) {
    for index in 0..<chordKeyCount where chordKeyCodes[index] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble(
      "chord_duration"
    ), duration > 0 {
      chordDuration = duration
    }
    guard let sessionLease,
      ownsCurrentSession(sessionLease)
    else { return }
    chordTimer = Timer.scheduledTimer(
      withTimeInterval: chordDuration, repeats: false
    ) { [weak self] timer in
      self?.onChordTimer(
        timer,
        sessionLease: sessionLease)
    }
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

  func createSession(client sessionClient: IMKTextInput?) {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      retireSessionLease()
      return
    }
    let app = sessionClient?.bundleIdentifier() ?? {
      Self.unknownAppCount &+= 1
      return "UnknownApp\(Self.unknownAppCount)"
    }()
    print("createSession: \(app)")
    currentApp = app
    let identifier = rimeAPI.create_session()
    sessionLease = LinnetRimeSessionLease.acquire(identifier: identifier)

    if sessionIsCurrent() {
      updateAppOptions()
    }
  }

  func sessionIsCurrent() -> Bool {
    guard let sessionLease else { return false }
    return sessionLease.isCurrent(
      sessionExists: { rimeAPI.find_session($0) }
    )
  }

  func retireSessionLease() {
    sessionLease?.retire()
    sessionLease = nil
  }

  /// Recreates an invalid Rime session and restores only its presentation
  /// projection. Physical modifier state remains owned by macOS and Rime.
  func ensureReadySession(for expectedClient: IMKTextInput) -> Bool {
    let recoveredSession = !sessionIsCurrent()
    if recoveredSession {
      clearChord()
      retireSessionLease()
      createSession(client: expectedClient)
    }
    guard sessionIsCurrent() else { return false }
    if recoveredSession,
      !synchronizeRecoveredInputMode() {
      return false
    }
    return true
  }

  func updateAppOptions() {
    guard sessionIsCurrent(), !currentApp.isEmpty else { return }
    let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp)
    for (key, value) in appOptions ?? [:] {
      print("set app option: \(key) = \(value)")
      rimeAPI.set_option(session, key, value)
    }
  }

  func destroySession() {
    defer { clearChord() }
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      retireSessionLease()
      return
    }
    if sessionIsCurrent() {
      _ = rimeAPI.destroy_session(session)
    }
    retireSessionLease()
  }

  func processKey(
    _ rimeKeycode: UInt32,
    modifiers rimeModifiers: UInt32
  ) -> Bool {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput,
      activeClient != nil, sessionIsCurrent()
    else { return false }

    synchronizeCandidateLayoutOptions()
    let effectiveKeycode = effectiveRimeKeycode(for: rimeKeycode)
    let handled = rimeAPI.process_key(
      session,
      Int32(effectiveKeycode),
      Int32(rimeModifiers))
    consumeCandidateExpansionRequest()
    if handled {
      updateChordState(
        keycode: effectiveKeycode,
        modifiers: rimeModifiers)
    }
    return handled
  }

  /// Consumes the one-shot intent published by the canonical Rime key owner.
  /// This boundary does not infer which physical key caused the page switch.
  private func consumeCandidateExpansionRequest() {
    var value = [CChar](repeating: 0, count: 2)
    let present = Self.candidateExpansionRequestProperty.withCString { property in
      value.withUnsafeMutableBufferPointer { buffer in
        rimeAPI.get_property(session, property, buffer.baseAddress, buffer.count)
      }
    }
    guard present else { return }
    Self.candidateExpansionRequestProperty.withCString { property in
      "".withCString { empty in
        rimeAPI.set_property(session, property, empty)
      }
    }
    guard value.first == 49 else { return }
    NSApp.squirrelAppDelegate.panel?.requestCandidateExpansionForKeyboardPaging()
  }

  private func synchronizeCandidateLayoutOptions() {
    guard let panel = NSApp.squirrelAppDelegate.panel else { return }
    let navigationLayout = LinnetCandidatePresentation.rimeNavigationLayout(
      flow: panel.linear ? .horizontal : .vertical,
      verticalText: panel.vertical,
      expanded: panel.candidateExpansionRequested)
    if navigationLayout.linear != rimeAPI.get_option(session, "_linear") {
      rimeAPI.set_option(session, "_linear", navigationLayout.linear)
    }
    if navigationLayout.vertical != rimeAPI.get_option(session, "_vertical") {
      rimeAPI.set_option(session, "_vertical", navigationLayout.vertical)
    }
  }

  private func effectiveRimeKeycode(for keycode: UInt32) -> UInt32 {
    guard let keypadEquivalent =
      SquirrelKeycode.composingKeypadEquivalent(keycode),
      hasPendingRimeInput
    else { return keycode }
    return keypadEquivalent
  }

  private func updateChordState(
    keycode: UInt32,
    modifiers: UInt32
  ) {
    if isChordingKey(keycode) && rimeAPI.get_option(session, "_chord_typing") {
      updateChord(
        keycode: keycode,
        modifiers: modifiers)
    } else if modifiers & kReleaseMask.rawValue == 0 {
      clearChord()
    }
  }

  private func isChordingKey(_ keycode: UInt32) -> Bool {
    switch Int32(keycode) {
    case XK_space...XK_asciitilde,
         XK_Control_L, XK_Control_R,
         XK_Alt_L, XK_Alt_R,
         XK_Shift_L, XK_Shift_R:
      return true
    default:
      return false
    }
  }
}
