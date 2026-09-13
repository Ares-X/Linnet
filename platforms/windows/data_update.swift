import Foundation

// Settings and the resident server are different executables. The channel must
// not live in either executable's default preferences domain.
private let updateDefaults = UserDefaults(
  suiteName: LinnetPackContract.productIdentifier + ".Updates")!

private var selectedUpdateChannel: LinnetSettingsDownloadSource.UpdateChannel {
  updateDefaults.synchronize()
  return LinnetSettingsDownloadSource.UpdateChannel.load(from: updateDefaults)
}

@_cdecl("linnet_update_channel_read")
public func readUpdateChannel() -> Int32 { selectedUpdateChannel == .preview ? 1 : 0 }

@_cdecl("linnet_update_channel_save")
public func saveUpdateChannel(_ preview: Int32) -> Int32 {
  let channel: LinnetSettingsDownloadSource.UpdateChannel = preview == 1 ? .preview : .stable
  channel.save(to: updateDefaults)
  return updateDefaults.synchronize() ? 0 : -1
}

// A retained async task at the Swift/C boundary, not a second update algorithm.
// Native Settings polls it on its UI thread and performs activation under the
// existing Configurator maintenance scope. No callback outlives a closed HWND.
private final class WindowsLanguageUpdate: @unchecked Sendable {
  enum Status: Int32 { case failed = -1, downloading = 0, verifying, ready, activating, completed, cancelled }
  let registry: LinnetDataRegistry
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var status = Status.downloading
  private var progress = 0.0
  private var message = ""
  private var candidate: LinnetDataRegistry.ActivationCandidate?
  private var activation: CheckedContinuation<Void, Error>?

  init(registry: LinnetDataRegistry) { self.registry = registry }

  func start(source: LinnetSettingsDownloadSource,
    channel: LinnetSettingsDownloadSource.UpdateChannel, complete: Bool, repair: Bool) {
    lock.lock()
    task = Task.detached { [self] in
      do {
        try await LinnetLanguageDataUpdate.run(
          registry: registry, transport: LinnetSettingsDownloadTransport(source: source),
          catalogURL: channel.catalogURL,
          edition: complete ? .full : nil,
          allowCompleteRepair: repair,
          progress: { [self] phase, value in report(phase, progress: value) },
          diagnostic: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) },
          activate: { [self] candidate in try await awaitNativeActivation(candidate) })
        finish(.completed)
      } catch is CancellationError {
        finish(.cancelled)
      } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
        finish(.cancelled)
      } catch {
        finish(.failed, message: error.localizedDescription)
      }
    }
    lock.unlock()
  }

  private func report(_ phase: LinnetLanguageDataUpdate.Phase, progress: Double) {
    lock.lock()
    defer { lock.unlock() }
    switch phase {
    case .downloading: status = .downloading
    case .verifying, .activating: status = .verifying
    }
    self.progress = progress
  }

  private func awaitNativeActivation(_ candidate: LinnetDataRegistry.ActivationCandidate) async throws {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        if Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        self.candidate = candidate
        activation = continuation
        status = .ready
        lock.unlock()
      }
    }, onCancel: { [self] in cancelWaitingActivation() })
  }

  private func cancelWaitingActivation() {
    lock.lock()
    let pending = status == .ready ? activation : nil
    if pending != nil { activation = nil; candidate = nil; status = .verifying }
    lock.unlock()
    pending?.resume(throwing: CancellationError())
  }

  func cancel() {
    lock.lock()
    let operation = status == .activating ? nil : task
    lock.unlock()
    operation?.cancel()
  }

  private func finish(_ status: Status, message: String = "") {
    lock.lock()
    defer { lock.unlock() }
    self.status = status
    self.message = message
    task = nil
  }

  func snapshot() -> (Status, Double, String) {
    lock.lock()
    defer { lock.unlock() }
    return (status, progress, message)
  }

  func publish() throws {
    lock.lock()
    guard status == .ready, let candidate else {
      lock.unlock()
      throw LinnetDataRegistry.Failure.invalidActiveState
    }
    status = .activating // From here native publication/recovery is not cancellable.
    lock.unlock()
    try registry.publishWindowsActivation(candidate)
  }

  func commit() throws {
    guard let candidate else { throw LinnetDataRegistry.Failure.invalidActiveState }
    try registry.commitDataChannelUpdate(transactionID: candidate.transactionID)
  }

  func restore() throws {
    guard let candidate else { throw LinnetDataRegistry.Failure.invalidActiveState }
    let active = try registry.loadActiveStateDocument().state
    if active.publication == .prepared {
      guard active.transactionID == candidate.transactionID else { throw LinnetDataRegistry.Failure.invalidActiveState }
      try registry.recoverPreparedLanguageActivation()
    }
  }

  func finishActivation(_ failure: String?) {
    lock.lock()
    let pending = activation
    activation = nil
    lock.unlock()
    if let failure {
      pending?.resume(throwing: NSError(domain: "Linnet.Windows.Activation", code: 1,
        userInfo: [NSLocalizedDescriptionKey: failure]))
    } else {
      pending?.resume()
    }
  }
}

private func languageUpdate(_ handle: UnsafeMutableRawPointer) -> WindowsLanguageUpdate {
  Unmanaged<WindowsLanguageUpdate>.fromOpaque(handle).takeUnretainedValue()
}

@_cdecl("linnet_data_update_start")
public func startLanguageUpdate(
  _ core: UnsafePointer<CChar>, _ user: UnsafePointer<CChar>, _ version: UnsafePointer<CChar>,
  _ complete: Int32, _ repair: Int32,
  _ context: UnsafeMutableRawPointer?, _ failed: @escaping DataError
) -> UnsafeMutableRawPointer? {
  do {
    let root = URL(fileURLWithPath: String(cString: user), isDirectory: true)
    let registry = try LinnetDataRegistry(productName: root.lastPathComponent,
      coreVersion: String(cString: version), applicationSupportDirectory: root.deletingLastPathComponent(),
      rootAccess: .existing, coreDataDirectory: URL(fileURLWithPath: String(cString: core), isDirectory: true))
    let preference = LinnetSettingsDownloadSource.load()
    if let failure = preference.failure { throw failure }
    guard let source = preference.source else { throw LinnetSettingsDownloadSource.Failure.invalidStoredMode }
    let operation = WindowsLanguageUpdate(registry: registry)
    operation.start(source: source, channel: selectedUpdateChannel,
      complete: complete != 0, repair: repair != 0)
    return Unmanaged.passRetained(operation).toOpaque()
  } catch {
    error.localizedDescription.withCString { failed(context, $0) }
    return nil
  }
}

public typealias DataProgress = @convention(c) (UnsafeMutableRawPointer?, Double, UnsafePointer<CChar>?) -> Void

@_cdecl("linnet_data_update_poll")
public func pollLanguageUpdate(_ handle: UnsafeMutableRawPointer, _ context: UnsafeMutableRawPointer?,
  _ receive: @escaping DataProgress) -> Int32 {
  let (status, progress, message) = languageUpdate(handle).snapshot()
  message.withCString { receive(context, progress, $0) }
  return status.rawValue
}

@_cdecl("linnet_data_update_cancel")
public func cancelLanguageUpdate(_ handle: UnsafeMutableRawPointer) { languageUpdate(handle).cancel() }

@_cdecl("linnet_data_update_release")
public func releaseLanguageUpdate(_ handle: UnsafeMutableRawPointer) {
  let operation = Unmanaged<WindowsLanguageUpdate>.fromOpaque(handle).takeRetainedValue()
  operation.cancel()
}

// These three calls run only inside Configurator::UpdateWorkspace. Errors cross
// the ABI synchronously and keep their message; native deployment owns rollback.
@_cdecl("linnet_data_update_mutate")
public func mutateLanguageUpdate(_ handle: UnsafeMutableRawPointer, _ action: Int32,
  _ context: UnsafeMutableRawPointer?, _ failed: @escaping DataError) -> Int32 {
  do {
    let operation = languageUpdate(handle)
    switch action {
    case 0: try operation.publish()
    case 1: try operation.commit()
    case 2: try operation.restore()
    default: throw LinnetDataRegistry.Failure.invalidActiveState
    }
    return 0
  } catch {
    error.localizedDescription.withCString { failed(context, $0) }
    return -1
  }
}

@_cdecl("linnet_data_update_finish_activation")
public func finishLanguageActivation(_ handle: UnsafeMutableRawPointer, _ failure: UnsafePointer<CChar>?) {
  languageUpdate(handle).finishActivation(failure.map(String.init(cString:)))
}

public typealias DataSourcePreference = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
  UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

@_cdecl("linnet_data_source_read")
public func readDataSource(_ context: UnsafeMutableRawPointer?, _ receive: @escaping DataSourcePreference) {
  let preference = LinnetSettingsDownloadSource.load()
  preference.mode.rawValue.withCString { mode in
    preference.mirrorPrefix.withCString { mirror in
      (preference.failure?.localizedDescription ?? "").withCString { receive(context, mode, mirror, $0) }
    }
  }
}

@_cdecl("linnet_data_source_save")
public func saveDataSource(_ mode: UnsafePointer<CChar>, _ mirror: UnsafePointer<CChar>,
  _ context: UnsafeMutableRawPointer?, _ failed: @escaping DataError) -> Int32 {
  do {
    let source: LinnetSettingsDownloadSource
    switch LinnetSettingsDownloadSource.Mode(rawValue: String(cString: mode)) {
    case .github: source = .direct
    case .publicMirror: source = .publicMirror
    case .customMirror: source = try .customMirror(prefix: String(cString: mirror))
    case nil: throw LinnetSettingsDownloadSource.Failure.invalidStoredMode
    }
    LinnetSettingsDownloadSource.save(source)
    return 0
  } catch {
    error.localizedDescription.withCString { failed(context, $0) }
    return -1
  }
}
