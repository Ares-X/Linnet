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

  /// Only publication of the first installed App may register Linnet and ask
  /// macOS for user authorization. Selection remains exclusively owned by the
  /// user and macOS after authorization. Existing-App Complete
  /// repairs and Core updates preserve the App inode and never call this path.
  /// An immediate HIToolbox property remains only an observation; it is never
  /// promoted to durable authorization evidence.
  func requestFirstInstallAuthorization() throws {
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
    guard let inputSource = inspection.inputSource else {
      throw Failure.registrationStateRejected(inspection.state.wireValue)
    }
    // A stale registration can survive an earlier uninstall, so first install
    // still submits the standard enablement request after validating the one
    // exact source. No update path may infer authorization from this
    // process-local observation or resubmit the request. The explicit first-
    // install/identity-repair action does not select the source: macOS may keep
    // authorization pending after enablement returns, and selection is a user
    // action in System Settings or the input menu.
    let enableStatus = TISEnableInputSource(inputSource)
    guard enableStatus == noErr else { throw Failure.enableFailed(enableStatus) }
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
