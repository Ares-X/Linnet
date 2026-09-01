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
  static let dataRegistry: LinnetDataRegistry = {
    do {
      return try LinnetDataRegistry(productName: productName, coreVersion: productVersion)
    } catch {
      configurationFailure("The language data registry is unavailable: \(error)")
    }
  }()
  static var userDir: URL { dataRegistry.userDataDirectory }

  static let appDir = Bundle.main.bundleURL

  /// Invalid product metadata cannot be repaired at runtime, but it also must
  /// never become a macOS crash report. Exit normally with one diagnostic.
  static func configurationFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Linnet startup failure: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
  static func main() {
    let main = Bundle.main
    guard SquirrelInstaller.hostMayStartRuntime(bundleURL: main.bundleURL) else {
      configurationFailure("The Linnet executable must run from its installed user path")
    }
    let handled = autoreleasepool {
      let installer = SquirrelInstaller()
      let args = CommandLine.arguments
      if args.count > 1 {
        do {
          switch args[1] {
          case "--request-first-install-authorization":
            guard args.count == 2 else {
              configurationFailure("First-install authorization accepts no input source identifier")
            }
            try installer.requestFirstInstallAuthorization()
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
    Manage \(productName):
      --request-first-install-authorization request initial macOS user authorization
    """
  }
}
