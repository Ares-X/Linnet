import CoreFoundation
import Foundation

public typealias DataPaths = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
  UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias DataError = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

// Native maintenance owns exclusion and Rime setup/deployment. This boundary
// projects the shared Registry snapshot, without a second path/state parser.
@_cdecl("linnet_data_setup")
public func setupData(
  _ core: UnsafePointer<CChar>, _ user: UnsafePointer<CChar>, _ version: UnsafePointer<CChar>,
  _ recover: Int32, _ context: UnsafeMutableRawPointer?,
  _ paths: @escaping DataPaths, _ failed: @escaping DataError
) -> Int32 {
  do {
    let root = URL(fileURLWithPath: String(cString: user), isDirectory: true)
    let registry = try LinnetDataRegistry(productName: root.lastPathComponent,
      coreVersion: String(cString: version), applicationSupportDirectory: root.deletingLastPathComponent(),
      coreDataDirectory: URL(fileURLWithPath: String(cString: core), isDirectory: true))
    if recover != 0 {
      try registry.installWindowsFactoryIfMissing()
      try registry.recoverPreparedLanguageActivation()
    }
    try registry.refreshWindowsCoreProjection()
    let snapshot = try recover != 0 ? registry.runtimeSnapshot() : registry.tentativeRuntimeSnapshot()
    snapshot.sharedDataDirectory.path.withCString { shared in
      snapshot.userDataDirectory.path.withCString { user in
        snapshot.prebuiltDataDirectory.path.withCString { prebuilt in
          snapshot.stagingDirectory.path.withCString { staging in
            paths(context, shared, user, prebuilt, staging)
          }
        }
      }
    }
    return 0
  } catch {
    error.localizedDescription.withCString { failed(context, $0) }
    return -1
  }
}

// This ABI translates the native host's callbacks; all scheduling and cycle
// transitions stay in LinnetRimeSyncController. Calls are main-thread confined.
public typealias SyncStep = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32
public typealias SyncAttempt = @convention(c) (UnsafeMutableRawPointer?, Double) -> Int32
public typealias SyncResult = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

@_cdecl("linnet_sync_create")
public func createSync(
  _ directory: UnsafePointer<CChar>, _ lastAttempt: Double,
  _ context: UnsafeMutableRawPointer?, _ step: @escaping SyncStep,
  _ attempt: @escaping SyncAttempt, _ result: @escaping SyncResult
) -> UnsafeMutableRawPointer {
  let directory = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
  let configuration = LinnetRimeSyncConfiguration(
    syncDirectory: directory,
    lastAttempt: lastAttempt > 0 ? Date(timeIntervalSince1970: lastAttempt) : nil)
  let controller = LinnetRimeSyncController(
    loadConfiguration: { configuration },
    recordAttempt: { attempt(context, $0.timeIntervalSince1970) != 0 },
    recordResult: {
      switch $0 {
      case .completed: result(context, 0)
      case .deferred: result(context, 2)
      case .failed: result(context, -1)
      case .unavailable: result(context, -2)
      }
    },
    operation: { directory in
      switch directory.path.withCString({ step(context, $0) }) {
      case 0: return .completed
      case 1: return .inProgress
      case 2: return .deferred
      case 3: return .waiting
      case 4: return .busy
      default: return .failed
      }
    },
    cancelOperation: { _ = step(context, nil) })
  controller.start()
  return Unmanaged.passRetained(controller).toOpaque()
}

@_cdecl("linnet_sync_destroy")
public func destroySync(_ handle: UnsafeMutableRawPointer) {
  let controller = Unmanaged<LinnetRimeSyncController>.fromOpaque(handle).takeRetainedValue()
  controller.stop()
}

@_cdecl("linnet_sync_poll")
public func pollSync(_ handle: UnsafeMutableRawPointer) -> Double {
  let controller = Unmanaged<LinnetRimeSyncController>.fromOpaque(handle).takeUnretainedValue()
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true)
  return controller.nextWakeUp.map { max(0, $0.timeIntervalSinceNow) } ?? -1
}
