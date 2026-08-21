import Darwin
import Foundation

/// Owns the durable user-selected folder boundary for Rime learning sync.
struct LinnetCloudSyncLocation: Equatable, Sendable {
  enum Failure: Error, Equatable {
    case invalidFolder
    case invalidBookmark
  }

  let folder: URL
  let bookmark: Data

  var learningDirectory: URL {
    folder.appending(component: "Linnet-Rime-Sync", directoryHint: .isDirectory)
  }

  var displayName: String {
    folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
  }

  func prepareLearningDirectory() throws -> URL {
    let directory = learningDirectory
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw Failure.invalidFolder }
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false)
      } catch {
        throw Failure.invalidFolder
      }
    }
    return try Self.validatedFolder(directory)
  }

  static func select(folder: URL) throws -> Self {
    let normalized = try validatedFolder(folder)
    do {
      let bookmark = try normalized.bookmarkData(
        options: [.minimalBookmark],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      return Self(folder: normalized, bookmark: bookmark)
    } catch {
      throw Failure.invalidBookmark
    }
  }

  static func resolve(bookmark: Data) throws -> Self {
    var stale = false
    let resolved: URL
    do {
      resolved = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    } catch {
      throw Failure.invalidBookmark
    }
    let normalized = try validatedFolder(resolved)
    if stale { return try select(folder: normalized) }
    return Self(folder: normalized, bookmark: bookmark)
  }

  private static func validatedFolder(_ candidate: URL) throws -> URL {
    guard candidate.isFileURL else { throw Failure.invalidFolder }
    let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
    var info = stat()
    guard lstat(candidate.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid(),
      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    else {
      throw Failure.invalidFolder
    }
    return normalized
  }
}
