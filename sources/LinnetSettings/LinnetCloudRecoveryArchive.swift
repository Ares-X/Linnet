import CryptoKit
import Darwin
import Foundation

/// Immutable manual-recovery objects stored below Linnet's fixed iCloud Drive
/// product folder. This is deliberately separate from Rime's learning-data sync: it
/// records portable recovery snapshots, never runs by itself, and publishes a
/// head only after every referenced object has been verified.
enum LinnetCloudRecoveryArchive {
  static let directoryName = "Linnet-Recovery-v1"
  private static let payloadName = "payload.\(LinnetBackupStore.portableExtension)"
  private static let maximumHeadsToProbe = 32
  private static let maximumHeadBytes = 128 * 1024

  enum Failure: LocalizedError {
    case needsConfirmedRepair
    case invalid(String)

    var errorDescription: String? {
      switch self {
      case .needsConfirmedRepair:
        "No verified cloud recovery baseline is available; explicit repair confirmation is required."
      case .invalid(let detail): "Invalid cloud recovery archive: \(detail)."
      }
    }
  }

  struct Outcome: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case uploaded, unchanged }
    let kind: Kind
    let verifiedAt: Date
  }

  private struct PayloadIdentity: Codable, Equatable {
    let formatVersion: Int
    let appVersion: String
    let dataVersion: String
    let categories: [LinnetBackupStore.Category]
    let personal: [LinnetBackupStore.PortablePersonalArtifact]
    let learning: [LinnetBackupStore.PortableLearningArtifact]
  }

  private struct Delta: Codable, Equatable {
    let name: String
    let targetDigest: String
    let sha256: String
  }

  private struct Head: Codable, Equatable {
    let formatVersion: Int
    let operationID: UUID
    let createdAt: Date
    let baseDigest: String
    let targetDigest: String
    let payloadIdentity: String
    let deltas: [Delta]
  }

  private enum Latest {
    case absent
    case verified(Head, URL)
    case unusable
  }

  static func root(in cloudFolder: URL) -> URL {
    cloudFolder.appending(path: directoryName, directoryHint: .isDirectory)
  }

  /// Publishes an initial full base only when no cloud history exists. Later
  /// writes are rsync batches against the latest verified chain. `repair` is
  /// intentionally a separate, caller-confirmed operation.
  static func publish(
    portable payload: Data,
    in cloudFolder: URL,
    repair: Bool
  ) throws -> Outcome {
    let archive = try LinnetBackupStore.decodePortable(payload)
    let identity = try payloadIdentity(archive)
    let work = FileManager.default.temporaryDirectory.appending(
      path: "LinnetCloudRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: work) }
    let target = work.appending(path: "target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: target, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let targetPayload = target.appending(path: payloadName)
    try payload.write(to: targetPayload, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: targetPayload.path)

    let archiveRoot = root(in: cloudFolder)
    let latest = try latestVerified(in: archiveRoot, workspace: work)
    switch latest {
    case .verified(let head, let baseline):
      guard head.payloadIdentity != identity else {
        return .init(kind: .unchanged, verifiedAt: head.createdAt)
      }
      let verifiedAt = try publishDelta(
        from: baseline, to: target, previous: head, payloadIdentity: identity,
        archiveRoot: archiveRoot, workspace: work)
      return .init(kind: .uploaded, verifiedAt: verifiedAt)
    case .absent:
      return .init(
        kind: .uploaded,
        verifiedAt: try publishBase(target, payloadIdentity: identity, archiveRoot: archiveRoot))
    case .unusable:
      guard repair else { throw Failure.needsConfirmedRepair }
      return .init(
        kind: .uploaded,
        verifiedAt: try publishBase(target, payloadIdentity: identity, archiveRoot: archiveRoot))
    }
  }

  /// Reconstructs and validates one recent viable chain. It never treats an
  /// older portable file as a successful new-format recovery result.
  static func materializeLatest(
    in cloudFolder: URL,
    workspace: URL
  ) throws -> URL? {
    switch try latestVerified(in: root(in: cloudFolder), workspace: workspace) {
    case .absent: return nil
    case .unusable: throw Failure.invalid("no recent verified head")
    case .verified(_, let directory):
      let archive = directory.appending(path: payloadName, directoryHint: .notDirectory)
      try requireRegular(archive)
      _ = try LinnetBackupStore.decodePortable(Data(contentsOf: archive))
      return archive
    }
  }
}

private extension LinnetCloudRecoveryArchive {
  private static func publishBase(
    _ target: URL,
    payloadIdentity: String,
    archiveRoot: URL
  ) throws -> Date {
    try ensureLayout(archiveRoot)
    let digest = try publishDirectory(target, archiveRoot: archiveRoot)
    let createdAt = millisecondDate(Date())
    try publishHead(.init(
      formatVersion: 1, operationID: UUID(), createdAt: createdAt, baseDigest: digest,
      targetDigest: digest, payloadIdentity: payloadIdentity, deltas: []), archiveRoot: archiveRoot)
    return createdAt
  }

  private static func publishDelta(
    from baseline: URL,
    to target: URL,
    previous: Head,
    payloadIdentity: String,
    archiveRoot: URL,
    workspace: URL
  ) throws -> Date {
    try ensureLayout(archiveRoot)
    let delta = workspace.appending(path: "next.linnetdelta", directoryHint: .notDirectory)
    try LinnetDirectoryDelta.build(base: baseline, target: target, output: delta)
    let targetDigest = try LinnetDirectoryDelta.digest(target)
    let hash = try sha256(delta)
    let name = "\(targetDigest)-\(hash).linnetdelta"
    let destination = archiveRoot.appending(path: "deltas/\(name)", directoryHint: .notDirectory)
    try publishFile(delta, to: destination, sha256: hash, archiveRoot: archiveRoot)
    var deltas = previous.deltas
    deltas.append(.init(name: name, targetDigest: targetDigest, sha256: hash))
    let createdAt = millisecondDate(max(Date(), previous.createdAt.addingTimeInterval(0.001)))
    try publishHead(.init(
      formatVersion: 1, operationID: UUID(), createdAt: createdAt, baseDigest: previous.baseDigest,
      targetDigest: targetDigest, payloadIdentity: payloadIdentity, deltas: deltas), archiveRoot: archiveRoot)
    return createdAt
  }

  private static func latestVerified(in archiveRoot: URL, workspace: URL) throws -> Latest {
    let heads = archiveRoot.appending(path: "heads", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: heads.path) else {
      return try hasRecoveryObjects(in: archiveRoot) ? .unusable : .absent
    }
    try requireDirectory(heads)
    let candidates = try FileManager.default.contentsOfDirectory(
      at: heads, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    guard !candidates.isEmpty else {
      return try hasRecoveryObjects(in: archiveRoot) ? .unusable : .absent
    }
    for candidate in candidates.prefix(maximumHeadsToProbe) {
      let candidateWorkspace = workspace.appending(
        path: "head-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: candidateWorkspace, withIntermediateDirectories: false)
      do {
        let head = try readHead(candidate)
        let reconstructed = try reconstruct(
          head, archiveRoot: archiveRoot, workspace: candidateWorkspace)
        return .verified(head, reconstructed)
      } catch {
        try? FileManager.default.removeItem(at: candidateWorkspace)
      }
    }
    return .unusable
  }

  private static func hasRecoveryObjects(in archiveRoot: URL) throws -> Bool {
    for name in ["bases", "deltas"] {
      let directory = archiveRoot.appending(path: name, directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: directory.path) else { continue }
      try requireDirectory(directory)
      if !(try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])).isEmpty {
        return true
      }
    }
    return false
  }

  private static func reconstruct(_ head: Head, archiveRoot: URL, workspace: URL) throws -> URL {
    guard head.formatVersion == 1, head.deltas.count <= 1024 else {
      throw Failure.invalid("head version or length")
    }
    let base = archiveRoot.appending(path: "bases/\(head.baseDigest)", directoryHint: .isDirectory)
    try requireDirectory(base)
    guard try LinnetDirectoryDelta.digest(base) == head.baseDigest else {
      throw Failure.invalid("base digest")
    }
    var current = base
    for (index, delta) in head.deltas.enumerated() {
      guard safeName(delta.name) else { throw Failure.invalid("delta name") }
      let source = archiveRoot.appending(path: "deltas/\(delta.name)", directoryHint: .notDirectory)
      try requireRegular(source)
      guard try sha256(source) == delta.sha256 else { throw Failure.invalid("delta hash") }
      let output = workspace.appending(path: "reconstructed-\(index)", directoryHint: .isDirectory)
      guard !FileManager.default.fileExists(atPath: output.path) else {
        throw Failure.invalid("reconstruction workspace")
      }
      try LinnetDirectoryDelta.apply(base: current, delta: source, output: output)
      guard try LinnetDirectoryDelta.digest(output) == delta.targetDigest else {
        throw Failure.invalid("delta target")
      }
      current = output
    }
    guard try LinnetDirectoryDelta.digest(current) == head.targetDigest else {
      throw Failure.invalid("head target")
    }
    let archive = current.appending(path: payloadName, directoryHint: .notDirectory)
    try requireRegular(archive)
    let payload = try Data(contentsOf: archive)
    guard try payloadIdentity(LinnetBackupStore.decodePortable(payload)) == head.payloadIdentity else {
      throw Failure.invalid("payload identity")
    }
    return current
  }

  private static func payloadIdentity(_ archive: LinnetBackupStore.PortableArchive) throws -> String {
    let value = PayloadIdentity(
      formatVersion: archive.formatVersion, appVersion: archive.appVersion, dataVersion: archive.dataVersion,
      categories: archive.categories, personal: archive.personal, learning: archive.learning)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(value))
  }

  private static func publishDirectory(_ source: URL, archiveRoot: URL) throws -> String {
    let staged = archiveRoot.appending(path: "staging/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: staged)
    defer { try? FileManager.default.removeItem(at: staged) }
    let stagedDigest = try LinnetDirectoryDelta.digest(staged)
    let destination = archiveRoot.appending(
      path: "bases/\(stagedDigest)", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: destination.path) {
      try requireDirectory(destination)
      guard try LinnetDirectoryDelta.digest(destination) == stagedDigest else {
        throw Failure.invalid("base collision")
      }
      return stagedDigest
    }
    try moveImmutable(staged, to: destination)
    try requireDirectory(destination)
    guard try LinnetDirectoryDelta.digest(destination) == stagedDigest else {
      throw Failure.invalid("published base")
    }
    return stagedDigest
  }

  private static func publishFile(_ source: URL, to destination: URL, sha256 expected: String, archiveRoot: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      try requireRegular(destination)
      guard try sha256(destination) == expected else { throw Failure.invalid("delta collision") }
      return
    }
    let staged = archiveRoot.appending(path: "staging/\(UUID().uuidString)", directoryHint: .notDirectory)
    try FileManager.default.copyItem(at: source, to: staged)
    defer { try? FileManager.default.removeItem(at: staged) }
    guard try sha256(staged) == expected else { throw Failure.invalid("staged delta") }
    try moveImmutable(staged, to: destination)
    guard try sha256(destination) == expected else { throw Failure.invalid("published delta") }
  }

  private static func publishHead(_ head: Head, archiveRoot: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(head)
    guard data.count <= maximumHeadBytes else { throw Failure.invalid("head size") }
    let millis = Int64(head.createdAt.timeIntervalSince1970 * 1000)
    let destination = archiveRoot.appending(
      path: "heads/\(String(format: "%020lld", millis))-\(head.operationID.uuidString).json",
      directoryHint: .notDirectory)
    let staged = archiveRoot.appending(path: "staging/\(UUID().uuidString)", directoryHint: .notDirectory)
    try data.write(to: staged, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: staged) }
    try moveImmutable(staged, to: destination)
    try requireRegular(destination)
    guard try Data(contentsOf: destination) == data else { throw Failure.invalid("published head") }
  }

  private static func readHead(_ url: URL) throws -> Head {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 0, info.st_size <= Int64(maximumHeadBytes) else {
      throw Failure.invalid("head size")
    }
    try requireRegular(url)
    let data = try Data(contentsOf: url)
    guard data.count <= maximumHeadBytes else { throw Failure.invalid("head size") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let head = try decoder.decode(Head.self, from: data)
    guard head.formatVersion == 1, safeName(url.lastPathComponent),
      hash(head.baseDigest), hash(head.targetDigest),
      head.deltas.allSatisfy({ safeName($0.name) && hash($0.targetDigest) && hash($0.sha256) })
    else {
      throw Failure.invalid("head")
    }
    return head
  }

  private static func ensureLayout(_ archiveRoot: URL) throws {
    for path in ["", "bases", "deltas", "heads", "staging"] {
      let directory = path.isEmpty ? archiveRoot : archiveRoot.appending(path: path, directoryHint: .isDirectory)
      if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      try requireDirectory(directory)
    }
  }

  private static func moveImmutable(_ staged: URL, to destination: URL) throws {
    do {
      try FileManager.default.moveItem(at: staged, to: destination)
    } catch {
      guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
    }
  }

  private static func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw Failure.invalid("directory") }
  }

  private static func requireRegular(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw Failure.invalid("file") }
  }

  private static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent && !name.contains("/")
  }

  private static func hash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }

  private static func millisecondDate(_ value: Date) -> Date {
    Date(timeIntervalSince1970: TimeInterval(Int64(value.timeIntervalSince1970 * 1000)) / 1000)
  }

  private static func sha256(_ url: URL) throws -> String {
    try requireRegular(url)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

}
