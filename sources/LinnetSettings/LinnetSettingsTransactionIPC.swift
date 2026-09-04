import Darwin
import Foundation

protocol LinnetSettingsTransactionRequesting: AnyObject {
  func request(
    _ request: LinnetSettingsContract.DataRequest,
    timeout: TimeInterval,
    onProgress: @escaping @Sendable (LinnetSettingsContract.RuntimeReply) -> Void
  ) async throws -> LinnetSettingsContract.RuntimeReply
}

/// The one authoritative Settings <-> Host transaction boundary. Both ends
/// authenticate the connected Unix-domain peer inside the product's same-user
/// trust domain using kernel-owned UID/PID facts before any JSON is decoded.
/// The owner-only endpoint remains stable while Core updates atomically replace
/// the app bundle; executable paths are deliberately not runtime identity
/// because a still-running InputMethodKit Host can outlive its old pathname.
enum LinnetSettingsTransactionIPC {
  enum Failure: Error, Equatable {
    case unavailable
    case invalidMessage
    case timedOut
  }

  typealias Reply = (LinnetSettingsContract.RuntimeReply) -> Void
  typealias Handler = (LinnetSettingsContract.DataRequest, @escaping Reply) -> Void

  final class Host: @unchecked Sendable {
    private let endpointURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "io.github.ares-x.linnet.settings-ipc")
    private let transactionQueue = DispatchQueue(
      label: "io.github.ares-x.linnet.settings-ipc.transaction",
      qos: .userInitiated)
    private var listenerIdentity: (dev_t, ino_t)?
    private var source: DispatchSourceRead?

    convenience init(startingAt bundle: Bundle = .main, handler: @escaping Handler) throws {
      self.init(endpointURL: try liveEndpoint(startingAt: bundle), handler: handler)
    }

    private init(endpointURL: URL, handler: @escaping Handler) {
      self.endpointURL = endpointURL
      self.handler = handler
    }

    func start() throws {
      guard source == nil else { return }
      try LinnetSettingsTransactionIPC.prepareEndpointParent(
        endpointURL.deletingLastPathComponent())
      try LinnetSettingsTransactionIPC.removeStaleSocket(at: endpointURL)
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw Failure.unavailable }
      var boundIdentity: (dev_t, ino_t)?
      do {
        try withSocketAddress(endpointURL.path) { address, length in
          guard Darwin.bind(fd, address, length) == 0 else { throw Failure.unavailable }
        }
        var info = stat()
        guard lstat(endpointURL.path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFSOCK,
          info.st_uid == geteuid()
        else { throw Failure.unavailable }
        boundIdentity = (info.st_dev, info.st_ino)
        guard chmod(endpointURL.path, S_IRUSR | S_IWUSR) == 0,
          listen(fd, 8) == 0
        else { throw Failure.unavailable }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection(from: fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listenerIdentity = (info.st_dev, info.st_ino)
        self.source = source
        source.resume()
      } catch {
        Darwin.close(fd)
        if let boundIdentity {
          var current = stat()
          if lstat(endpointURL.path, &current) == 0,
            current.st_dev == boundIdentity.0, current.st_ino == boundIdentity.1 {
            try? FileManager.default.removeItem(at: endpointURL)
          }
        }
        throw error
      }
    }

    func stop() {
      let source = self.source
      self.source = nil
      let socketIdentity = listenerIdentity
      listenerIdentity = nil
      source?.cancel()
      guard let socketIdentity else { return }
      var info = stat()
      if lstat(endpointURL.path, &info) == 0,
        info.st_dev == socketIdentity.0, info.st_ino == socketIdentity.1 {
        try? FileManager.default.removeItem(at: endpointURL)
      }
    }

    deinit { stop() }

    private func acceptConnection(from listener: Int32) {
      let fd = accept(listener, nil, nil)
      guard fd >= 0 else { return }
      let channel = Channel(fd: fd)
      transactionQueue.async { [weak self] in
        guard let self else {
          channel.close()
          return
        }
        self.receiveRequest(on: channel)
      }
    }

    private func receiveRequest(on channel: Channel) {
      guard let pid = peerPID(channel.fd),
        peerIsSameUser(channel.fd), pid != getpid(),
        let payload = try? channel.readFrame(deadline: Date().addingTimeInterval(3)),
        let request = try? decode(LinnetSettingsContract.DataRequest.self, from: payload),
        LinnetSettingsContract.validDataRequest(request),
        request.requesterPID == pid
      else {
        channel.close()
        return
      }
      let sendReply: Reply = { reply in
        guard reply.transactionID == request.transactionID,
          LinnetSettingsContract.validRuntimeReply(reply),
          let payload = try? encode(reply)
        else { return }
        self.queue.async {
          let deadline = Date().addingTimeInterval(3)
          guard (try? channel.writeFrame(payload, deadline: deadline)) != nil else {
            channel.close()
            return
          }
          if reply.status != .verifying { channel.close() }
        }
      }
      guard request.command != .pause
        || request.nativeLearningDataVersion == LinnetSettingsContract.nativeLearningDataVersion
      else {
        sendReply(.init(
          transactionID: request.transactionID,
          status: .rejected,
          code: .requesterUnavailable,
          detail: "The requested native learning-data view is unavailable.",
          health: nil))
        return
      }
      handler(request, sendReply)
    }
  }

  final class Client: LinnetSettingsTransactionRequesting, @unchecked Sendable {
    private let bundle: Bundle

    init(startingAt bundle: Bundle = .main) { self.bundle = bundle }

    func request(
      _ request: LinnetSettingsContract.DataRequest,
      timeout: TimeInterval,
      onProgress: @escaping @Sendable (LinnetSettingsContract.RuntimeReply) -> Void
    ) async throws -> LinnetSettingsContract.RuntimeReply {
      guard LinnetSettingsContract.validDataRequest(request), timeout > 0 else {
        throw Failure.invalidMessage
      }
      let endpointURL = try liveEndpoint(startingAt: bundle)
      return try await Task.detached(priority: .userInitiated) {
        try Self.perform(
          request, timeout: timeout, endpointURL: endpointURL, progress: onProgress)
      }.value
    }

    private static func perform(
      _ request: LinnetSettingsContract.DataRequest,
      timeout: TimeInterval,
      endpointURL: URL,
      progress: @Sendable (LinnetSettingsContract.RuntimeReply) -> Void
    ) throws -> LinnetSettingsContract.RuntimeReply {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw Failure.unavailable }
      let channel = Channel(fd: fd)
      defer { channel.close() }
      let deadline = Date().addingTimeInterval(timeout)
      try withSocketAddress(endpointURL.path) { address, length in
        try connectUnixSocket(
          fd: fd, address: address, length: length, deadline: deadline)
      }
      guard peerIsSameUser(fd) else {
        throw Failure.unavailable
      }
      try channel.writeFrame(try encode(request), deadline: deadline)
      while true {
        let payload = try channel.readFrame(deadline: deadline)
        guard let reply = try? decode(LinnetSettingsContract.RuntimeReply.self, from: payload),
          reply.transactionID == request.transactionID,
          LinnetSettingsContract.validRuntimeReply(reply)
        else { throw Failure.invalidMessage }
        guard reply.status != .verifying else {
          progress(reply)
          continue
        }
        return reply
      }
    }
  }
}

extension LinnetSettingsTransactionIPC {
  private final class Channel: @unchecked Sendable {
    let fd: Int32
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    deinit { close() }

    func readFrame(deadline: Date) throws -> Data {
      let header = try read(count: 4, deadline: deadline)
      let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard length > 0, length <= 64 * 1024 else { throw Failure.invalidMessage }
      return try read(count: Int(length), deadline: deadline)
    }

    func writeFrame(_ payload: Data, deadline: Date) throws {
      guard !payload.isEmpty, payload.count <= 64 * 1024 else {
        throw Failure.invalidMessage
      }
      var length = UInt32(payload.count).bigEndian
      guard !closed else { throw Failure.unavailable }
      var frame = withUnsafeBytes(of: &length) { Data($0) }
      frame.append(payload)
      try write(frame, deadline: deadline)
    }

    func close() {
      guard !closed else { return }
      closed = true
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
    }

    private func read(count: Int, deadline: Date) throws -> Data {
      var data = Data(count: count)
      var offset = 0
      while offset < count {
        try wait(for: Int16(POLLIN), until: deadline)
        let readCount = data.withUnsafeMutableBytes { buffer in
          Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
        }
        if readCount < 0, errno == EINTR { continue }
        guard readCount > 0 else { throw Failure.unavailable }
        offset += readCount
      }
      return data
    }

    private func write(_ data: Data, deadline: Date) throws {
      var offset = 0
      while offset < data.count {
        try wait(for: Int16(POLLOUT), until: deadline)
        let written = data.withUnsafeBytes { buffer in
          send(
            fd, buffer.baseAddress!.advanced(by: offset), data.count - offset,
            MSG_DONTWAIT | MSG_NOSIGNAL)
        }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw Failure.unavailable }
        offset += written
      }
    }

    private func wait(for event: Int16, until deadline: Date) throws {
      while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw Failure.timedOut }
        var descriptor = pollfd(fd: fd, events: event, revents: 0)
        let result = poll(&descriptor, 1, Int32(min(remaining * 1_000, 30_000)))
        if result == 0 || (result < 0 && errno == EINTR) { continue }
        guard result > 0, descriptor.revents & event != 0 else {
          throw Failure.unavailable
        }
        return
      }
    }
  }

  private static func liveEndpoint(startingAt bundle: Bundle) throws -> URL {
    guard let registry = LinnetSettingsContract.dataRegistry(startingAt: bundle)
    else { throw Failure.unavailable }
    let endpointURL = registry.rootDirectory.appending(
      path: "State/settings-transaction.sock", directoryHint: .notDirectory)
    let endpoint = endpointURL.standardizedFileURL
    guard endpointURL.isFileURL, endpoint.path.hasPrefix("/")
    else { throw Failure.unavailable }
    return endpoint
  }

  private static func peerIsSameUser(_ descriptor: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(descriptor, &uid, &gid) == 0 && uid == geteuid()
  }

  private static func connectUnixSocket(
    fd: Int32,
    address: UnsafePointer<sockaddr>,
    length: socklen_t,
    deadline: Date
  ) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw Failure.unavailable
    }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    if Darwin.connect(fd, address, length) == 0 { return }
    guard errno == EINPROGRESS else { throw Failure.unavailable }
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw Failure.timedOut }
      var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      let result = poll(&descriptor, 1, Int32(min(remaining * 1_000, 30_000)))
      if result == 0 { continue }
      guard result > 0 else { throw Failure.unavailable }
      var error: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0
      else { throw Failure.unavailable }
      return
    }
  }

  private static func peerPID(_ fd: Int32) -> pid_t? {
    var pid: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0
    else { return nil }
    return pid
  }

  private static func prepareEndpointParent(_ parent: URL) throws {
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(parent.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == geteuid(), (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unavailable }
  }

  private static func removeStaleSocket(at url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      guard errno == ENOENT else { throw Failure.unavailable }
      return
    }
    guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid()
    else { throw Failure.unavailable }
    let staleIdentity = (info.st_dev, info.st_ino)
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { throw Failure.unavailable }
    defer { Darwin.close(probe) }
    let connectionError = try withSocketAddress(url.path) { address, length in
      if Darwin.connect(probe, address, length) == 0 { return Int32(0) }
      return errno
    }
    // A successful connection proves a live owner. Any result other than a
    // refused connection is ambiguous and therefore also fails closed.
    guard connectionError == ECONNREFUSED else { throw Failure.unavailable }
    guard lstat(url.path, &info) == 0,
      info.st_dev == staleIdentity.0, info.st_ino == staleIdentity.1
    else { throw Failure.unavailable }
    try FileManager.default.removeItem(at: url)
  }

  private static func withSocketAddress<T>(
    _ path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
  ) throws -> T {
    let bytes = Array(path.utf8CString)
    var address = sockaddr_un()
    let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
      offset + bytes.count <= Int(UInt8.max)
    else { throw Failure.unavailable }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(offset + bytes.count)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      for index in bytes.indices {
        destination[index] = UInt8(bitPattern: bytes[index])
      }
    }
    let length = socklen_t(address.sun_len)
    return try withUnsafePointer(to: &address) {
      try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        try body($0, length)
      }
    }
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
  }

}
