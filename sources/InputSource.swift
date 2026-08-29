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
    case registrationStateRejected(String)

    var description: String {
      switch self {
      case .registrationFailed(let status):
        "Input source registration failed (OSStatus \(status))."
      case .registrationStateRejected(let state):
        "Input source registration state is not repairable in place: \(state)."
      }
    }
  }

  /// Registration only makes a first installation discoverable. Re-registering
  /// an already enabled source crosses the macOS input-source lifecycle again
  /// and can remove it from the current login session's Input menu.
  func register() throws {
    let identifier = SquirrelApp.bundleIdentifier
    let state = LinnetInputSourceRegistration.state(identifier: identifier)
    switch state {
    case .registered:
      print("Input source is already registered: \(identifier)")
      return
    case .missing:
      break
    case .duplicate, .conflictingIdentity, .unknownBundleIdentifier:
      throw Failure.registrationStateRejected(state.wireValue)
    }
    let status = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    guard status == noErr else { throw Failure.registrationFailed(status) }
    print("Registered input source from \(SquirrelApp.appDir)")
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
