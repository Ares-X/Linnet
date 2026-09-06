import CryptoKit
import Darwin
import Foundation

struct LinnetPreparedCoreUpdate: Equatable, Sendable {
  let core: LinnetDataChannel.Core
  let baseIdentity: LinnetSettingsContract.ProductIdentity
  let installedApp: URL
  let stagingRoot: URL
  let candidateApp: URL
  let baseSHA256: String
  let targetSHA256: String
}

protocol LinnetCoreUpdateInstalling: Sendable {
  func prepare(
    _ core: LinnetDataChannel.Core,
    artifact: URL,
    installedApp: URL
  ) async throws -> LinnetPreparedCoreUpdate
  func exchange(_ update: LinnetPreparedCoreUpdate) async throws
  func discard(_ update: LinnetPreparedCoreUpdate) async
  func removeStaleUpdates(beside installedApp: URL) async
}

/// Owns the user-domain filesystem mutation for a verified online Core.
struct LinnetCoreUpdateInstaller: LinnetCoreUpdateInstalling {
  func prepare(
    _ core: LinnetDataChannel.Core,
    artifact: URL,
    installedApp: URL
  ) async throws -> LinnetPreparedCoreUpdate {
    try await Task.detached {
      guard core.artifactFormat == .appArchive,
        artifact.pathExtension == "linnetcore",
        let baseIdentity = LinnetSettingsContract.productIdentity(at: installedApp),
        let expectedLeaf = Self.releaseSigningLeaf(at: installedApp)
      else { throw Failure.invalidIdentity }
      try LinnetDataChannel.verifyDownloadedArtifact(
        bytes: core.bytes, sha256: core.sha256, at: artifact)

      let parent = installedApp.deletingLastPathComponent()
      try Self.requireOwnedDirectory(parent)
      let stagingRoot = parent.appending(
        path: ".linnet-core-update.\(UUID().uuidString)",
        directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: stagingRoot, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      do {
        try Self.run("/usr/bin/tar", [
          "-xzf", artifact.path, "--safe-writes", "--no-same-owner",
          "--no-same-permissions", "--no-acls", "--no-fflags",
          "--no-mac-metadata", "--no-xattrs", "-C", stagingRoot.path
        ])
        let candidate = stagingRoot.appending(
          path: "Linnet.payload", directoryHint: .isDirectory)
        guard try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
          == ["Linnet.payload"],
          let targetIdentity = LinnetSettingsContract.productIdentity(at: candidate),
          targetIdentity == .init(
            version: core.version, build: core.build, revision: core.revision),
          core.availability(
            currentVersion: baseIdentity.version,
            currentBuild: baseIdentity.build,
            currentRevision: baseIdentity.revision) == .available
        else { throw Failure.invalidIdentity }
        try Self.verifyProduct(candidate, expectedLeaf: expectedLeaf)
        return try LinnetPreparedCoreUpdate(
          core: core,
          baseIdentity: baseIdentity,
          installedApp: installedApp,
          stagingRoot: stagingRoot,
          candidateApp: candidate,
          baseSHA256: LinnetDirectoryDelta.digest(installedApp),
          targetSHA256: LinnetDirectoryDelta.digest(candidate))
      } catch {
        try? FileManager.default.removeItem(at: stagingRoot)
        throw error
      }
    }.value
  }

  func exchange(_ update: LinnetPreparedCoreUpdate) async throws {
    try await Task.detached {
      try LinnetDirectoryDelta.exchangeApp(
        installed: update.installedApp,
        staged: update.candidateApp,
        baseSHA256: update.baseSHA256,
        targetSHA256: update.targetSHA256)
    }.value
  }

  func discard(_ update: LinnetPreparedCoreUpdate) async {
    await Task.detached {
      try? FileManager.default.removeItem(at: update.stagingRoot)
    }.value
  }

  func removeStaleUpdates(beside installedApp: URL) async {
    await Task.detached {
      let parent = installedApp.deletingLastPathComponent()
      guard let children = try? FileManager.default.contentsOfDirectory(
        at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      else { return }
      for child in children where child.lastPathComponent.hasPrefix(".linnet-core-update.") {
        guard let values = try? child.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
          values.isDirectory == true, values.isSymbolicLink != true
        else { continue }
        try? FileManager.default.removeItem(at: child)
      }
    }.value
  }

  private static func verifyProduct(_ app: URL, expectedLeaf: String) throws {
    try run(
      "/usr/bin/codesign",
      ["--verify", "--deep", "--strict", "--all-architectures", app.path])
    let settings = app.appending(
      path: "Contents/Applications/Settings.app", directoryHint: .isDirectory)
    guard try signingLeaf(of: app) == expectedLeaf,
      try signingLeaf(of: settings) == expectedLeaf
    else { throw Failure.invalidSignature }
  }

  private static func signingLeaf(of app: URL) throws -> String {
    let parent = app.deletingLastPathComponent()
    let prefix = parent.appending(path: ".linnet-cert-\(UUID().uuidString)").path
    defer {
      for index in 0..<8 { try? FileManager.default.removeItem(atPath: "\(prefix)\(index)") }
    }
    try run("/usr/bin/codesign", ["-d", "--extract-certificates=\(prefix)", app.path])
    let certificate = try Data(contentsOf: URL(fileURLWithPath: "\(prefix)0"))
    return SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
  }

  private static func releaseSigningLeaf(at app: URL) -> String? {
    let url = app.appending(
      path: "Contents/Resources/LinnetRelease/VERSION.json",
      directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: url),
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let distribution = document["distribution"] as? [String: Any],
      let signature = distribution["application_code_signature"] as? [String: Any],
      signature["profile"] as? String == "community-cms",
      let leaf = signature["leaf_certificate_sha256"] as? String,
      leaf.count == 64,
      leaf.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      })
    else { return nil }
    return leaf
  }

  private static func requireOwnedDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o022 == 0
    else { throw Failure.unsafeInstallLocation }
  }

  private static func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw Failure.toolFailed
    }
  }

  private enum Failure: Error {
    case invalidIdentity
    case invalidSignature
    case unsafeInstallLocation
    case toolFailed
  }
}
