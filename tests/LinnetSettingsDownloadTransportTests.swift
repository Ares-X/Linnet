import Darwin
import Foundation

@main
struct LinnetSettingsDownloadTransportTests {
  private enum TestFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
      switch self { case .message(let message): message }
    }
  }

  static func main() async {
    do {
      try await catalogMatrix()
      try await packMatrix()
      try await redirectMatrix()
      try await publicMirrorMatrix()
      try await mirrorMatrix()
      try await freshInstallReplayFloorMatrix()
      try await cancellationAndTimeoutMatrix()
      print("LinnetSettingsDownloadTransportTests: PASS")
    } catch {
      FileHandle.standardError.write(Data("Transport test failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func catalogMatrix() async throws {
    let body = Data("data".utf8)
    var result = try await catalog(
      .response(headers: ["Content-Length": "4", "Content-Encoding": "identity"]),
      .data(Data("da".utf8)), .data(Data("ta".utf8)), .finish)
    try require(result == body, "catalog exact body")
    try require(
      StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Accept-Encoding") == "identity",
      "identity encoding request")
    try assertPublicRequestHeaders(StubURLProtocol.requests.last)

    result = try await catalog(
      .response(headers: [:]), .data(Data("da".utf8)), .data(Data("ta".utf8)), .finish)
    try require(result == body, "catalog without Content-Length")

    let maximumBody = Data(repeating: 0x61, count: LinnetDataChannel.maximumCatalogBytes)
    result = try await catalog(
      .response(headers: ["Content-Length": "\(maximumBody.count)"]),
      .data(maximumBody), .finish)
    try require(result == maximumBody, "catalog rejected the exact byte maximum")

    try await expect(.httpStatus(503)) {
      _ = try await catalog(.response(status: 503), .finish)
    }
    try await expect(.invalidResponse) {
      _ = try await catalog(.nonHTTPResponse, .finish)
    }
    try await expect(.unsupportedContentEncoding) {
      _ = try await catalog(
        .response(headers: ["Content-Encoding": "gzip"]), .data(body), .finish)
    }
    try await expect(.invalidContentLength) {
      _ = try await catalog(
        .response(headers: ["Content-Length": "4, 4"]), .data(body), .finish)
    }
    try await expect(.responseTooLarge) {
      _ = try await catalog(
        .response(headers: [
          "Content-Length": "\(LinnetDataChannel.maximumCatalogBytes + 1)"
        ]), .finish)
    }
    try await expect(.responseTooLarge) {
      _ = try await catalog(
        .response(headers: [:]),
        .data(Data(repeating: 0x61, count: LinnetDataChannel.maximumCatalogBytes)),
        .data(Data([0x62])), .finish)
    }
    try await expect(.lengthMismatch) {
      _ = try await catalog(
        .response(headers: ["Content-Length": "4"]),
        .data(Data("bad".utf8)), .finish)
    }
  }

  private static func packMatrix() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let body = Data("pack".utf8)

    let oversizedDestination = root.appending(path: "oversized.linnetpack")
    try await expect(.responseTooLarge, requiresStop: false) {
      StubURLProtocol.install([.response(headers: [:]), .finish])
      try await transport().downloadPack(
        artifact(bytes: LinnetPackContract.maximumContainerBytes + 1),
        to: oversizedDestination)
    }
    try assertUnpublished(oversizedDestination, root: root, label: "oversized artifact")

    var destination = root.appending(path: "exact.linnetpack")
    try await pack(body, destination: destination,
      .response(headers: [:]), .data(Data("pa".utf8)), .data(Data("ck".utf8)), .finish)
    try require(try Data(contentsOf: destination) == body, "streamed exact pack")
    try require(try partials(in: root).isEmpty, "success left no partial")

    destination = root.appending(path: "matching.linnetpack")
    try await pack(body, destination: destination,
      .response(headers: ["Content-Length": "4"]), .data(body), .finish)
    try require(try Data(contentsOf: destination) == body, "matching length pack")

    destination = root.appending(path: "wrong-header.linnetpack")
    try await expect(.lengthMismatch) {
      try await pack(body, destination: destination,
        .response(headers: ["Content-Length": "5"]), .data(body), .finish)
    }
    try assertUnpublished(destination, root: root, label: "wrong header")

    destination = root.appending(path: "status.linnetpack")
    try await expect(.httpStatus(503)) {
      try await pack(body, destination: destination, .response(status: 503), .finish)
    }
    try assertUnpublished(destination, root: root, label: "HTTP status")

    destination = root.appending(path: "non-http.linnetpack")
    try await expect(.invalidResponse) {
      try await pack(body, destination: destination, .nonHTTPResponse, .finish)
    }
    try assertUnpublished(destination, root: root, label: "non-HTTP response")

    destination = root.appending(path: "encoding.linnetpack")
    try await expect(.unsupportedContentEncoding) {
      try await pack(body, destination: destination,
        .response(headers: ["Content-Encoding": "gzip"]), .data(body), .finish)
    }
    try assertUnpublished(destination, root: root, label: "content encoding")

    destination = root.appending(path: "invalid-length.linnetpack")
    try await expect(.invalidContentLength) {
      try await pack(body, destination: destination,
        .response(headers: ["Content-Length": "4, 4"]), .data(body), .finish)
    }
    try assertUnpublished(destination, root: root, label: "invalid Content-Length")

    destination = root.appending(path: "overflow.linnetpack")
    try await expect(.responseTooLarge) {
      try await pack(body, destination: destination,
        .response(headers: [:]), .data(Data("pac".utf8)), .data(Data("kx".utf8)), .finish)
    }
    try assertUnpublished(destination, root: root, label: "overflow")

    destination = root.appending(path: "short.linnetpack")
    try await expect(.lengthMismatch) {
      try await pack(body, destination: destination,
        .response(headers: [:]), .data(Data("pac".utf8)), .finish)
    }
    try assertUnpublished(destination, root: root, label: "short EOF")

    let sentinel = root.appending(path: "sentinel")
    try Data("sentinel".utf8).write(to: sentinel)
    destination = root.appending(path: "existing-symlink.linnetpack")
    try FileManager.default.createSymbolicLink(
      atPath: destination.path, withDestinationPath: sentinel.path)
    try await expect(.destinationExists, requiresStop: false) {
      try await pack(body, destination: destination,
        .response(headers: [:]), .data(body), .finish)
    }
    try require(try Data(contentsOf: sentinel) == Data("sentinel".utf8), "symlink target")
    try require(
      try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
      "destination symlink preserved")
    try require(try partials(in: root).isEmpty, "existing symlink left partial")
    try FileManager.default.removeItem(at: destination)

    destination = root.appending(path: "existing-file.linnetpack")
    try Data("existing".utf8).write(to: destination)
    try await expect(.destinationExists, requiresStop: false) {
      try await pack(body, destination: destination,
        .response(headers: [:]), .data(body), .finish)
    }
    try require(try Data(contentsOf: destination) == Data("existing".utf8), "existing file")
    try require(try partials(in: root).isEmpty, "existing file left partial")
    try FileManager.default.removeItem(at: destination)

    let readOnly = root.appending(path: "read-only", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
    destination = readOnly.appending(path: "storage.linnetpack")
    let storageGenerationBefore = StubURLProtocol.currentGeneration
    do {
      try await pack(body, destination: destination,
        .response(headers: [:]), .data(body), .finish)
      throw TestFailure.message("read-only destination accepted")
    } catch let failure as LinnetSettingsDownloadTransport.Failure {
      guard case .storage = failure else { throw failure }
    }
    try assertNoProtocolStarted(after: storageGenerationBefore, label: "storage preflight")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
    try assertUnpublished(destination, root: readOnly, label: "storage failure")

    destination = root.appending(path: "appeared.linnetpack")
    let appearedGeneration = StubURLProtocol.install([
      .response(headers: [:]), .suspend, .data(body), .finish,
    ])
    let appearedTransport = transport()
    let appearedArtifact = artifact(bytes: 4)
    let appearedTask = Task.detached {
      try await appearedTransport.downloadPack(appearedArtifact, to: destination)
    }
    do {
      try await waitForPartial(in: root)
    } catch {
      let setupError = error
      appearedTask.cancel()
      StubURLProtocol.resume()
      _ = try? await appearedTask.value
      throw setupError
    }
    try FileManager.default.createSymbolicLink(
      atPath: destination.path, withDestinationPath: sentinel.path)
    StubURLProtocol.resume()
    do {
      try await appearedTask.value
      throw TestFailure.message("mid-transfer destination accepted")
    } catch let failure as LinnetSettingsDownloadTransport.Failure {
      guard case .storage = failure else { throw failure }
    }
    try require(try Data(contentsOf: sentinel) == Data("sentinel".utf8), "appeared target")
    try require(try partials(in: root).isEmpty, "appeared destination left partial")
    try await waitForStop(generation: appearedGeneration)
  }

  private static func redirectMatrix() async throws {
    StubURLProtocol.install([
      .redirect(URL(string: "https://release-assets.githubusercontent.com/final")!),
      .response(headers: ["Content-Length": "4"]), .data(Data("data".utf8)), .finish,
    ])
    let redirected = try await transport().downloadCatalog(at: catalogURL)
    try require(redirected == Data("data".utf8), "allowed HTTPS redirect")

    for url in [
      URL(string: "http://release-assets.githubusercontent.com/final")!,
      URL(string: "https://example.com/final")!,
    ] {
      try await expect(.invalidURL) {
        StubURLProtocol.install([.redirect(url)])
        _ = try await transport().downloadCatalog(at: catalogURL)
      }
    }

    try await expect(.invalidURL) {
      StubURLProtocol.install([
        .redirect(URL(string: "https://release-assets.githubusercontent.com/one")!),
        .redirect(URL(string: "https://release-assets.githubusercontent.com/two")!),
        .redirect(URL(string: "https://release-assets.githubusercontent.com/three")!),
      ])
      _ = try await transport(
        policy: .init(
          idleTimeout: 1, catalogTimeout: 1, operationTimeout: 1, maximumRedirects: 2)
      ).downloadCatalog(at: catalogURL)
    }

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "redirect-rejected.linnetpack")
    try await expect(.invalidURL) {
      StubURLProtocol.install([.redirect(URL(string: "https://example.com/pack")!)])
      try await transport().downloadPack(artifact(bytes: 4), to: destination)
    }
    try assertUnpublished(destination, root: root, label: "rejected pack redirect")
  }

  private static func mirrorMatrix() async throws {
    let source = try LinnetSettingsDownloadSource.customMirror(
      prefix: "https://mirror.example.com/")
    let body = Data("data".utf8)
    StubURLProtocol.install([
      .response(headers: ["Content-Length": "4"]), .data(body), .finish,
    ])
    let catalog = try await transport(source: source).downloadCatalog(
      at: LinnetSettingsDownloadSource.canonicalCatalogURL)
    try require(catalog == body, "mirror catalog body")
    try require(
      StubURLProtocol.requests.count == 1,
      "mirror catalog used retry or fallback")
    try require(
      StubURLProtocol.requests[0].url?.absoluteString
        == LinnetSettingsDownloadSource.canonicalCatalogURL.absoluteString,
      "custom mirror replaced the canonical catalog route")
    try assertPublicRequestHeaders(StubURLProtocol.requests.first)

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "mirror.linnetpack")
    StubURLProtocol.install([
      .response(headers: ["Content-Length": "4"]), .data(Data("pack".utf8)), .finish,
    ])
    try await transport(source: source).downloadPack(
      artifact(bytes: 4), to: destination)
    try require(try Data(contentsOf: destination) == Data("pack".utf8), "mirror pack")
    try require(
      StubURLProtocol.requests.count == 1,
      "mirror pack used retry or fallback")
    try require(
      StubURLProtocol.requests[0].url?.absoluteString
        == "https://mirror.example.com/https://github.com/Ares-X/Linnet/releases/download/data-1/Linnet-Chinese.linnetpack",
      "mirror pack request URL")

    try await expect(.invalidURL) {
      StubURLProtocol.install([
        .redirect(URL(string: "https://mirror.example.com/final")!)])
      _ = try await transport(source: source).downloadCatalog(
        at: LinnetSettingsDownloadSource.canonicalCatalogURL)
    }
    try require(StubURLProtocol.requests.count == 1, "catalog tried a mirror fallback")
  }

  private static func publicMirrorMatrix() async throws {
    let source = LinnetSettingsDownloadSource.publicMirror
    let body = Data("data".utf8)
    StubURLProtocol.install([
      .response(headers: ["Content-Length": "4"]), .data(body), .finish,
    ])
    let catalog = try await transport(source: source).downloadCatalog(
      at: LinnetSettingsDownloadSource.canonicalCatalogURL)
    try require(catalog == body, "public mirror catalog body")
    try require(StubURLProtocol.requests.count == 1, "public mirror used fallback")
    try require(
      StubURLProtocol.requests[0].url?.absoluteString
        == LinnetSettingsDownloadSource.canonicalCatalogURL.absoluteString,
      "public mirror replaced the canonical catalog route")
    try assertPublicRequestHeaders(StubURLProtocol.requests.first)

    try await expect(.invalidURL) {
      StubURLProtocol.install([.redirect(URL(string: "https://gh-proxy.com/final")!)])
      _ = try await transport(source: source).downloadCatalog(
        at: LinnetSettingsDownloadSource.canonicalCatalogURL)
    }

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "public-mirror.linnetpack")
    StubURLProtocol.install([
      .response(headers: ["Content-Length": "4"]), .data(Data("pack".utf8)), .finish,
    ])
    try await transport(source: source).downloadPack(
      artifact(bytes: 4), to: destination)
    try require(
      try Data(contentsOf: destination) == Data("pack".utf8),
      "public mirror pack")
    try require(StubURLProtocol.requests.count == 1, "public mirror pack used fallback")
    try require(
      StubURLProtocol.requests[0].url?.absoluteString
        == "https://gh-proxy.com/https://github.com/Ares-X/Linnet/releases/download/data-1/Linnet-Chinese.linnetpack",
      "public mirror pack request URL")

    try require(StubURLProtocol.requests.count == 1, "catalog tried a public-mirror fallback")
  }

  private static func freshInstallReplayFloorMatrix() async throws {
    let staleCatalog = catalog(sequence: 3)
    let catalogBytes = try JSONEncoder().encode(staleCatalog)
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = try LinnetDataRegistry(
      productName: "Linnet", coreVersion: "0.1.1",
      applicationSupportDirectory: root)
    try installFreshActiveState(in: registry)
    let activeStateURL = registry.activeSharedDataDirectory.appending(path: "activation.json")
    let activeBefore = try Data(contentsOf: activeStateURL)
    let freshSnapshot = try registry.runtimeSnapshot()
    try require(
      freshSnapshot.state.acceptedCatalog == nil,
      "fresh Active fabricated a catalog receipt")
    let sources = [
      LinnetSettingsDownloadSource.direct,
      LinnetSettingsDownloadSource.publicMirror,
      try LinnetSettingsDownloadSource.customMirror(prefix: "https://mirror.example.com/"),
    ]
    for source in sources {
      StubURLProtocol.install([
        .response(headers: ["Content-Length": "\(catalogBytes.count)"]),
        .data(catalogBytes), .finish,
      ])
      let bytes = try await transport(source: source).downloadCatalog(
        at: LinnetSettingsDownloadSource.canonicalCatalogURL)
      do {
        _ = try registry.verifyDataChannel(bytes)
        throw TestFailure.message("fresh install accepted catalog below Core floor")
      } catch let failure as LinnetDataChannel.Failure {
        try require(
          failure == .invalidCatalog("identity"),
          "unexpected catalog floor failure: \(failure)")
      }
      try require(StubURLProtocol.requests.count == 1, "catalog floor used fallback")
      try require(
        StubURLProtocol.requests[0].url?.absoluteString
          == LinnetSettingsDownloadSource.canonicalCatalogURL.absoluteString,
        "catalog floor was routed through a mirror")
      try require(
        try FileManager.default.contentsOfDirectory(
          at: registry.transactionsDirectory, includingPropertiesForKeys: nil).isEmpty,
        "catalog floor created a language transaction")
      try require(
        try FileManager.default.contentsOfDirectory(
          at: registry.downloadsDirectory, includingPropertiesForKeys: nil).isEmpty,
        "catalog floor created a download directory")
      try require(
        try Data(contentsOf: activeStateURL) == activeBefore,
        "catalog floor changed fresh Active bytes")
    }

    let floorBytesDocument = try JSONEncoder().encode(catalog(sequence: 4))
    StubURLProtocol.install([
      .response(headers: ["Content-Length": "\(floorBytesDocument.count)"]),
      .data(floorBytesDocument), .finish,
    ])
    let floorBytes = try await transport(source: .direct).downloadCatalog(
      at: LinnetSettingsDownloadSource.canonicalCatalogURL)
    let verified = try registry.verifyDataChannel(floorBytes)
    try require(verified.catalog.sequence == 4, "Core rejected its catalog floor")
    try require(StubURLProtocol.requests.count == 1, "catalog floor used fallback")
    try require(
      try Data(contentsOf: activeStateURL) == activeBefore,
      "catalog verification changed fresh Active bytes")
  }

  private static func cancellationAndTimeoutMatrix() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "cancelled.linnetpack")
    let cancellationGeneration = StubURLProtocol.install([
      .response(headers: [:]), .data(Data("pa".utf8)),
      .delayedData(Data("ck".utf8), 2), .finish,
    ])
    let cancellationTransport = transport()
    let cancellationArtifact = artifact(bytes: 4)
    let task = Task.detached {
      try await cancellationTransport.downloadPack(cancellationArtifact, to: destination)
    }
    try await Task.sleep(nanoseconds: 80_000_000)
    task.cancel()
    do {
      try await task.value
      throw TestFailure.message("cancelled transfer succeeded")
    } catch is CancellationError {}
    try assertUnpublished(destination, root: root, label: "cancellation")
    try await waitForStop(generation: cancellationGeneration)

    let idle = LinnetSettingsDownloadTransport.Policy(
      idleTimeout: 0.15, catalogTimeout: 1, operationTimeout: 1, maximumRedirects: 2)
    let idleGeneration = StubURLProtocol.install([
      .response(headers: [:]), .delayedData(Data("data".utf8), 1), .finish,
    ])
    try await expectTimeout(generation: idleGeneration) {
      _ = try await transport(policy: idle).downloadCatalog(at: catalogURL)
    }

    let idleDestination = root.appending(path: "idle-timeout.linnetpack")
    let idlePackGeneration = StubURLProtocol.install([
      .response(headers: [:]), .suspend,
    ])
    try await expectTimeout(generation: idlePackGeneration) {
      try await transport(policy: idle).downloadPack(
        artifact(bytes: 4), to: idleDestination)
    }
    try assertUnpublished(idleDestination, root: root, label: "idle timeout")

    let total = LinnetSettingsDownloadTransport.Policy(
      idleTimeout: 1, catalogTimeout: 2, operationTimeout: 0.45, maximumRedirects: 2)
    let totalGeneration = StubURLProtocol.install([
      .response(headers: [:]),
      .delayedData(Data("a".utf8), 0.1),
      .delayedData(Data("b".utf8), 0.1),
      .delayedData(Data("c".utf8), 0.1),
      .delayedData(Data("d".utf8), 0.1),
      .delayedData(Data("e".utf8), 0.1),
      .finish,
    ])
    try await expectTimeout(generation: totalGeneration) {
      _ = try await transport(policy: total).downloadCatalog(at: catalogURL)
    }

    let totalDestination = root.appending(path: "total-timeout.linnetpack")
    let totalPackGeneration = StubURLProtocol.install([
      .response(headers: [:]), .delayedData(Data("pa".utf8), 0.2),
      .delayedData(Data("ck".utf8), 0.4), .finish,
    ])
    try await expectTimeout(generation: totalPackGeneration) {
      try await transport(policy: total).downloadPack(
        artifact(bytes: 4), to: totalDestination)
    }
    try assertUnpublished(totalDestination, root: root, label: "total timeout")
  }

  private static let catalogURL = URL(
    string: "https://raw.githubusercontent.com/Ares-X/Linnet/data-channel/catalog.json")!

  private static func transport(
    source: LinnetSettingsDownloadSource = .direct,
    policy: LinnetSettingsDownloadTransport.Policy = .production
  ) -> LinnetSettingsDownloadTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return LinnetSettingsDownloadTransport(
      source: source, configuration: configuration, policy: policy)
  }

  private static func assertPublicRequestHeaders(_ request: URLRequest?) throws {
    guard let request else { throw TestFailure.message("missing public request") }
    for header in ["Authorization", "Proxy-Authorization", "Cookie"] {
      try require(
        request.value(forHTTPHeaderField: header) == nil,
        "public download leaked \(header)")
    }
  }

  private static func catalog(_ events: StubURLProtocol.Event...) async throws -> Data {
    StubURLProtocol.install(events)
    return try await transport().downloadCatalog(at: catalogURL)
  }

  private static func pack(
    _ expected: Data,
    destination: URL,
    _ events: StubURLProtocol.Event...
  ) async throws {
    StubURLProtocol.install(events)
    try await transport().downloadPack(artifact(bytes: UInt64(expected.count)), to: destination)
  }

  private static func artifact(bytes: UInt64) -> LinnetDataChannel.Artifact {
    .init(
      kind: .chinese, version: "1.0.0", sequence: 1, dataABI: 1,
      minCore: "0.1.0", contentSHA256: String(repeating: "a", count: 64),
      bytes: bytes,
      containerSHA256: String(repeating: "b", count: 64),
      url: URL(
        string: "https://github.com/Ares-X/Linnet/releases/download/data-1/Linnet-Chinese.linnetpack"
      )!
    )
  }

  private static func catalog(sequence: UInt64) -> LinnetDataChannel.Catalog {
    func artifact(_ kind: LinnetPackContract.Kind, abi: UInt32) -> LinnetDataChannel.Artifact {
      .init(
        kind: kind, version: "stale", sequence: 1, dataABI: abi,
        minCore: "0.1.0", contentSHA256: String(repeating: "a", count: 64),
        bytes: 4,
        containerSHA256: String(repeating: "b", count: 64),
        url: URL(
          string:
            "https://github.com/Ares-X/Linnet/releases/download/data-\(sequence)/\(kind.releaseAssetName)"
        )!)
    }
    return .init(
      format: LinnetDataChannel.format, sequence: sequence,
      activationSets: [
        .init(edition: .standard, packs: [
          artifact(.chinese, abi: 2), artifact(.english, abi: 1),
          artifact(.lts, abi: 2),
        ]),
        .init(edition: .full, packs: [
          artifact(.chinese, abi: 2), artifact(.english, abi: 1),
          artifact(.lts, abi: 2), artifact(.extended, abi: 2),
        ]),
      ])
  }

  private static func installFreshActiveState(in registry: LinnetDataRegistry) throws {
    let active = registry.activeSharedDataDirectory
    try FileManager.default.createDirectory(
      at: active.appending(path: "build", directoryHint: .isDirectory),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let installed = try [
      writeInstalledPack(
        .chinese, sequence: 12, dataABI: 2, minCore: "0.1.1",
        files: [
          "default.yaml": Data("default".utf8),
          "squirrel.yaml": Data("squirrel".utf8),
          "linnet_zh.schema.yaml": Data("schema".utf8),
          "linnet_zh.dict.yaml": Data("dictionary".utf8),
        ], registry: registry),
      writeInstalledPack(
        .english, sequence: 8, dataABI: 1, minCore: "0.1.1",
        files: ["linnet_en.schema.yaml": Data("English schema".utf8)], registry: registry),
      writeInstalledPack(
        .lts, sequence: 2, dataABI: 2, minCore: "0.1.0",
        files: ["wanxiang-lts-zh-hans.gram": Data("LTS model".utf8)], registry: registry),
    ]
    let packs = installed.map(\.pack)
    for fixture in installed {
      for path in fixture.files.keys.sorted() where path != "linnet_zh.dict.yaml" {
        try FileManager.default.createSymbolicLink(
          at: active.appending(path: path),
          withDestinationURL: fixture.root.appending(path: path))
      }
    }
    let chinese = installed.first { $0.pack.kind == .chinese }!
    try FileManager.default.createSymbolicLink(
      at: active.appending(path: "linnet_zh.dict.yaml"),
      withDestinationURL: chinese.root.appending(path: "linnet_zh.dict.yaml"))
    try Data("grammar:\n  language: wanxiang-lts-zh-hans\n".utf8).write(
      to: active.appending(path: "linnet_grammar_active.yaml"))
    let state = LinnetDataRegistry.ActiveState(
      format: LinnetDataRegistry.stateFormat,
      edition: .standard, generation: 1, activeView: "Runtime/Active", packs: packs,
      publication: .committed, transactionID: nil, acceptedCatalog: nil,
      rollbackPacks: [])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(state) + Data("\n".utf8)).write(
      to: active.appending(path: "activation.json"),
      options: .atomic)
    try FileManager.default.createDirectory(
      at: registry.activeStateURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(
      atPath: registry.activeStateURL.path,
      withDestinationPath: "../Runtime/Active/activation.json")
  }

  private static func writeInstalledPack(
    _ kind: LinnetDataRegistry.PackKind,
    sequence: UInt64,
    dataABI: UInt32,
    minCore: String,
    files: [String: Data],
    registry: LinnetDataRegistry
  ) throws -> (pack: LinnetDataRegistry.ActivePack, root: URL, files: [String: Data]) {
    let version = "embedded"
    let root = registry.packsDirectory.appending(
      path: "\(kind.rawValue)/\(sequence)-\(version)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let entries = try files.keys.sorted().map { path in
      let data = files[path]!
      let file = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: file)
      return LinnetPackContract.FileEntry(
        path: path, bytes: UInt64(data.count), sha256: LinnetPackContract.sha256(data))
    }
    let unpacked = entries.reduce(into: Data()) { result, entry in
      result.append(files[entry.path]!)
    }
    let contentSHA256 = LinnetPackContract.sha256(unpacked)
    let requirements: [LinnetPackContract.Requirement] =
      kind == .lts || kind == .extended ? [.init(kind: .chinese, dataABI: dataABI)] : []
    let manifest = LinnetPackContract.Manifest(
      format: LinnetPackContract.manifestFormat,
      product: LinnetPackContract.productIdentifier,
      packID: LinnetPackContract.Kind(rawValue: kind.rawValue)!.packID,
      kind: LinnetPackContract.Kind(rawValue: kind.rawValue)!,
      version: version, sequence: sequence, dataABI: dataABI, minCore: minCore,
      contentSHA256: contentSHA256,
      requires: requirements,
      files: entries)
    let manifestData = try LinnetPackContract.canonicalManifestData(manifest)
    try manifestData.write(to: root.appending(path: "manifest.json"))
    let pack = LinnetDataRegistry.ActivePack(
      packID: manifest.packID, kind: kind, version: version, sequence: sequence,
      dataABI: dataABI, contentSHA256: contentSHA256, minCore: minCore,
      requirements: requirements.map {
        .init(kind: LinnetDataRegistry.PackKind(rawValue: $0.kind.rawValue)!, dataABI: $0.dataABI)
      },
      relativePath: "Data/Packs/\(kind.rawValue)/\(sequence)-\(version)",
      manifestSHA256: LinnetPackContract.sha256(manifestData))
    return (pack, root, files)
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "linnet-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  private static func partials(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".partial-") }
  }

  private static func waitForPartial(in directory: URL) async throws {
    for _ in 0..<200 {
      if try !partials(in: directory).isEmpty, StubURLProtocol.isSuspended { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    throw TestFailure.message(
      "transfer did not create a partial before destination race: \(directory.path) \(names) "
        + "\(StubURLProtocol.snapshot())")
  }

  private static func assertUnpublished(_ destination: URL, root: URL, label: String) throws {
    try require(!FileManager.default.fileExists(atPath: destination.path), "\(label) published")
    try require(try partials(in: root).isEmpty, "\(label) left partial")
  }

  private static func expect(
    _ expected: LinnetSettingsDownloadTransport.Failure,
    requiresStop: Bool = true,
    operation: () async throws -> Void
  ) async throws {
    let generationBefore = StubURLProtocol.currentGeneration
    do {
      try await operation()
      throw TestFailure.message("expected \(expected)")
    } catch let failure as LinnetSettingsDownloadTransport.Failure {
      try require(failure == expected, "expected \(expected), got \(failure)")
      if requiresStop {
        let generation = StubURLProtocol.currentGeneration
        try require(generation > generationBefore, "failure did not start a new protocol request")
        try await waitForStop(generation: generation)
      } else {
        try assertNoProtocolStarted(after: generationBefore, label: "download preflight")
      }
    }
  }

  private static func expectTimeout(
    generation: Int,
    operation: () async throws -> Void
  ) async throws {
    do {
      try await operation()
      throw TestFailure.message("expected timeout")
    } catch let error as URLError {
      try require(error.code == .timedOut, "expected timeout, got \(error)")
      try await waitForStop(generation: generation)
    }
  }

  private static func waitForStop(generation: Int) async throws {
    try require(
      StubURLProtocol.startCount(for: generation) > 0,
      "URLProtocol generation \(generation) never started")
    for _ in 0..<100 {
      if StubURLProtocol.stopCount(for: generation) > 0 { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw TestFailure.message("URLProtocol generation \(generation) was not stopped")
  }

  private static func assertNoProtocolStarted(after generation: Int, label: String) throws {
    let current = StubURLProtocol.currentGeneration
    try require(current > generation, "\(label) did not install its protocol fixture")
    try require(StubURLProtocol.startCount(for: current) == 0, "\(label) started URLProtocol")
    try require(StubURLProtocol.stopCount(for: current) == 0, "\(label) stopped an unstarted task")
  }

  private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String)
    throws
  {
    guard try condition() else { throw TestFailure.message(message) }
  }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Event {
    case response(status: Int = 200, headers: [String: String] = [:])
    case nonHTTPResponse
    case data(Data)
    case delayedData(Data, TimeInterval)
    case suspend
    case redirect(URL)
    case finish
  }

  private static let stateLock = NSLock()
  private static var events: [Event] = []
  private static var suspended: (() -> Void)?
  private static var currentGenerationStorage = 0
  private static var startCounts: [Int: Int] = [:]
  private static var stopCounts: [Int: Int] = [:]
  private(set) static var requests: [URLRequest] = []
  private let instanceLock = NSLock()
  private var stopped = false
  private var generation = 0

  @discardableResult static func install(_ events: [Event]) -> Int {
    stateLock.lock()
    currentGenerationStorage += 1
    self.events = events
    suspended = nil
    requests = []
    let generation = currentGenerationStorage
    stateLock.unlock()
    return generation
  }

  static func resume() {
    stateLock.lock()
    let continuation = suspended
    suspended = nil
    stateLock.unlock()
    continuation?()
  }

  static func snapshot() -> String {
    stateLock.lock()
    defer { stateLock.unlock() }
    return "requests=\(requests.count) pending=\(events.count) suspended=\(suspended != nil)"
  }

  static var currentGeneration: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return currentGenerationStorage
  }

  static func stopCount(for generation: Int) -> Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopCounts[generation, default: 0]
  }

  static func startCount(for generation: Int) -> Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return startCounts[generation, default: 0]
  }

  static var isSuspended: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return suspended != nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.stateLock.lock()
    Self.requests.append(request)
    let events = Self.events
    Self.events = []
    let generation = Self.currentGenerationStorage
    Self.startCounts[generation, default: 0] += 1
    Self.stateLock.unlock()
    instanceLock.lock()
    self.generation = generation
    instanceLock.unlock()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.deliver(events, at: 0, delay: 0)
    }
  }

  override func stopLoading() {
    instanceLock.lock()
    stopped = true
    let generation = generation
    instanceLock.unlock()
    Self.stateLock.lock()
    Self.stopCounts[generation, default: 0] += 1
    Self.stateLock.unlock()
  }

  private func deliver(_ events: [Event], at index: Int, delay: TimeInterval) {
    guard events.indices.contains(index) else { return }
    let action = { [weak self] in
      guard let self, !self.isStopped else { return }
      let event = events[index]
      do {
        switch event {
        case .response(let status, let headers):
          guard let url = self.request.url,
            let response = HTTPURLResponse(
              url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
          else { throw URLError(.badServerResponse) }
          self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case .nonHTTPResponse:
          guard let url = self.request.url else { throw URLError(.badURL) }
          self.client?.urlProtocol(
            self,
            didReceive: URLResponse(
              url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil),
            cacheStoragePolicy: .notAllowed)
        case .data(let data), .delayedData(let data, _):
          self.client?.urlProtocol(self, didLoad: data)
        case .suspend:
          Self.stateLock.lock()
          Self.suspended = { [weak self] in
            self?.deliver(events, at: index + 1, delay: 0)
          }
          Self.stateLock.unlock()
          return
        case .redirect(let target):
          guard let source = self.request.url,
            let response = HTTPURLResponse(
              url: source, statusCode: 302, httpVersion: "HTTP/1.1",
              headerFields: ["Location": target.absoluteString])
          else { throw URLError(.badServerResponse) }
          Self.stateLock.lock()
          Self.events = Array(events.dropFirst(index + 1))
          Self.stateLock.unlock()
          self.client?.urlProtocol(
            self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
          return
        case .finish:
          self.client?.urlProtocolDidFinishLoading(self)
        }
        let nextDelay: TimeInterval
        if events.indices.contains(index + 1),
          case .delayedData(_, let value) = events[index + 1]
        {
          nextDelay = value
        } else {
          nextDelay = 0
        }
        self.deliver(events, at: index + 1, delay: nextDelay)
      } catch {
        self.client?.urlProtocol(self, didFailWithError: error)
      }
    }
    if delay > 0 {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
    } else {
      DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + 0.01, execute: action)
    }
  }

  private var isStopped: Bool {
    instanceLock.lock()
    defer { instanceLock.unlock() }
    return stopped
  }
}
