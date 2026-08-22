import Darwin
import Foundation

/// Owns Linnet's single product-defined iCloud Drive boundary.
struct LinnetCloudSyncLocation: Equatable, Sendable {
  enum Failure: Error, Equatable {
    case iCloudDriveUnavailable
    case invalidFolder
  }

  let folder: URL

  var learningDirectory: URL {
    folder.appending(component: "Linnet-Rime-Sync", directoryHint: .isDirectory)
  }

  var displayName: String {
    "iCloud Drive/Linnet"
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

  static func productLocation() throws -> Self {
    guard let libraryDirectory = FileManager.default.urls(
      for: .libraryDirectory, in: .userDomainMask
    ).first else {
      throw Failure.iCloudDriveUnavailable
    }
    return try productLocation(libraryDirectory: libraryDirectory)
  }

  static func productLocation(libraryDirectory: URL) throws -> Self {
    let library = try validatedFolder(libraryDirectory)
    let mobileDocuments = try validatedFolder(
      library.appending(component: "Mobile Documents", directoryHint: .isDirectory))
    let cloudDocuments = try validatedFolder(
      mobileDocuments.appending(
        component: "com~apple~CloudDocs", directoryHint: .isDirectory))
    let productDirectory = cloudDocuments.appending(
      component: "Linnet", directoryHint: .isDirectory)

    var info = stat()
    if lstat(productDirectory.path, &info) != 0 {
      guard errno == ENOENT else { throw Failure.invalidFolder }
      do {
        try FileManager.default.createDirectory(
          at: productDirectory, withIntermediateDirectories: false)
      } catch {
        throw Failure.invalidFolder
      }
    }
    return Self(folder: try validatedFolder(productDirectory))
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
