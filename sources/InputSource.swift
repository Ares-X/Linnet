//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

final class SquirrelInstaller {
  enum Failure: Error, Equatable, CustomStringConvertible {
    case registrationFailed(OSStatus)
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
      case .registrationFailed(let status):
        "Input source registration failed (OSStatus \(status))."
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
    let status = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    guard status == noErr else { throw Failure.registrationFailed(status) }
    // Registration mutates a macOS-owned cache.  Its OSStatus alone does not
    // prove that the product identity is now usable or unique, so close this
    // external boundary with the same exact-one owner used by every later
    // lifecycle action.  This is validation only; Core updates still preserve
    // both enabled and selected state.
    _ = try inputSource(identifier: SquirrelApp.bundleIdentifier)
    print("Registered input source from \(SquirrelApp.appDir)")
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
    quiesceHost: () -> Bool
  ) throws {
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
      && currentAfterQuiescence != currentBeforeQuiescence
    {
      print("Input source changed during Host quiescence; preserving \(currentAfterQuiescence)")
    }
    try register()
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
        || currentAfterQuiescence != postQuiescenceInputSourceID
      {
        return currentAfterQuiescence
      }
    }
    if currentBeforeQuiescence == targetInputSourceID
      || (wasCurrent && currentBeforeQuiescence == postQuiescenceInputSourceID)
    {
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
      && postRegistrationInputSourceID != targetInputSourceID
    {
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
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue()
      as! [TISInputSource]
    let matches = sourceList.filter { source in
      let sourceIDRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
      return unsafeBitCast(sourceIDRef, to: CFString?.self) as String? == identifier
    }
    guard matches.count == 1, let source = matches.first else {
      throw Failure.inputSourceCountMismatch(identifier, matches.count)
    }
    return source
  }

  private func enableSource(identifier: String) throws {
    let source = try inputSource(identifier: identifier)
    guard let enabled = Self.boolProperty(source, key: kTISPropertyInputSourceIsEnabled) else {
      throw Failure.inputSourcePropertyUnavailable(identifier, "enabled")
    }
    // Re-enabling an accepted source can reopen the macOS authorization prompt
    // and race a following selection. The enabled property owns idempotence.
    if enabled { return }
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
