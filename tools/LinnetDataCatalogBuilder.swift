import Foundation

/// Release-only projection from four verified immutable packs to the catalog
/// consumed by Linnet Settings. This file is not linked into either shipped
/// application target.
enum LinnetDataCatalogBuilder {
  struct PublishedArtifact: Sendable {
    let manifest: LinnetPackContract.Manifest
    let bytes: UInt64
    let containerSHA256: String
  }

  enum Failure: LocalizedError, Equatable {
    case invalidArtifacts

    var errorDescription: String? {
      "The catalog requires exactly one verified pack of every kind."
    }
  }

  static func build(
    sequence: UInt64,
    coreVersion: String,
    artifacts: [PublishedArtifact]
  ) throws -> Data {
    guard sequence > 0, artifacts.count == LinnetPackContract.Kind.allCases.count else {
      throw Failure.invalidArtifacts
    }
    let byKind = Dictionary(grouping: artifacts, by: { $0.manifest.kind })
    guard byKind.count == LinnetPackContract.Kind.allCases.count,
      byKind.values.allSatisfy({ $0.count == 1 }),
      artifacts.allSatisfy({ $0.bytes > 0 && isSHA256($0.containerSHA256) })
    else { throw Failure.invalidArtifacts }

    func artifact(_ kind: LinnetPackContract.Kind) throws -> LinnetDataChannel.Artifact {
      guard let published = byKind[kind]?.first,
        let url = URL(
          string: "https://github.com/Ares-X/Linnet/releases/download/data-\(sequence)/\(kind.releaseAssetName)"
        )
      else { throw Failure.invalidArtifacts }
      let manifest = published.manifest
      return .init(
        kind: kind,
        version: manifest.version,
        sequence: manifest.sequence,
        dataABI: manifest.dataABI,
        minCore: manifest.minCore,
        contentSHA256: manifest.contentSHA256,
        bytes: published.bytes,
        containerSHA256: published.containerSHA256,
        url: url)
    }

    let sharedKinds: [LinnetPackContract.Kind] = [.chinese, .english, .lts]
    let catalog = LinnetDataChannel.Catalog(
      format: LinnetDataChannel.format,
      sequence: sequence,
      activationSets: [
        .init(edition: .standard, packs: try sharedKinds.map(artifact)),
        .init(edition: .full, packs: try (sharedKinds + [.extended]).map(artifact)),
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(catalog) + Data("\n".utf8)
    _ = try LinnetDataChannel.verify(data, coreVersion: coreVersion)
    return data
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }
}
