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
}
