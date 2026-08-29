//
//  LinnetInputSourceRegistration.swift
//  Linnet
//

import Carbon

/// The single read-only owner for Linnet's HIToolbox registration state.
/// HIToolbox publishes source and bundle identifiers, but no authoritative
/// bundle URL, so a registered result deliberately makes no path claim.
enum LinnetInputSourceRegistration {
  struct Source: Equatable {
    let identifier: String?
    let bundleIdentifier: String?
  }

  enum State: Equatable {
    case missing
    case registered
    case duplicate(count: Int)
    case conflictingIdentity
    case unknownBundleIdentifier

    var wireValue: String {
      switch self {
      case .missing: "missing"
      case .registered: "registered:bundle-match:path-unknown"
      case .duplicate(let count): "duplicate:\(count)"
      case .conflictingIdentity: "conflict:source-or-bundle-id"
      case .unknownBundleIdentifier: "unknown:bundle-id"
      }
    }
  }

  static func classify(_ sources: [Source], identifier: String) -> State {
    let related = sources.filter {
      $0.identifier == identifier || $0.bundleIdentifier == identifier
    }
    guard let source = related.first else { return .missing }
    let exactMatches = related.filter {
      $0.identifier == identifier && $0.bundleIdentifier == identifier
    }
    if related.count > 1 {
      return exactMatches.count == related.count
        ? .duplicate(count: related.count) : .conflictingIdentity
    }
    guard source.identifier == identifier else { return .conflictingIdentity }
    guard let bundleIdentifier = source.bundleIdentifier else {
      return .unknownBundleIdentifier
    }
    guard bundleIdentifier == identifier else { return .conflictingIdentity }
    return .registered
  }

  static func state(identifier: String) -> State {
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue()
      as! [TISInputSource]
    let registeredSources = sourceList.map { source in
      Source(
        identifier: stringProperty(source, key: kTISPropertyInputSourceID),
        bundleIdentifier: stringProperty(source, key: kTISPropertyBundleID))
    }
    return classify(registeredSources, identifier: identifier)
  }

  /// The sole raw HIToolbox read boundary. Callers must immediately pass this
  /// optional evidence to `LinnetInputSourceSelection.classify`.
  static func currentInputSourceID() -> String? {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return nil
    }
    return stringProperty(current, key: kTISPropertyInputSourceID)
  }

  private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
    let value = TISGetInputSourceProperty(source, key)
    return unsafeBitCast(value, to: CFString?.self) as String?
  }
}
