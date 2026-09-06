//
//  BridgingFunctions.swift
//  Squirrel
//
//  Created by Leo Liu on 5/11/24.
//

import Darwin
import Foundation

protocol DataSizeable {
  init()
  // swiftlint:disable:next identifier_name
  var data_size: Int32 { get set }
}

extension RimeContext_stdbool: DataSizeable {}
extension RimeTraits: DataSizeable {}
extension RimeCommit: DataSizeable {}
extension RimeStatus_stdbool: DataSizeable {}
extension RimeModule: DataSizeable {}

extension DataSizeable {
  static func rimeStructInit() -> Self {
    var value = Self()
    let offset = MemoryLayout.size(ofValue: \Self.data_size)
    value.data_size = Int32(MemoryLayout<Self>.size - offset)
    return value
  }
}

/// Owns the Swift-to-C lifetime and field mapping for the synchronous
/// `rime_api_setup` boundary.
struct LinnetRimeTraitValues {
  let sharedDataDirectory: String
  let userDataDirectory: String
  let prebuiltDataDirectory: String
  let stagingDirectory: String
  let logDirectory: String
  let distributionCodeName: String
  let distributionName: String
  let distributionVersion: String
  let applicationName: String
  var minimumLogLevel: Int32 = 0

  @discardableResult
  func apply(to api: RimeApi_stdbool) -> Bool {
    let values = [
      sharedDataDirectory,
      userDataDirectory,
      prebuiltDataDirectory,
      stagingDirectory,
      logDirectory,
      distributionCodeName,
      distributionName,
      distributionVersion,
      applicationName
    ]
    let strings = values.compactMap { value in value.withCString { strdup($0) } }
    defer {
      for pointer in strings {
        free(UnsafeMutableRawPointer(pointer))
      }
    }
    guard strings.count == values.count else { return false }

    var traits = RimeTraits.rimeStructInit()
    traits.shared_data_dir = UnsafePointer(strings[0])
    traits.user_data_dir = UnsafePointer(strings[1])
    traits.prebuilt_data_dir = UnsafePointer(strings[2])
    traits.staging_dir = UnsafePointer(strings[3])
    traits.log_dir = UnsafePointer(strings[4])
    traits.distribution_code_name = UnsafePointer(strings[5])
    traits.distribution_name = UnsafePointer(strings[6])
    traits.distribution_version = UnsafePointer(strings[7])
    traits.app_name = UnsafePointer(strings[8])
    traits.min_log_level = minimumLogLevel
    api.setup(&traits)
    return true
  }
}

infix operator ?= : AssignmentPrecedence
// swiftlint:disable:next function_name_whitespace
func ?=<T>(left: inout T, right: T?) {
  if let right = right {
    left = right
  }
}
// swiftlint:disable:next function_name_whitespace
func ?=<T>(left: inout T?, right: T?) {
  if let right = right {
    left = right
  }
}

extension NSRange {
  static let empty = NSRange(location: NSNotFound, length: 0)
}

extension NSPoint {
  static func += (lhs: inout Self, rhs: Self) {
    lhs.x += rhs.x
    lhs.y += rhs.y
  }
  static func - (lhs: Self, rhs: Self) -> Self {
    Self.init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }
  static func -= (lhs: inout Self, rhs: Self) {
    lhs.x -= rhs.x
    lhs.y -= rhs.y
  }
  static func * (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x * rhs, y: lhs.y * rhs)
  }
  static func / (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x / rhs, y: lhs.y / rhs)
  }
  var length: CGFloat {
    sqrt(pow(self.x, 2) + pow(self.y, 2))
  }
}
