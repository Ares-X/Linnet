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

  /// One release-owned switch separates a build that can only use embedded
  /// data from a build whose online catalog has actually been
  /// published. Settings consumes this state; it never guesses publication
  /// from the presence of a local public key or Active directory.
  enum Service: Equatable, Sendable {
    case unpublished
    case published
  }

  static let service: Service = .unpublished

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
      kind.rawValue == pack.kind.rawValue
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

  struct Catalog: Codable, Equatable, Sendable {
    let format: Int
    let sequence: UInt64
    let activationSets: [ActivationSet]

    enum CodingKeys: String, CodingKey {
      case format, sequence
      case activationSets = "activation_sets"
    }

    func activationSet(for edition: LinnetDataRegistry.Edition) -> ActivationSet? {
      activationSets.first { $0.edition == edition }
    }
  }

  struct Verified: Equatable, Sendable {
    let catalog: Catalog
    let digest: String
  }

  static func verify(_ data: Data, coreVersion: String) throws -> Verified {
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
    try validate(
      catalog, coreVersion: coreVersion,
      minimumSequence: minimumCatalogSequence)
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
    _ catalog: Catalog, coreVersion: String, minimumSequence: UInt64
  ) throws {
    guard catalog.format == format, catalog.sequence >= minimumSequence,
      catalog.activationSets.count == 2
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
          LinnetPackContract.supportsCore(required: pack.minCore, actual: coreVersion),
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

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
