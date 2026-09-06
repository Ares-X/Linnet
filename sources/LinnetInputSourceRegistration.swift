//
//  LinnetInputSourceRegistration.swift
//  Linnet
//

import Carbon

/// The single read-only owner for Linnet's HIToolbox registration observation.
/// HIToolbox publishes neither an authoritative bundle URL nor a durable user-
/// authorization result, so enabled/selected properties remain observations
/// and every accepted result deliberately makes no path claim.
enum LinnetInputSourceRegistration {
  struct Source: Equatable {
    let identifier: String?
    let bundleIdentifier: String?
    let category: String?
    let type: String?
    let isEnableCapable: Bool?
    let isSelectCapable: Bool?
    let isEnabled: Bool?
    let isSelected: Bool?
  }

  enum State: Equatable {
    case missing
    case enablementRequired
    case enabledObservation
    case selectedObservation
    case duplicate(count: Int)
    case conflictingIdentity
    case conflictingKind
    case unavailableCapabilities
    case unknownAvailability
    case unknownBundleIdentifier

    var wireValue: String {
      switch self {
      case .missing: "missing"
      case .enablementRequired: "registered:enablement-required:path-unknown"
      case .enabledObservation: "registered:enabled-observation:selectable:path-unknown"
      case .selectedObservation: "registered:selected-observation:selectable:path-unknown"
      case .duplicate(let count): "duplicate:\(count)"
      case .conflictingIdentity: "conflict:source-or-bundle-id"
      case .conflictingKind: "conflict:source-category-or-type"
      case .unavailableCapabilities: "unavailable:input-source-capabilities"
      case .unknownAvailability: "unknown:availability-properties"
      case .unknownBundleIdentifier: "unknown:bundle-id"
      }
    }
  }

  struct Inspection {
    let state: State
    let inputSource: TISInputSource?
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
    guard source.category == kTISCategoryKeyboardInputSource as String,
      source.type == kTISTypeKeyboardInputMethodWithoutModes as String
    else { return .conflictingKind }
    guard let isEnableCapable = source.isEnableCapable,
      let isSelectCapable = source.isSelectCapable,
      let isEnabled = source.isEnabled,
      let isSelected = source.isSelected
    else { return .unknownAvailability }
    guard isEnableCapable, isSelectCapable else { return .unavailableCapabilities }
    guard isEnabled else { return .enablementRequired }
    return isSelected ? .selectedObservation : .enabledObservation
  }

  static func state(identifier: String) -> State {
    inspect(identifier: identifier).state
  }

  static func inspect(identifier: String) -> Inspection {
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue()
      as! [TISInputSource]
    let sources = sourceList.map { source in
      Source(
        identifier: stringProperty(source, key: kTISPropertyInputSourceID),
        bundleIdentifier: stringProperty(source, key: kTISPropertyBundleID),
        category: stringProperty(source, key: kTISPropertyInputSourceCategory),
        type: stringProperty(source, key: kTISPropertyInputSourceType),
        isEnableCapable: boolProperty(source, key: kTISPropertyInputSourceIsEnableCapable),
        isSelectCapable: boolProperty(source, key: kTISPropertyInputSourceIsSelectCapable),
        isEnabled: boolProperty(source, key: kTISPropertyInputSourceIsEnabled),
        isSelected: boolProperty(source, key: kTISPropertyInputSourceIsSelected))
    }
    let state = classify(sources, identifier: identifier)
    let inputSource: TISInputSource?
    switch state {
    case .enablementRequired, .enabledObservation, .selectedObservation:
      inputSource = zip(sourceList, sources).first {
        $0.1.identifier == identifier && $0.1.bundleIdentifier == identifier
      }?.0
    default:
      inputSource = nil
    }
    return Inspection(state: state, inputSource: inputSource)
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

  private static func boolProperty(_ source: TISInputSource, key: CFString) -> Bool? {
    let value = TISGetInputSourceProperty(source, key)
    guard let boolean = unsafeBitCast(value, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(boolean)
  }
}
