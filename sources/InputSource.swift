//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

enum CoreIdentityTransition: String {
  case sameCommunityCMSLeaf = "same-community-cms-leaf"
  case legacyCommunityAdhocToCMS = "legacy-community-adhoc-to-cms"
  case missingAppInstall = "missing-app-install"
}

enum PriorEnablement: String {
  case enabled
  case disabled
  case unregistered
}

final class SquirrelInstaller {
  enum RegistrationIntent: String {
    case ensurePresent
    case preservePresent
    case preserveAbsent
  }

  enum CoreUpdateEnableIntent {
    case preserve
    case reassert
  }

  struct CoreUpdatePlan {
    let registrationIntent: RegistrationIntent
    let enableIntent: CoreUpdateEnableIntent
  }

  enum Failure: Error, Equatable, CustomStringConvertible {
    case invalidCoreUpdateState(String, String)
    case registrationFailed(OSStatus)
    case registrationStateMismatch(String, RegistrationIntent, Int)
    case inputSourceCountMismatch(String, Int)
    case inputSourcePropertyUnavailable(String, String)
    case inputSourceNotEnabled(String)
    case inputSourceNotEnableCapable(String)
    case inputSourceNotSelectable(String)
    case currentInputSourceUnavailable
    case enableFailed(String, OSStatus)
    case disableFailed(String, OSStatus)
    case selectFailed(String, OSStatus)
    case selectionVerificationFailed(String)
    case hostQuiescenceFailed

    var description: String {
      switch self {
      case .invalidCoreUpdateState(let transition, let priorEnablement):
        "Core update state is invalid: \(transition) with \(priorEnablement)."
      case .registrationFailed(let status):
        "Input source registration failed (OSStatus \(status))."
      case .registrationStateMismatch(let identifier, let intent, let count):
        "Input source \(identifier) registration state differs from \(intent.rawValue); found \(count)."
      case .inputSourceCountMismatch(let identifier, let count):
        "Input source \(identifier) must resolve exactly once; found \(count)."
      case .inputSourcePropertyUnavailable(let identifier, let property):
        "Input source \(identifier) has no readable \(property) state."
      case .inputSourceNotEnabled(let identifier):
        "Input source is not enabled: \(identifier)."
      case .inputSourceNotEnableCapable(let identifier):
        "Input source cannot be enabled: \(identifier)."
      case .inputSourceNotSelectable(let identifier):
        "Input source cannot be selected: \(identifier)."
      case .currentInputSourceUnavailable:
        "The current keyboard input source is unavailable."
      case .enableFailed(let identifier, let status):
        "Input source enable failed for \(identifier) (OSStatus \(status))."
      case .disableFailed(let identifier, let status):
        "Input source disable failed for \(identifier) (OSStatus \(status))."
      case .selectFailed(let identifier, let status):
        "Input source selection failed for \(identifier) (OSStatus \(status))."
      case .selectionVerificationFailed(let identifier):
        "Input source selection could not be verified: \(identifier)."
      case .hostQuiescenceFailed:
        "Linnet Host did not terminate cleanly before Core activation."
      }
    }
  }

  func register() throws {
    try register(intent: .ensurePresent)
  }

  private func register(intent: RegistrationIntent) throws {
    let identifier = SquirrelApp.bundleIdentifier
    let existingSources = inputSources(identifier: identifier)
    guard try Self.registrationRequired(
      inputSourceCount: existingSources.count,
      intent: intent,
      identifier: identifier)
    else {
      print("Input source is already registered: \(identifier)")
      return
    }
    let status = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    guard status == noErr else { throw Failure.registrationFailed(status) }
    // Registration mutates macOS-owned input-menu state. Existing Core updates
    // preserve the exact TIS identity above; only a genuinely missing source
    // crosses this repair boundary. Its OSStatus alone does not prove that the
    // identity is now usable or unique, so resolve it exactly once afterward.
    _ = try inputSource(identifier: identifier)
    print("Registered input source from \(SquirrelApp.appDir)")
  }

  static func registrationRequired(
    inputSourceCount: Int,
    intent: RegistrationIntent,
    identifier: String
  ) throws -> Bool {
    guard inputSourceCount == 0 || inputSourceCount == 1 else {
      throw Failure.inputSourceCountMismatch(identifier, inputSourceCount)
    }
    switch (intent, inputSourceCount) {
    case (.ensurePresent, 0): return true
    case (.ensurePresent, 1), (.preservePresent, 1), (.preserveAbsent, 0): return false
    default:
      throw Failure.registrationStateMismatch(identifier, intent, inputSourceCount)
    }
  }

  static func coreUpdatePlan(
    identityTransition: CoreIdentityTransition,
    priorEnablement: PriorEnablement,
    wasCurrent: Bool
  ) -> CoreUpdatePlan? {
    // A source absent from the pre-payload TIS snapshot cannot simultaneously
    // be the selected source. Reject this copied-state contradiction before
    // quiescing any process or mutating input-source state.
    guard priorEnablement != .unregistered || !wasCurrent else { return nil }
    switch (identityTransition, priorEnablement) {
    case (.missingAppInstall, .enabled), (.missingAppInstall, .disabled): return nil
    case (.missingAppInstall, .unregistered):
      return CoreUpdatePlan(registrationIntent: .ensurePresent, enableIntent: .preserve)
    case (.legacyCommunityAdhocToCMS, .enabled):
      return CoreUpdatePlan(registrationIntent: .preservePresent, enableIntent: .reassert)
    case (.legacyCommunityAdhocToCMS, .disabled),
      (.sameCommunityCMSLeaf, .enabled), (.sameCommunityCMSLeaf, .disabled):
      return CoreUpdatePlan(registrationIntent: .preservePresent, enableIntent: .preserve)
    case (.legacyCommunityAdhocToCMS, .unregistered),
      (.sameCommunityCMSLeaf, .unregistered):
      return CoreUpdatePlan(registrationIntent: .preserveAbsent, enableIntent: .preserve)
    }
  }

  func enable() throws {
    try enableSource(identifier: SquirrelApp.bundleIdentifier)
  }

  func select() throws {
    try selectSource(identifier: SquirrelApp.bundleIdentifier)
  }

  func refreshAfterCoreUpdate(
    wasCurrent: Bool,
    postQuiescenceInputSourceID: String,
    identityTransition: CoreIdentityTransition,
    priorEnablement: PriorEnablement,
    quiesceHost: () -> Bool
  ) throws {
    guard let plan = Self.coreUpdatePlan(
      identityTransition: identityTransition,
      priorEnablement: priorEnablement,
      wasCurrent: wasCurrent)
    else {
      throw Failure.invalidCoreUpdateState(
        identityTransition.rawValue, priorEnablement.rawValue)
    }
    let identifier = SquirrelApp.bundleIdentifier
    guard let currentBeforeQuiescence = Self.currentInputSourceID() else {
      throw Failure.currentInputSourceUnavailable
    }
    guard quiesceHost() else { throw Failure.hostQuiescenceFailed }
    guard let currentAfterQuiescence = Self.currentInputSourceID() else {
      throw Failure.currentInputSourceUnavailable
    }
    let desiredInputSourceID = Self.desiredInputSourceAfterCoreUpdate(
      wasCurrent: wasCurrent,
      postQuiescenceInputSourceID: postQuiescenceInputSourceID,
      currentBeforeQuiescence: currentBeforeQuiescence,
      currentAfterQuiescence: currentAfterQuiescence,
      targetInputSourceID: identifier)
    if desiredInputSourceID == currentAfterQuiescence
      && currentAfterQuiescence != currentBeforeQuiescence {
      print("Input source changed during Host quiescence; preserving \(currentAfterQuiescence)")
    }
    try register(intent: plan.registrationIntent)
    if plan.enableIntent == .reassert {
      try enableSource(identifier: identifier, intent: plan.enableIntent)
    }
    guard let currentAfterRegister = Self.currentInputSourceID() else {
      throw Failure.currentInputSourceUnavailable
    }
    guard let inputSourceToRestore = Self.inputSourceToRestoreAfterRegistration(
      desiredInputSourceID: desiredInputSourceID,
      preRegistrationInputSourceID: currentAfterQuiescence,
      postRegistrationInputSourceID: currentAfterRegister,
      targetInputSourceID: identifier)
    else { return }
    let source = try inputSource(identifier: inputSourceToRestore)
    try selectSource(
      identifier: inputSourceToRestore,
      resolvedSource: source,
      expectedCurrentInputSourceID: currentAfterRegister)
  }

  static func desiredInputSourceAfterCoreUpdate(
    wasCurrent: Bool,
    postQuiescenceInputSourceID: String,
    currentBeforeQuiescence: String,
    currentAfterQuiescence: String,
    targetInputSourceID: String
  ) -> String {
    if currentAfterQuiescence != currentBeforeQuiescence {
      if currentBeforeQuiescence != targetInputSourceID
        || currentAfterQuiescence != postQuiescenceInputSourceID {
        return currentAfterQuiescence
      }
    }
    if currentBeforeQuiescence == targetInputSourceID
      || (wasCurrent && currentBeforeQuiescence == postQuiescenceInputSourceID) {
      return targetInputSourceID
    }
    return currentBeforeQuiescence
  }

  static func inputSourceToRestoreAfterRegistration(
    desiredInputSourceID: String,
    preRegistrationInputSourceID: String,
    postRegistrationInputSourceID: String,
    targetInputSourceID: String
  ) -> String? {
    if postRegistrationInputSourceID == desiredInputSourceID { return nil }
    if postRegistrationInputSourceID != preRegistrationInputSourceID
      && postRegistrationInputSourceID != targetInputSourceID {
      return nil
    }
    return desiredInputSourceID
  }

  private func selectSource(
    identifier: String,
    resolvedSource: TISInputSource? = nil,
    expectedCurrentInputSourceID: String? = nil
  ) throws {
    let source = try resolvedSource ?? inputSource(identifier: identifier)
    guard let enabled = Self.boolProperty(source, key: kTISPropertyInputSourceIsEnabled) else {
      throw Failure.inputSourcePropertyUnavailable(identifier, "enabled")
    }
    guard enabled else { throw Failure.inputSourceNotEnabled(identifier) }
    guard let selectable = Self.boolProperty(
      source, key: kTISPropertyInputSourceIsSelectCapable)
    else {
      throw Failure.inputSourcePropertyUnavailable(identifier, "selectable")
    }
    guard selectable else { throw Failure.inputSourceNotSelectable(identifier) }
    if let expectedCurrentInputSourceID {
      guard let current = Self.currentInputSourceID() else {
        throw Failure.currentInputSourceUnavailable
      }
      guard current == expectedCurrentInputSourceID else {
        print("Input source changed before Core restoration; preserving \(current)")
        return
      }
    }
    let status = TISSelectInputSource(source)
    guard status == noErr else { throw Failure.selectFailed(identifier, status) }
    guard Self.currentInputSourceID() == identifier else {
      throw Failure.selectionVerificationFailed(identifier)
    }
    print("Selection succeeds for input source: \(identifier)")
  }

  func disable() throws {
    try disableSource(identifier: SquirrelApp.bundleIdentifier)
  }

  private func inputSource(identifier: String) throws -> TISInputSource {
    let matches = inputSources(identifier: identifier)
    guard matches.count == 1, let source = matches.first else {
      throw Failure.inputSourceCountMismatch(identifier, matches.count)
    }
    return source
  }

  private func inputSources(identifier: String) -> [TISInputSource] {
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue()
      as! [TISInputSource]
    return sourceList.filter { source in
      let sourceIDRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
      return unsafeBitCast(sourceIDRef, to: CFString?.self) as String? == identifier
    }
  }

  private func enableSource(
    identifier: String,
    intent: CoreUpdateEnableIntent = .preserve
  ) throws {
    let source = try inputSource(identifier: identifier)
    guard let enabled = Self.boolProperty(source, key: kTISPropertyInputSourceIsEnabled) else {
      throw Failure.inputSourcePropertyUnavailable(identifier, "enabled")
    }
    // The enabled property owns normal idempotence. A known Core identity
    // transition may reassert previously enabled user intent because macOS can
    // cache this property while omitting the replacement from the input menu.
    if enabled && intent == .preserve { return }
    guard let enableCapable = Self.boolProperty(
      source, key: kTISPropertyInputSourceIsEnableCapable)
    else {
      throw Failure.inputSourcePropertyUnavailable(identifier, "enable-capable")
    }
    guard enableCapable else { throw Failure.inputSourceNotEnableCapable(identifier) }
    let status = TISEnableInputSource(source)
    guard status == noErr else { throw Failure.enableFailed(identifier, status) }
    print("Enable succeeds for input source: \(identifier)")
  }

  private func disableSource(identifier: String) throws {
    let source = try inputSource(identifier: identifier)
    guard let enabled = Self.boolProperty(source, key: kTISPropertyInputSourceIsEnabled) else {
      throw Failure.inputSourcePropertyUnavailable(identifier, "enabled")
    }
    if !enabled { return }
    let status = TISDisableInputSource(source)
    guard status == noErr else { throw Failure.disableFailed(identifier, status) }
    print("Disable succeeds for input source: \(identifier)")
  }

  private static func boolProperty(_ inputSource: TISInputSource, key: CFString!) -> Bool? {
    let enabledRef = TISGetInputSourceProperty(inputSource, key)
    guard let enabled = unsafeBitCast(enabledRef, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(enabled)
  }

  static func currentInputSourceID() -> String? {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return nil
    }
    let sourceIDRef = TISGetInputSourceProperty(current, kTISPropertyInputSourceID)
    return unsafeBitCast(sourceIDRef, to: CFString?.self) as String?
  }
}
