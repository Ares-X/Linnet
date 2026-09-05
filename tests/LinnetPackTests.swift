import Foundation

@main
struct LinnetPackTests {
  static func main() {
    do {
      try run()
    } catch {
      LinnetTestFailure.fail("pack contract: \(error)")
    }
  }

  private static func run() throws {
    try directoryDeltaRoundTrip()
    try differentialPackStagesThroughRegistry()
    try validCatalogSelectedPackStagesThroughRegistry()
    try sameVersionNewSequenceUsesDistinctIdentityPath()
    try installedSameVersionStagesIdempotently()
    try undeclaredInstalledFileFailsClosed()
    try declaredParentSymlinkFailsClosed()
    try corruptInstalledSameIdentityFailsClosed()
    try oversizedInstalledManifestFailsClosed()
    try traversalFailsClosed()
    try chineseLuaFailsClosed()
    try payloadHashAndTrailingBytesFailClosed()
    try corruptAndTruncatedZlibFailClosed()
    try compressionFixtureIsActuallyCompressed()
    try englishEntityDictionaryIsOwnedByEnglishPack()
    try chinesePackRejectsEnglishEntityDictionary()
    try minimumCoreFailsClosed()
    try extendedPackRequiresMatchingChineseABI()
    try unsupportedRequirementFailsClosed()
    print("LinnetPackTests: PASS")
  }

  private static func englishEntityDictionaryIsOwnedByEnglishPack() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(
        path: "english-entities.linnetpack")
      _ = try makePack(
        package, path: "linnet_english_entities.dict.yaml",
        payload: Data("AI\tAI\t1\n".utf8))
      let active = try registry.verifyAndStagePack(
        package: package, artifact: try catalogArtifact(package), transfer: .complete)
      require(
        FileManager.default.fileExists(
          atPath: registry.rootDirectory
            .appending(path: active.relativePath)
            .appending(path: "linnet_english_entities.dict.yaml").path),
        "English entity dictionary ownership")
    }
  }

  private static func differentialPackStagesThroughRegistry() throws {
    try withFixture { registry in
      try withFixture { builder in
        let firstPackage = registry.downloadsDirectory.appending(path: "base.linnetpack")
        let nextPackage = builder.downloadsDirectory.appending(path: "target.linnetpack")
        _ = try makePack(firstPackage, kind: .chinese, path: "dicts/jichu.dict.yaml",
                         payload: Data(repeating: 97, count: 131_072))
        var changed = Data(repeating: 97, count: 131_072)
        changed[1024] = 98
        _ = try makePack(nextPackage, kind: .chinese, path: "dicts/jichu.dict.yaml",
                         payload: changed, sequence: 2)
        let base = try registry.verifyAndStagePack(
          package: firstPackage, artifact: catalogArtifact(firstPackage), transfer: .complete)
        var artifact = try catalogArtifact(nextPackage)
        let target = try builder.verifyAndStagePack(package: nextPackage, artifact: artifact, transfer: .complete)
        let baseRoot = registry.rootDirectory.appending(path: base.relativePath)
        let targetRoot = builder.rootDirectory.appending(path: target.relativePath)
        let deltaFile = registry.downloadsDirectory.appending(path: "update.linnetdelta")
        // PKG extraction produces writable directories; an installed pack is
        // read-only. That difference must not change language-content identity.
        let nested = baseRoot.appending(path: "dicts")
        require(chmod(nested.path, 0o755) == 0, "fixture directory mode")
        try LinnetDirectoryDelta.build(base: baseRoot, target: targetRoot, output: deltaFile)
        require(chmod(nested.path, 0o555) == 0, "installed directory mode")
        let before = try LinnetDirectoryDelta.digest(baseRoot)
        let bytes = try Data(contentsOf: deltaFile)
        let delta = LinnetDataChannel.Delta(
          baseContentSHA256: base.contentSHA256, bytes: UInt64(bytes.count), sha256: LinnetPackContract.sha256(bytes),
          url: URL(string: "https://github.com/Ares-X/Linnet/releases/download/data-5/update.linnetdelta")!)
        artifact.deltas = [delta]
        requireRegistryFailure(.invalidActiveState) {
          _ = try registry.verifyAndStagePack(package: deltaFile, artifact: artifact, transfer: .requiresCompleteRepair)
        }
        let corrupt = registry.downloadsDirectory.appending(path: "corrupt.linnetdelta")
        var corruptBytes = bytes
        corruptBytes[corruptBytes.count - 1] ^= 1
        try corruptBytes.write(to: corrupt)
        do {
          _ = try registry.verifyAndStagePack(package: corrupt, artifact: artifact, transfer: artifact.transfer(from: base))
          LinnetTestFailure.fail("corrupt differential transfer was accepted")
        } catch LinnetDataChannel.Failure.invalidArtifact { }
        require(!FileManager.default.fileExists(atPath: registry.rootDirectory.appending(path: target.relativePath).path),
          "failed delta published a target pack")
        let baseFile = baseRoot.appending(path: "dicts/jichu.dict.yaml")
        require(chmod(baseFile.path, 0o644) == 0, "fixture file mode")
        try changed.write(to: baseFile)
        do {
          _ = try registry.verifyAndStagePack(package: deltaFile, artifact: artifact, transfer: artifact.transfer(from: base))
          LinnetTestFailure.fail("corrupt baseline content was accepted")
        } catch LinnetDataRegistry.Failure.invalidActiveState { }
        try Data(repeating: 97, count: 131_072).write(to: baseFile)
        require(chmod(baseFile.path, 0o444) == 0, "restore fixture file mode")
        let staged = try registry.verifyAndStagePack(
          package: deltaFile, artifact: artifact, transfer: artifact.transfer(from: base))
        require(artifact.matches(staged), "reconstructed pack did not satisfy the canonical target")
        require(try LinnetDirectoryDelta.digest(baseRoot) == before, "delta mutated the installed base")
        let repeated = try registry.verifyAndStagePack(
          package: deltaFile, artifact: artifact, transfer: artifact.transfer(from: base))
        require(repeated == staged, "verified target was not reused idempotently")
      }
    }
  }

  private static func chinesePackRejectsEnglishEntityDictionary() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(
        path: "chinese-cannot-own-english-entities.linnetpack")
      _ = try makePack(
        package, kind: .chinese,
        path: "linnet_english_entities.dict.yaml",
        payload: Data("AI\tAI\t1\n".utf8))
      requirePackFailure(.unsafePath("linnet_english_entities.dict.yaml")) {
        _ = try LinnetPackContract.verify(
          package: package, coreVersion: "1.0.0")
      }
    }
  }

  private static func sameVersionNewSequenceUsesDistinctIdentityPath() throws {
    try withFixture { registry in
      let firstPackage = registry.downloadsDirectory.appending(path: "sequence-1.linnetpack")
      let secondPackage = registry.downloadsDirectory.appending(path: "sequence-2.linnetpack")
      _ = try makePack(
        firstPackage, payload: Data("first".utf8), sequence: 1)
      _ = try makePack(
        secondPackage, payload: Data("second".utf8), sequence: 2)

      let first = try registry.verifyAndStagePack(package: firstPackage, artifact: try catalogArtifact(firstPackage), transfer: .complete)
      let second = try registry.verifyAndStagePack(package: secondPackage, artifact: try catalogArtifact(secondPackage), transfer: .complete)

      require(first.version == second.version, "same public version")
      require(first.sequence < second.sequence, "forward sequence")
      require(first.relativePath != second.relativePath, "distinct immutable identity paths")
      require(
        FileManager.default.fileExists(
          atPath: registry.rootDirectory.appending(path: first.relativePath).path),
        "first immutable identity")
      require(
        FileManager.default.fileExists(
          atPath: registry.rootDirectory.appending(path: second.relativePath).path),
        "second immutable identity")
    }
  }

  private static func corruptInstalledSameIdentityFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "corrupt-installed.linnetpack")
      _ = try makePack(package, payload: Data("trusted".utf8))
      let active = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      let installed = registry.rootDirectory.appending(path: active.relativePath)
      let installedFile = installed.appending(path: "linnet_en.dict.yaml")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: installed.path)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: installedFile.path)
      try Data("corrupt".utf8).write(to: installedFile)

      requireRegistryFailure(.invalidActiveState) {
        _ = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      }
    }
  }

  private static func undeclaredInstalledFileFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "undeclared-installed.linnetpack")
      _ = try makePack(package, payload: Data("trusted".utf8))
      let first = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      let installed = registry.rootDirectory.appending(path: first.relativePath)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: installed.path)
      let undeclared = installed.appending(path: "undeclared.plugin.yaml")
      try Data("must-not-authorize".utf8).write(to: undeclared)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444], ofItemAtPath: undeclared.path)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: installed.path)

      requireRegistryFailure(.invalidActiveState) {
        _ = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      }
    }
  }

  private static func declaredParentSymlinkFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "parent-symlink.linnetpack")
      _ = try makePack(
        package, path: "build/linnet_en.dict.yaml",
        payload: Data("trusted".utf8))
      let active = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      let installed = registry.rootDirectory.appending(path: active.relativePath)
      let declaredParent = installed.appending(path: "build", directoryHint: .isDirectory)
      let replacement = installed.appending(
        path: "declared-parent-replacement", directoryHint: .isDirectory)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: installed.path)
      try FileManager.default.moveItem(at: declaredParent, to: replacement)
      try FileManager.default.createSymbolicLink(
        atPath: declaredParent.path, withDestinationPath: replacement.path)

      requireRegistryFailure(.invalidActiveState) {
        _ = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      }
    }
  }

  private static func oversizedInstalledManifestFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "oversized-installed.linnetpack")
      _ = try makePack(package, payload: Data("trusted".utf8))
      let active = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      let installed = registry.rootDirectory.appending(path: active.relativePath)
      let manifest = installed.appending(path: "manifest.json")
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installed.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
      let handle = try FileHandle(forWritingTo: manifest)
      try handle.truncate(atOffset: 1_048_577)
      try handle.close()
      requireRegistryFailure(.invalidActiveState) {
        _ = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      }
    }
  }

  private static func mismatchedCoreAuthorityFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "core-owner.linnetpack")
      _ = try makePack(package, payload: Data("hello".utf8))
      requirePackFailure(.invalidManifest("core version authority")) {
        _ = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      }
    }
  }

  private static func installedSameVersionStagesIdempotently() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "same-release.linnetpack")
      _ = try makePack(package, payload: Data("hello".utf8))
      let first = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      let second = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      require(second == first, "installed identity is idempotent")
      require(
        FileManager.default.fileExists(
          atPath: registry.rootDirectory.appending(path: first.relativePath)
            .appending(path: "manifest.json").path),
        "installed manifest")
    }
  }

  private static func validCatalogSelectedPackStagesThroughRegistry() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "english.linnetpack")
      _ = try makePack(package, payload: Data("hello".utf8))
      let active = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      require(active.kind == .english, "kind")
      require(active.version == "2026.08.1", "version")
      let installed = registry.rootDirectory.appending(path: active.relativePath)
      require(
        try Data(contentsOf: installed.appending(path: "linnet_en.dict.yaml"))
          == Data("hello".utf8),
        "installed payload")
      require(FileManager.default.fileExists(atPath: installed.appending(path: "manifest.json").path),
        "installed manifest")
    }
  }

  private static func traversalFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "traversal.linnetpack")
      _ = try makePack(
        package, path: "../linnet_en.dict.yaml", payload: Data("hello".utf8))
      requirePackFailure(.unsafePath("../linnet_en.dict.yaml")) {
        _ = try registry.verifyAndStagePack(package: package, artifact: try catalogArtifact(package), transfer: .complete)
      }
    }
  }

  private static func chineseLuaFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "chinese-lua.linnetpack")
      _ = try makePack(
        package, kind: .chinese, path: "lua/sentinel.lua",
        payload: Data("error('must not execute')".utf8))
      requirePackFailure(.unsafePath("lua/sentinel.lua")) {
        _ = try LinnetPackContract.verify(
          package: package, coreVersion: "1.0.0")
      }
    }
  }

  private static func payloadHashAndTrailingBytesFailClosed() throws {
    try withFixture { registry in
      let badHash = registry.downloadsDirectory.appending(path: "bad-hash.linnetpack")
      _ = try makePack(
        badHash, payload: Data("hello".utf8),
        fileHash: String(repeating: "0", count: 64))
      requirePackFailure(.invalidPayload("hash linnet_en.dict.yaml")) {
        _ = try LinnetPackContract.verify(
          package: badHash, coreVersion: "1.0.0")
      }

      let trailing = registry.downloadsDirectory.appending(path: "trailing.linnetpack")
      _ = try makePack(
        trailing, payload: Data("hello".utf8), trailing: Data("x".utf8))
      requirePackFailure(.invalidPayload("zlib trailing bytes")) {
        _ = try LinnetPackContract.verify(
          package: trailing, coreVersion: "1.0.0")
      }
    }
  }

  private static func corruptAndTruncatedZlibFailClosed() throws {
    try withFixture { registry in
      let corrupt = registry.downloadsDirectory.appending(path: "corrupt.linnetpack")
      _ = try makePack(corrupt, payload: Data(repeating: 0x61, count: 32_768))
      var corruptBytes = try Data(contentsOf: corrupt)
      corruptBytes[corruptBytes.index(before: corruptBytes.endIndex)] ^= 0xff
      try corruptBytes.write(to: corrupt)
      requireInvalidPayload {
        _ = try LinnetPackContract.verify(
          package: corrupt, coreVersion: "1.0.0")
      }

      let truncated = registry.downloadsDirectory.appending(path: "truncated.linnetpack")
      _ = try makePack(truncated, payload: Data(repeating: 0x62, count: 32_768))
      var truncatedBytes = try Data(contentsOf: truncated)
      truncatedBytes.removeLast()
      try truncatedBytes.write(to: truncated)
      requireInvalidPayload {
        _ = try LinnetPackContract.verify(
          package: truncated, coreVersion: "1.0.0")
      }

      let internalTail = registry.downloadsDirectory.appending(path: "internal-tail.linnetpack")
      _ = try makePack(
        internalTail, payload: Data(repeating: 0x63, count: 32_768),
        internalTrailing: Data([0]))
      requirePackFailure(.invalidPayload("zlib trailing bytes")) {
        _ = try LinnetPackContract.verify(
          package: internalTail, coreVersion: "1.0.0")
      }
    }
  }

  private static func compressionFixtureIsActuallyCompressed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "ratio.linnetpack")
      let payload = try makePack(
        package, payload: Data(repeating: 0x61, count: 1_048_576))
      _ = try LinnetPackContract.verify(
        package: package, coreVersion: "1.0.0")
      let containerBytes = try package.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      require(UInt64(containerBytes) * 20 < payload.unpackedBytes, "compression ratio")
      print("compression fixture: \(containerBytes)/\(payload.unpackedBytes) bytes")
    }
  }

  private static func minimumCoreFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "new-core.linnetpack")
      _ = try makePack(
        package, payload: Data("hello".utf8), minCore: "2.0.0")
      requirePackFailure(.incompatibleCore(required: "2.0.0", actual: "1.0.0")) {
        _ = try LinnetPackContract.verify(
          package: package, coreVersion: "1.0.0")
      }
    }
  }

  private static func unsupportedRequirementFailsClosed() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "unsupported-requirement.linnetpack")
      _ = try makePack(
        package, payload: Data("hello".utf8),
        requires: [.init(kind: .chinese, dataABI: 1)])
      requirePackFailure(.invalidManifest("unsupported requirement")) {
        _ = try LinnetPackContract.verify(
          package: package, coreVersion: "1.0.0")
      }
    }
  }

  private static func extendedPackRequiresMatchingChineseABI() throws {
    try withFixture { registry in
      let package = registry.downloadsDirectory.appending(path: "extended.linnetpack")
      _ = try makePack(
        package, kind: .extended, path: "dicts/yixue.dict.yaml",
        payload: Data("deep\n".utf8),
        requires: [.init(kind: .chinese, dataABI: 1)])
      let verified = try LinnetPackContract.verify(
        package: package, coreVersion: "1.0.0")
      require(verified.manifest.kind == .extended, "extended kind")

      let missingRequirement = registry.downloadsDirectory.appending(
        path: "extended-no-chinese.linnetpack")
      _ = try makePack(
        missingRequirement, kind: .extended, path: "dicts/yixue.dict.yaml",
        payload: Data("deep\n".utf8))
      requirePackFailure(.invalidManifest("Chinese data requirement")) {
        _ = try LinnetPackContract.verify(
          package: missingRequirement, coreVersion: "1.0.0")
      }
    }
  }

  private static func withFixture(
    _ body: (LinnetDataRegistry) throws -> Void
  ) throws {
    let root = LinnetTestScratch.directory.appending(
      path: "LinnetPackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let registry = try LinnetDataRegistry(
      productName: "Linnet", coreVersion: "1.0.0", applicationSupportDirectory: root)
    try registry.prepareMutableDirectories()
    try body(registry)
  }

  private static func catalogArtifact(
    _ package: URL
  ) throws -> LinnetDataChannel.Artifact {
    let verified = try LinnetPackContract.verify(
      package: package, coreVersion: "1.0.0")
    let bytes = try Data(contentsOf: package, options: [.mappedIfSafe])
    let manifest = verified.manifest
    return .init(
      kind: manifest.kind,
      version: manifest.version,
      sequence: manifest.sequence,
      dataABI: manifest.dataABI,
      minCore: manifest.minCore,
      contentSHA256: manifest.contentSHA256,
      bytes: UInt64(bytes.count),
      containerSHA256: LinnetPackContract.sha256(bytes),
      url: URL(
        string: "https://github.com/Ares-X/Linnet/releases/download/data-5/\(manifest.kind.releaseAssetName)"
      )!)
  }

  private static func makePack(
    _ package: URL,
    kind: LinnetPackContract.Kind = .english,
    path: String = "linnet_en.dict.yaml",
    payload: Data,
    version: String = "2026.08.1",
    sequence: UInt64 = 1,
    fileHash: String? = nil,
    minCore: String = "1.0.0",
    requires: [LinnetPackContract.Requirement] = [],
    trailing: Data = Data(),
    internalTrailing: Data = Data()
  ) throws -> LinnetPackEncoder.EncodedPayload {
    let rawPayload = package.deletingLastPathComponent().appending(
      path: ".raw-payload-\(UUID().uuidString)")
    let storedPayload = package.deletingLastPathComponent().appending(
      path: ".zlib-payload-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: rawPayload)
      try? FileManager.default.removeItem(at: storedPayload)
    }
    try payload.write(to: rawPayload)
    let encoded = try LinnetPackEncoder.compressZlib(source: rawPayload, to: storedPayload)
    if !internalTrailing.isEmpty {
      let handle = try FileHandle(forWritingTo: storedPayload)
      try handle.seekToEnd()
      try handle.write(contentsOf: internalTrailing)
      try handle.close()
    }
    let manifest = LinnetPackContract.Manifest(
      format: LinnetPackContract.manifestFormat,
      product: LinnetPackContract.productIdentifier,
      packID: kind.packID,
      kind: kind,
      version: version,
      sequence: sequence,
      dataABI: 1,
      minCore: minCore,
      contentSHA256: encoded.unpackedSHA256,
      requires: requires,
      files: [.init(
        path: path,
        bytes: UInt64(payload.count),
        sha256: fileHash ?? LinnetPackContract.sha256(payload))]
    )
    let manifestData = try LinnetPackContract.canonicalManifestData(manifest)
    if !trailing.isEmpty {
      let handle = try FileHandle(forWritingTo: storedPayload)
      try handle.seekToEnd()
      try handle.write(contentsOf: trailing)
      try handle.close()
    }
    try LinnetPackEncoder.writeContainer(
      manifestData: manifestData, payload: storedPayload, to: package)
    return encoded
  }

  private static func requirePackFailure(
    _ expected: LinnetPackContract.Failure,
    _ body: () throws -> Void
  ) {
    do {
      try body()
      LinnetTestFailure.fail("Expected \(expected)")
    } catch let error as LinnetPackContract.Failure {
      require(error == expected, "expected \(expected), got \(error)")
    } catch {
      LinnetTestFailure.fail("Unexpected error: \(error)")
    }
  }

  private static func requireRegistryFailure(
    _ expected: LinnetDataRegistry.Failure,
    _ body: () throws -> Void
  ) {
    do {
      try body()
      LinnetTestFailure.fail("Expected \(expected)")
    } catch let error as LinnetDataRegistry.Failure {
      require(error == expected, "expected \(expected), got \(error)")
    } catch {
      LinnetTestFailure.fail("Unexpected error: \(error)")
    }
  }

  private static func requireInvalidPayload(_ body: () throws -> Void) {
    do {
      try body()
      LinnetTestFailure.fail("Expected invalid payload")
    } catch let failure as LinnetPackContract.Failure {
      guard case LinnetPackContract.Failure.invalidPayload = failure else {
        LinnetTestFailure.fail("Unexpected pack failure: \(failure)")
      }
    } catch {
      LinnetTestFailure.fail("Unexpected error: \(error)")
    }
  }

  private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
      guard try condition() else { LinnetTestFailure.fail("Requirement failed: \(message)") }
    } catch {
      LinnetTestFailure.fail("Requirement failed: \(message): \(error)")
    }
  }
}
