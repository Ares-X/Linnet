import CryptoKit
import Darwin
import Foundation

/// Owns the JSON codec, first-run adoption, and atomic publication primitive
/// for the settings document. Settings writes only transaction candidates;
/// Host is the sole owner that exchanges one with the live document.
enum LinnetSettingsDocumentStore {
  static let fileName = "linnet_settings.json"
  static let maximumDocumentBytes = 1024 * 1024
  private static let chineseProfileSchemaVersion = 8
  private static let rimeUserConfigFile = "user.yaml"

  struct Snapshot: Equatable, Sendable {
    let document: LinnetSettingsDocument
    let revision: String
  }

  enum Failure: LocalizedError, Equatable, Sendable {
    case unsafePath(String)
    case malformedDocument
    case documentTooLarge
    case newerSchemaVersion(Int)

    var errorDescription: String? {
      switch self {
      case .unsafePath(let path): "Unsafe settings document path: \(path)"
      case .malformedDocument: "The settings document could not be read."
      case .documentTooLarge: "The settings document is too large."
      case .newerSchemaVersion(let version):
        "The settings document was created by a newer version (schema \(version))."
      }
    }
  }

  /// Loads the document. A missing file builds the default document and
  /// adopts legacy English interaction values and the last recognized Rime
  /// Chinese profile so an upgraded install keeps its behavior. Malformed
  /// JSON and newer schema versions fail closed without touching the file.
  static func snapshot(from directory: URL) throws -> Snapshot {
    let url = directory.appending(path: fileName)
    let stored: StoredDocumentBytes?
    do {
      stored = try boundedDataIfPresent(url)
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.malformedDocument
    }
    guard let stored else {
      let adopted = try adoptLegacy(from: directory)
      return Snapshot(
        document: adopted,
        revision: revision(presence: "absent", data: try encoded(adopted)))
    }
    var document: LinnetSettingsDocument
    do {
      document = try JSONDecoder().decode(LinnetSettingsDocument.self, from: stored.data)
    } catch {
      throw Failure.malformedDocument
    }
    guard document.schemaVersion <= LinnetSettingsDocument.currentSchemaVersion else {
      throw Failure.newerSchemaVersion(document.schemaVersion)
    }
    if shouldAdoptLegacyChineseProfile(from: stored.data),
      let profile = legacyChineseProfile(from: directory) {
      document.input.chineseProfile = profile
    }
    return Snapshot(document: document, revision: stored.revision)
  }

  static func load(from directory: URL) throws -> LinnetSettingsDocument {
    try snapshot(from: directory).document
  }

  static func defaultSnapshot() throws -> Snapshot {
    let document = LinnetSettingsDocument.default
    return Snapshot(
      document: document,
      revision: revision(presence: "absent", data: try encoded(document)))
  }

  static func write(_ document: LinnetSettingsDocument, to directory: URL) throws {
    try requireDirectory(directory)
    let data = try encoded(document)
    let file = directory.appending(path: fileName)
    if try boundedDataIfPresent(file)?.data == data { return }
    do {
      try data.write(to: file, options: .atomic)
    } catch {
      throw Failure.unsafePath(fileName)
    }
  }

  /// Atomically exchanges the candidate and live document on the same volume.
  /// It is deliberately involutive: after a successful exchange the candidate
  /// holds the previous live document, so the identical operation is rollback.
  /// Exactly one side may be absent, which covers first-run publication and
  /// restoring that physical absence without a journal or sentinel file.
  static func exchangeCandidateDocument(
    candidateDirectory: URL,
    liveDirectory: URL
  ) throws {
    let candidateDirectoryDescriptor = try ownedDirectoryDescriptor(candidateDirectory)
    defer { close(candidateDirectoryDescriptor) }
    let liveDirectoryDescriptor = try ownedDirectoryDescriptor(liveDirectory)
    defer { close(liveDirectoryDescriptor) }
    var candidateDirectoryInfo = stat()
    var liveDirectoryInfo = stat()
    guard fstat(candidateDirectoryDescriptor, &candidateDirectoryInfo) == 0,
      fstat(liveDirectoryDescriptor, &liveDirectoryInfo) == 0,
      candidateDirectoryInfo.st_dev == liveDirectoryInfo.st_dev
    else { throw Failure.unsafePath(fileName) }
    let candidate = candidateDirectory.appending(path: fileName)
    let live = liveDirectory.appending(path: fileName)
    let candidatePresent = try boundedDataIfPresent(candidate) != nil
    let livePresent = try boundedDataIfPresent(live) != nil
    guard candidatePresent || livePresent else { return }

    let result: Int32
    if candidatePresent && livePresent {
      result = fileName.withCString { candidateName in
        fileName.withCString { liveName in
          renameatx_np(
            candidateDirectoryDescriptor,
            candidateName,
            liveDirectoryDescriptor,
            liveName,
            UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
          )
        }
      }
    } else {
      let source = candidatePresent ? candidate : live
      let sourceDirectoryDescriptor = candidatePresent
        ? candidateDirectoryDescriptor : liveDirectoryDescriptor
      let destinationDirectoryDescriptor = candidatePresent
        ? liveDirectoryDescriptor : candidateDirectoryDescriptor
      result = source.lastPathComponent.withCString { sourceName in
        fileName.withCString { destinationName in
          renameatx_np(
            sourceDirectoryDescriptor,
            sourceName,
            destinationDirectoryDescriptor,
            destinationName,
            UInt32(RENAME_NOFOLLOW_ANY)
          )
        }
      }
    }
    guard result == 0 else { throw Failure.unsafePath(fileName) }
  }

  private static func encoded(_ document: LinnetSettingsDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(document.normalized())
    } catch {
      throw Failure.malformedDocument
    }
    guard data.count <= maximumDocumentBytes else { throw Failure.documentTooLarge }
    return data
  }

  /// One-time adoption moves legacy English interaction values and the last
  /// recognized Rime Chinese profile into the document. Best effort; missing,
  /// malformed, or unknown legacy values yield the explicit defaults.
  static func adoptLegacy(from directory: URL) throws -> LinnetSettingsDocument {
    var document = LinnetSettingsDocument.default
    let userSettings = directory.appending(
      path: LinnetPersonalDataStore.legacyUserSettingsFile)
    if FileManager.default.fileExists(atPath: userSettings.path),
      let legacy = try? LinnetPersonalDataStore.readLegacyUserSettings(userSettings) {
      document.english.sentenceCapitalization = legacy.sentenceCapitalization
      document.english.tabBehavior =
        LinnetSettingsDocument.TabBehavior(rawValue: legacy.tabBehavior) ?? .smartComplete
    }
    if let profile = legacyChineseProfile(from: directory) {
      document.input.chineseProfile = profile
    }
    return document
  }

  private struct StoredShape: Decodable {
    struct InputShape: Decodable {
      let chineseProfile: String?
    }

    let schemaVersion: Int?
    let input: InputShape?
  }

  private static func shouldAdoptLegacyChineseProfile(from data: Data) -> Bool {
    guard let shape = try? JSONDecoder().decode(StoredShape.self, from: data),
      let version = shape.schemaVersion,
      version < chineseProfileSchemaVersion
    else {
      return false
    }
    return shape.input?.chineseProfile == nil
  }

  /// Reads the previous Rime owner only at document adoption. A recognized
  /// profile is written into the typed document on the next Apply; unknown,
  /// duplicate, or malformed values never become a steady-state fallback.
  private static func legacyChineseProfile(
    from directory: URL
  ) -> LinnetSettingsContract.ChineseProfile? {
    let url = directory.appending(path: rimeUserConfigFile)
    guard let stored = try? boundedDataIfPresent(url),
      let contents = String(data: stored.data, encoding: .utf8)
    else {
      return nil
    }
    var insideVar = false
    var selected: LinnetSettingsContract.ChineseProfile?
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      if line == "var:" {
        insideVar = true
        continue
      }
      if !line.hasPrefix(" ") {
        insideVar = false
      }
      guard insideVar,
        line.hasPrefix("  previously_selected_schema: ")
      else {
        continue
      }
      let value = String(line.dropFirst("  previously_selected_schema: ".count))
        .trimmingCharacters(in: .whitespaces)
      guard selected == nil,
        let profile = LinnetSettingsContract.ChineseProfile(schemaID: value)
      else {
        return nil
      }
      selected = profile
    }
    return selected
  }

  private static func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.unsafePath(url.path)
    }
  }

  /// Pins a user-owned directory for a subsequent relative-name mutation so
  /// system-level symlinks in an otherwise valid absolute prefix do not become
  /// part of the document publication decision.
  private static func ownedDirectoryDescriptor(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.unsafePath(url.path) }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      close(descriptor)
      throw Failure.unsafePath(url.path)
    }
    return descriptor
  }

  private struct StoredDocumentBytes {
    let data: Data
    let revision: String
  }

  private static func boundedDataIfPresent(_ url: URL) throws -> StoredDocumentBytes? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 && errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw Failure.unsafePath(url.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else {
      throw Failure.unsafePath(url.lastPathComponent)
    }
    guard info.st_size >= 0, info.st_size <= maximumDocumentBytes else {
      throw Failure.documentTooLarge
    }
    var data = Data()
    var hasher = revisionHasher(presence: "present")
    data.reserveCapacity(Int(info.st_size))
    while true {
      let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
      if chunk.isEmpty { break }
      guard data.count <= maximumDocumentBytes - chunk.count else {
        throw Failure.documentTooLarge
      }
      data.append(chunk)
      hasher.update(data: chunk)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      info.st_dev == after.st_dev, info.st_ino == after.st_ino,
      info.st_size == after.st_size,
      info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      data.count == Int(info.st_size)
    else { throw Failure.unsafePath(url.lastPathComponent) }
    return StoredDocumentBytes(data: data, revision: hex(hasher.finalize()))
  }

  private static func revision(presence: String, data: Data) -> String {
    var hasher = revisionHasher(presence: presence)
    hasher.update(data: data)
    return hex(hasher.finalize())
  }

  private static func revisionHasher(presence: String) -> SHA256 {
    var hasher = SHA256()
    hasher.update(data: Data("io.github.ares-x.linnet.settings-document.v1\0".utf8))
    hasher.update(data: Data(presence.utf8))
    hasher.update(data: Data([0]))
    return hasher
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
