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
    case enableFailed(OSStatus)
    case selectionFailed(OSStatus)
    case registrationStateRejected(String)

    var description: String {
      switch self {
      case .registrationFailed(let status):
        "Input source registration failed (OSStatus \(status))."
      case .enableFailed(let status):
        "Input source enablement failed (OSStatus \(status))."
      case .selectionFailed(let status):
        "Input source selection failed (OSStatus \(status))."
      case .registrationStateRejected(let state):
        "Input source registration state is not repairable in place: \(state)."
      }
    }
  }

  /// Complete is the sole explicit repair boundary. It registers a missing
  /// source, then uses HIToolbox's standard enable/select transition once so
  /// macOS records Linnet in the current user's Input menu. Core updates never
  /// call this path and therefore preserve the user's later selection.
  func repair() throws {
    let identifier = SquirrelApp.bundleIdentifier
    var inspection = LinnetInputSourceRegistration.inspect(identifier: identifier)
    switch inspection.state {
    case .missing:
      let status = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
      guard status == noErr else { throw Failure.registrationFailed(status) }
      inspection = LinnetInputSourceRegistration.inspect(identifier: identifier)
    case .disabled, .available, .selected:
      break
    case .duplicate, .conflictingIdentity, .conflictingKind,
      .unavailableCapabilities, .unknownAvailability, .unknownBundleIdentifier:
      throw Failure.registrationStateRejected(inspection.state.wireValue)
    }
    guard let inputSource = inspection.inputSource else {
      throw Failure.registrationStateRejected(inspection.state.wireValue)
    }
    let enableStatus = TISEnableInputSource(inputSource)
    guard enableStatus == noErr else { throw Failure.enableFailed(enableStatus) }
    let selectionStatus = TISSelectInputSource(inputSource)
    guard selectionStatus == noErr else { throw Failure.selectionFailed(selectionStatus) }
    let finalState = LinnetInputSourceRegistration.state(identifier: identifier)
    guard finalState == .selected else {
      throw Failure.registrationStateRejected(finalState.wireValue)
    }
    print("Repaired and selected input source: \(identifier)")
  }

  /// An InputMethodKit Host is valid only from the per-user installation
  /// location. Build, analysis, and cache copies must fail before they open the
  /// production Rime data or publish the production Settings IPC endpoint.
  static func hostMayStartRuntime(
    bundleURL: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    let installedHost = homeDirectory.appending(
      path: "Library/Input Methods/\(SquirrelApp.appDir.lastPathComponent)",
      directoryHint: .isDirectory)
    return bundleURL.standardizedFileURL == installedHost.standardizedFileURL
  }

}
