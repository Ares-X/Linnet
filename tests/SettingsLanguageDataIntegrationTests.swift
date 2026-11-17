import Foundation

/// Exercises the actual Model -> transport -> Registry update path. Only HTTP
/// delivery is controlled; catalog and complete-pack bytes pass their owners.
@MainActor
enum SettingsLanguageDataIntegrationTests {
  static func run(bundle: Bundle, registry: LinnetDataRegistry) async throws {
    let root = LinnetTestScratch.directory.appending(path: "language-downloads")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try Fixture(root: root, registry: registry)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LanguageDataHTTP.self]
    var models: [SettingsModel] = []
    defer { models.forEach { $0.cancelLanguagePackDownload() } }
    defer { LanguageDataHTTP.reset() }

    func model() async -> SettingsModel {
      let model = SettingsModel(bundle: bundle, downloadSessionConfiguration: configuration)
      models.append(model)
      // Do not save or replace the maintainer's real download preference.
      model.downloadSourceMode = .github
      model.activeDownloadSource = .direct
      await model.prepareInitialState()
      return model
    }
    func begin(_ model: SettingsModel) async throws -> LanguageDataHTTP {
      LanguageDataHTTP.install(catalog: fixture.catalog)
      model.downloadLanguageData(.currentEdition)
      return try await request(fixture.deltaURL)
    }
    func finish(_ model: SettingsModel, _ expected: SettingsPresentationPackState) async throws {
      try await wait("download did not finish as \(expected)") {
        !model.packDownloadActive && model.status == .pack(.languageData, expected)
      }
      try require(LanguageDataHTTP.requestURLs == [model.updateChecker.updateChannel.catalogURL, fixture.deltaURL],
        "a non-recoverable delta failure downloaded a complete pack")
      try require(try registry.runtimeSnapshot().state == fixture.baseline,
        "failed download changed the active data")
      try require(try FileManager.default.contentsOfDirectory(atPath: registry.downloadsDirectory.path).isEmpty,
        "failed download retained its transaction bytes")
    }

    for (error, expected) in [
      (URLError(.notConnectedToInternet) as Error, SettingsPresentationPackState.offline),
      (URLError(.timedOut) as Error, .downloadFailed),
      (NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteNoPermission.rawValue),
        .storageFailed),
    ] {
      let candidate = await model()
      let transfer = try await begin(candidate)
      transfer.fail(error)
      try await finish(candidate, expected)
    }

    // A real sink publication collision is storage failure, even though all
    // advertised delta bytes reached the transport. It must not fetch full.
    do {
      let candidate = await model()
      let transfer = try await begin(candidate)
      let directories = try FileManager.default.contentsOfDirectory(
        at: registry.downloadsDirectory, includingPropertiesForKeys: nil)
      try require(directories.count == 1, "download transaction missing")
      let collision = directories[0].appending(path: fixture.deltaURL.lastPathComponent)
      try Data("existing destination".utf8).write(to: collision, options: .withoutOverwriting)
      transfer.respond(body: fixture.corruptDelta)
      try await finish(candidate, .storageFailed)
    }

    // The first pack is still streaming. Progress must move before publication
    // or verification completes; cancellation must not turn into a full fetch.
    let cancelled = await model()
    let oldTransfer = try await begin(cancelled)
    oldTransfer.respondHeaders()
    oldTransfer.send(Data(fixture.corruptDelta.prefix(16)))
    try await wait("first-pack streaming progress stayed at zero") {
      cancelled.packDownloadProgress > 0 && cancelled.packDownloadProgress < 1
    }
    cancelled.cancelLanguagePackDownload()
    try await finish(cancelled, .cancelled)
    try require(cancelled.packDownloadProgress == 0, "cancelled progress was retained")
    try await wait("cancelled HTTP task was not stopped") { oldTransfer.stopped }

    // A SHA mismatch and a missing delta both permit a full transfer. Reaching
    // the English request proves the Chinese complete pack passed Registry
    // verification, rather than merely observing a fallback URL.
    for missing in [false, true] {
      let candidate = await model()
      let delta = try await begin(candidate)
      if missing { delta.respond(status: 404, body: Data()) }
      else { delta.respond(body: fixture.corruptDelta) }
      let full = try await request(fixture.chinese.url)
      try require(candidate.status == .pack(.languageData, .downloadingCompletePack),
        "full recovery was not presented as a complete transfer")
      try require(candidate.packDownloadProgress < 1,
        "failed delta left recovery looking complete")
      full.respondHeaders()
      full.send(Data(fixture.chineseBytes.prefix(fixture.chineseBytes.count / 2)))
      try await wait("complete fallback did not report streaming bytes") {
        candidate.packDownloadProgress > 0 && candidate.packDownloadProgress < 1
      }
      full.send(Data(fixture.chineseBytes.dropFirst(fixture.chineseBytes.count / 2)))
      full.finish()
      let english = try await request(fixture.english.url)
      let expected = Double(fixture.chineseBytes.count)
        / Double(fixture.chineseBytes.count + fixture.englishBytes.count)
      try await wait("second pack did not retain completed byte progress") {
        abs(candidate.packDownloadProgress - expected) < 0.000001
      }
      try require(candidate.status == .pack(.languageData, .downloading),
        "second pack retained the previous fallback state")
      english.respondHeaders()
      english.send(Data(fixture.englishBytes.prefix(fixture.englishBytes.count / 2)))
      try await wait("second-pack streaming progress did not advance") {
        candidate.packDownloadProgress > expected && candidate.packDownloadProgress < 1
      }
      try require(LanguageDataHTTP.requestURLs == [candidate.updateChecker.updateChannel.catalogURL, fixture.deltaURL,
        fixture.chinese.url, fixture.english.url], "fallback repeated or skipped an artifact")
      // The old protocol still has its delayed body. Resume it only after a new
      // transfer owns the Model, as a real late network delivery attempt.
      let currentProgress = candidate.packDownloadProgress
      let previousLateDeliveries = oldTransfer.lateDeliveries
      oldTransfer.sendLate(Data(fixture.corruptDelta.dropFirst(16)))
      oldTransfer.finishLate()
      try await wait("late delivery was not attempted") {
        oldTransfer.lateDeliveries == previousLateDeliveries + 2
      }
      try await Task.sleep(nanoseconds: 30_000_000)
      try require(candidate.packDownloadProgress == currentProgress
        && candidate.status == .pack(.languageData, .downloading),
        "cancelled transfer polluted the new transfer's state")
      candidate.cancelLanguagePackDownload()
      try await wait("second-pack cancellation did not settle") {
        !candidate.packDownloadActive && candidate.status == .pack(.languageData, .cancelled)
      }
      try await wait("second-pack HTTP task was not stopped") { english.stopped }
      try require(candidate.packDownloadProgress == 0, "second-pack cancellation retained progress")
      try require(try registry.runtimeSnapshot().state == fixture.baseline,
        "cancelled recovery changed active data")
    }
    print("SettingsLanguageDataIntegrationTests: PASS")
  }

  private struct Fixture {
    let baseline: LinnetDataRegistry.ActiveState
    let deltaURL: URL
    let corruptDelta = Data(repeating: 0x61, count: 64)
    let chinese: LinnetDataChannel.Artifact
    let english: LinnetDataChannel.Artifact
    let chineseBytes: Data
    let englishBytes: Data
    let catalog: Data

    init(root: URL, registry: LinnetDataRegistry) throws {
      baseline = try registry.runtimeSnapshot().state
      guard let base = baseline.packs.first(where: { $0.kind == .chinese }),
        let lts = baseline.packs.first(where: { $0.kind == .lts }) else {
        throw Failure(message: "fixture active packs unavailable")
      }
      chinese = try Self.pack(kind: .chinese, path: "linnet_zh.dict.yaml", root: root)
      english = try Self.pack(kind: .english, path: "linnet_en.dict.yaml", root: root)
      chineseBytes = try Data(contentsOf: root.appending(path: chinese.kind.releaseAssetName))
      englishBytes = try Data(contentsOf: root.appending(path: english.kind.releaseAssetName))
      deltaURL = URL(string: "https://github.com/Ares-X/Linnet/releases/download/data-5/"
        + base.kind.releaseAssetName.replacingOccurrences(of: ".linnetpack",
          with: "-from-\(base.contentSHA256).linnetdelta"))!
      var updatedChinese = chinese
      updatedChinese.deltas = [.init(baseContentSHA256: base.contentSHA256,
        bytes: 64, sha256: String(repeating: "0", count: 64), url: deltaURL)]
      func current(_ pack: LinnetDataRegistry.ActivePack) -> LinnetDataChannel.Artifact {
        .init(kind: pack.kind, version: pack.version, sequence: pack.sequence,
          dataABI: pack.dataABI, minCore: pack.minCore, contentSHA256: pack.contentSHA256,
          bytes: 1, containerSHA256: String(repeating: "b", count: 64),
          url: URL(string: "https://github.com/Ares-X/Linnet/releases/download/data-5/"
            + pack.kind.releaseAssetName)!)
      }
      let standard = [updatedChinese, english, current(lts)]
      let extended = LinnetDataChannel.Artifact(kind: .extended, version: "fixture-2",
        sequence: 2, dataABI: 1, minCore: "1.0.0", contentSHA256: String(repeating: "c", count: 64),
        bytes: 1, containerSHA256: String(repeating: "d", count: 64),
        url: URL(string: "https://github.com/Ares-X/Linnet/releases/download/data-5/Linnet-Extended.linnetpack")!)
      let channel = LinnetDataChannel.Catalog(format: LinnetDataChannel.legacyFormat,
        sequence: 5, core: .init(version: "1.0.0", build: 1,
          revision: String(repeating: "a", count: 40), bytes: 1,
          sha256: String(repeating: "b", count: 64), artifactFormat: .installerPackage,
          artifactURL: URL(string: "https://github.com/Ares-X/Linnet/releases/download/core-v1.0.0/Linnet-1.0.0-arm64-Core-community-beta.pkg")!,
          releaseURL: URL(string: "https://github.com/Ares-X/Linnet/releases/tag/core-v1.0.0")!),
        activationSets: [.init(edition: .standard, packs: standard),
          .init(edition: .full, packs: standard + [extended])])
      catalog = try LinnetDataChannel.canonicalCatalogData(channel)
      _ = try registry.verifyDataChannel(catalog)
    }

    private static func pack(
      kind: LinnetPackContract.Kind, path: String, root: URL
    ) throws -> LinnetDataChannel.Artifact {
      // Small deterministic, nontrivially compressed payloads keep weighted
      // progress observable without copying production dictionaries or Rime.
      let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
      let raw = root.appending(path: "\(kind.rawValue).raw")
      let zlib = root.appending(path: "\(kind.rawValue).zlib")
      try payload.write(to: raw)
      let encoded = try LinnetPackEncoder.compressZlib(source: raw, to: zlib)
      let manifest = LinnetPackContract.Manifest(format: LinnetPackContract.manifestFormat,
        product: LinnetPackContract.productIdentifier, packID: kind.packID, kind: kind,
        version: "fixture-2", sequence: 2, dataABI: 1, minCore: "1.0.0",
        contentSHA256: encoded.unpackedSHA256, requires: [],
        files: [.init(path: path, bytes: UInt64(payload.count), sha256: LinnetPackContract.sha256(payload))])
      let package = root.appending(path: kind.releaseAssetName)
      try LinnetPackEncoder.writeContainer(manifestData: LinnetPackContract.canonicalManifestData(manifest),
        payload: zlib, to: package)
      let bytes = try Data(contentsOf: package)
      _ = try LinnetPackContract.verify(package: package, coreVersion: "1.0.0")
      return .init(kind: kind, version: manifest.version, sequence: manifest.sequence,
        dataABI: manifest.dataABI, minCore: manifest.minCore,
        contentSHA256: manifest.contentSHA256, bytes: UInt64(bytes.count),
        containerSHA256: LinnetPackContract.sha256(bytes),
        url: URL(string: "https://github.com/Ares-X/Linnet/releases/download/data-5/" + kind.releaseAssetName)!)
    }
  }

  private static func request(_ url: URL) async throws -> LanguageDataHTTP {
    try await wait("missing HTTP request: \(url.lastPathComponent)") {
      LanguageDataHTTP.transfer(at: url) != nil
    }
    return LanguageDataHTTP.transfer(at: url)!
  }
  private static func wait(_ message: String, until ready: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    try require(ready(), message)
  }
  private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
  }
  private struct Failure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }
}

private final class LanguageDataHTTP: URLProtocol, @unchecked Sendable {
  private static let catalogURLs = [
    LinnetSettingsDownloadSource.canonicalCatalogURL,
    URL(string: "https://raw.githubusercontent.com/Ares-X/Linnet/preview-channel/Linnet-Data-Channel.json")!,
  ]
  private static let lock = NSLock()
  private static var catalog = Data()
  private static var transfers: [URL: LanguageDataHTTP] = [:]
  private static var urls: [URL] = []
  private let delivery = DispatchQueue(label: "Linnet.Tests.LanguageDataHTTP")
  private let stateLock = NSLock()
  private var didStop = false
  private var lateCount = 0

  static func install(catalog: Data) {
    lock.lock()
    self.catalog = catalog
    transfers = [:]
    urls = []
    lock.unlock()
  }
  static func reset() { install(catalog: Data()) }
  static var requestURLs: [URL] {
    lock.lock(); defer { lock.unlock() }; return urls
  }
  static func transfer(at url: URL) -> LanguageDataHTTP? {
    lock.lock(); defer { lock.unlock() }; return transfers[url]
  }
  var stopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return didStop }
  var lateDeliveries: Int { stateLock.lock(); defer { stateLock.unlock() }; return lateCount }
  override class func canInit(with request: URLRequest) -> Bool {
    guard let url = request.url else { return false }
    return catalogURLs.contains(url)
      || (url.scheme == "https" && url.host == "github.com"
        && url.path.hasPrefix("/Ares-X/Linnet/releases/download/data-5/"))
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    Self.lock.lock()
    Self.transfers[url] = self
    Self.urls.append(url)
    let catalog = Self.catalog
    Self.lock.unlock()
    if Self.catalogURLs.contains(url) { respond(body: catalog) }
  }
  override func stopLoading() { stateLock.lock(); didStop = true; stateLock.unlock() }
  func respondHeaders() {
    delivery.async { [self] in
      // Without a MIME type CFNetwork buffers these tiny chunks for sniffing,
      // so a paused small fixture would not exercise streaming at all.
      let response = HTTPURLResponse(url: request.url!, statusCode: 200,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
  }
  func respond(status: Int = 200, body: Data) {
    delivery.async { [self] in
      let response = HTTPURLResponse(url: request.url!, statusCode: status,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  func send(_ bytes: Data) {
    delivery.asyncAfter(deadline: .now() + 0.02) { [self] in
      client?.urlProtocol(self, didLoad: bytes)
    }
  }
  func finish() {
    delivery.asyncAfter(deadline: .now() + 0.04) { [self] in
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  func fail(_ error: Error) { delivery.async { [self] in client?.urlProtocol(self, didFailWithError: error) } }
  func sendLate(_ bytes: Data) {
    delivery.async { [self] in
      client?.urlProtocol(self, didLoad: bytes)
      stateLock.lock(); lateCount += 1; stateLock.unlock()
    }
  }
  func finishLate() {
    delivery.async { [self] in
      client?.urlProtocolDidFinishLoading(self)
      stateLock.lock(); lateCount += 1; stateLock.unlock()
    }
  }
}
