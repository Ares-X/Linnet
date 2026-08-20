//
//  Main.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit
import Darwin

@main
struct SquirrelApp {
  static var bundleIdentifier: String {
    guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
      configurationFailure("The input method requires a bundle identifier")
    }
    return identifier
  }

  static var productName: String {
    guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
      !name.isEmpty
    else {
      configurationFailure("The input method requires a display name")
    }
    return name
  }

  static var productVersion: String {
    guard
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String,
      !version.isEmpty
    else {
      configurationFailure("The input method requires a product version")
    }
    return version
  }

  static var productSlug: String { productName.lowercased() }
  static var rimeAppName: String { "rime.\(productSlug)" }
  static var settingsBundleIdentifier: String { "\(bundleIdentifier).settings" }

  static let dataRegistry: LinnetDataRegistry = {
    do {
      return try LinnetDataRegistry(productName: productName, coreVersion: productVersion)
    } catch {
      configurationFailure("The language data registry is unavailable: \(error)")
    }
  }()
  static var userDir: URL { dataRegistry.userDataDirectory }

  static let appDir = Bundle.main.bundleURL

  enum TerminationPolicy {
    case uninstall
    case hostClean

    var bundleIdentifiers: [String] {
      switch self {
      case .uninstall: return [bundleIdentifier, settingsBundleIdentifier]
      case .hostClean: return [bundleIdentifier]
      }
    }

    var allowsForcedTermination: Bool {
      switch self {
      case .uninstall: return true
      case .hostClean: return false
      }
    }
  }

  /// Owns process enumeration for executable-driven lifecycle boundaries.
  /// Uninstall may force Host and Settings only after its grace period. Core
  /// postinstall uses the same owner to request a clean Host-only exit and
  /// fails closed instead of overriding Settings or force terminating Host.
  /// The package's pre-payload cooperative boundary is separately owned by its
  /// packaged script because the installed executable is about to be replaced.
  static func quitProductProcesses(_ policy: TerminationPolicy) -> Bool {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    func runningTargets() -> [NSRunningApplication] {
      policy.bundleIdentifiers.flatMap { identifier in
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
      }.filter { $0.processIdentifier != ownPID && !$0.isTerminated }
    }
    func waitForExit(until deadline: Date) -> Bool {
      while Date() < deadline {
        if runningTargets().isEmpty { return true }
        Thread.sleep(forTimeInterval: 0.05)
      }
      return runningTargets().isEmpty
    }

    let targets = runningTargets()
    targets.forEach { _ = $0.terminate() }
    if waitForExit(until: Date().addingTimeInterval(3)) { return true }
    guard policy.allowsForcedTermination else { return false }
    runningTargets().forEach { _ = $0.forceTerminate() }
    return waitForExit(until: Date().addingTimeInterval(2))
  }

  /// Removes the temporary log path whose name and location are owned here.
  /// The uninstaller calls this before deleting the executable so it never has
  /// to duplicate or infer Foundation's per-user temporary-directory contract.
  static func purgeOwnedTemporaryState() -> Bool {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
    let targets = [logDir.standardizedFileURL]
    guard logDir.lastPathComponent == rimeAppName,
      targets.allSatisfy({
        $0 != temporaryRoot && $0.deletingLastPathComponent() == temporaryRoot
      })
    else { return false }

    do {
      for target in targets {
        let exists = fileManager.fileExists(atPath: target.path)
          || (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil
        if exists { try fileManager.removeItem(at: target) }
      }
      return true
    } catch {
      FileHandle.standardError.write(
        Data("Linnet temporary-state cleanup failed: \(error.localizedDescription)\n".utf8))
      return false
    }
  }

  /// Invalid product metadata cannot be repaired at runtime, but it also must
  /// never become a macOS crash report. Exit normally with one diagnostic.
  static func configurationFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Linnet startup failure: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
  static var logDir: URL {
    FileManager.default.temporaryDirectory.appending(
      component: rimeAppName, directoryHint: .isDirectory)
  }
  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
    let handled = autoreleasepool {
      let installer = SquirrelInstaller()
      let args = CommandLine.arguments
      if args.count > 1 {
        do {
          switch args[1] {
          case "--quit":
            guard args.count == 2 else {
              configurationFailure("Quit accepts no process identifier")
            }
            guard quitProductProcesses(.uninstall) else {
              configurationFailure("Linnet processes did not terminate before uninstall")
            }
            return true
          case "--quit-host-clean":
            guard args.count == 2 else {
              configurationFailure("Clean Host quit accepts no process identifier")
            }
            guard quitProductProcesses(.hostClean) else {
              configurationFailure("Linnet Host did not terminate cleanly before Core activation")
            }
            return true
          case "--purge-owned-temporary-state":
            guard purgeOwnedTemporaryState() else {
              configurationFailure("Linnet temporary state could not be removed")
            }
            return true
          case "--register-input-source":
            guard args.count == 2 else {
              configurationFailure("Register accepts no input source identifier")
            }
            try installer.register()
            return true
          case "--enable-input-source":
            guard args.count == 2 else {
              configurationFailure("Enable accepts no input source identifier")
            }
            try installer.enable()
            return true
          case "--disable-input-source":
            guard args.count == 2 else {
              configurationFailure("Disable accepts no input source identifier")
            }
            try installer.disable()
            return true
          case "--select-input-source":
            guard args.count == 2 else {
              configurationFailure("Select accepts no input source identifier")
            }
            try installer.select()
            return true
          case "--refresh-core-input-source":
            guard args.count == 4, !args[3].isEmpty else {
              configurationFailure(
                "Core refresh requires a prior-current flag and post-quiescence input source")
            }
            let wasCurrent: Bool
            switch args[2] {
            case "true": wasCurrent = true
            case "false": wasCurrent = false
            default:
              configurationFailure(
                "Core refresh requires a prior-current flag and post-quiescence input source")
            }
            try installer.refreshAfterCoreUpdate(
              wasCurrent: wasCurrent,
              postQuiescenceInputSourceID: args[3],
              quiesceHost: { quitProductProcesses(.hostClean) })
            return true
          case "--help":
            print(helpDoc)
            return true
          default:
            break
          }
        } catch let failure as SquirrelInstaller.Failure {
          configurationFailure(failure.description)
        } catch {
          configurationFailure("Input source lifecycle failed")
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      // find the bundle identifier and then initialize the input method server
      let main = Bundle.main
      guard
        let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName")
          as? String,
        !connectionName.isEmpty,
        let bundleIdentifier = main.bundleIdentifier,
        !bundleIdentifier.isEmpty
      else {
        configurationFailure("The InputMethodKit server metadata is incomplete")
      }
      _ = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
      // load the bundle explicitly because in this case the input method is a
      // background only application
      let app = NSApplication.shared
      let delegate = SquirrelApplicationDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)

      guard delegate.setupRime() else {
        configurationFailure("The active language data is missing or invalid")
      }
      guard delegate.startRime(fullCheck: false) else {
        configurationFailure("The Rime runtime could not start")
      }
      guard delegate.loadSettings() else {
        delegate.shutdownRime()
        configurationFailure("The Rime settings could not load")
      }
      print("\(productName) reporting!")

      // Only a fully initialized input method may publish a live IMK server.
      app.run()
      print("\(productName) is quitting...")
      // RimeFinalize is owned by SquirrelApplicationDelegate.shutdownRime()
      // (called from applicationWillTerminate and workspaceWillPowerOff), so
      // the runtime is torn down exactly once, with sessions destroyed
      // before the process-lifetime Lua state is released.
    }
    return
  }

  static var helpDoc: String {
    """
    Supported arguments:
    Perform actions:
      --quit                     quit all \(productName) processes
      --quit-host-clean          cleanly quit only the \(productName) Host
      --purge-owned-temporary-state
                                 remove Linnet-owned temporary logs
    Manage \(productName):
      --register-input-source             register input source
      --enable-input-source               enable input source
      --disable-input-source             disable input source
      --select-input-source              select input source
      --refresh-core-input-source        atomically refresh a Core update's TIS state
    """
  }
}
