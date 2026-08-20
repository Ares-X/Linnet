import Foundation

/// The Settings process's only external byte-transfer boundary.
///
/// Catalog and pack identity remain owned by `LinnetDataChannel`; this only bounds
/// how untrusted HTTP bytes enter memory or a transaction directory. One instance
/// represents one update, so every request consumes the same monotonic deadline.
struct LinnetSettingsDownloadTransport: @unchecked Sendable {
  struct Policy: Sendable {
    static let production = Policy(
      idleTimeout: 60,
      catalogTimeout: 60,
      operationTimeout: 4 * 60 * 60,
      maximumRedirects: 5
    )

    let idleTimeout: TimeInterval
    let catalogTimeout: TimeInterval
    let operationTimeout: TimeInterval
    let maximumRedirects: Int
  }

  enum Failure: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case unsupportedContentEncoding
    case invalidContentLength
    case responseTooLarge
    case lengthMismatch
    case unsafeDestination
    case destinationExists
    case storage(Int32)

    var errorDescription: String? {
      switch self {
      case .invalidConfiguration: "The language-data downloader is not configured safely."
      case .invalidURL: "The language-data download URL is not trusted."
      case .invalidResponse: "The language-data service returned an invalid response."
      case .httpStatus(let status): "The language-data service returned HTTP \(status)."
      case .unsupportedContentEncoding:
        "The language-data service returned an unsupported content encoding."
      case .invalidContentLength:
        "The language-data service returned an invalid content length."
      case .responseTooLarge: "The language-data response exceeded its byte limit."
      case .lengthMismatch: "The language-data response ended at the wrong byte count."
      case .unsafeDestination: "The language-data download destination is unsafe."
      case .destinationExists: "The language-data download destination already exists."
      case .storage(let code): "The language-data download could not be stored (\(code))."
      }
    }
  }

  private let baseConfiguration: URLSessionConfiguration
  private let source: LinnetSettingsDownloadSource
  private let policy: Policy
  private let deadlineUptimeNanoseconds: UInt64

  init(
    source: LinnetSettingsDownloadSource,
    configuration: URLSessionConfiguration = .ephemeral,
    policy: Policy = .production
  ) {
    self.source = source
    baseConfiguration = configuration
    self.policy = policy
    let now = DispatchTime.now().uptimeNanoseconds
    let duration = Self.nanoseconds(policy.operationTimeout)
    let sum = now.addingReportingOverflow(duration)
    deadlineUptimeNanoseconds = sum.overflow ? UInt64.max : sum.partialValue
  }

  func downloadCatalog(at url: URL) async throws -> Data {
    let configuration = try configuredSession()
    let transfer = try Transfer(
      request: request(for: url, source: .direct),
      source: .direct,
      mode: .catalog(maximumBytes: UInt64(LinnetDataChannel.maximumCatalogBytes)),
      configuration: configuration,
      idleNanoseconds: Self.nanoseconds(policy.idleTimeout),
      deadlineUptimeNanoseconds: try deadline(maximum: policy.catalogTimeout),
      maximumRedirects: policy.maximumRedirects
    )
    guard let data = try await transfer.run() else { throw Failure.invalidResponse }
    return data
  }

  func downloadPack(_ artifact: LinnetDataChannel.Artifact, to destination: URL) async throws {
    guard artifact.bytes > 0,
      artifact.bytes <= LinnetPackContract.maximumContainerBytes
    else { throw Failure.responseTooLarge }
    let configuration = try configuredSession()
    let transfer = try Transfer(
      request: request(for: artifact.url, source: source),
      source: source,
      mode: .pack(expectedBytes: artifact.bytes, destination: destination),
      configuration: configuration,
      idleNanoseconds: Self.nanoseconds(policy.idleTimeout),
      deadlineUptimeNanoseconds: try deadline(maximum: policy.operationTimeout),
      maximumRedirects: policy.maximumRedirects
    )
    _ = try await transfer.run()
  }

  private func request(
    for url: URL, source requestSource: LinnetSettingsDownloadSource
  ) throws -> URLRequest {
    let routedURL: URL
    do {
      routedURL = try requestSource.requestURL(for: url)
    } catch {
      throw Failure.invalidURL
    }
    guard requestSource.allowsTransferURL(routedURL) else { throw Failure.invalidURL }
    var request = URLRequest(url: routedURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private func configuredSession() throws -> URLSessionConfiguration {
    guard policy.idleTimeout.isFinite, policy.idleTimeout > 0,
      policy.catalogTimeout.isFinite, policy.catalogTimeout > 0,
      policy.operationTimeout.isFinite, policy.operationTimeout > 0,
      policy.maximumRedirects >= 0,
      let configuration = baseConfiguration.copy() as? URLSessionConfiguration
    else { throw Failure.invalidConfiguration }
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    configuration.httpMaximumConnectionsPerHost = 1
    return configuration
  }

  private func deadline(maximum: TimeInterval) throws -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    let duration = Self.nanoseconds(maximum)
    let sum = now.addingReportingOverflow(duration)
    let localDeadline = sum.overflow ? UInt64.max : sum.partialValue
    let result = min(deadlineUptimeNanoseconds, localDeadline)
    guard duration > 0, result > now else {
      throw URLError(.timedOut)
    }
    return result
  }

  private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    let value = seconds * 1_000_000_000
    guard value < Double(UInt64.max) else { return UInt64.max }
    return UInt64(value.rounded(.up))
  }
}

private extension LinnetSettingsDownloadTransport {
  final class Transfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    enum Mode {
      case catalog(maximumBytes: UInt64)
      case pack(expectedBytes: UInt64, destination: URL)

      var maximumBytes: UInt64 {
        switch self {
        case .catalog(let maximumBytes): maximumBytes
        case .pack(let expectedBytes, _): expectedBytes
        }
      }
    }

    private let request: URLRequest
    private let source: LinnetSettingsDownloadSource
    private let mode: Mode
    private let configuration: URLSessionConfiguration
    private let idleNanoseconds: UInt64
    private let deadlineUptimeNanoseconds: UInt64
    private let maximumRedirects: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timeoutTask: Task<Void, Never>?
    private var terminal = false
    private var cancellationRequested = false
    private var responseAccepted = false
    private var declaredLength: UInt64?
    private var receivedBytes: UInt64 = 0
    private var lastProgressUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var redirects = 0
    private var catalogData = Data()
    private var sink: LinnetSettingsExclusiveFileSink?

    init(request: URLRequest, source: LinnetSettingsDownloadSource, mode: Mode,
      configuration: URLSessionConfiguration,
      idleNanoseconds: UInt64, deadlineUptimeNanoseconds: UInt64,
      maximumRedirects: Int) throws {
      guard let url = request.url, source.allowsTransferURL(url) else {
        throw Failure.invalidURL
      }
      guard idleNanoseconds > 0,
        deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds
      else { throw Failure.invalidConfiguration }
      self.request = request
      self.source = source
      self.mode = mode
      self.configuration = configuration
      self.idleNanoseconds = idleNanoseconds
      self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
      self.maximumRedirects = maximumRedirects
      if case .pack(_, let destination) = mode {
        sink = try LinnetSettingsExclusiveFileSink(destination: destination)
      }
    }

    func run() async throws -> Data? {
      try await withTaskCancellationHandler(
        operation: {
          try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
            let session = URLSession(
              configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)
            lock.lock()
            self.continuation = continuation
            self.session = session
            self.task = task
            let timeoutTask = Task.detached { [weak self] in
              guard let self else { return }; await self.watchTimeout()
            }
            self.timeoutTask = timeoutTask
            let cancel = cancellationRequested
            lock.unlock()
            task.resume()
            if cancel { task.cancel() }
          }
        },
        onCancel: { [self] in cancel() }
      )
    }

    func cancel() {
      lock.lock()
      cancellationRequested = true
      let task = task
      lock.unlock()
      task?.cancel()
    }

    private func watchTimeout() async {
      while !Task.isCancelled {
        guard let nextDeadline = nextTimeoutDeadline() else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard nextDeadline > now else {
          complete(.failure(URLError(.timedOut)))
          return
        }
        do { try await Task.sleep(nanoseconds: nextDeadline - now) }
        catch { return }
      }
    }

    private func nextTimeoutDeadline() -> UInt64? {
      lock.lock()
      defer { lock.unlock() }
      guard !terminal else { return nil }
      let idleSum = lastProgressUptimeNanoseconds.addingReportingOverflow(idleNanoseconds)
      let idleDeadline = idleSum.overflow ? UInt64.max : idleSum.partialValue
      return min(deadlineUptimeNanoseconds, idleDeadline)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void) {
      lock.lock()
      redirects += 1
      let allowed = !terminal && redirects <= maximumRedirects
        && request.url.map(source.allowsTransferURL) == true
      if allowed { lastProgressUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds }
      lock.unlock()
      guard allowed else {
        completionHandler(nil)
        complete(.failure(Failure.invalidURL))
        return
      }
      completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
      let validation: Result<UInt64?, Error>
      do {
        validation = .success(try validate(response))
      } catch {
        validation = .failure(error)
      }
      switch validation {
      case .failure(let error):
        completionHandler(.cancel)
        complete(.failure(error))
      case .success(let length):
        lock.lock()
        guard !terminal, !responseAccepted else {
          lock.unlock()
          completionHandler(.cancel)
          complete(.failure(Failure.invalidResponse))
          return
        }
        responseAccepted = true
        declaredLength = length
        lastProgressUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        if case .catalog = mode, let length {
          catalogData.reserveCapacity(Int(length))
        }
        lock.unlock()
        completionHandler(.allow)
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
      didReceive data: Data) {
      var failure: Error?
      lock.lock()
      if !terminal && responseAccepted {
        let count = UInt64(data.count)
        if count > mode.maximumBytes - receivedBytes {
          failure = Failure.responseTooLarge
        } else {
          do {
            switch mode {
            case .catalog:
              catalogData.append(data)
            case .pack:
              guard let sink else { throw Failure.invalidResponse }
              try sink.write(data)
            }
            receivedBytes += count
            if count > 0 {
              lastProgressUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            }
          } catch {
            failure = error
          }
        }
      }
      lock.unlock()
      if let failure { complete(.failure(failure)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
      didCompleteWithError error: Error?) {
      if let error {
        lock.lock()
        let cancelled = cancellationRequested
        lock.unlock()
        complete(.failure(cancelled ? CancellationError() : error))
        return
      }

      lock.lock()
      let accepted = responseAccepted
      let declared = declaredLength
      let received = receivedBytes
      let data = catalogData
      lock.unlock()
      guard accepted else {
        complete(.failure(Failure.invalidResponse))
        return
      }
      if let declared, declared != received {
        complete(.failure(Failure.lengthMismatch))
        return
      }
      switch mode {
      case .catalog:
        complete(.success(data))
      case .pack(let expected, _):
        guard received == expected else {
          complete(.failure(Failure.lengthMismatch))
          return
        }
        complete(.success(nil), publishingFile: true)
      }
    }

    private func validate(_ response: URLResponse) throws -> UInt64? {
      guard let response = response as? HTTPURLResponse,
        response.url.map(source.allowsTransferURL) == true
      else { throw Failure.invalidResponse }
      guard response.statusCode == 200 else { throw Failure.httpStatus(response.statusCode) }
      if let encoding = response.value(forHTTPHeaderField: "Content-Encoding") {
        guard encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          == "identity"
        else { throw Failure.unsupportedContentEncoding }
      }
      let length = try Self.contentLength(response)
      if let length {
        switch mode {
        case .catalog:
          guard length <= mode.maximumBytes else { throw Failure.responseTooLarge }
        case .pack(let expected, _):
          guard length == expected else { throw Failure.lengthMismatch }
        }
      }
      if case .pack = mode, sink == nil { throw Failure.invalidResponse }
      return length
    }

    private static func contentLength(_ response: HTTPURLResponse) throws -> UInt64? {
      guard let value = response.value(forHTTPHeaderField: "Content-Length") else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
        trimmed.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
        let length = UInt64(trimmed)
      else { throw Failure.invalidContentLength }
      return length
    }

    private func complete(_ proposed: Result<Data?, Error>, publishingFile: Bool = false) {
      lock.lock()
      guard !terminal else {
        lock.unlock()
        return
      }
      var result = proposed
      if publishingFile {
        do {
          guard let sink else { throw Failure.invalidResponse }
          try sink.publish()
        } catch {
          result = .failure(error)
        }
      }
      if case .failure = result, let sink {
        do {
          try sink.discard()
        } catch {
          result = .failure(error)
        }
      }
      sink = nil
      terminal = true
      let continuation = continuation
      self.continuation = nil
      let session = session
      self.session = nil
      let timeoutTask = timeoutTask
      self.timeoutTask = nil
      task = nil
      lock.unlock()

      timeoutTask?.cancel()
      switch result {
      case .success: session?.finishTasksAndInvalidate()
      case .failure: session?.invalidateAndCancel()
      }
      continuation?.resume(with: result)
    }
  }
}
