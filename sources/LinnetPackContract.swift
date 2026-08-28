import CryptoKit
import Darwin
import Foundation
import zlib

/// Canonical on-disk contract for deterministic Linnet language packs.
///
/// The container deliberately has no archive-entry headers. File names and
/// byte boundaries come only from the exhaustive manifest, which removes the
/// usual ZIP path/extra-entry ambiguity. The canonical HTTPS catalog binds the
/// exact container byte count and SHA-256; no private data-signing key exists.
enum LinnetPackContract {
  static let productIdentifier = "io.github.ares-x.inputmethod.Linnet"
  static let containerVersion: UInt16 = 2
  static let manifestFormat = 2
  static let magic = Data([0x4c, 0x4e, 0x54, 0x50, 0x41, 0x43, 0x4b, 0x00]) // LNTPACK\0
  static let maximumManifestBytes = 1_048_576
  static let maximumFiles = 4_096
  static let maximumPathBytes = 1_024
  static let maximumFileBytes = 1_073_741_824
  static let maximumPayloadBytes = 1_610_612_736
  static let maximumContainerBytes: UInt64 = 1_700_000_000

  enum Kind: String, Codable, CaseIterable, Sendable {
    case chinese
    case english
    case lts
    case extended

    var packID: String { "\(productIdentifier).data.\(rawValue)" }

    var releaseAssetName: String {
      switch self {
      case .chinese: "Linnet-Chinese.linnetpack"
      case .english: "Linnet-English.linnetpack"
      case .lts: "Linnet-LTS.linnetpack"
      case .extended: "Linnet-Extended.linnetpack"
      }
    }
  }

  struct Requirement: Codable, Equatable, Sendable {
    let kind: Kind
    let dataABI: UInt32

    enum CodingKeys: String, CodingKey {
      case kind
      case dataABI = "data_abi"
    }
  }

  struct FileEntry: Codable, Equatable, Sendable {
    let path: String
    let bytes: UInt64
    let sha256: String
  }

  struct Manifest: Codable, Equatable, Sendable {
    let format: Int
    let product: String
    let packID: String
    let kind: Kind
    let version: String
    let sequence: UInt64
    let dataABI: UInt32
    let minCore: String
    let contentSHA256: String
    let requires: [Requirement]
    let files: [FileEntry]

    enum CodingKeys: String, CodingKey {
      case format, product
      case packID = "pack_id"
      case kind, version, sequence
      case dataABI = "data_abi"
      case minCore = "min_core"
      case contentSHA256 = "content_sha256"
      case requires, files
    }
  }

  struct VerifiedPack: Sendable {
    let manifest: Manifest
    let manifestData: Data
    let manifestSHA256: String
  }

  enum Failure: LocalizedError, Equatable {
    case invalidContainer
    case unsupportedContainer(UInt16)
    case manifestTooLarge
    case invalidManifest(String)
    case incompatibleCore(required: String, actual: String)
    case unsafePath(String)
    case invalidPayload(String)
    case outputNotEmpty

    var errorDescription: String? {
      switch self {
      case .invalidContainer: "The Linnet language pack container is invalid."
      case .unsupportedContainer(let version):
        "Unsupported Linnet language pack container version: \(version)."
      case .manifestTooLarge: "The Linnet language pack manifest is too large."
      case .invalidManifest(let detail): "Invalid Linnet language pack manifest: \(detail)."
      case .incompatibleCore(let required, let actual):
        "The language pack requires Linnet \(required) or newer; this core is \(actual)."
      case .unsafePath(let path): "The language pack contains an unsafe path: \(path)."
      case .invalidPayload(let detail): "Invalid Linnet language pack payload: \(detail)."
      case .outputNotEmpty: "The language pack staging directory is not empty."
      }
    }
  }

  static func canonicalManifestData(_ manifest: Manifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
  }

  static func parseManifest(_ manifestData: Data, coreVersion: String) throws -> Manifest {
    guard !manifestData.isEmpty, manifestData.count <= maximumManifestBytes else {
      throw Failure.manifestTooLarge
    }
    let manifest: Manifest
    do {
      manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    } catch {
      throw Failure.invalidManifest("JSON")
    }
    try validate(manifest, coreVersion: coreVersion)
    guard try canonicalManifestData(manifest) == manifestData else {
      throw Failure.invalidManifest("canonical encoding")
    }
    return manifest
  }

  /// Verifies the manifest and exhaustive payload and optionally extracts it.
  /// Online callers authenticate the exact container through the signed
  /// catalog before entering this structural boundary.
  static func verify(
    package: URL,
    coreVersion: String,
    extractingTo destination: URL? = nil
  ) throws -> VerifiedPack {
    if let destination {
      try requireEmptySecureDirectory(destination)
    }
    let values = try package.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, UInt64(size) <= maximumContainerBytes
    else { throw Failure.invalidContainer }
    let handle = try FileHandle(forReadingFrom: package)
    defer { try? handle.close() }
    guard try readExact(handle, count: magic.count) == magic else {
      throw Failure.invalidContainer
    }
    let version = try uint16(try readExact(handle, count: 2))
    guard version == containerVersion else { throw Failure.unsupportedContainer(version) }
    let manifestLength = Int(try uint32(try readExact(handle, count: 4)))
    guard manifestLength > 0, manifestLength <= maximumManifestBytes else {
      throw Failure.manifestTooLarge
    }
    let manifestData = try readExact(handle, count: manifestLength)
    let manifest = try parseManifest(manifestData, coreVersion: coreVersion)

    let payload = try ZlibPayloadReader(
      handle: handle,
      expectedBytes: manifest.files.reduce(0) { $0 + $1.bytes },
      expectedSHA256: manifest.contentSHA256)
    for entry in manifest.files {
      try verifyPayloadFile(entry, payload: payload, destination: destination)
    }
    try payload.finish()
    return VerifiedPack(
      manifest: manifest,
      manifestData: manifestData,
      manifestSHA256: sha256(manifestData)
    )
  }

}

extension LinnetPackContract {
  static func validate(_ manifest: Manifest, coreVersion: String) throws {
    try validateIdentity(manifest, coreVersion: coreVersion)
    try validateFiles(manifest.files, kind: manifest.kind)
    try validateRequirements(manifest.requires, for: manifest)
  }

  static func validateIdentity(_ manifest: Manifest, coreVersion: String) throws {
    guard manifest.format == manifestFormat else { throw Failure.invalidManifest("format") }
    guard manifest.product == productIdentifier else { throw Failure.invalidManifest("product") }
    guard manifest.packID == manifest.kind.packID else { throw Failure.invalidManifest("pack_id") }
    guard safeIdentifier(manifest.version), manifest.sequence > 0, manifest.dataABI > 0 else {
      throw Failure.invalidManifest("identity")
    }
    guard isSHA256(manifest.contentSHA256) else {
      throw Failure.invalidManifest("digest")
    }
    guard !manifest.files.isEmpty, manifest.files.count <= maximumFiles else {
      throw Failure.invalidManifest("file count")
    }
    guard let required = SemanticVersion(manifest.minCore),
      let actual = SemanticVersion(coreVersion)
    else {
      throw Failure.invalidManifest("core version")
    }
    guard actual >= required else {
      throw Failure.incompatibleCore(required: manifest.minCore, actual: coreVersion)
    }
  }

  static func validateFiles(_ files: [FileEntry], kind: Kind) throws {
    var total: UInt64 = 0
    var portablePaths = Set<String>()
    var previous: String?
    for entry in files {
      try validatePath(entry.path, kind: kind)
      guard entry.bytes <= UInt64(maximumFileBytes), isSHA256(entry.sha256) else {
        throw Failure.invalidManifest("file \(entry.path)")
      }
      guard previous == nil || previous! < entry.path else {
        throw Failure.invalidManifest("file order")
      }
      previous = entry.path
      let portable = entry.path.precomposedStringWithCanonicalMapping.lowercased()
      guard portablePaths.insert(portable).inserted else {
        throw Failure.invalidManifest("duplicate path")
      }
      let sum = total.addingReportingOverflow(entry.bytes)
      guard !sum.overflow else { throw Failure.invalidManifest("payload overflow") }
      total = sum.partialValue
    }
    guard total > 0, total <= UInt64(maximumPayloadBytes) else {
      throw Failure.invalidManifest("payload size")
    }
  }

  static func validateRequirements(_ requirements: [Requirement], for manifest: Manifest) throws {
    let sorted = requirements.sorted { $0.kind.rawValue < $1.kind.rawValue }
    guard sorted == requirements,
      Set(requirements.map(\.kind)).count == requirements.count,
      requirements.allSatisfy({ $0.dataABI > 0 && $0.kind != manifest.kind })
    else {
      throw Failure.invalidManifest("requirements")
    }
    if [.lts, .extended].contains(manifest.kind) {
      guard requirements == [.init(kind: .chinese, dataABI: manifest.dataABI)] else {
        throw Failure.invalidManifest("Chinese data requirement")
      }
    } else {
      guard requirements.isEmpty else {
        throw Failure.invalidManifest("unsupported requirement")
      }
    }
  }

  fileprivate static func verifyPayloadFile(
    _ entry: FileEntry,
    payload: ZlibPayloadReader,
    destination: URL?
  ) throws {
    var remaining = entry.bytes
    var fileHasher = SHA256()
    var output: FileHandle?
    if let destination {
      let fileURL = destination.appending(path: entry.path, directoryHint: .notDirectory)
      try prepareParentDirectories(for: fileURL, beneath: destination)
      let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw Failure.unsafePath(entry.path) }
      output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    do {
      while remaining > 0 {
        let count = Int(min(remaining, 1_048_576))
        let chunk = try payload.read(maximumBytes: count)
        guard !chunk.isEmpty else { throw Failure.invalidPayload("unpacked size") }
        fileHasher.update(data: chunk)
        try output?.write(contentsOf: chunk)
        remaining -= UInt64(chunk.count)
      }
      try output?.synchronize()
      try output?.close()
    } catch {
      try? output?.close()
      throw error
    }
    guard hex(fileHasher.finalize()) == entry.sha256 else {
      throw Failure.invalidPayload("hash \(entry.path)")
    }
    if let destination {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: destination.appending(path: entry.path).path
      )
    }
  }

  static func validatePath(_ path: String, kind: Kind) throws {
    guard !path.isEmpty, path.utf8.count <= maximumPathBytes,
      path == path.precomposedStringWithCanonicalMapping,
      !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: {
        $0.value == 0 || CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw Failure.unsafePath(path)
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
    }), kindOwns(path: path, kind: kind) else {
      throw Failure.unsafePath(path)
    }
  }

  fileprivate static func kindOwns(path: String, kind: Kind) -> Bool {
    switch kind {
    case .lts:
      return path == "wanxiang-lts-zh-hans.gram"
    case .extended:
      let names = [
        "linnet_zh_full.dict.yaml",
        "dicts/yixue.dict.yaml", "dicts/huaxue.dict.yaml",
        "dicts/yaopin.dict.yaml", "dicts/mingren.dict.yaml",
        "dicts/yiren.dict.yaml", "dicts/wuzhong.dict.yaml",
        "dicts/renming.dict.yaml", "dicts/taifeng.dict.yaml",
        "dicts/fangyan.dict.yaml"
      ]
      return names.contains(path)
    case .english:
      return path == "linnet.smart.db"
        || path == "linnet.english-data-manifest.json"
        || path.hasPrefix("linnet_en.")
        || path.hasPrefix("build/linnet_en.")
    case .chinese:
      let names = [
        "default.yaml", "squirrel.yaml", "linnet_algebra.yaml", "linnet_user.yaml",
        "linnet_reviewed.dict.yaml", "zh-hans-t-essay-bgw.gram",
        "symbols_v.yaml", "symbols_caps_v.yaml"
      ]
      let dictionaries = [
        "dicts/zi.dict.yaml", "dicts/jichu.dict.yaml",
        "dicts/lianxiang.dict.yaml", "dicts/cuoyin.dict.yaml",
        "dicts/duoyin.dict.yaml", "dicts/shici.dict.yaml",
        "dicts/diming.dict.yaml"
      ]
      return names.contains(path) || dictionaries.contains(path)
        || ["linnet_zh", "radical_pinyin"].contains(where: path.hasPrefix)
        || path.hasPrefix("opencc/")
        || (path.hasPrefix("build/") && !path.hasPrefix("build/linnet_en."))
    }
  }

  fileprivate static func requireEmptySecureDirectory(_ directory: URL) throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(), (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
      try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
    else {
      throw Failure.outputNotEmpty
    }
  }

  fileprivate static func prepareParentDirectories(for file: URL, beneath root: URL) throws {
    let parent = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else {
      throw Failure.unsafePath(file.lastPathComponent)
    }
  }

  fileprivate static func readExact(_ handle: FileHandle, count: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
      let chunk = try handle.read(upToCount: count - result.count) ?? Data()
      guard !chunk.isEmpty else { throw Failure.invalidContainer }
      result.append(chunk)
    }
    return result
  }

  fileprivate final class ZlibPayloadReader {
    private let handle: FileHandle
    private let expectedBytes: UInt64
    private let expectedSHA256: String
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
    private var stream: z_stream
    private var unpackedHasher = SHA256()
    private var unpackedBytes: UInt64 = 0
    private var inputEnded = false
    private var ended = false

    init(handle: FileHandle, expectedBytes: UInt64, expectedSHA256: String) throws {
      self.handle = handle
      self.expectedBytes = expectedBytes
      self.expectedSHA256 = expectedSHA256
      stream = z_stream()
      guard inflateInit_(
        &stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
      else {
        input.deallocate()
        output.deallocate()
        throw Failure.invalidPayload("zlib initialization")
      }
    }

    deinit {
      inflateEnd(&stream)
      input.deallocate()
      output.deallocate()
    }

    func read(maximumBytes: Int) throws -> Data {
      guard maximumBytes > 0, !ended else { return Data() }
      let capacity = min(maximumBytes, 1_048_576)
      while true {
        if stream.avail_in == 0 && !inputEnded {
          let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
          if chunk.isEmpty {
            inputEnded = true
          } else {
            chunk.copyBytes(to: input, count: chunk.count)
            stream.next_in = input
            stream.avail_in = UInt32(chunk.count)
          }
        }
        stream.next_out = output
        stream.avail_out = UInt32(capacity)
        let noMoreInput = inputEnded && stream.avail_in == 0
        let status = inflate(&stream, noMoreInput ? Z_FINISH : Z_NO_FLUSH)
        guard status == Z_OK || status == Z_STREAM_END else {
          throw Failure.invalidPayload("zlib stream")
        }
        let produced = capacity - Int(stream.avail_out)
        if produced > 0 {
          let chunk = Data(bytes: output, count: produced)
          unpackedBytes += UInt64(produced)
          guard unpackedBytes <= expectedBytes else {
            throw Failure.invalidPayload("unpacked size")
          }
          unpackedHasher.update(data: chunk)
          if status == Z_STREAM_END {
            try markEnded()
          }
          return chunk
        }
        if status == Z_STREAM_END {
          try markEnded()
          return Data()
        }
        guard !noMoreInput else { throw Failure.invalidPayload("truncated zlib stream") }
      }
    }

    func finish() throws {
      guard unpackedBytes == expectedBytes else {
        throw Failure.invalidPayload("unpacked size")
      }
      if !ended {
        guard try read(maximumBytes: 1).isEmpty, ended else {
          throw Failure.invalidPayload("unpacked size")
        }
      }
      guard LinnetPackContract.hex(unpackedHasher.finalize()) == expectedSHA256 else {
        throw Failure.invalidPayload("unpacked hash")
      }
    }

    private func markEnded() throws {
      guard stream.avail_in == 0,
        (try handle.read(upToCount: 1) ?? Data()).isEmpty
      else {
        throw Failure.invalidPayload("zlib trailing bytes")
      }
      inputEnded = true
      ended = true
    }
  }

  fileprivate static func uint16(_ data: Data) throws -> UInt16 {
    guard data.count == 2 else { throw Failure.invalidContainer }
    return data.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
  }

  fileprivate static func uint32(_ data: Data) throws -> UInt32 {
    guard data.count == 4 else { throw Failure.invalidContainer }
    return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

  fileprivate static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  fileprivate static func safeIdentifier(_ value: String) -> Bool {
    guard let first = value.first, first.isLetter || first.isNumber,
      value.count <= 64
    else { return false }
    return value.allSatisfy { $0.isLetter || $0.isNumber || "._-+".contains($0) }
  }

  static func supportsCore(required: String, actual: String) -> Bool {
    guard let required = SemanticVersion(required), let actual = SemanticVersion(actual) else {
      return false
    }
    return actual >= required
  }

  fileprivate struct SemanticVersion: Comparable {
    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    let prerelease: [String]

    init?(_ value: String) {
      let coreAndPre = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      let core = coreAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
      guard core.count == 3, let major = UInt64(core[0]), let minor = UInt64(core[1]),
        let patch = UInt64(core[2])
      else { return nil }
      let prerelease = coreAndPre.count == 2
        ? coreAndPre[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        : []
      guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy {
        $0.isLetter || $0.isNumber || $0 == "-"
      } }) else { return nil }
      self.major = major
      self.minor = minor
      self.patch = patch
      self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.major != rhs.major { return lhs.major < rhs.major }
      if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
      if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
      if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
      for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
        let leftNumber = UInt64(left)
        let rightNumber = UInt64(right)
        if let leftNumber, let rightNumber { return leftNumber < rightNumber }
        if leftNumber != nil { return true }
        if rightNumber != nil { return false }
        return left < right
      }
      return lhs.prerelease.count < rhs.prerelease.count
    }
  }
}
