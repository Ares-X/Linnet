import Foundation

@main
struct LinnetDataChannelTests {
  static func main() {
    do {
      try run()
    } catch {
      LinnetTestFailure.fail("data channel: \(error)")
    }
  }

  private static func run() throws {
    require(
      LinnetPackContract.maximumContainerBytes == 1_700_000_000,
      "container maximum drifted from the canonical pack contract")
    require(
      LinnetDataChannel.maximumCatalogBytes == 64 * 1024,
      "catalog cap drifted from its transport contract")
    require(
      LinnetDataChannel.minimumCatalogSequence == 4,
      "Core catalog replay floor drifted from the first public data release")
    let catalog = makeCatalog()
    try differentialCatalogContract(catalog)
    let data = try catalogData(catalog)
    let verified = try LinnetDataChannel.verify(data, coreVersion: "1.0.0")
    require(verified.catalog.sequence == 5, "valid canonical catalog")
    let nextCore = LinnetDataChannel.Core(
      version: catalog.core.version, build: catalog.core.build + 1,
      revision: String(repeating: "d", count: 40), bytes: catalog.core.bytes + 1,
      sha256: String(repeating: "e", count: 64),
      packageURL: catalog.core.packageURL, releaseURL: catalog.core.releaseURL)
    let coreOnly = try LinnetDataChannel.verify(catalogData(.init(
      format: catalog.format, sequence: catalog.sequence, core: nextCore,
      activationSets: catalog.activationSets)), coreVersion: "1.0.0")
    require(coreOnly.digest != verified.digest, "full Catalog identity lost Core bytes")
    require(try LinnetDataChannel.packSnapshotDigest(coreOnly.catalog)
      == LinnetDataChannel.packSnapshotDigest(catalog), "Core-only change altered immutable pack identity")
    require(
      verified.catalog.core.availability(currentVersion: "1.0.0", currentBuild: 7)
        == .available,
      "newer Core build was not reported")
    require(
      verified.catalog.core.availability(currentVersion: "1.0.0", currentBuild: 8)
        == .current,
      "current Core build was reported as outdated")
    require(
      try verified.catalog.updateAvailability(
        currentVersion: "1.0.0", currentBuild: 7, edition: .standard,
        installedPacks: []) == .core(verified.catalog.core),
      "Core update did not take priority over data")
    require(
      try verified.catalog.updateAvailability(
        currentVersion: "1.0.0", currentBuild: 8, edition: .standard,
        installedPacks: []) == .languageData([
          .init(
            kind: .chinese, installedVersion: nil, installedSequence: nil,
            availableVersion: "2026.08.10", availableSequence: 5),
          .init(
            kind: .english, installedVersion: nil, installedSequence: nil,
            availableVersion: "2026.08.10", availableSequence: 5),
          .init(
            kind: .lts, installedVersion: nil, installedSequence: nil,
            availableVersion: "2026.08.10", availableSequence: 5),
        ]),
      "missing language-data releases were not identified")
    let installedStandard = installedPacks(from: catalog.activationSets[0].packs)
    for edition in [LinnetDataRegistry.Edition.standard, .full] {
      let packs = installedPacks(from: catalog.activationSet(for: edition)!.packs)
      for sequences: [UInt64] in [packs.map { $0.sequence + 1 }, packs.enumerated().map { $0.offset == 0 ? 6 : 4 }] {
        let newerLocal = zip(packs, sequences).map { pack, sequence in
          LinnetDataRegistry.ActivePack(
            packID: pack.packID, kind: pack.kind, version: pack.version,
            sequence: sequence, dataABI: pack.dataABI, contentSHA256: pack.contentSHA256,
            minCore: pack.minCore, requirements: pack.requirements,
            relativePath: pack.relativePath, manifestSHA256: pack.manifestSHA256)
        }
        require(try catalog.updateAvailability(
          currentVersion: "1.0.0", currentBuild: 8, edition: edition, installedPacks: newerLocal) == .localDataAhead,
          "local-ahead or mixed new/old activation set must be explicitly identified")
      }
    }
    let staleEnglish = LinnetDataRegistry.ActivePack(
      packID: installedStandard[1].packID, kind: installedStandard[1].kind,
      version: "2026.08.09", sequence: 4, dataABI: installedStandard[1].dataABI,
      contentSHA256: String(repeating: "c", count: 64),
      minCore: installedStandard[1].minCore, requirements: [],
      relativePath: installedStandard[1].relativePath,
      manifestSHA256: installedStandard[1].manifestSHA256)
    let conflictingEnglish = LinnetDataRegistry.ActivePack(
      packID: staleEnglish.packID, kind: .english,
      version: staleEnglish.version, sequence: 5, dataABI: staleEnglish.dataABI,
      contentSHA256: staleEnglish.contentSHA256, minCore: staleEnglish.minCore, requirements: [],
      relativePath: staleEnglish.relativePath, manifestSHA256: staleEnglish.manifestSHA256)
    do {
      _ = try catalog.updateAvailability(
        currentVersion: "1.0.0", currentBuild: 8, edition: .standard,
        installedPacks: [installedStandard[0], conflictingEnglish, installedStandard[2]])
      LinnetTestFailure.fail("same-sequence different content was accepted as current or an update")
    } catch LinnetDataChannel.Failure.invalidCatalog { }
    require(
      try verified.catalog.updateAvailability(
        currentVersion: "1.0.0", currentBuild: 8, edition: .standard,
        installedPacks: [installedStandard[0], staleEnglish, installedStandard[2]])
        == .languageData([
          .init(
            kind: .english,
            installedVersion: "2026.08.09", installedSequence: 4,
            availableVersion: "2026.08.10", availableSequence: 5),
        ]),
      "an outdated language-data release did not report both versions")
    require(
      try verified.catalog.updateAvailability(
        currentVersion: "1.0.0", currentBuild: 8, edition: .standard,
        installedPacks: installedPacks(from: catalog.activationSets[0].packs)) == .current,
      "an exact installation was reported as outdated")

    do {
      _ = try LinnetDataChannel.verify(
        try catalogData(makeCatalog(sequence: 3)), coreVersion: "1.0.0")
      LinnetTestFailure.fail("catalog below the Core replay floor was accepted")
    } catch {}
    var oversized = data
    oversized.append(Data(
      repeating: 0x20,
      count: LinnetDataChannel.maximumCatalogBytes - data.count + 1))
    do {
      _ = try LinnetDataChannel.verify(oversized, coreVersion: "1.0.0")
      LinnetTestFailure.fail("oversized catalog was accepted")
    } catch {}
    do {
      _ = try LinnetDataChannel.verify(
        try catalogData(makeCatalog(
          artifactBytes: LinnetPackContract.maximumContainerBytes + 1)),
        coreVersion: "1.0.0")
      LinnetTestFailure.fail("catalog accepted an oversized pack container")
    } catch {}

    let built = try LinnetDataCatalogBuilder.build(
      sequence: 9,
      coreVersion: "1.0.0",
      core: publishedCore(),
      artifacts: LinnetPackContract.Kind.allCases.map(publishedArtifact))
    let builtCatalog = try LinnetDataChannel.verify(
      built, coreVersion: "1.0.0").catalog
    let repeated = try LinnetDataCatalogBuilder.build(
      sequence: 9,
      coreVersion: "1.0.0",
      core: publishedCore(),
      artifacts: LinnetPackContract.Kind.allCases.map(publishedArtifact))
    require(built == repeated, "catalog builder is not byte-reproducible")
    require(builtCatalog.sequence == 9, "catalog sequence")
    require(
      builtCatalog.activationSet(for: .standard)?.packs.map(\.kind)
        == [.chinese, .english, .lts],
      "standard activation set")
    require(
      builtCatalog.activationSet(for: .full)?.packs.map(\.kind)
        == [.chinese, .english, .lts, .extended],
      "full activation set")
    for set in builtCatalog.activationSets {
      for artifact in set.packs {
        require(
          artifact.url.lastPathComponent == artifact.kind.releaseAssetName,
          "canonical release asset name")
      }
    }
    do {
      _ = try LinnetDataCatalogBuilder.build(
        sequence: 9,
        coreVersion: "1.0.0",
        core: publishedCore(),
        artifacts: LinnetPackContract.Kind.allCases.dropLast().map(publishedArtifact))
      LinnetTestFailure.fail("catalog builder accepted a missing kind")
    } catch {}

    do {
      _ = try LinnetDataChannel.verify(
        try catalogData(makeCatalog(useCanonicalAssetNames: false)),
        coreVersion: "1.0.0")
      LinnetTestFailure.fail("catalog accepted a non-canonical asset name")
    } catch {}
    do {
      _ = try LinnetDataChannel.verify(
        try catalogData(makeCatalog(
          artifactBaseURL:
            "https://mirror.example.com/https://github.com/Ares-X/Linnet/releases/download/data-5")),
        coreVersion: "1.0.0")
      LinnetTestFailure.fail("catalog accepted a transport mirror as artifact identity")
    } catch {}
    do {
      _ = try LinnetDataChannel.verify(data, coreVersion: "0.9.0")
      LinnetTestFailure.fail("old Core was accepted")
    } catch {}

    let file = LinnetTestScratch.directory.appending(
      path: "LinnetDataChannelTests-\(UUID().uuidString).linnetpack")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("four".utf8).write(to: file)
    let artifact = catalog.activationSets[0].packs[0]
    try LinnetDataChannel.verifyDownloadedArtifact(bytes: artifact.bytes, sha256: artifact.containerSHA256, at: file)
    try Data("evil".utf8).write(to: file)
    do {
      try LinnetDataChannel.verifyDownloadedArtifact(bytes: artifact.bytes, sha256: artifact.containerSHA256, at: file)
      LinnetTestFailure.fail("same-size artifact tampering was accepted")
    } catch {}
    try FileManager.default.removeItem(at: file)
    try Data("short".utf8).write(to: file)
    do {
      try LinnetDataChannel.verifyDownloadedArtifact(bytes: artifact.bytes, sha256: artifact.containerSHA256, at: file)
      LinnetTestFailure.fail("wrong artifact size was accepted")
    } catch {}
    try FileManager.default.removeItem(at: file)
    let target = file.deletingLastPathComponent().appending(
      path: "LinnetDataChannelTarget-\(UUID().uuidString).linnetpack")
    defer { try? FileManager.default.removeItem(at: target) }
    try Data("four".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      atPath: file.path, withDestinationPath: target.path)
    do {
      try LinnetDataChannel.verifyDownloadedArtifact(bytes: artifact.bytes, sha256: artifact.containerSHA256, at: file)
      LinnetTestFailure.fail("artifact verifier followed a destination symlink")
    } catch {}
    print("LinnetDataChannelTests: PASS")
  }

  private static func differentialCatalogContract(_ catalog: LinnetDataChannel.Catalog) throws {
    var document = try JSONSerialization.jsonObject(with: catalogData(catalog)) as! [String: Any]
    let base = String(repeating: "c", count: 64)
    var sets = document["activation_sets"] as! [[String: Any]]
    for index in sets.indices {
      var packs = sets[index]["packs"] as! [[String: Any]]
      for packIndex in packs.indices {
        let kind = LinnetPackContract.Kind(rawValue: packs[packIndex]["kind"] as! String)!
        let name = kind.releaseAssetName.replacingOccurrences(of: ".linnetpack", with: "-from-\(base).linnetdelta")
        packs[packIndex]["deltas"] = [[
          "base_content_sha256": base, "bytes": 128,
          "sha256": String(repeating: "d", count: 64),
          "url": "https://github.com/Ares-X/Linnet/releases/download/data-5/\(name)"
        ]]
      }
      sets[index]["packs"] = packs
    }
    document["activation_sets"] = sets
    let data = try JSONSerialization.data(withJSONObject: document)
    let verified = try LinnetDataChannel.verifyPublished(data)
    let canonical = try LinnetDataChannel.canonicalCatalogData(verified.catalog)
    let roundTrip = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
    let roundTripSets = roundTrip["activation_sets"] as! [[String: Any]]
    let firstPack = (roundTripSets[0]["packs"] as! [[String: Any]])[0]
    require(firstPack["deltas"] != nil, "authenticated Catalog discarded its differential artifact identity")
    require(try LinnetDataChannel.packSnapshotDigest(verified.catalog) == LinnetDataChannel.packSnapshotDigest(catalog),
      "delta transport metadata changed immutable pack identity")
    let artifact = verified.catalog.activationSets[0].packs[0]
    let current = installedPacks(from: [artifact])[0]
    let previous = LinnetDataRegistry.ActivePack(
      packID: current.packID, kind: current.kind, version: "2026.08.09", sequence: 4,
      dataABI: current.dataABI, contentSHA256: base, minCore: current.minCore,
      requirements: current.requirements, relativePath: current.relativePath,
      manifestSHA256: current.manifestSHA256)
    require(artifact.transfer(from: nil) == .complete, "first installation needs its baseline")
    require(artifact.transfer(from: current) == .current(current), "unchanged pack must not download")
    require(artifact.transfer(from: previous) == .delta(artifact.deltas![0], base: previous),
      "normal update must select the exact base-bound delta")
    var noDelta = artifact
    noDelta.deltas = nil
    require(noDelta.transfer(from: previous) == .requiresCompleteRepair, "missing delta silently authorized a full download")
    require(noDelta.transfer(from: previous, allowCompleteRepair: true) == .complete,
      "explicit repair was not accepted")
    require(noDelta.transfer(from: current, allowCompleteRepair: true) == .current(current),
      "repair must still reuse unchanged packs")
    let invalidFields: [(String, Any)] = [
      ("base_content_sha256", artifact.contentSHA256),
      ("base_content_sha256", "invalid"), ("bytes", 0), ("sha256", "invalid"),
      ("url", "https://example.com/update.linnetdelta"),
      ("url", artifact.deltas![0].url.absoluteString + "?alternate=1")
    ]
    for (field, value) in invalidFields {
      var invalid = document
      var invalidSets = invalid["activation_sets"] as! [[String: Any]]
      var invalidPacks = invalidSets[0]["packs"] as! [[String: Any]]
      var invalidDeltas = invalidPacks[0]["deltas"] as! [[String: Any]]
      invalidDeltas[0][field] = value
      invalidPacks[0]["deltas"] = invalidDeltas
      invalidSets[0]["packs"] = invalidPacks
      invalid["activation_sets"] = invalidSets
      do {
        _ = try LinnetDataChannel.verifyPublished(JSONSerialization.data(withJSONObject: invalid))
        LinnetTestFailure.fail("invalid differential Catalog \(field) was accepted")
      } catch LinnetDataChannel.Failure.invalidCatalog { }
    }
  }

  private static func catalogData(_ catalog: LinnetDataChannel.Catalog) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(catalog) + Data("\n".utf8)
  }

  private static func makeCatalog(
    sequence: UInt64 = 5,
    useCanonicalAssetNames: Bool = true,
    artifactBytes: UInt64 = 4,
    artifactBaseURL: String =
      "https://github.com/Ares-X/Linnet/releases/download/data-5"
  ) -> LinnetDataChannel.Catalog {
    func artifact(_ kind: LinnetPackContract.Kind, abi: UInt32) -> LinnetDataChannel.Artifact {
      let name = useCanonicalAssetNames ? kind.releaseAssetName : "\(kind.rawValue).linnetpack"
      return .init(
        kind: kind, version: "2026.08.10", sequence: 5, dataABI: abi,
        minCore: "1.0.0", contentSHA256: String(repeating: "b", count: 64),
        bytes: artifactBytes,
        containerSHA256: "04efaf080f5a3e74e1c29d1ca6a48569382cbbcd324e8d59d2b83ef21c039f00",
        url: URL(
          string: artifactBaseURL.replacingOccurrences(
            of: "data-5", with: "data-\(sequence)") + "/\(name)")!)
    }
    return .init(
      format: LinnetDataChannel.format, sequence: sequence, core: .init(
        version: "1.0.0", build: 8,
        revision: String(repeating: "a", count: 40),
        bytes: 16, sha256: String(repeating: "d", count: 64),
        packageURL: URL(
          string:
            "https://github.com/Ares-X/Linnet/releases/download/core-v1.0.0/Linnet-1.0.0-arm64-Core-community-beta.pkg")!,
        releaseURL: URL(string: "https://github.com/Ares-X/Linnet/releases/tag/core-v1.0.0")!),
      activationSets: [
        .init(edition: .standard, packs: [
          artifact(.chinese, abi: 1), artifact(.english, abi: 1), artifact(.lts, abi: 1),
        ]),
        .init(edition: .full, packs: [
          artifact(.chinese, abi: 2), artifact(.english, abi: 1), artifact(.lts, abi: 2),
          artifact(.extended, abi: 2),
        ]),
      ])
  }

  private static func publishedCore() -> LinnetDataCatalogBuilder.PublishedCore {
    .init(
      version: "1.0.0", build: 8,
      revision: String(repeating: "a", count: 40), bytes: 16,
      sha256: String(repeating: "d", count: 64))
  }

  private static func installedPacks(
    from artifacts: [LinnetDataChannel.Artifact]
  ) -> [LinnetDataRegistry.ActivePack] {
    artifacts.map { artifact in
      .init(
        packID: artifact.kind.packID,
        kind: artifact.kind,
        version: artifact.version, sequence: artifact.sequence,
        dataABI: artifact.dataABI, contentSHA256: artifact.contentSHA256,
        minCore: artifact.minCore, requirements: [],
        relativePath: "Data/Packs/\(artifact.kind.rawValue)/fixture",
        manifestSHA256: String(repeating: "e", count: 64))
    }
  }

  private static func publishedArtifact(
    _ kind: LinnetPackContract.Kind
  ) -> LinnetDataCatalogBuilder.PublishedArtifact {
    let abi: UInt32 = kind == .english ? 1 : 2
    let manifest = LinnetPackContract.Manifest(
      format: LinnetPackContract.manifestFormat,
      product: LinnetPackContract.productIdentifier,
      packID: kind.packID,
      kind: kind,
      version: "2026.08.10",
      sequence: 7,
      dataABI: abi,
      minCore: "1.0.0",
      contentSHA256: String(repeating: "c", count: 64),
      requires: kind == .lts || kind == .extended
        ? [.init(kind: .chinese, dataABI: 2)] : [],
      files: [.init(
        path: [
          LinnetPackContract.Kind.chinese: "default.yaml",
          .english: "linnet.smart.db",
          .lts: "wanxiang-lts-zh-hans.gram",
          .extended: "linnet_zh_full.dict.yaml",
        ][kind]!,
        bytes: 1,
        sha256: String(repeating: "e", count: 64))])
    return .init(
      manifest: manifest, bytes: 4,
      containerSHA256: "04efaf080f5a3e74e1c29d1ca6a48569382cbbcd324e8d59d2b83ef21c039f00")
  }

  private static func require(_ condition: Bool, _ message: String) {
    guard condition else { LinnetTestFailure.fail(message) }
  }
}
