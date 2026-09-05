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

  func forgetCandidate(absoluteIndex: Int) {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput,
      activeClient != nil, sessionIsCurrent(), absoluteIndex >= 0
    else { return }
    // Rime owns learning and refreshes the composition after a deletion.
    // Its Bool only confirms dispatch, not that a dictionary entry existed.
    _ = rimeAPI.delete_candidate(session, absoluteIndex)
    rimeUpdate()
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

  func createSession(client sessionClient: IMKTextInput?) {
    guard NSApp.squirrelAppDelegate.canAcceptRimeInput else {
      retireSessionLease()
      return
    }
    let app = sessionClient?.bundleIdentifier() ?? {
      Self.unknownAppCount &+= 1
      return "UnknownApp\(Self.unknownAppCount)"
    }()
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
      rimeAPI.set_option(session, key, value)
    }
  }

  func destroySession() {
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
    if rimeModifiers == 0,
      (UInt32(XK_1)...UInt32(XK_9)).contains(effectiveKeycode),
      let panel = NSApp.squirrelAppDelegate.panel,
      panel.candidateSnapshot?.isExpanded == true {
      if let target = panel.expandedCandidateSelectionTarget(
        number: Int(effectiveKeycode - UInt32(XK_1)) + 1) {
        _ = rimeAPI.select_candidate(session, target)
      }
      // A number without a label must not select a different Rime page item.
      return true
    }
    if rimeModifiers == 0,
      effectiveKeycode == UInt32(XK_Up) || effectiveKeycode == UInt32(XK_Down),
      let target = NSApp.squirrelAppDelegate.panel?.expandedCandidateNavigationTarget(
        up: effectiveKeycode == UInt32(XK_Up)) {
      // At the end of the candidate list Rime declines the move; the arrow
      // still belongs to candidate browsing, not to the application's caret.
      _ = rimeAPI.highlight_candidate(session, target)
      return true
    }
    let handled = rimeAPI.process_key(
      session,
      Int32(effectiveKeycode),
      Int32(rimeModifiers))
    consumeCandidateExpansionRequest()
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
    // The panel owns visual rows; the Rime processor still owns printable-key
    // classification and selection. Empty targets retain compact paging.
    for (property, previous) in [
      ("linnet/candidate_previous_row_v1", true),
      ("linnet/candidate_next_row_v1", false),
    ] {
      let target: String
      if panel.candidateSnapshot?.isExpanded == true {
        target = String(panel.expandedCandidateNavigationTarget(up: previous) ?? -1)
      } else {
        target = panel.view.currentTheme.candidateExpansionAllowed ? "expand" : ""
      }
      property.withCString { name in
        target.withCString { value in rimeAPI.set_property(session, name, value) }
      }
    }
    let navigationLayout = LinnetCandidatePresentation.rimeNavigationLayout(
      flow: panel.linear ? .horizontal : .vertical,
      verticalText: panel.vertical,
      expanded: panel.candidateExpansionRequested)
    let changesLinear = navigationLayout.linear != rimeAPI.get_option(session, "_linear")
    let changesVertical = navigationLayout.vertical != rimeAPI.get_option(session, "_vertical")
    guard changesLinear || changesVertical else { return }

    // Rime refreshes the composition when any option changes, including layout.
    // Preserve its selection across that refresh, before processing the key.
    var context = RimeContext_stdbool.rimeStructInit()
    var selectedIndex: Int?
    if rimeAPI.get_context(session, &context) {
      if context.menu.num_candidates > 0 {
        selectedIndex = Int(context.menu.page_no) * Int(context.menu.page_size)
          + Int(context.menu.highlighted_candidate_index)
      }
      _ = rimeAPI.free_context(&context)
    }
    if changesLinear {
      rimeAPI.set_option(session, "_linear", navigationLayout.linear)
    }
    if changesVertical {
      rimeAPI.set_option(session, "_vertical", navigationLayout.vertical)
    }
    if let selectedIndex {
      _ = rimeAPI.highlight_candidate(session, selectedIndex)
    }
  }

  private func effectiveRimeKeycode(for keycode: UInt32) -> UInt32 {
    guard let keypadEquivalent =
      SquirrelKeycode.composingKeypadEquivalent(keycode),
      hasPendingRimeInput
    else { return keycode }
    return keypadEquivalent
  }
}
