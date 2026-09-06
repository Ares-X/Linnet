//
//  LinnetClientAppearance.swift
//  Linnet
//
//  Resolves the appearance for the one active InputMethodKit client. Apple
//  does not publish this selector in IMKTextInput, so the capability is
//  optional and must never outlive or identify the client that supplied it.
//

import AppKit

enum LinnetClientAppearance {
  enum MaterialMode: String, Equatable {
    case system, light, dark
  }

  struct Resolution {
    let appearance: NSAppearance
    let isDark: Bool
  }

  private static let windowAppearanceSelector =
    NSSelectorFromString("windowEffectiveAppearance")

  static func resolve(
    client: (any NSObjectProtocol)?,
    systemAppearance: NSAppearance
  ) -> Resolution {
    let clientAppearance = appearance(from: client)
    let appearance = clientAppearance ?? systemAppearance
    return Resolution(
      appearance: appearance,
      isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    )
  }

  static func resolveMaterial(
    mode: MaterialMode,
    automaticAppearance: NSAppearance
  ) -> NSAppearance {
    switch mode {
    case .system: automaticAppearance
    case .light: NSAppearance(named: .aqua)!
    case .dark: NSAppearance(named: .darkAqua)!
    }
  }

  private static func appearance(
    from client: (any NSObjectProtocol)?
  ) -> NSAppearance? {
    guard let client,
      client.responds(to: windowAppearanceSelector),
      let unmanaged = client.perform(windowAppearanceSelector),
      let appearance = unmanaged.takeUnretainedValue() as? NSAppearance
    else {
      return nil
    }
    return appearance
  }
}
