//
//  MacOSKeyCodes.swift
//  Squirrel
//
//  Created by Leo Liu on 5/9/24.
//

import Carbon
import AppKit

/// Converts InputMethodKit's aggregate flags into side-aware physical events.
/// Aggregate flags cannot distinguish a second Shift down from the first Shift
/// up while its counterpart remains held, so the physical key code owns that
/// transition. Rime remains responsible for tap/hold/chord interpretation.
struct SquirrelModifierTransitionState {
  struct Event {
    let keycode: UInt32
    let modifiers: UInt32
  }

  private static let trackedFlags: NSEvent.ModifierFlags = [
    .capsLock, .shift, .control, .option, .command
  ]

  private var aggregateModifiers: NSEvent.ModifierFlags
  private var pressedKeyCodes: Set<UInt16> = []
  private var suppressedActivationModifiers: NSEvent.ModifierFlags

  init(hardwareFlags: CGEventFlags) {
    aggregateModifiers = Self.modifiers(from: hardwareFlags)
    suppressedActivationModifiers = aggregateModifiers.subtracting(.capsLock)
  }

  mutating func reset(from hardwareFlags: CGEventFlags) {
    aggregateModifiers = Self.modifiers(from: hardwareFlags)
    suppressedActivationModifiers = aggregateModifiers.subtracting(.capsLock)
    pressedKeyCodes.removeAll(keepingCapacity: true)
  }

  mutating func transitions(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> [Event] {
    let current = modifiers.intersection(Self.trackedFlags)
    suppressedActivationModifiers.formIntersection(current)
    var physicalKeyCode = keyCode
    if Self.descriptor(for: physicalKeyCode) == nil {
      let changes = aggregateModifiers.symmetricDifference(current)
      if changes.isEmpty {
        aggregateModifiers = current
        return []
      }
      let changedDescriptors = Self.leftDescriptors.filter { changes.contains($0.flag) }
      guard changedDescriptors.count == 1 else {
        // Preserve every already transported edge. A remote multi-flag
        // snapshot is not enough evidence to manufacture transitions or to
        // forget a down event that Rime is still waiting to see released.
        return []
      }
      let descriptor = changedDescriptors[0]
      if !current.contains(descriptor.flag) {
        let tracked = pressedKeyCodes.filter {
          Self.descriptor(for: $0)?.flag == descriptor.flag
        }
        guard tracked.count == 1, let trackedKeyCode = tracked.first else {
          aggregateModifiers = current
          return []
        }
        physicalKeyCode = trackedKeyCode
      } else {
        physicalKeyCode = descriptor.keyCode
      }
    }

    guard let descriptor = Self.descriptor(for: physicalKeyCode) else {
      aggregateModifiers = current
      return []
    }
    defer { aggregateModifiers = current }

    if descriptor.flag != .capsLock,
      suppressedActivationModifiers.contains(descriptor.flag) {
      return []
    }

    if descriptor.flag == .capsLock {
      return capsLockTransition(descriptor: descriptor, current: current)
    }
    return momentaryTransition(
      descriptor: descriptor,
      physicalKeyCode: physicalKeyCode,
      current: current
    )
  }

  private func capsLockTransition(
    descriptor: Descriptor,
    current: NSEvent.ModifierFlags
  ) -> [Event] {
    guard aggregateModifiers.contains(.capsLock) != current.contains(.capsLock) else {
      return []
    }
    let modifiers = SquirrelKeycode.osxModifiersToRime(modifiers: current)
      ^ kLockMask.rawValue
    return [Event(keycode: descriptor.rimeKeyCode, modifiers: modifiers)]
  }

  private mutating func momentaryTransition(
    descriptor: Descriptor,
    physicalKeyCode: UInt16,
    current: NSEvent.ModifierFlags
  ) -> [Event] {
    let matchingPressedKeyCodes = pressedKeyCodes.filter {
      Self.descriptor(for: $0)?.flag == descriptor.flag
    }
    let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: current)
    if pressedKeyCodes.contains(physicalKeyCode) {
      guard !current.contains(descriptor.flag) || matchingPressedKeyCodes.count > 1 else {
        return []
      }
      pressedKeyCodes.remove(physicalKeyCode)
      return [Event(
        keycode: descriptor.rimeKeyCode,
        modifiers: rimeModifiers | kReleaseMask.rawValue
      )]
    }
    guard current.contains(descriptor.flag) else { return [] }
    pressedKeyCodes.insert(physicalKeyCode)
    return [Event(keycode: descriptor.rimeKeyCode, modifiers: rimeModifiers)]
  }

  private struct Descriptor {
    let keyCode: UInt16
    let flag: NSEvent.ModifierFlags
    let rimeKeyCode: UInt32
  }

  private static let leftDescriptors = [
    Descriptor(keyCode: UInt16(kVK_CapsLock), flag: .capsLock, rimeKeyCode: UInt32(XK_Caps_Lock)),
    Descriptor(keyCode: UInt16(kVK_Shift), flag: .shift, rimeKeyCode: UInt32(XK_Shift_L)),
    Descriptor(keyCode: UInt16(kVK_Control), flag: .control, rimeKeyCode: UInt32(XK_Control_L)),
    Descriptor(keyCode: UInt16(kVK_Option), flag: .option, rimeKeyCode: UInt32(XK_Alt_L)),
    Descriptor(keyCode: UInt16(kVK_Command), flag: .command, rimeKeyCode: UInt32(XK_Super_L))
  ]

  private static let rightDescriptors = [
    Descriptor(keyCode: UInt16(kVK_RightShift), flag: .shift, rimeKeyCode: UInt32(XK_Shift_R)),
    Descriptor(keyCode: UInt16(kVK_RightControl), flag: .control, rimeKeyCode: UInt32(XK_Control_R)),
    Descriptor(keyCode: UInt16(kVK_RightOption), flag: .option, rimeKeyCode: UInt32(XK_Alt_R)),
    Descriptor(keyCode: UInt16(kVK_RightCommand), flag: .command, rimeKeyCode: UInt32(XK_Super_R))
  ]

  private static func descriptor(for keyCode: UInt16) -> Descriptor? {
    (leftDescriptors + rightDescriptors).first { $0.keyCode == keyCode }
  }

  private static func modifiers(from hardwareFlags: CGEventFlags) -> NSEvent.ModifierFlags {
    var modifiers: NSEvent.ModifierFlags = []
    if hardwareFlags.contains(.maskAlphaShift) { modifiers.insert(.capsLock) }
    if hardwareFlags.contains(.maskShift) { modifiers.insert(.shift) }
    if hardwareFlags.contains(.maskControl) { modifiers.insert(.control) }
    if hardwareFlags.contains(.maskAlternate) { modifiers.insert(.option) }
    if hardwareFlags.contains(.maskCommand) { modifiers.insert(.command) }
    return modifiers
  }
}

struct SquirrelKeycode {

  static func osxModifiersToRime(modifiers: NSEvent.ModifierFlags) -> UInt32 {
    var ret: UInt32 = 0
    if modifiers.contains(.capsLock) {
      ret |= kLockMask.rawValue
    }
    if modifiers.contains(.shift) {
      ret |= kShiftMask.rawValue
    }
    if modifiers.contains(.control) {
      ret |= kControlMask.rawValue
    }
    if modifiers.contains(.option) {
      ret |= kAltMask.rawValue
    }
    if modifiers.contains(.command) {
      ret |= kSuperMask.rawValue
    }
    return ret
  }

  static func osxKeycodeToRime(keycode: UInt16, keychar: Character?, shift: Bool, caps: Bool) -> UInt32 {
    if let code = keycodeMappings[Int(keycode)] {
      return UInt32(code)
    }

    // Physical cursor/modifier keys remain authoritative when an IMK client
    // supplies no character payload. Printable keys must never be inferred
    // from their QWERTY position in that state.
    guard let keychar else { return UInt32(XK_VoidSymbol) }
    if keychar.isASCII, let codeValue = keychar.unicodeScalars.first?.value {
      // NOTE: IBus/Rime use different keycodes for uppercase/lowercase letters.
      if keychar.isLowercase && (shift != caps) {
        // lowercase -> Uppercase
        return keychar.uppercased().unicodeScalars.first?.value ?? codeValue
      }

      switch codeValue {
      case 0x20...0x7e:
        return codeValue
      case 0x1b:
        return UInt32(XK_bracketleft)
      case 0x1c:
        return UInt32(XK_backslash)
      case 0x1d:
        return UInt32(XK_bracketright)
      case 0x1f:
        return UInt32(XK_minus)
      default:
        break
      }
    }

    if let code = additionalCodeMappings[Int(keycode)] {
      return UInt32(code)
    }

    return UInt32(XK_VoidSymbol)
  }

  static func composingKeypadEquivalent(_ keycode: UInt32) -> UInt32? {
    switch Int32(keycode) {
    case XK_KP_0...XK_KP_9:
      UInt32(XK_0 + Int32(keycode) - XK_KP_0)
    case XK_KP_Decimal: UInt32(XK_period)
    case XK_KP_Equal: UInt32(XK_equal)
    case XK_KP_Add: UInt32(XK_plus)
    case XK_KP_Subtract: UInt32(XK_minus)
    case XK_KP_Multiply: UInt32(XK_asterisk)
    case XK_KP_Divide: UInt32(XK_slash)
    default: nil
    }
  }

  private static let keycodeMappings: [Int: Int32] = [
    // modifiers
    kVK_CapsLock: XK_Caps_Lock,
    kVK_Command: XK_Super_L,  // XK_Meta_L?
    kVK_RightCommand: XK_Super_R,  // XK_Meta_R?
    kVK_Control: XK_Control_L,
    kVK_RightControl: XK_Control_R,
    kVK_Function: XK_Hyper_L,
    kVK_Option: XK_Alt_L,
    kVK_RightOption: XK_Alt_R,
    kVK_Shift: XK_Shift_L,
    kVK_RightShift: XK_Shift_R,

    // special
    kVK_Delete: XK_BackSpace,
    kVK_Escape: XK_Escape,
    kVK_ForwardDelete: XK_Delete,
    kVK_Help: XK_Help,
    kVK_Return: XK_Return,
    kVK_Space: XK_space,
    kVK_Tab: XK_Tab,

    // function
    kVK_F1: XK_F1,
    kVK_F2: XK_F2,
    kVK_F3: XK_F3,
    kVK_F4: XK_F4,
    kVK_F5: XK_F5,
    kVK_F6: XK_F6,
    kVK_F7: XK_F7,
    kVK_F8: XK_F8,
    kVK_F9: XK_F9,
    kVK_F10: XK_F10,
    kVK_F11: XK_F11,
    kVK_F12: XK_F12,
    kVK_F13: XK_F13,
    kVK_F14: XK_F14,
    kVK_F15: XK_F15,
    kVK_F16: XK_F16,
    kVK_F17: XK_F17,
    kVK_F18: XK_F18,
    kVK_F19: XK_F19,
    kVK_F20: XK_F20,

    // cursor
    kVK_UpArrow: XK_Up,
    kVK_DownArrow: XK_Down,
    kVK_LeftArrow: XK_Left,
    kVK_RightArrow: XK_Right,
    kVK_PageUp: XK_Page_Up,
    kVK_PageDown: XK_Page_Down,
    kVK_Home: XK_Home,
    kVK_End: XK_End,

    // keypad
    kVK_ANSI_Keypad0: XK_KP_0,
    kVK_ANSI_Keypad1: XK_KP_1,
    kVK_ANSI_Keypad2: XK_KP_2,
    kVK_ANSI_Keypad3: XK_KP_3,
    kVK_ANSI_Keypad4: XK_KP_4,
    kVK_ANSI_Keypad5: XK_KP_5,
    kVK_ANSI_Keypad6: XK_KP_6,
    kVK_ANSI_Keypad7: XK_KP_7,
    kVK_ANSI_Keypad8: XK_KP_8,
    kVK_ANSI_Keypad9: XK_KP_9,
    kVK_ANSI_KeypadClear: XK_Clear,
    kVK_ANSI_KeypadDecimal: XK_KP_Decimal,
    kVK_ANSI_KeypadEquals: XK_KP_Equal,
    kVK_ANSI_KeypadMinus: XK_KP_Subtract,
    kVK_ANSI_KeypadMultiply: XK_KP_Multiply,
    kVK_ANSI_KeypadPlus: XK_KP_Add,
    kVK_ANSI_KeypadDivide: XK_KP_Divide,
    kVK_ANSI_KeypadEnter: XK_Return,

    // other
    kVK_ISO_Section: XK_section,
    kVK_JIS_Yen: XK_yen,
    kVK_JIS_Underscore: XK_underscore,
    kVK_JIS_KeypadComma: XK_comma,
    kVK_JIS_Eisu: XK_Eisu_Shift,
    kVK_JIS_Kana: XK_Kana_Shift
  ]

  private static let additionalCodeMappings: [Int: Int32] = [
    // numbers
    kVK_ANSI_0: XK_0,
    kVK_ANSI_1: XK_1,
    kVK_ANSI_2: XK_2,
    kVK_ANSI_3: XK_3,
    kVK_ANSI_4: XK_4,
    kVK_ANSI_5: XK_5,
    kVK_ANSI_6: XK_6,
    kVK_ANSI_7: XK_7,
    kVK_ANSI_8: XK_8,
    kVK_ANSI_9: XK_9,

    // pubct
    kVK_ANSI_RightBracket: XK_bracketright,
    kVK_ANSI_LeftBracket: XK_bracketleft,
    kVK_ANSI_Comma: XK_comma,
    kVK_ANSI_Grave: XK_grave,
    kVK_ANSI_Period: XK_period,
    // kVK_VolumeUp:
    // kVK_VolumeDown:
    // kVK_Mute:
    kVK_ANSI_Semicolon: XK_semicolon,
    kVK_ANSI_Quote: XK_apostrophe,
    kVK_ANSI_Backslash: XK_backslash,
    kVK_ANSI_Minus: XK_minus,
    kVK_ANSI_Slash: XK_slash,
    kVK_ANSI_Equal: XK_equal,

    // letters
    kVK_ANSI_A: XK_a,
    kVK_ANSI_B: XK_b,
    kVK_ANSI_C: XK_c,
    kVK_ANSI_D: XK_d,
    kVK_ANSI_E: XK_e,
    kVK_ANSI_F: XK_f,
    kVK_ANSI_G: XK_g,
    kVK_ANSI_H: XK_h,
    kVK_ANSI_I: XK_i,
    kVK_ANSI_J: XK_j,
    kVK_ANSI_K: XK_k,
    kVK_ANSI_L: XK_l,
    kVK_ANSI_M: XK_m,
    kVK_ANSI_N: XK_n,
    kVK_ANSI_O: XK_o,
    kVK_ANSI_P: XK_p,
    kVK_ANSI_Q: XK_q,
    kVK_ANSI_R: XK_r,
    kVK_ANSI_S: XK_s,
    kVK_ANSI_T: XK_t,
    kVK_ANSI_U: XK_u,
    kVK_ANSI_V: XK_v,
    kVK_ANSI_W: XK_w,
    kVK_ANSI_X: XK_x,
    kVK_ANSI_Y: XK_y,
    kVK_ANSI_Z: XK_z
  ]
}
