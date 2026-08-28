import CryptoKit
import Darwin
import Foundation

extension LinnetBackupStore {
  static let canonicalPersonalFiles = Set([
    LinnetPersonalDataStore.customWordsFile,
    LinnetPersonalDataStore.userSettingsFile,
    LinnetPersonalDataStore.expansionsFile
  ])
  static let legacyV2PersonalFiles = Set([
    LinnetPersonalDataStore.customWordsFile,
    LinnetPersonalDataStore.legacyUserSettingsFile,
    LinnetPersonalDataStore.expansionsFile
  ])
  static let stableFiles = Set(["installation.yaml", "user.yaml"])
  static let learningFiles = Set(["linnet_zh.txt", "linnet_en.txt"])

  enum StableLayout {
    case current
    case legacyV2

    var requiredFiles: Set<String> {
      switch self {
      case .current: canonicalPersonalFiles.union([LinnetSettingsDocumentStore.fileName])
      case .legacyV2: legacyV2PersonalFiles
      }
    }
  }

  static func backupRecord(_ transactionDirectory: URL) -> BackupRecord {
    let transactionID = UUID(uuidString: transactionDirectory.lastPathComponent)
    let backup = transactionDirectory.appending(path: "backup", directoryHint: .isDirectory)
    let identity = try? transactionIdentity(transactionDirectory)
    do {
      guard identity != nil else {
        throw Failure.unsafeArtifact(transactionDirectory.lastPathComponent)
      }
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .verified(try verifyBackup(at: backup)),
        transactionIdentity: identity
      )
    } catch Failure.incompleteBackup {
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .incomplete,
        transactionIdentity: identity
      )
    } catch let failure as Failure {
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .corrupt(failure),
        transactionIdentity: identity
      )
    } catch {
      return BackupRecord(
        transactionDirectory: transactionDirectory,
        backupDirectory: backup,
        transactionID: transactionID,
        state: .corrupt(.invalidDocument("filesystem")),
        transactionIdentity: identity
      )
    }
  }

  static func transactionIdentity(_ url: URL) throws -> TransactionIdentity {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafeArtifact(url.lastPathComponent) }
    return .init(
      device: UInt64(info.st_dev),
      inode: UInt64(info.st_ino),
      modifiedSeconds: info.st_mtimespec.tv_sec,
      modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      changedSeconds: info.st_ctimespec.tv_sec,
      changedNanoseconds: info.st_ctimespec.tv_nsec
    )
  }

  static func rollbackOwnedTransaction(
    transactionID: UUID,
    backupID: UUID,
    in transactionsRoot: URL
  ) throws {
    let root = transactionsRoot.standardizedFileURL
    let transaction = root.appending(
      path: transactionID.uuidString,
      directoryHint: .isDirectory
    ).standardizedFileURL
    guard transaction.deletingLastPathComponent() == root,
      transaction.resolvingSymlinksInPath() == transaction,
      (try? requireDirectory(transaction)) != nil
    else {
      throw Failure.unsafeArtifact(transactionID.uuidString)
    }
    let backup = transaction.appending(path: "backup", directoryHint: .isDirectory)
    let manifestURL = backup.appending(path: "manifest.json")
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      let data = try readBoundedRegularFile(manifestURL, limit: maximumManifestBytes)
      let manifest: BackupManifest
      do {
        manifest = try decoder().decode(BackupManifest.self, from: data)
      } catch {
        throw Failure.invalidDocument("rollback manifest")
      }
      guard manifest.transactionID == transactionID, manifest.backupID == backupID else {
        throw Failure.unsafeArtifact(transactionID.uuidString)
      }
    }
    try FileManager.default.removeItem(at: transaction)
  }

  static func deletableTransaction(
    _ transactionDirectory: URL,
    backupDirectory: URL,
    transactionID: UUID,
    transactionsRoot: URL
  ) -> Bool {
    let root = transactionsRoot.standardizedFileURL
    let transaction = transactionDirectory.standardizedFileURL
    let backup = backupDirectory.standardizedFileURL
    guard transaction.deletingLastPathComponent() == root,
      UUID(uuidString: transaction.lastPathComponent) == transactionID,
      backup == transaction.appending(path: "backup", directoryHint: .isDirectory),
      transaction.resolvingSymlinksInPath() == transaction,
      (try? requireDirectory(transaction)) != nil
    else {
      return false
    }
    return true
  }

  static func encoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  static func validateVersionLabel(_ value: String, name: String) throws {
    let count = value.lengthOfBytes(using: .utf8)
    guard !value.isEmpty, count <= 256,
      !value.contains("\n"), !value.contains("\r"), !value.contains("\0")
    else {
      throw Failure.invalidDocument(name)
    }
  }

  static func personalArtifact(
    _ category: Category,
    data: LinnetPersonalData
  ) throws -> PortablePersonalArtifact {
    let rows: [PortableRow]
    switch category {
    case .customWords:
      rows = data.customWords.map { .init(value: $0.value, key: $0.code) }
    case .disabledWords:
      rows = data.disabledWords.map { .init(value: $0.value, key: nil) }
    case .textExpander:
      rows = data.expansions.map { .init(value: $0.value, key: $0.trigger) }
    case .chineseLearning, .englishLearning:
      throw Failure.invalidCategory(category.rawValue)
    }
    try validateRows(rows, category: category)
    return PortablePersonalArtifact(
      category: category,
      rowCount: rows.count,
      sha256: sha256(try encoder().encode(rows)),
      rows: rows
    )
  }

  static func learningArtifact(
    schema: String,
    contents: String
  ) throws -> PortableLearningArtifact {
    guard let category = Category.allCases.first(where: { $0.learningSchema == schema }) else {
      throw Failure.invalidCategory(schema)
    }
    let data = Data(contents.utf8)
    guard data.count <= maximumLearningBytes else { throw Failure.artifactTooLarge(schema) }
    let rowCount = try validateLearningContents(contents, name: schema)
    return PortableLearningArtifact(
      category: category,
      schema: schema,
      rowCount: rowCount,
      sha256: sha256(data),
      contents: contents
    )
  }

  static func validate(_ archive: PortableArchive) throws {
    guard archive.formatVersion == portableFormatVersion else {
      throw Failure.unsupportedVersion(archive.formatVersion)
    }
    try validateVersionLabel(archive.appVersion, name: "appVersion")
    try validateVersionLabel(archive.dataVersion, name: "dataVersion")
    let categories = Set(archive.categories)
    guard categories.count == archive.categories.count else {
      throw Failure.invalidCategory("duplicate category")
    }
    var payloadCategories = try validatePersonalArtifacts(archive.personal)
    try validateLearningArtifacts(archive.learning, categories: &payloadCategories)
    guard payloadCategories == categories else {
      throw Failure.invalidCategory("payload does not match selected categories")
    }
    try validatePortablePersonalData(archive.personal)
  }

  static func validatePersonalArtifacts(
    _ artifacts: [PortablePersonalArtifact]
  ) throws -> Set<Category> {
    var categories = Set<Category>()
    for artifact in artifacts {
      guard artifact.category.learningSchema == nil,
        categories.insert(artifact.category).inserted
      else {
        throw Failure.invalidCategory(artifact.category.rawValue)
      }
      try validateRows(artifact.rows, category: artifact.category)
      guard artifact.rowCount == artifact.rows.count else {
        throw Failure.invalidRowCount(artifact.category.rawValue)
      }
      guard artifact.sha256 == sha256(try encoder().encode(artifact.rows)) else {
        throw Failure.invalidHash(artifact.category.rawValue)
      }
    }
    return categories
  }

  static func validateLearningArtifacts(
    _ artifacts: [PortableLearningArtifact],
    categories: inout Set<Category>
  ) throws {
    for artifact in artifacts {
      guard artifact.category.learningSchema == artifact.schema,
        categories.insert(artifact.category).inserted
      else {
        throw Failure.invalidCategory(artifact.schema)
      }
      let data = Data(artifact.contents.utf8)
      guard data.count <= maximumLearningBytes else {
        throw Failure.artifactTooLarge(artifact.schema)
      }
      let rowCount = try validateLearningContents(artifact.contents, name: artifact.schema)
      guard artifact.rowCount == rowCount else {
        throw Failure.invalidRowCount(artifact.schema)
      }
      guard artifact.sha256 == sha256(data) else {
        throw Failure.invalidHash(artifact.schema)
      }
    }
  }

  static func validatePortablePersonalData(_ artifacts: [PortablePersonalArtifact]) throws {
    var candidate = LinnetPersonalData.empty
    for artifact in artifacts {
      switch artifact.category {
      case .customWords:
        candidate.customWords = artifact.rows.map {
          .init(value: $0.value, code: $0.key ?? "")
        }
      case .disabledWords:
        candidate.disabledWords = artifact.rows.map { .init(value: $0.value) }
      case .textExpander:
        candidate.expansions = artifact.rows.map {
          .init(value: $0.value, trigger: $0.key ?? "")
        }
      case .chineseLearning, .englishLearning:
        throw Failure.invalidCategory(artifact.category.rawValue)
      }
    }
    do {
      _ = try LinnetPersonalDataStore.normalized(candidate)
    } catch {
      throw Failure.invalidDocument("personal data")
    }
  }

  static func validateRows(_ rows: [PortableRow], category: Category) throws {
    guard rows.count <= LinnetPersonalDataStore.maximumRows else {
      throw Failure.artifactTooLarge(category.rawValue)
    }
    for row in rows {
      guard row.value.lengthOfBytes(using: .utf8) <= LinnetPersonalDataStore.maximumFieldBytes,
        (row.key?.lengthOfBytes(using: .utf8) ?? 0)
          <= LinnetPersonalDataStore.maximumFieldBytes
      else {
        throw Failure.artifactTooLarge(category.rawValue)
      }
      switch category {
      case .disabledWords:
        guard row.key == nil else { throw Failure.invalidDocument(category.rawValue) }
      case .customWords, .textExpander:
        guard row.key != nil else { throw Failure.invalidDocument(category.rawValue) }
      case .chineseLearning, .englishLearning:
        throw Failure.invalidCategory(category.rawValue)
      }
    }
  }

  static func learningRowCount(_ contents: String) -> Int {
    contents.split(whereSeparator: \.isNewline).filter {
      let row = $0.trimmingCharacters(in: .whitespaces)
      return !row.isEmpty && !row.hasPrefix("#")
    }.count
  }

  static func validateLearningContents(_ contents: String, name: String) throws -> Int {
    guard !contents.contains("\0") else { throw Failure.invalidDocument(name) }
    var rowCount = 0
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard (2...3).contains(fields.count),
        !fields[0].isEmpty, !fields[1].isEmpty,
        fields.allSatisfy({ $0.utf8.count <= LinnetPersonalDataStore.maximumFieldBytes })
      else {
        throw Failure.invalidDocument(name)
      }
      rowCount += 1
      guard rowCount <= maximumLearningRows else { throw Failure.artifactTooLarge(name) }
    }
    return rowCount
  }

  static func collectBackupArtifacts(
    _ backupDirectory: URL,
    formatVersion: Int
  ) throws -> [BackupArtifact] {
    let stable = backupDirectory.appending(path: "stable", directoryHint: .isDirectory)
    let learning = backupDirectory.appending(
      path: "user-dictionaries",
      directoryHint: .isDirectory
    )
    try requireDirectory(learning)
    let stableURLs = try stableArtifactURLs(
      stable, formatVersion: formatVersion).files
    let learningURLs = try immediateChildren(
      of: learning,
      maximumCount: learningFiles.count,
      overflow: .artifactTooLarge("learning file count")
    )
    var aggregateBytes = 0
    for url in stableURLs + learningURLs {
      let name = url.lastPathComponent
      let limit = stableURLs.contains(url) ? stableArtifactLimit(name) : maximumBackupArtifactBytes
      let byteCount = try regularFileSize(url, limit: limit)
      guard aggregateBytes <= maximumBackupBytes - byteCount else {
        throw Failure.artifactTooLarge("backup total")
      }
      aggregateBytes += byteCount
    }
    var artifacts: [BackupArtifact] = []
    for url in stableURLs {
      let name = url.lastPathComponent
      artifacts.append(try backupArtifact(url, path: "stable/\(name)", learning: false))
    }
    for url in learningURLs {
      let name = url.lastPathComponent
      guard learningFiles.contains(name) else { throw Failure.unsafeArtifact(name) }
      artifacts.append(
        try backupArtifact(
          url,
          path: "user-dictionaries/\(name)",
          learning: true
        ))
    }
    return artifacts.sorted { $0.path < $1.path }
  }

  static func backupArtifact(_ url: URL, path: String, learning: Bool) throws
    -> BackupArtifact {
    let limit = learning ? maximumBackupArtifactBytes : stableArtifactLimit(url.lastPathComponent)
    let byteCount = try regularFileSize(url, limit: limit)
    let contents: String?
    if learning {
      let data = try readBoundedRegularFile(url, limit: maximumBackupArtifactBytes)
      guard let decoded = String(data: data, encoding: .utf8) else {
        throw Failure.invalidDocument(path)
      }
      _ = try validateLearningContents(decoded, name: path)
      contents = decoded
    } else {
      contents = nil
    }
    return BackupArtifact(
      path: path,
      byteCount: byteCount,
      rowCount: contents.map(learningRowCount),
      sha256: try sha256(url, expectedBytes: byteCount)
    )
  }

  static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }

  static func stableSourceNameIsAllowed(_ name: String) -> Bool {
    stableFiles.contains(name)
      || name == LinnetSettingsDocumentStore.fileName
      || (name.hasSuffix(".custom.yaml") && safeName(name))
  }

  static func stableArtifactLimit(_ name: String) -> Int {
    if name == LinnetSettingsDocumentStore.fileName {
      return LinnetSettingsDocumentStore.maximumDocumentBytes
    }
    return maximumStableArtifactBytes
  }

  static func stableArtifactURLs(
    _ directory: URL,
    formatVersion: Int?
  ) throws -> (layout: StableLayout, files: [URL]) {
    let files = try immediateChildren(
      of: directory,
      maximumCount: maximumStableFiles,
      overflow: .artifactTooLarge("stable file count")
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    let names = Set(files.map(\.lastPathComponent))
    let layout: StableLayout
    switch formatVersion {
    case backupFormatVersion: layout = .current
    case legacyBackupFormatVersion: layout = .legacyV2
    case .some(let version): throw Failure.unsupportedVersion(version)
    case nil:
      if legacyV2PersonalFiles.isSubset(of: names) {
        layout = .legacyV2
      } else if canonicalPersonalFiles.isSubset(of: names) {
        layout = .current
      } else {
        throw Failure.incompleteBackup
      }
    }
    guard layout.requiredFiles.isSubset(of: names) else {
      throw Failure.incompleteBackup
    }
    for file in files {
      let name = file.lastPathComponent
      guard layout.requiredFiles.contains(name) || stableSourceNameIsAllowed(name) else {
        throw Failure.unsafeArtifact(name)
      }
    }
    let total = try files.reduce(into: 0) { partial, file in
      let bytes = try regularFileSize(
        file,
        limit: stableArtifactLimit(file.lastPathComponent)
      )
      guard partial <= maximumBackupBytes - bytes else {
        throw Failure.artifactTooLarge("backup total")
      }
      partial += bytes
    }
    guard total <= maximumBackupBytes else { throw Failure.artifactTooLarge("backup total") }
    return (layout, files)
  }

  /// The sole compatibility branch: verified v2 bytes are decoded with the
  /// frozen v2 codec and materialized as current canonical files. No v2 writer
  /// or steady-state fallback exists.
  static func normalizeLegacyV2Stable(
    _ files: [URL],
    from source: URL,
    to destination: URL
  ) throws {
    let legacy = try LinnetPersonalDataStore.legacyV2Snapshot(from: source)
    let hadDocument = FileManager.default.fileExists(
      atPath: source.appending(path: LinnetSettingsDocumentStore.fileName).path)
    let document = try LinnetSettingsDocumentStore.load(from: source)
    if !hadDocument {
      guard document.english.sentenceCapitalization == legacy.sentenceCapitalization,
        document.english.tabBehavior.rawValue == legacy.tabBehavior
      else {
        throw Failure.invalidDocument("backup-v2 interaction adoption")
      }
    }

    let replacedFiles = legacyV2PersonalFiles
      .union(canonicalPersonalFiles)
      .union([LinnetSettingsDocumentStore.fileName])
    let preserved = files.filter { !replacedFiles.contains($0.lastPathComponent) }
    guard preserved.count + canonicalPersonalFiles.count + 1 <= maximumStableFiles else {
      throw Failure.artifactTooLarge("stable file count")
    }
    var copiedBytes = 0
    for file in preserved {
      let remaining = maximumBackupBytes - copiedBytes
      let copied = try copyBoundedRegularFile(
        file,
        to: destination.appending(path: file.lastPathComponent),
        limit: min(stableArtifactLimit(file.lastPathComponent), remaining)
      )
      copiedBytes += copied
    }
    try LinnetPersonalDataStore.writePersonalFiles(legacy.data, to: destination)
    try LinnetPersonalDataStore.writeRuntimeSettings(legacy.data, to: destination)
    try LinnetSettingsDocumentStore.write(document, to: destination)
    _ = try regularBytes(in: destination, maximumCount: maximumStableFiles)
  }

  static func regularBytes(in directory: URL, maximumCount: Int) throws -> Int {
    let files = try immediateChildren(
      of: directory,
      maximumCount: maximumCount,
      overflow: .artifactTooLarge("stable file count")
    )
    var total = 0
    for file in files {
      let bytes = try regularFileSize(
        file,
        limit: stableArtifactLimit(file.lastPathComponent)
      )
      guard total <= maximumBackupBytes - bytes else {
        throw Failure.artifactTooLarge("backup total")
      }
      total += bytes
    }
    return total
  }

  static func immediateChildren(
    of directory: URL,
    maximumCount: Int,
    overflow: Failure
  ) throws -> [URL] {
    guard maximumCount > 0 else { throw overflow }
    try requireDirectory(directory)
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    ) else {
      throw Failure.unsafeArtifact(directory.lastPathComponent)
    }
    var result: [URL] = []
    while let url = enumerator.nextObject() as? URL {
      result.append(url)
      guard result.count <= maximumCount else { throw overflow }
    }
    return result
  }

  static func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
  }

  static func requireRegularFile(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else {
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
  }

  static func regularFileSize(_ url: URL, limit: Int) throws -> Int {
    var info = stat()
    guard limit >= 0,
      lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_size >= 0,
      info.st_size <= limit
    else {
      if info.st_size > limit { throw Failure.artifactTooLarge(url.lastPathComponent) }
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    return Int(info.st_size)
  }

  static func copyBoundedRegularFile(
    _ source: URL,
    to destination: URL,
    limit: Int
  ) throws -> Int {
    let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
    guard sourceDescriptor >= 0 else { throw Failure.unsafeArtifact(source.lastPathComponent) }
    let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
    defer { try? sourceHandle.close() }
    var info = stat()
    guard limit >= 0,
      fstat(sourceDescriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_size >= 0,
      info.st_size <= limit
    else {
      if info.st_size > limit { throw Failure.artifactTooLarge(source.lastPathComponent) }
      throw Failure.unsafeArtifact(source.lastPathComponent)
    }
    let destinationDescriptor = open(
      destination.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard destinationDescriptor >= 0 else {
      throw Failure.unsafeArtifact(destination.lastPathComponent)
    }
    let destinationHandle = FileHandle(
      fileDescriptor: destinationDescriptor,
      closeOnDealloc: true
    )
    var copied = 0
    do {
      while true {
        let chunk = try sourceHandle.read(upToCount: 1024 * 1024) ?? Data()
        if chunk.isEmpty { break }
        guard copied <= limit - chunk.count else {
          throw Failure.artifactTooLarge(source.lastPathComponent)
        }
        try destinationHandle.write(contentsOf: chunk)
        copied += chunk.count
      }
      guard copied == Int(info.st_size) else {
        throw Failure.unsafeArtifact(source.lastPathComponent)
      }
      try destinationHandle.synchronize()
      try destinationHandle.close()
      return copied
    } catch {
      try? destinationHandle.close()
      throw error
    }
  }

  /// Reads one current-user regular file through a single no-follow descriptor.
  /// Both byte count and inode metadata must remain identical for the complete
  /// read; a concurrent grow, shrink, replacement or rewrite is never accepted.
  static func readBoundedRegularFile(_ url: URL, limit: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw Failure.missingArtifact(url.lastPathComponent) }
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard limit >= 0,
      fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == getuid(),
      before.st_size >= 0,
      before.st_size <= limit
    else {
      if before.st_size > limit { throw Failure.artifactTooLarge(url.lastPathComponent) }
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    var result = Data()
    result.reserveCapacity(Int(before.st_size))
    while true {
      let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if chunk.isEmpty { break }
      guard result.count <= limit - chunk.count else {
        throw Failure.artifactTooLarge(url.lastPathComponent)
      }
      result.append(chunk)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      result.count == Int(before.st_size),
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else {
      throw Failure.unsafeArtifact(url.lastPathComponent)
    }
    return result
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func sha256(_ url: URL, expectedBytes: Int) throws -> String {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Failure.unsafeArtifact(url.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var hasher = SHA256()
    var observed = 0
    while true {
      let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if data.isEmpty { break }
      guard observed <= expectedBytes - data.count else {
        throw Failure.artifactTooLarge(url.lastPathComponent)
      }
      observed += data.count
      hasher.update(data: data)
    }
    guard observed == expectedBytes else { throw Failure.unsafeArtifact(url.lastPathComponent) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
