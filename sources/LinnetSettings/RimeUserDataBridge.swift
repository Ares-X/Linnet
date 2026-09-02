import Darwin
import Foundation

/// Owns the Settings-process boundary to librime's deployer and Levers APIs.
/// It snapshots learning and prepares isolated personal-table databases; the
/// Host remains the only owner that publishes those bytes to the live runtime.
struct RimeUserDataBridge {
  static let chineseSchema = "linnet_zh"
  static let englishSchema = "linnet_en"
  static let learningSchemas = Set([chineseSchema, englishSchema])
  enum PersonalDictionary: String, CaseIterable, Hashable, Sendable {
    case customWords = "linnet_custom_words"
    case textExpander = "linnet_text_expander"

    var file: String {
      switch self {
      case .customWords: LinnetPersonalDataStore.customWordsFile
      case .textExpander: LinnetPersonalDataStore.expansionsFile
      }
    }

    var database: String { "\(rawValue).userdb" }
  }

  func reusablePersonalDictionaryDirectories(in directory: URL) throws -> Set<String> {
    try requireDirectory(directory)
    var reusable: Set<String> = []
    for dictionary in PersonalDictionary.allCases {
      let source = directory.appending(path: dictionary.file)
      var info = stat()
      if lstat(source.path, &info) == 0 {
        try requireRegularFile(source)
        reusable.insert(dictionary.database)
      } else if errno != ENOENT {
        throw Failure.unsafeDirectory(source.path)
      }
    }
    return reusable
  }

  struct LearningFile: Equatable, Sendable {
    let schema: String
    let file: URL
    let rows: Int
  }

  struct LearningImport: Equatable, Sendable {
    let schema: String
    let file: URL
  }

  struct LegacySnapshot: Equatable, Sendable {
    let files: [LearningFile]
    let importedRows: Int
  }

  struct PreparedUserDirectory: Equatable, Sendable {
    fileprivate let directory: URL
    fileprivate let identity: UserDirectoryIdentity
    fileprivate let recognizedSources: Set<String>

    var recognizedDictionaryCount: Int {
      recognizedSources.count
    }
  }

  enum Failure: LocalizedError, Equatable, Sendable {
    case unsafeDirectory(String)
    case leversUnavailable
    case exportFailed(String)
    case importFailed(String)
    case invalidSchema(String)
    case deployFailed
    case moduleUnavailable(String)
    case smokeFailed(String)

    var errorDescription: String? {
      switch self {
      case .unsafeDirectory(let path): "Unsafe Rime user-data directory: \(path)"
      case .leversUnavailable: "Rime Levers is unavailable."
      case .exportFailed(let schema): "Could not export Rime learning: \(schema)"
      case .importFailed(let schema): "Could not import Rime learning: \(schema)"
      case .invalidSchema(let schema): "Unsupported Rime learning schema: \(schema)"
      case .deployFailed: "Rime candidate deployment failed."
      case .moduleUnavailable(let module): "Required Rime module is unavailable: \(module)"
      case .smokeFailed(let detail): "Rime candidate smoke test failed: \(detail)"
      }
    }
  }

  private let rime = rime_get_api_stdbool().pointee
  fileprivate static let legacyMappings = [
    "rime_ice": chineseSchema,
    "melt_eng": englishSchema
  ]

  func prepareLegacyDirectory(
    _ directory: URL,
    shared: URL,
    product: String
  ) throws -> PreparedUserDirectory {
    let identity = try Self.inspectUserDirectory(directory)
    let available = try userDictionaryNames(
      from: directory,
      shared: shared,
      product: product
    )
    guard try Self.inspectUserDirectory(directory) == identity else {
      throw Failure.unsafeDirectory(directory.path)
    }
    return .init(
      directory: directory,
      identity: identity,
      recognizedSources: Set(Self.legacyMappings.keys).intersection(available)
    )
  }

  static func validatePreparedUserDirectory(_ prepared: PreparedUserDirectory) throws {
    guard try inspectUserDirectory(prepared.directory) == prepared.identity else {
      throw Failure.unsafeDirectory(prepared.directory.path)
    }
  }

  func exportPortableLearning(
    from userDirectory: URL,
    to destination: URL,
    shared: URL,
    product: String,
    schemas: Set<String>
  ) throws -> [LearningFile] {
    guard schemas.isSubset(of: Self.learningSchemas) else {
      throw Failure.invalidSchema("portable export")
    }
    guard !schemas.isEmpty else { return [] }
    try requireDirectory(destination)
    return try snapshot(
      from: userDirectory,
      to: destination,
      shared: shared,
      product: product,
      mappings: Dictionary(uniqueKeysWithValues: schemas.map { ($0, $0) }),
      prepared: nil
    ).files
  }

  func snapshotLegacy(
    from prepared: PreparedUserDirectory,
    to destination: URL,
    shared: URL,
    product: String
  ) throws -> LegacySnapshot {
    try requireDirectory(destination)
    return try snapshot(
      from: prepared.directory,
      to: destination,
      shared: shared,
      product: product,
      mappings: Self.legacyMappings,
      prepared: prepared
    )
  }

  func deploy(
    candidate: URL,
    shared: URL,
    product: String,
    imports: [LearningImport],
    substitutionProbe: HallelujahSubstitutionImporter.SmokeProbe?
  ) throws {
    try requireDirectory(candidate)
    for item in imports {
      guard Self.learningSchemas.contains(item.schema) else {
        throw Failure.invalidSchema(item.schema)
      }
      try requireRegularFile(item.file)
    }

    withTraits(user: candidate, shared: shared, product: product) { traits in
      rime.deployer_initialize(&traits)
    }
    do {
      defer { rime.finalize() }
      guard rime.deploy() else { throw Failure.deployFailed }
      let levers = try leversAPI()
      for item in imports {
        let rows = item.schema.withCString { schema in
          item.file.path.withCString { levers.import_user_dict(schema, $0) }
        }
        guard rows >= 0 else { throw Failure.importFailed(item.schema) }
      }
    }

    withTraits(user: candidate, shared: shared, product: product) { traits in
      rime.setup(&traits)
    }
    rime.initialize(nil)
    defer { rime.finalize() }
    guard "smart_english".withCString({ rime.find_module($0) != nil }) else {
      throw Failure.moduleUnavailable("smart_english")
    }
    guard "octagram".withCString({ rime.find_module($0) != nil }) else {
      throw Failure.moduleUnavailable("octagram")
    }
    // Smoke every shipped schema in a stable order. The document-selected
    // profile is owned by default.custom.yaml's schema-list projection; probing
    // it last would mutate user.yaml and create a competing selection owner.
    let schemas = LinnetSettingsContract.ChineseProfile.allCases.map(\.schemaID)
      + [Self.englishSchema]
    for schema in schemas {
      try smoke(schema: schema, substitutionProbe: substitutionProbe)
    }
  }

  /// Rebuilds only the selected personal tables in an isolated candidate.
  /// The live Host remains the sole publication/activation owner.
  func preparePersonalDictionaries(
    candidate: URL,
    shared: URL,
    product: String,
    dictionaries: Set<PersonalDictionary>
  ) throws {
    try requireDirectory(candidate)
    for dictionary in dictionaries.sorted(by: { $0.rawValue < $1.rawValue }) {
      try requireRegularFile(candidate.appending(path: dictionary.file))
      let database = candidate.appending(
        path: "\(dictionary.rawValue).userdb", directoryHint: .isDirectory)
      var info = stat()
      if lstat(database.path, &info) == 0 {
        try requireDirectory(database)
        try FileManager.default.removeItem(at: database)
      } else if errno != ENOENT {
        throw Failure.unsafeDirectory(database.path)
      }
    }

    guard !dictionaries.isEmpty else { return }
    withTraits(user: candidate, shared: shared, product: product) { traits in
      rime.deployer_initialize(&traits)
    }
    defer { rime.finalize() }
    let levers = try leversAPI()
    for dictionary in dictionaries.sorted(by: { $0.rawValue < $1.rawValue }) {
      let source = candidate.appending(path: dictionary.file)
      let rows = dictionary.rawValue.withCString { name in
        source.path.withCString { levers.import_user_dict(name, $0) }
      }
      guard rows >= 0 else { throw Failure.importFailed(dictionary.rawValue) }
    }
  }

  static func changedPersonalDictionaries(
    from current: LinnetPersonalData,
    to desired: LinnetPersonalData
  ) -> Set<PersonalDictionary> {
    var changed: Set<PersonalDictionary> = []
    if current.customWords.count != desired.customWords.count
      || zip(current.customWords, desired.customWords).contains(where: {
        $0.value != $1.value || $0.code != $1.code
      }) {
      changed.insert(.customWords)
    }
    if current.expansions.count != desired.expansions.count
      || zip(current.expansions, desired.expansions).contains(where: {
        $0.value != $1.value || $0.trigger != $1.trigger
      }) {
      changed.insert(.textExpander)
    }
    return changed
  }
}

extension RimeUserDataBridge {
  fileprivate struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
  }

  fileprivate struct DirectoryEntryIdentity: Equatable, Sendable {
    let name: String
    let type: mode_t
    let device: UInt64
    let inode: UInt64
  }

  fileprivate struct UserDirectoryIdentity: Equatable, Sendable {
    let root: FileIdentity
    let entries: [DirectoryEntryIdentity]
  }

  private func snapshot(
    from userDirectory: URL,
    to destination: URL,
    shared: URL,
    product: String,
    mappings: [String: String],
    prepared: PreparedUserDirectory?
  ) throws -> LegacySnapshot {
    let baseline: UserDirectoryIdentity
    if let prepared {
      try Self.validatePreparedUserDirectory(prepared)
      baseline = prepared.identity
    } else {
      baseline = try Self.inspectUserDirectory(userDirectory)
    }
    withTraits(user: userDirectory, shared: shared, product: product) { traits in
      rime.deployer_initialize(&traits)
    }
    defer { rime.finalize() }
    let levers = try leversAPI()
    let available = try userDictionaryNames(levers: levers, directory: userDirectory)
    guard try Self.inspectUserDirectory(userDirectory) == baseline else {
      throw Failure.unsafeDirectory(userDirectory.path)
    }
    if let prepared {
      let recognized = Set(mappings.keys).intersection(available)
      guard recognized == prepared.recognizedSources else {
        throw Failure.unsafeDirectory(userDirectory.path)
      }
    }
    var files: [LearningFile] = []
    for source in mappings.keys.sorted() where available.contains(source) {
      guard let target = mappings[source], Self.learningSchemas.contains(target) else {
        throw Failure.invalidSchema(mappings[source] ?? source)
      }
      let file = destination.appending(path: "\(target).txt")
      let rows = source.withCString { schema in
        file.path.withCString { levers.export_user_dict(schema, $0) }
      }
      guard rows >= 0 else { throw Failure.exportFailed(source) }
      files.append(.init(schema: target, file: file, rows: Int(rows)))
    }
    guard try Self.inspectUserDirectory(userDirectory) == baseline else {
      throw Failure.unsafeDirectory(userDirectory.path)
    }
    return LegacySnapshot(
      files: files.sorted { $0.schema < $1.schema },
      importedRows: files.reduce(0) { $0 + $1.rows }
    )
  }

  fileprivate static func inspectUserDirectory(_ directoryURL: URL) throws
    -> UserDirectoryIdentity {
    let descriptor = open(
      directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Failure.unsafeDirectory(directoryURL.path) }
    defer { close(descriptor) }
    let before = try directoryIdentity(descriptor, path: directoryURL.path)
    let iteratorDescriptor = dup(descriptor)
    guard iteratorDescriptor >= 0, let directory = fdopendir(iteratorDescriptor) else {
      if iteratorDescriptor >= 0 { close(iteratorDescriptor) }
      throw Failure.unsafeDirectory(directoryURL.path)
    }
    defer { closedir(directory) }

    var entryCount = 0
    var entries: [DirectoryEntryIdentity] = []
    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      entryCount += 1
      guard entryCount <= LinnetBackupStore.maximumLiveDirectoryEntries else {
        throw Failure.unsafeDirectory(directoryURL.path)
      }
      var info = stat()
      let status = name.withCString {
        fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
      }
      let type = info.st_mode & S_IFMT
      guard status == 0,
        type == S_IFDIR || type == S_IFREG,
        info.st_uid == getuid(),
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
      else { throw Failure.unsafeDirectory(directoryURL.path) }
      entries.append(.init(
        name: name,
        type: type,
        device: UInt64(info.st_dev),
        inode: UInt64(info.st_ino)
      ))
    }
    guard errno == 0,
      try directoryIdentity(descriptor, path: directoryURL.path) == before
    else { throw Failure.unsafeDirectory(directoryURL.path) }
    return .init(
      root: before,
      entries: entries.sorted { $0.name < $1.name })
  }

  private func userDictionaryNames(
    from directory: URL,
    shared: URL,
    product: String
  ) throws -> Set<String> {
    withTraits(user: directory, shared: shared, product: product) { traits in
      rime.deployer_initialize(&traits)
    }
    defer { rime.finalize() }
    return try userDictionaryNames(levers: leversAPI(), directory: directory)
  }

  private func userDictionaryNames(
    levers: RimeLeversApi_stdbool,
    directory: URL
  ) throws -> Set<String> {
    var iterator = RimeUserDictIterator()
    guard levers.user_dict_iterator_init(&iterator) else { return [] }
    defer { levers.user_dict_iterator_destroy(&iterator) }

    var available = Set<String>()
    var observedCount = 0
    while let pointer = levers.next_user_dict(&iterator) {
      observedCount += 1
      let name = String(cString: pointer)
      guard observedCount <= LinnetBackupStore.maximumLiveDirectoryEntries,
        !name.isEmpty,
        name.utf8.count <= Int(NAME_MAX),
        available.insert(name).inserted
      else { throw Failure.unsafeDirectory(directory.path) }
    }
    return available
  }

  fileprivate static func directoryIdentity(_ descriptor: Int32, path: String) throws
    -> FileIdentity {
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else { throw Failure.unsafeDirectory(path) }
    return .init(
      device: UInt64(info.st_dev),
      inode: UInt64(info.st_ino),
      modifiedSeconds: info.st_mtimespec.tv_sec,
      modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      changedSeconds: info.st_ctimespec.tv_sec,
      changedNanoseconds: info.st_ctimespec.tv_nsec)
  }

  private func smoke(
    schema: String,
    substitutionProbe: HallelujahSubstitutionImporter.SmokeProbe?
  ) throws {
    let session = rime.create_session()
    guard session != 0 else { throw Failure.smokeFailed("session \(schema)") }
    defer { _ = rime.destroy_session(session) }
    guard schema.withCString({ rime.select_schema(session, $0) }) else {
      throw Failure.smokeFailed("schema \(schema)")
    }
    let builtIn: HallelujahSubstitutionImporter.SmokeProbe
    switch schema {
    case "linnet_zh": builtIn = .init(trigger: "nihk", expectedValue: "你好")
    case "linnet_zh_pinyin": builtIn = .init(trigger: "nihao", expectedValue: "你好")
    case "linnet_zh_flypy": builtIn = .init(trigger: "nihc", expectedValue: "你好")
    case "linnet_zh_mspy", "linnet_zh_sogou", "linnet_zh_abc":
      builtIn = .init(trigger: "nihk", expectedValue: "你好")
    case "linnet_zh_ziguang": builtIn = .init(trigger: "nihq", expectedValue: "你好")
    case "linnet_zh_jiajia": builtIn = .init(trigger: "nihd", expectedValue: "你好")
    case "linnet_en": builtIn = .init(trigger: "hello", expectedValue: "hello")
    default: throw Failure.invalidSchema(schema)
    }
    try expectCandidate(builtIn, schema: schema, session: session)
    rime.clear_composition(session)
    if let substitutionProbe {
      try expectCandidate(substitutionProbe, schema: schema, session: session)
    }
  }

  private func expectCandidate(
    _ probe: HallelujahSubstitutionImporter.SmokeProbe,
    schema: String,
    session: RimeSessionId
  ) throws {
    guard probe.trigger.withCString({ rime.simulate_key_sequence(session, $0) }) else {
      throw Failure.smokeFailed("input \(schema)")
    }
    var context = RimeContext_stdbool()
    context.data_size = Int32(MemoryLayout<RimeContext_stdbool>.size - MemoryLayout<Int32>.size)
    guard rime.get_context(session, &context) else {
      throw Failure.smokeFailed("context \(schema)")
    }
    defer { _ = rime.free_context(&context) }
    let matched = (0..<Int(context.menu.num_candidates)).contains { index in
      context.menu.candidates.map { String(cString: $0[index].text) == probe.expectedValue }
        ?? false
    }
    guard matched else { throw Failure.smokeFailed("result \(schema)") }
  }

  private func leversAPI() throws -> RimeLeversApi_stdbool {
    guard let module = "levers_stdbool".withCString({ rime.find_module($0) }),
      let getter = module.pointee.get_api,
      let raw = getter()
    else {
      throw Failure.leversUnavailable
    }
    return UnsafeMutableRawPointer(raw).assumingMemoryBound(to: RimeLeversApi_stdbool.self).pointee
  }

  private func withTraits(
    user: URL,
    shared: URL,
    product: String,
    _ body: (inout RimeTraits) -> Void
  ) {
    let prebuilt = shared.appending(path: "build").path
    let staging = user.appending(path: "build").path
    shared.path.withCString { sharedPath in
      prebuilt.withCString { prebuiltPath in
        user.path.withCString { userPath in
          staging.withCString { stagingPath in
            product.withCString { productPath in
              "".withCString { logPath in
                var traits = RimeTraits()
                traits.data_size = Int32(
                  MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
                traits.shared_data_dir = sharedPath
                traits.prebuilt_data_dir = prebuiltPath
                traits.user_data_dir = userPath
                traits.staging_dir = stagingPath
                traits.distribution_name = productPath
                traits.app_name = productPath
                traits.min_log_level = 2
                traits.log_dir = logPath
                body(&traits)
              }
            }
          }
        }
      }
    }
  }

  private func requireDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.unsafeDirectory(url.path)
    }
  }

  private func requireRegularFile(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw Failure.unsafeDirectory(url.path)
    }
  }
}
