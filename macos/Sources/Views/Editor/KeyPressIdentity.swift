import AppKit

/// The identity a key event has in a `key_press` sent to the BEAM: its codepoint and modifier bits.
///
/// The editor view and the native picker query field both derive it here, so a key the BEAM lists for a picker is matched against the same values the frontend would send for it.
public nonisolated struct KeyPressIdentity: Equatable, Sendable {
    public let codepoint: UInt32
    public let modifiers: UInt8

    public init(codepoint: UInt32, modifiers: UInt8) {
        self.codepoint = codepoint
        self.modifiers = modifiers
    }

    /// The `key_press` modifier bits of AppKit modifier flags: shift 1, control 2, option 4, command 8.
    public static func modifierBits(from flags: NSEvent.ModifierFlags) -> UInt8 {
        var mods: UInt8 = 0
        if flags.contains(.shift)   { mods |= 0x01 }
        if flags.contains(.control) { mods |= 0x02 }
        if flags.contains(.option)  { mods |= 0x04 }
        if flags.contains(.command) { mods |= 0x08 }
        return mods
    }

    /// The codepoint of a named key (Return, Tab, the arrows, the page and function keys), or nil for a key that produces text.
    public static func namedKeyCodepoint(keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 36:  return 13     // Return
        case 48:  return 9      // Tab
        case 51:  return 127    // Backspace / Delete
        case 53:  return 27     // Escape
        case 123: return 57350  // Left arrow
        case 124: return 57351  // Right arrow
        case 125: return 57353  // Down arrow
        case 126: return 57352  // Up arrow
        case 115: return 57360  // Home
        case 119: return 57361  // End
        case 116: return 57362  // Page Up
        case 121: return 57363  // Page Down
        case 117: return 57376  // Forward Delete
        case 122: return 57364  // F1
        case 120: return 57365  // F2
        case 99:  return 57366  // F3
        case 118: return 57367  // F4
        case 96:  return 57368  // F5
        case 97:  return 57369  // F6
        case 98:  return 57370  // F7
        case 100: return 57371  // F8
        case 101: return 57372  // F9
        case 109: return 57373  // F10
        case 103: return 57374  // F11
        case 111: return 57375  // F12
        default:  return nil
        }
    }

    /// The identity of a key that is not plain text: a named key with its modifiers, or a Control chord on one character.
    ///
    /// A Control chord carries the character without Control applied and no shift bit, because the character already encodes shift. Plain text, Option and Command combinations have no identity here: text reaches the BEAM as text, and Command belongs to the menus.
    public static func command(keyCode: UInt16, charactersIgnoringModifiers: String?, flags: NSEvent.ModifierFlags) -> KeyPressIdentity? {
        let modifiers = modifierBits(from: flags.intersection(.deviceIndependentFlagsMask))

        // Keypad Enter runs what Return runs.
        if let codepoint = keyCode == keypadEnterKeyCode ? 13 : namedKeyCodepoint(keyCode: keyCode) {
            return KeyPressIdentity(codepoint: codepoint, modifiers: modifiers)
        }

        guard flags.contains(.control), !flags.contains(.command),
              let character = charactersIgnoringModifiers, character.unicodeScalars.count == 1
        else { return nil }

        // Caps Lock alone must not turn ⌃J into another key: only Shift picks the upper-case character.
        let typed = flags.contains(.capsLock) && !flags.contains(.shift) ? character.lowercased() : character
        guard typed.unicodeScalars.count == 1, let scalar = typed.unicodeScalars.first else { return nil }

        return KeyPressIdentity(codepoint: scalar.value, modifiers: modifiers & ~0x01)
    }

    private static let keypadEnterKeyCode: UInt16 = 76

    /// The identity of a key-down event that is not plain text. See `command(keyCode:charactersIgnoringModifiers:flags:)`.
    public static func command(from event: NSEvent) -> KeyPressIdentity? {
        guard event.type == .keyDown else { return nil }
        return command(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers, flags: event.modifierFlags)
    }
}
