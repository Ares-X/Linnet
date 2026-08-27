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

    var description: String {
      switch self {
      case .registrationFailed(let status):
        "Input source registration failed (OSStatus \(status))."
      case .inputSourceCountMismatch(let identifier, let count):
        "Input source \(identifier) must resolve at most once before registration; found \(count)."
      }
    }
  }

  /// Registration only makes a first installation discoverable. Re-registering
  /// an already enabled source crosses the macOS input-source lifecycle again
  /// and can remove it from the current login session's Input menu.
  func register() throws {
    let identifier = SquirrelApp.bundleIdentifier
    let existingSources = inputSources(identifier: identifier)
    guard try Self.registrationRequired(
      inputSourceCount: existingSources.count, identifier: identifier)
    else {
      print("Input source is already registered: \(identifier)")
      return
    }
    let status = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    guard status == noErr else { throw Failure.registrationFailed(status) }
    print("Registered input source from \(SquirrelApp.appDir)")
  }

  static func registrationRequired(inputSourceCount: Int, identifier: String) throws -> Bool {
    switch inputSourceCount {
    case 0: true
    case 1: false
    default: throw Failure.inputSourceCountMismatch(identifier, inputSourceCount)
    }
  }

  private func inputSources(identifier: String) -> [TISInputSource] {
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue()
      as! [TISInputSource]
    return sourceList.filter { source in
      let sourceIDRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
      return unsafeBitCast(sourceIDRef, to: CFString?.self) as String? == identifier
    }
  }

  /// Read-only presentation evidence; it never changes macOS input-source state.
  static func currentInputSourceID() -> String? {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return nil
    }
    let sourceIDRef = TISGetInputSourceProperty(current, kTISPropertyInputSourceID)
    return unsafeBitCast(sourceIDRef, to: CFString?.self) as String?
  }
}
