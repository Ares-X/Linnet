import Foundation
import WinSDK

private func dataFileError(_ operation: String, code: DWORD = GetLastError()) -> NSError {
  NSError(domain: "Windows.Win32", code: Int(code), userInfo: [
    NSLocalizedDescriptionKey: "\(operation) failed (Windows error \(code))."
  ])
}

/// One native HANDLE owner for pack extraction and Registry storage. These are
/// actual Windows identities/ACLs, not a POSIX stat or permissions emulation.
final class LinnetWindowsDataFile {
  enum Access { case directory, metadata, read, create, remove }
  struct Identity: Equatable, Sendable {
    let volume: UInt32
    let file: UInt64
  }

  private var handle: HANDLE?
  let information: BY_HANDLE_FILE_INFORMATION
  var identity: Identity {
    .init(volume: information.dwVolumeSerialNumber,
      file: UInt64(information.nFileIndexHigh) << 32 | UInt64(information.nFileIndexLow))
  }
  var byteCount: UInt64 {
    UInt64(information.nFileSizeHigh) << 32 | UInt64(information.nFileSizeLow)
  }
  var isDirectory: Bool { information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 }

  init(_ url: URL, access: Access) throws {
    let rights: DWORD = switch access {
    case .directory, .metadata: DWORD(FILE_READ_ATTRIBUTES | READ_CONTROL)
    case .read: GENERIC_READ | DWORD(READ_CONTROL)
    case .create: DWORD(GENERIC_WRITE | FILE_READ_ATTRIBUTES | READ_CONTROL)
    case .remove: DWORD(DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL)
    }
    let sharing: DWORD = switch access {
    case .directory, .metadata: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE)
    case .read: DWORD(FILE_SHARE_READ)
    case .create: 0
    case .remove: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
    }
    let opened = (Array(url.path.utf16) + [0]).withUnsafeBufferPointer {
      CreateFileW($0.baseAddress, rights, sharing, nil,
        DWORD(access == .create ? CREATE_NEW : OPEN_EXISTING),
        DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
    }
    guard let opened, opened != INVALID_HANDLE_VALUE else { throw dataFileError("Open language-data file") }
    var info = BY_HANDLE_FILE_INFORMATION()
    do {
      guard GetFileInformationByHandle(opened, &info) else { throw dataFileError("Inspect language-data file") }
      guard info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw LinnetPackContract.Failure.unsafePath(url.path)
      }
      let directory = info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      guard access == .metadata || access == .remove || directory == (access == .directory) else {
        throw LinnetPackContract.Failure.unsafePath(url.path)
      }
      try Self.verifyOwnerAndWriters(opened, path: url.path)
    } catch {
      CloseHandle(opened)
      throw error
    }
    information = info
    handle = opened
  }

  deinit { if let handle { CloseHandle(handle) } }

  var canonicalURL: URL {
    get throws {
      guard let handle else { throw dataFileError("Resolve closed file", code: DWORD(ERROR_INVALID_HANDLE)) }
      let required = GetFinalPathNameByHandleW(handle, nil, 0, DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS))
      guard required > 0 else { throw dataFileError("Size canonical path") }
      var buffer = [WCHAR](repeating: 0, count: Int(required) + 1)
      let count = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count),
        DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS))
      guard count > 0, Int(count) < buffer.count else { throw dataFileError("Read canonical path") }
      var path = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
      if path.hasPrefix("\\\\?\\UNC\\") { path = "\\\\" + path.dropFirst(8) }
      else if path.hasPrefix("\\\\?\\") { path = String(path.dropFirst(4)) }
      return URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
    }
  }

  func read(upToCount count: Int) throws -> Data {
    guard let handle else { throw dataFileError("Read closed file", code: DWORD(ERROR_INVALID_HANDLE)) }
    var buffer = [UInt8](repeating: 0, count: count)
    var received: DWORD = 0
    guard ReadFile(handle, &buffer, DWORD(count), &received, nil) else { throw dataFileError("Read language data") }
    return Data(buffer.prefix(Int(received)))
  }

  func write(contentsOf data: Data) throws {
    guard let handle else { throw dataFileError("Write closed file", code: DWORD(ERROR_INVALID_HANDLE)) }
    try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      var offset = 0
      while offset < bytes.count {
        var written: DWORD = 0
        guard WriteFile(handle, bytes.baseAddress!.advanced(by: offset),
          DWORD(min(bytes.count - offset, Int(UInt32.max))), &written, nil)
        else { throw dataFileError("Write language data") }
        guard written > 0 else { throw dataFileError("Write language data", code: DWORD(ERROR_WRITE_FAULT)) }
        offset += Int(written)
      }
    }
  }

  func synchronize() throws {
    guard let handle else { throw dataFileError("Flush closed file", code: DWORD(ERROR_INVALID_HANDLE)) }
    guard FlushFileBuffers(handle) else { throw dataFileError("Flush language data") }
  }

  func close() throws {
    guard let handle else { return }
    guard CloseHandle(handle) else { throw dataFileError("Close language-data file") }
    self.handle = nil
  }

  /// Unlink a retired read-only file without clearing its attributes on other
  /// hard links. Directory removal still fails if any child remains.
  func remove() throws {
    guard let handle else { throw dataFileError("Remove closed file", code: DWORD(ERROR_INVALID_HANDLE)) }
    var disposition = FILE_DISPOSITION_INFO_EX(Flags: DWORD(
      FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS
        | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE))
    guard SetFileInformationByHandle(handle, FileDispositionInfoEx, &disposition,
      DWORD(MemoryLayout<FILE_DISPOSITION_INFO_EX>.size)) else {
      throw dataFileError("Remove retired language data")
    }
    try close()
  }

  static func writeAtomically(_ data: Data, to destination: URL) throws {
    let parent = destination.deletingLastPathComponent()
    let lease = try LinnetWindowsDataFile(parent, access: .directory)
    defer { withExtendedLifetime(lease) {} }
    let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).partial-\(Foundation.UUID().uuidString)")
    do {
      let file = try LinnetWindowsDataFile(temporary, access: .create)
      try file.write(contentsOf: data)
      try file.synchronize()
      try file.close()
      try move(temporary, to: destination, replacing: true)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  static func move(_ source: URL, to destination: URL, replacing: Bool = false) throws {
    try (Array(source.path.utf16) + [0]).withUnsafeBufferPointer { origin in
      try (Array(destination.path.utf16) + [0]).withUnsafeBufferPointer { target in
        let flags = DWORD(MOVEFILE_WRITE_THROUGH) | (replacing ? DWORD(MOVEFILE_REPLACE_EXISTING) : 0)
        guard MoveFileExW(origin.baseAddress, target.baseAddress, flags) else {
          throw dataFileError("Publish language-data file")
        }
      }
    }
  }

  static func ensureDirectory(_ url: URL, intermediates: Bool) throws -> LinnetWindowsDataFile {
    if let existing = try existing(url, access: .directory) { return existing }
    if intermediates {
      _ = try ensureDirectory(url.deletingLastPathComponent(), intermediates: true)
    }
    try withCurrentUser { sid in
      var sidText: LPWSTR?
      guard ConvertSidToStringSidW(sid, &sidText), let sidText else { throw dataFileError("Encode process identity") }
      defer { LocalFree(sidText) }
      let user = String(decodingCString: sidText, as: UTF16.self)
      let sddl = "O:\(user)D:P(A;OICI;FA;;;\(user))(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
      var descriptor: PSECURITY_DESCRIPTOR?
      try (Array(sddl.utf16) + [0]).withUnsafeBufferPointer {
        guard ConvertStringSecurityDescriptorToSecurityDescriptorW(
          $0.baseAddress, DWORD(SDDL_REVISION_1), &descriptor, nil)
        else { throw dataFileError("Create private directory permissions") }
      }
      defer { LocalFree(descriptor) }
      var security = SECURITY_ATTRIBUTES(
        nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
        lpSecurityDescriptor: descriptor, bInheritHandle: false)
      let created = (Array(url.path.utf16) + [0]).withUnsafeBufferPointer {
        CreateDirectoryW($0.baseAddress, &security)
      }
      if !created {
        let code = GetLastError()
        guard code == ERROR_ALREADY_EXISTS else { throw dataFileError("Create private data directory", code: code) }
      }
    }
    return try LinnetWindowsDataFile(url, access: .directory)
  }

  static func existing(_ url: URL, access: Access) throws -> LinnetWindowsDataFile? {
    do { return try LinnetWindowsDataFile(url, access: access) }
    catch let error as NSError where error.domain == "Windows.Win32"
      && [Int(ERROR_FILE_NOT_FOUND), Int(ERROR_PATH_NOT_FOUND)].contains(error.code) {
      return nil
    }
  }

  static func prepareParents(path: String, beneath root: URL) throws -> [LinnetWindowsDataFile] {
    var directory = root
    var leases: [LinnetWindowsDataFile] = []
    for component in path.split(separator: "/").dropLast() {
      directory.appendPathComponent(String(component), isDirectory: true)
      leases.append(try ensureDirectory(directory, intermediates: false))
    }
    return leases
  }

  static func makeReadOnly(_ url: URL) throws {
    try (Array(url.path.utf16) + [0]).withUnsafeBufferPointer {
      let attributes = GetFileAttributesW($0.baseAddress)
      guard attributes != INVALID_FILE_ATTRIBUTES else { throw dataFileError("Inspect language-data file") }
      guard SetFileAttributesW($0.baseAddress, attributes | DWORD(FILE_ATTRIBUTE_READONLY)) else {
        throw dataFileError("Protect language-data file")
      }
    }
  }

  private static func withCurrentUser<T>(_ body: (PSID) throws -> T) throws -> T {
    var token: HANDLE?
    guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token) else {
      throw dataFileError("Open process token")
    }
    defer { CloseHandle(token) }
    var bytes: DWORD = 0
    GetTokenInformation(token, TokenUser, nil, 0, &bytes)
    guard bytes > 0 else { throw dataFileError("Size process identity") }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(bytes), alignment: MemoryLayout<TOKEN_USER>.alignment)
    defer { storage.deallocate() }
    guard GetTokenInformation(token, TokenUser, storage, bytes, &bytes) else {
      throw dataFileError("Read process identity")
    }
    return try body(storage.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid)
  }

  private static func verifyOwnerAndWriters(_ handle: HANDLE, path: String) throws {
    try withCurrentUser { user in
      var owner: PSID?
      var acl: PACL?
      var descriptor: PSECURITY_DESCRIPTOR?
      let status = GetSecurityInfo(handle, SE_FILE_OBJECT,
        DWORD(OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION),
        &owner, nil, &acl, nil, &descriptor)
      guard status == ERROR_SUCCESS else {
        throw dataFileError("Read language-data permissions", code: status)
      }
      defer { LocalFree(descriptor) }
      // Elevated Windows-created files may be owned by Administrators; both
      // that group and SYSTEM already have legitimate write authority here.
      func trustedIdentity(_ sid: PSID) -> Bool {
        EqualSid(sid, user) || IsWellKnownSid(sid, WinLocalSystemSid)
          || IsWellKnownSid(sid, WinBuiltinAdministratorsSid)
      }
      guard let owner, trustedIdentity(owner), let acl else {
        throw LinnetPackContract.Failure.unsafePath(path)
      }
      let writes = DWORD(GENERIC_ALL | GENERIC_WRITE | DELETE | WRITE_DAC | WRITE_OWNER
        | FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES
        | FILE_DELETE_CHILD)
      for index in 0..<DWORD(acl.pointee.AceCount) {
        var raw: LPVOID?
        guard GetAce(acl, index, &raw), let raw else { throw dataFileError("Read access entry") }
        let header = raw.assumingMemoryBound(to: ACE_HEADER.self).pointee
        if header.AceFlags & BYTE(INHERIT_ONLY_ACE) != 0 { continue }
        if header.AceType == BYTE(ACCESS_DENIED_ACE_TYPE) { continue }
        guard header.AceType == BYTE(ACCESS_ALLOWED_ACE_TYPE) else {
          throw LinnetPackContract.Failure.unsafePath(path)
        }
        let entry = raw.assumingMemoryBound(to: ACCESS_ALLOWED_ACE.self)
        if entry.pointee.Mask & writes == 0 { continue }
        let trusted = withUnsafeMutablePointer(to: &entry.pointee.SidStart) { sid in
          trustedIdentity(sid)
        }
        guard trusted else { throw LinnetPackContract.Failure.unsafePath(path) }
      }
    }
  }
}
