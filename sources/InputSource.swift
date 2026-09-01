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
    case registrationStateRejected(String)

    var description: String {
      switch self {
      case .registrationFailed(let status):
        "Input source registration failed (OSStatus \(status))."
      case .enableFailed(let status):
        "Input source enablement failed (OSStatus \(status))."
      case .registrationStateRejected(let state):
        "Input source registration state cannot request authorization: \(state)."
      }
    }
  }

  /// Complete is the sole explicit registration and authorization-request
  /// boundary. macOS owns the user's final approval and menu selection; an
  /// immediate HIToolbox property must never be promoted to either fact.
  /// Core updates never call this path.
  func requestAuthorization() throws {
    let identifier = SquirrelApp.bundleIdentifier
    var inspection = LinnetInputSourceRegistration.inspect(identifier: identifier)
    switch inspection.state {
    case .missing:
      let status = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
      guard status == noErr else { throw Failure.registrationFailed(status) }
      inspection = LinnetInputSourceRegistration.inspect(identifier: identifier)
    case .enablementRequired, .enabledObservation, .selectedObservation:
      break
    case .duplicate, .conflictingIdentity, .conflictingKind,
      .unavailableCapabilities, .unknownAvailability, .unknownBundleIdentifier:
      throw Failure.registrationStateRejected(inspection.state.wireValue)
    }
    if inspection.state == .enablementRequired {
      guard let inputSource = inspection.inputSource else {
        throw Failure.registrationStateRejected(inspection.state.wireValue)
      }
      let enableStatus = TISEnableInputSource(inputSource)
      guard enableStatus == noErr else { throw Failure.enableFailed(enableStatus) }
    }
    print("Input source authorization request is ready: \(identifier)")
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
