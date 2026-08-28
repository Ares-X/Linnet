import CryptoKit
import Foundation

/// The replay-resistant selection boundary for independently published
/// language packs. A catalog fetched from the canonical HTTPS endpoint names a
/// complete compatible Standard or Full Active set. Each entry binds the exact
/// immutable release asset before the pack contract validates its contents.
enum LinnetDataChannel {
  static let format = 1
  static let maximumCatalogBytes = 64 * 1024
  /// Core 0.1.1 ships the first public online catalog contract at data-4.
  /// A mirror is an untrusted transport, so a fresh install must reject older
  /// catalogs before it creates a transaction or downloads any pack.
  static let minimumCatalogSequence: UInt64 = 4

  enum Failure: LocalizedError, Equatable {
    case invalidCatalog(String)
    case invalidArtifact(String)

    var errorDescription: String? {
      switch self {
      case .invalidCatalog(let detail): "Invalid Linnet data catalog: \(detail)."
      case .invalidArtifact(let detail): "Invalid Linnet data artifact: \(detail)."
      }
    }
  }

  struct Artifact: Codable, Equatable, Sendable {
    let kind: LinnetPackContract.Kind
    let version: String
    let sequence: UInt64
    let dataABI: UInt32
    let minCore: String
    let contentSHA256: String
    let bytes: UInt64
    let containerSHA256: String
    let url: URL

    enum CodingKeys: String, CodingKey {
      case kind, version, sequence, bytes, url
      case dataABI = "data_abi"
      case minCore = "min_core"
      case contentSHA256 = "content_sha256"
      case containerSHA256 = "container_sha256"
    }

    func matches(_ pack: LinnetDataRegistry.ActivePack) -> Bool {
      kind == pack.kind
        && version == pack.version
        && sequence == pack.sequence
        && dataABI == pack.dataABI
        && minCore == pack.minCore
        && contentSHA256 == pack.contentSHA256
    }
  }

  struct ActivationSet: Codable, Equatable, Sendable {
    let edition: LinnetDataRegistry.Edition
    let packs: [Artifact]
  }

  enum CoreAvailability: Equatable, Sendable {
    case current
    case available
  }

  enum UpdateAvailability: Equatable, Sendable {
    case current
    case core(Core)
    case languageData([LanguageDataUpdate])
  }

  struct LanguageDataUpdate: Equatable, Sendable {
    let kind: LinnetPackContract.Kind
    let installedVersion: String?
    let installedSequence: UInt64?
    let availableVersion: String
    let availableSequence: UInt64
  }

  struct Core: Codable, Equatable, Sendable {
    let version: String
    let build: UInt64
    let revision: String
    let bytes: UInt64
    let sha256: String
    let packageURL: URL
    let releaseURL: URL

    enum CodingKeys: String, CodingKey {
      case version, build, revision, bytes, sha256
      case packageURL = "package_url"
      case releaseURL = "release_url"
    }

    func availability(currentVersion: String, currentBuild: UInt64) -> CoreAvailability {
      if version == currentVersion {
        return build > currentBuild ? .available : .current
      }
      return LinnetPackContract.supportsCore(required: currentVersion, actual: version)
        && !LinnetPackContract.supportsCore(required: version, actual: currentVersion)
        ? .available : .current
    }
  }

  struct Catalog: Codable, Equatable, Sendable {
    let format: Int
    let sequence: UInt64
    let core: Core
    let activationSets: [ActivationSet]

    enum CodingKeys: String, CodingKey {
      case format, sequence, core
      case activationSets = "activation_sets"
    }

    func activationSet(for edition: LinnetDataRegistry.Edition) -> ActivationSet? {
      activationSets.first { $0.edition == edition }
    }

    func updateAvailability(
      currentVersion: String,
      currentBuild: UInt64,
      edition: LinnetDataRegistry.Edition?,
      installedPacks: [LinnetDataRegistry.ActivePack]
    ) -> UpdateAvailability {
      if core.availability(currentVersion: currentVersion, currentBuild: currentBuild)
        == .available {
        return .core(core)
      }
      guard let edition, let selected = activationSet(for: edition) else { return .current }
      let updates = selected.packs.compactMap { artifact -> LanguageDataUpdate? in
        let installed = installedPacks.first {
          $0.kind == artifact.kind
        }
        guard installed.map({ artifact.matches($0) }) != true else { return nil }
        return .init(
          kind: artifact.kind,
          installedVersion: installed?.version,
          installedSequence: installed?.sequence,
          availableVersion: artifact.version,
          availableSequence: artifact.sequence)
      }
      return updates.isEmpty ? .current : .languageData(updates)
    }
  }

  struct Verified: Equatable, Sendable {
    let catalog: Catalog
    let digest: String
  }

  static func verify(_ data: Data, coreVersion: String) throws -> Verified {
    let verified = try verifyPublished(data)
    guard verified.catalog.activationSets.allSatisfy({ set in
      set.packs.allSatisfy {
        LinnetPackContract.supportsCore(required: $0.minCore, actual: coreVersion)
      }
    }) else { throw Failure.invalidCatalog("Core compatibility") }
    return verified
  }

  /// Update checks must be able to authenticate a newer Core even when its
  /// accompanying data no longer supports the installed Core. Mutation paths
  /// use `verify(_:coreVersion:)` and retain the stricter compatibility gate.
  static func verifyPublished(_ data: Data) throws -> Verified {
    guard !data.isEmpty, data.count <= maximumCatalogBytes else {
      throw Failure.invalidCatalog("size")
    }
    let catalog: Catalog
    do {
      catalog = try JSONDecoder().decode(Catalog.self, from: data)
    } catch {
      throw Failure.invalidCatalog("JSON")
    }
    let canonical = try canonicalCatalogData(catalog)
    try validate(catalog, minimumSequence: minimumCatalogSequence)
    return .init(catalog: catalog, digest: sha256(canonical))
  }

  static func canonicalCatalogData(_ catalog: Catalog) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(catalog)
  }

  /// The canonical catalog binds the complete downloaded container before the
  /// pack contract inspects its manifest and payload.
  static func verifyDownloadedArtifact(_ artifact: Artifact, at file: URL) throws {
    guard artifact.bytes > 0,
      artifact.bytes <= LinnetPackContract.maximumContainerBytes
    else { throw Failure.invalidArtifact("size") }
    let values = try file.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (attributes[.size] as? NSNumber)?.uint64Value == artifact.bytes
    else { throw Failure.invalidArtifact("size") }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == artifact.containerSHA256 else {
      throw Failure.invalidArtifact("SHA-256")
    }
  }

  private static func validate(
    _ catalog: Catalog, minimumSequence: UInt64
  ) throws {
    guard catalog.format == format, catalog.sequence >= minimumSequence,
      catalog.activationSets.count == 2, validate(catalog.core)
    else { throw Failure.invalidCatalog("identity") }
    let expectedEditions: Set<LinnetDataRegistry.Edition> = [.standard, .full]
    guard Set(catalog.activationSets.map(\.edition)) == expectedEditions else {
      throw Failure.invalidCatalog("edition set")
    }
    for set in catalog.activationSets {
      let required: Set<LinnetPackContract.Kind> = set.edition == .full
        ? [.chinese, .english, .lts, .extended]
        : [.chinese, .english, .lts]
      guard Set(set.packs.map(\.kind)) == required else {
        throw Failure.invalidCatalog("pack set")
      }
      guard let chinese = set.packs.first(where: { $0.kind == .chinese }) else {
        throw Failure.invalidCatalog("Chinese")
      }
      for pack in set.packs {
        guard isSafeIdentifier(pack.version), pack.sequence > 0, pack.dataABI > 0,
          isSHA256(pack.contentSHA256), isSHA256(pack.containerSHA256), pack.bytes > 0,
          pack.bytes <= LinnetPackContract.maximumContainerBytes,
          LinnetPackContract.supportsCore(
            required: pack.minCore, actual: catalog.core.version),
          isImmutableReleaseURL(
            pack.url, kind: pack.kind, catalogSequence: catalog.sequence)
        else { throw Failure.invalidCatalog("pack \(pack.kind.rawValue)") }
        if pack.kind == .lts || pack.kind == .extended {
          guard pack.dataABI == chinese.dataABI else {
            throw Failure.invalidCatalog("Chinese ABI")
          }
        }
      }
    }
  }

  private static func validate(_ core: Core) -> Bool {
    guard LinnetPackContract.supportsCore(required: core.version, actual: core.version),
      core.build > 0, isRevision(core.revision),
      core.bytes > 0, core.bytes <= LinnetPackContract.maximumContainerBytes,
      isSHA256(core.sha256), core.packageURL.query == nil,
      core.packageURL.fragment == nil, core.releaseURL.query == nil,
      core.releaseURL.fragment == nil
    else { return false }
    let releaseTag = "core-v\(core.version)"
    return core.packageURL.scheme == "https"
      && core.packageURL.host?.lowercased() == "github.com"
      && core.packageURL.path
        == "/Ares-X/Linnet/releases/download/\(releaseTag)/Linnet-\(core.version)-arm64-Core-community-beta.pkg"
      && core.releaseURL.scheme == "https"
      && core.releaseURL.host?.lowercased() == "github.com"
      && core.releaseURL.path == "/Ares-X/Linnet/releases/tag/\(releaseTag)"
  }

  private static func isImmutableReleaseURL(
    _ url: URL,
    kind: LinnetPackContract.Kind,
    catalogSequence: UInt64
  ) -> Bool {
    guard url.scheme == "https", url.host?.lowercased() == "github.com",
      url.query == nil, url.fragment == nil, url.pathExtension == "linnetpack"
    else { return false }
    let prefix = "/Ares-X/Linnet/releases/download/data-\(catalogSequence)/"
    return url.path == prefix + kind.releaseAssetName
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        .contains($0)
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  private static func isRevision(_ value: String) -> Bool {
    value.count == 40 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
