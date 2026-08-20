import CryptoKit
import Darwin
import Foundation

@main
struct LinnetPackTool {
  enum ToolFailure: LocalizedError {
    case usage(String)
    case unsafeOutput(String)
    case invalidSource(String)

    var errorDescription: String? {
      switch self {
      case .usage(let detail): detail
      case .unsafeOutput(let detail): "Unsafe output: \(detail)"
      case .invalidSource(let detail): "Invalid pack source: \(detail)"
      }
    }
  }

  static func main() {
    do {
      var arguments = Array(CommandLine.arguments.dropFirst())
      guard let command = arguments.first else { throw ToolFailure.usage(help) }
      arguments.removeFirst()
      let options = try parse(arguments)
      switch command {
      case "build-installed": try buildInstalled(options)
      case "build-container": try buildContainer(options)
      case "verify": try verify(options)
      case "inspect": try inspect(options)
      case "inspect-source": try inspectSource(options)
      case "extract": try extract(options)
      case "inspect-installed": try inspectInstalled(options)
      case "asset-name": try assetName(options)
      case "build-activation-profile": try buildActivationProfile(options)
      case "build-catalog": try buildCatalog(options)
      case "verify-catalog": try verifyCatalog(options)
      case "inspect-catalog": try inspectCatalog(options)
      default: throw ToolFailure.usage(help)
      }
    } catch {
      FileHandle.standardError.write(Data("linnet-pack: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  static let help = """
    Usage:
      linnet-pack build-installed --kind KIND --version VERSION --sequence N
        --data-abi N --min-core VERSION --content-sha256 SHA256 --source DIR --output DIR
      linnet-pack build-container --root DIR --core-version VERSION --output FILE
      linnet-pack verify --pack FILE --core-version VERSION
      linnet-pack inspect --pack FILE --core-version VERSION
      linnet-pack inspect-source --kind KIND --source DIR
      linnet-pack extract --pack FILE --core-version VERSION --output DIR
      linnet-pack inspect-installed --root DIR --core-version VERSION
      linnet-pack asset-name --kind KIND
      linnet-pack build-activation-profile --output FILE --core-version VERSION \\
        --chinese-pack DIR --english-pack DIR --lts-pack DIR \\
        --extended-pack DIR
      linnet-pack build-catalog --sequence N --core-version VERSION --output FILE
        --chinese-pack FILE --english-pack FILE --lts-pack FILE --extended-pack FILE
      linnet-pack verify-catalog --catalog FILE --core-version VERSION
      linnet-pack inspect-catalog --catalog FILE --core-version VERSION
    """

  static func buildInstalled(_ options: [String: String]) throws {
    guard options.count == 8,
      let kindValue = options["kind"],
      let kind = LinnetPackContract.Kind(rawValue: kindValue),
      let version = options["version"],
      let sequenceValue = options["sequence"], let sequence = UInt64(sequenceValue),
      let abiValue = options["data-abi"], let dataABI = UInt32(abiValue),
      let minCore = options["min-core"],
      let expectedContentSHA256 = options["content-sha256"],
      isSHA256(expectedContentSHA256)
    else { throw ToolFailure.usage(help) }

    let source = try requiredURL("source", options)
    let output = try requiredURL("output", options)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw ToolFailure.invalidSource("installed output already exists")
    }
    let files = try sourceFiles(source)
    let inventory = try sourceInventory(files, kind: kind)
    guard inventory.contentSHA256 == expectedContentSHA256 else {
      throw ToolFailure.invalidSource("source content differs from release metadata")
    }
    let requirements: [LinnetPackContract.Requirement] =
      kind == .lts || kind == .extended
      ? [.init(kind: .chinese, dataABI: dataABI)] : []
    let manifest = LinnetPackContract.Manifest(
      format: LinnetPackContract.manifestFormat,
      product: LinnetPackContract.productIdentifier,
      packID: kind.packID,
      kind: kind,
      version: version,
      sequence: sequence,
      dataABI: dataABI,
      minCore: minCore,
      contentSHA256: inventory.contentSHA256,
      requires: requirements,
      files: inventory.entries)
    try LinnetPackContract.validate(manifest, coreVersion: minCore)
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      for file in files {
        let destination = output.appending(path: file.path)
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: file.url, to: destination)
      }
      try writeExclusive(
        try LinnetPackContract.canonicalManifestData(manifest),
        to: output.appending(path: "manifest.json"), mode: 0o444)
      try makeImmutable(output)
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
  }

  static func buildContainer(_ options: [String: String]) throws {
    guard options.count == 3, let coreVersion = options["core-version"] else {
      throw ToolFailure.usage(help)
    }
    let root = try requiredURL("root", options)
    let output = try requiredURL("output", options)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw ToolFailure.invalidSource("container output already exists")
    }
    let (manifest, manifestData) = try verifiedInstalledManifest(
      at: root, coreVersion: coreVersion)
    let files = try sourceFiles(root).filter { $0.path != "manifest.json" }
    let raw = FileManager.default.temporaryDirectory.appending(
      path: "LinnetPackRaw-\(UUID().uuidString)")
    let compressed = FileManager.default.temporaryDirectory.appending(
      path: "LinnetPackZlib-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: raw)
      try? FileManager.default.removeItem(at: compressed)
    }
    let inventory = try writeRawPayload(files, kind: manifest.kind, to: raw)
    guard inventory.entries == manifest.files,
      inventory.contentSHA256 == manifest.contentSHA256
    else { throw ToolFailure.invalidSource("installed pack differs from its manifest") }
    let encoded = try LinnetPackContract.compressZlib(source: raw, to: compressed)
    guard encoded.unpackedBytes == inventory.bytes,
      encoded.unpackedSHA256 == inventory.contentSHA256
    else { throw ToolFailure.invalidSource("container payload differs from its manifest") }
    try LinnetPackContract.writeContainer(
      manifestData: manifestData, payload: compressed, to: output)
  }

  static func verify(_ options: [String: String]) throws {
    let result = try verified(options)
    print("Verified \(result.manifest.kind.rawValue) pack \(result.manifest.version)")
  }

  static func inspect(_ options: [String: String]) throws {
    let result = try verified(options)
    FileHandle.standardOutput.write(result.manifestData)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  static func inspectSource(_ options: [String: String]) throws {
    guard options.count == 2,
      let kindValue = options["kind"],
      let kind = LinnetPackContract.Kind(rawValue: kindValue)
    else { throw ToolFailure.usage(help) }
    let source = try requiredURL("source", options)
    let inventory = try sourceInventory(try sourceFiles(source), kind: kind)
    print(inventory.contentSHA256)
  }

  static func extract(_ options: [String: String]) throws {
    guard options.count == 3, let coreVersion = options["core-version"] else {
      throw ToolFailure.usage(help)
    }
    let output = try requiredURL("output", options)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw ToolFailure.invalidSource("installed output already exists")
    }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      let verified = try LinnetPackContract.verify(
        package: requiredURL("pack", options), coreVersion: coreVersion,
        extractingTo: output)
      try writeExclusive(
        verified.manifestData, to: output.appending(path: "manifest.json"), mode: 0o444)
      try makeImmutable(output)
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
  }

  static func inspectInstalled(_ options: [String: String]) throws {
    guard (options.count == 2 || options.count == 3),
      let coreVersion = options["core-version"]
    else {
      throw ToolFailure.usage(help)
    }
    let (manifest, data) = try verifiedInstalledManifest(
      at: requiredURL("root", options), coreVersion: coreVersion)
    if options["source"] != nil {
      let source = try sourceFiles(requiredURL("source", options))
      guard source.map(\.path) == manifest.files.map(\.path) else {
        throw ToolFailure.invalidSource("pack differs from the accepted source inventory")
      }
      for (file, entry) in zip(source, manifest.files) {
        let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
        guard UInt64(data.count) == entry.bytes,
          LinnetPackContract.sha256(data) == entry.sha256
        else { throw ToolFailure.invalidSource("pack differs from the accepted source bytes") }
      }
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  static func assetName(_ options: [String: String]) throws {
    guard options.count == 1, let value = options["kind"],
      let kind = LinnetPackContract.Kind(rawValue: value)
    else { throw ToolFailure.usage(help) }
    print(kind.releaseAssetName)
  }

  /// The release-only first-install writer converts verified package manifests
  /// to the shared runtime ActiveState contract. Package scripts assemble the
  /// filesystem projection but never serialize that contract themselves.
  static func buildActivationProfile(_ options: [String: String]) throws {
    guard options.count == 6, let coreVersion = options["core-version"] else {
      throw ToolFailure.usage(help)
    }
    let output = try requiredURL("output", options)
    let packs = try [
      activePack(
        from: requiredURL("chinese-pack", options), expected: .chinese,
        coreVersion: coreVersion),
      activePack(
        from: requiredURL("english-pack", options), expected: .english,
        coreVersion: coreVersion),
      activePack(
        from: requiredURL("lts-pack", options), expected: .lts,
        coreVersion: coreVersion),
      activePack(
        from: requiredURL("extended-pack", options), expected: .extended,
        coreVersion: coreVersion),
    ]
    guard output.lastPathComponent == "activation.json",
      output.deletingLastPathComponent().lastPathComponent == "Active",
      output.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Runtime",
      !FileManager.default.fileExists(atPath: output.path)
    else { throw ToolFailure.invalidSource("activation output is unsafe") }
    let state = LinnetDataRegistry.ActiveState(
      format: LinnetDataRegistry.stateFormat,
      edition: .full,
      generation: 1,
      activeView: "Runtime/Active",
      packs: packs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try writeExclusive(
      try encoder.encode(state) + Data("\n".utf8), to: output, mode: 0o644)
  }

  static func verifyCatalog(_ options: [String: String]) throws {
    let verified = try verifiedCatalog(options)
    print("Verified data catalog \(verified.catalog.sequence): \(verified.digest)")
  }

  static func inspectCatalog(_ options: [String: String]) throws {
    let verified = try verifiedCatalog(options)
    FileHandle.standardOutput.write(
      try LinnetDataChannel.canonicalCatalogData(verified.catalog))
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  static func buildCatalog(_ options: [String: String]) throws {
    guard options.count == 7,
      let sequenceValue = options["sequence"], let sequence = UInt64(sequenceValue),
      let coreVersion = options["core-version"]
    else { throw ToolFailure.usage(help) }
    let output = try requiredURL("output", options)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw ToolFailure.unsafeOutput("refusing to overwrite catalog")
    }
    let inputs: [(String, LinnetPackContract.Kind)] = [
      ("chinese-pack", .chinese), ("english-pack", .english),
      ("lts-pack", .lts), ("extended-pack", .extended),
    ]
    let artifacts = try inputs.map { option, expected in
      try publishedArtifact(
        at: requiredURL(option, options), expected: expected,
        coreVersion: coreVersion)
    }
    let data = try LinnetDataCatalogBuilder.build(
      sequence: sequence, coreVersion: coreVersion, artifacts: artifacts)
    try writeExclusive(data, to: output, mode: 0o444)
  }

  static func verifiedCatalog(
    _ options: [String: String]
  ) throws -> LinnetDataChannel.Verified {
    guard options.count == 2, let coreVersion = options["core-version"] else {
      throw ToolFailure.usage(help)
    }
    let data = try Data(contentsOf: requiredURL("catalog", options))
    return try LinnetDataChannel.verify(data, coreVersion: coreVersion)
  }

  static func publishedArtifact(
    at url: URL,
    expected: LinnetPackContract.Kind,
    coreVersion: String
  ) throws -> LinnetDataCatalogBuilder.PublishedArtifact {
    let values = try url.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let fileSize = values.fileSize, fileSize > 0
    else { throw ToolFailure.invalidSource("catalog pack is unsafe") }
    let verified = try LinnetPackContract.verify(
      package: url, coreVersion: coreVersion)
    guard verified.manifest.kind == expected else {
      throw ToolFailure.invalidSource("catalog pack kind mismatch")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return .init(
      manifest: verified.manifest,
      bytes: UInt64(fileSize),
      containerSHA256: hex(hasher.finalize()))
  }

  static func verified(_ options: [String: String]) throws -> LinnetPackContract.VerifiedPack {
    guard let coreVersion = options["core-version"] else { throw ToolFailure.usage(help) }
    return try LinnetPackContract.verify(
      package: requiredURL("pack", options),
      coreVersion: coreVersion
    )
  }
}

extension LinnetPackTool {
  struct SourceFile {
    let path: String
    let url: URL
  }

  struct SourceInventory {
    let entries: [LinnetPackContract.FileEntry]
    let bytes: UInt64
    let contentSHA256: String
  }

  static func parse(_ arguments: [String]) throws -> [String: String] {
    guard arguments.count.isMultiple(of: 2) else { throw ToolFailure.usage(help) }
    var result: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
      let key = arguments[index]
      guard key.hasPrefix("--"), result[String(key.dropFirst(2))] == nil else {
        throw ToolFailure.usage(help)
      }
      result[String(key.dropFirst(2))] = arguments[index + 1]
    }
    return result
  }

  static func requiredURL(_ name: String, _ options: [String: String]) throws -> URL {
    guard let value = options[name], value.hasPrefix("/") else { throw ToolFailure.usage(help) }
    return URL(fileURLWithPath: value)
  }

  static func activePack(
    from root: URL,
    expected: LinnetDataRegistry.PackKind,
    coreVersion: String
  ) throws -> LinnetDataRegistry.ActivePack {
    let (manifest, manifestData) = try verifiedInstalledManifest(
      at: root, coreVersion: coreVersion)
    let identity = "\(manifest.sequence)-\(manifest.version)"
    guard LinnetDataRegistry.PackKind(rawValue: manifest.kind.rawValue) == expected,
      root.lastPathComponent == identity,
      LinnetPackContract.Kind(rawValue: expected.rawValue)?.packID == manifest.packID
    else { throw ToolFailure.invalidSource("package manifest does not match its identity") }
    return .init(
      packID: manifest.packID,
      kind: expected,
      version: manifest.version,
      sequence: manifest.sequence,
      dataABI: manifest.dataABI,
      contentSHA256: manifest.contentSHA256,
      minCore: manifest.minCore,
      requirements: manifest.requires.map {
        .init(kind: LinnetDataRegistry.PackKind(rawValue: $0.kind.rawValue)!, dataABI: $0.dataABI)
      },
      relativePath: "Data/Packs/\(manifest.kind.rawValue)/\(identity)",
      manifestSHA256: hex(SHA256.hash(data: manifestData)))
  }

  static func verifiedInstalledManifest(
    at root: URL,
    coreVersion: String
  ) throws -> (LinnetPackContract.Manifest, Data) {
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw ToolFailure.invalidSource("installed pack root is unsafe")
    }
    let manifestData = try Data(
      contentsOf: root.appending(path: "manifest.json"), options: [.mappedIfSafe])
    let manifest = try LinnetPackContract.parseManifest(
      manifestData, coreVersion: coreVersion)
    let metadata = Set(["manifest.json"])
    let files = try sourceFiles(root).filter { !metadata.contains($0.path) }
    guard files.map(\.path) == manifest.files.map(\.path) else {
      throw ToolFailure.invalidSource("installed pack inventory differs from manifest")
    }
    for (file, entry) in zip(files, manifest.files) {
      let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
      guard UInt64(data.count) == entry.bytes,
        LinnetPackContract.sha256(data) == entry.sha256
      else {
        throw ToolFailure.invalidSource("installed pack file differs from manifest")
      }
    }
    return (manifest, manifestData)
  }

  static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  static func writeRawPayload(
    _ files: [SourceFile], kind: LinnetPackContract.Kind, to output: URL
  ) throws -> SourceInventory {
    guard !files.isEmpty, files.count <= LinnetPackContract.maximumFiles,
      FileManager.default.createFile(atPath: output.path, contents: nil)
    else { throw ToolFailure.invalidSource("cannot create a non-empty payload scratch") }
    let payloadHandle = try FileHandle(forWritingTo: output)
    do {
      let inventory = try sourceInventory(files, kind: kind, payload: payloadHandle)
      try payloadHandle.synchronize()
      try payloadHandle.close()
      return inventory
    } catch {
      try? payloadHandle.close()
      throw error
    }
  }

  static func sourceInventory(
    _ files: [SourceFile], kind: LinnetPackContract.Kind
  ) throws -> SourceInventory {
    try sourceInventory(files, kind: kind, payload: nil)
  }

  private static func sourceInventory(
    _ files: [SourceFile],
    kind: LinnetPackContract.Kind,
    payload: FileHandle?
  ) throws -> SourceInventory {
    guard !files.isEmpty, files.count <= LinnetPackContract.maximumFiles else {
      throw ToolFailure.invalidSource("pack source is empty or too large")
    }
    var payloadHasher = SHA256()
    var payloadBytes: UInt64 = 0
    var entries: [LinnetPackContract.FileEntry] = []
    for item in files {
      let handle = try FileHandle(forReadingFrom: item.url)
      var fileHasher = SHA256()
      var fileBytes: UInt64 = 0
      do {
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
          guard fileBytes <= UInt64(LinnetPackContract.maximumFileBytes - chunk.count),
            payloadBytes <= UInt64(LinnetPackContract.maximumPayloadBytes - chunk.count)
          else { throw ToolFailure.invalidSource("source exceeds the pack byte limit") }
          try payload?.write(contentsOf: chunk)
          fileHasher.update(data: chunk)
          payloadHasher.update(data: chunk)
          fileBytes += UInt64(chunk.count)
          payloadBytes += UInt64(chunk.count)
        }
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
      try LinnetPackContract.validatePath(item.path, kind: kind)
      entries.append(
        .init(path: item.path, bytes: fileBytes, sha256: hex(fileHasher.finalize())))
    }
    return .init(
      entries: entries,
      bytes: payloadBytes,
      contentSHA256: hex(payloadHasher.finalize()))
  }

  static func sourceFiles(_ root: URL) throws -> [SourceFile] {
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw ToolFailure.invalidSource("source is not a regular directory")
    }
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) else {
      throw ToolFailure.invalidSource("cannot enumerate source")
    }
    var result: [SourceFile] = []
    for case let file as URL in enumerator {
      let values = try file.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw ToolFailure.invalidSource("symbolic links are forbidden")
      }
      if values.isDirectory == true { continue }
      guard values.isRegularFile == true else {
        throw ToolFailure.invalidSource("non-regular file")
      }
      let prefix = root.standardizedFileURL.path + "/"
      let path = String(file.standardizedFileURL.path.dropFirst(prefix.count))
        .precomposedStringWithCanonicalMapping
      result.append(.init(path: path, url: file))
    }
    return result.sorted { $0.path < $1.path }
  }

  static func writeExclusive(_ data: Data, to url: URL, mode: mode_t) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
    guard descriptor >= 0 else { throw ToolFailure.unsafeOutput("refusing to overwrite output") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  static func makeImmutable(_ directory: URL) throws {
    for entry in try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw ToolFailure.invalidSource("installed pack contains a symbolic link")
      }
      if values.isDirectory == true {
        try makeImmutable(entry)
      } else {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o444], ofItemAtPath: entry.path)
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: directory.path)
  }

  static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
