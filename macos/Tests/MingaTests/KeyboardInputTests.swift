/// Tests for keyboard input handling in EditorNSView.
///
/// Verifies that special keys (arrows, Escape, Enter, etc.) are mapped
/// to the correct Kitty keyboard protocol codepoints, and that modifier
/// bits are encoded correctly.
///
/// Note: testing regular character input (e.g., typing "a") requires
/// the NSTextInputClient / IME pipeline, which needs a window and input
/// context. These tests focus on the special key mapping and modifier
/// encoding that bypass IME.

import Testing
import Foundation
import AppKit

@Suite("EditorNSView Keyboard Input")
struct KeyboardInputTests {

    @MainActor
    private func makeView(spy: SpyEncoder) -> EditorNSView? {
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 1.0)
        let guiState = GUIState()
        let disp = CommandDispatcher(cols: 80, rows: 24, guiState: guiState)
        guard let ctRenderer = CoreTextMetalRenderer() else { return nil }
        ctRenderer.setupRenderers(fontManager: fm)
        return EditorNSView(encoder: spy, fontFace: face, dispatcher: disp,
                            coreTextRenderer: ctRenderer, fontManager: fm)
    }

    /// Creates a key event with the given keyCode and modifiers.
    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = "",
        charactersIgnoringModifiers: String = ""
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // MARK: - Special key mapping

    @Test("Escape sends codepoint 27")
    @MainActor func escapeKey() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 53) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls.count == 1)
        #expect(spy.keyPressCalls[0].codepoint == 27)
    }

    @Test("Return sends codepoint 13")
    @MainActor func returnKey() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 36) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls.count == 1)
        #expect(spy.keyPressCalls[0].codepoint == 13)
    }

    @Test("Tab sends codepoint 9")
    @MainActor func tabKey() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 48) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls[0].codepoint == 9)
    }

    @Test("Backspace sends codepoint 127")
    @MainActor func backspaceKey() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 51) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls[0].codepoint == 127)
    }

    @Test("Arrow keys send Kitty codepoints")
    @MainActor func arrowKeys() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        let arrows: [(keyCode: UInt16, expected: UInt32)] = [
            (123, 57350), // Left
            (124, 57351), // Right
            (126, 57352), // Up
            (125, 57353), // Down
        ]

        for (keyCode, expected) in arrows {
            guard let event = keyEvent(keyCode: keyCode) else { continue }
            view.keyDown(with: event)
        }

        #expect(spy.keyPressCalls.count == 4)
        for (i, (_, expected)) in arrows.enumerated() {
            #expect(spy.keyPressCalls[i].codepoint == expected,
                    "Arrow key at index \(i) should be \(expected)")
        }
    }

    @Test("Home/End/PageUp/PageDown send correct codepoints")
    @MainActor func navigationKeys() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        let keys: [(keyCode: UInt16, expected: UInt32)] = [
            (115, 57360), // Home
            (119, 57361), // End
            (116, 57362), // PageUp
            (121, 57363), // PageDown
        ]

        for (keyCode, _) in keys {
            guard let event = keyEvent(keyCode: keyCode) else { continue }
            view.keyDown(with: event)
        }

        #expect(spy.keyPressCalls.count == 4)
        for (i, (_, expected)) in keys.enumerated() {
            #expect(spy.keyPressCalls[i].codepoint == expected)
        }
    }

    @Test("Forward Delete sends codepoint 57376")
    @MainActor func forwardDelete() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 117) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls[0].codepoint == 57376)
    }

    // MARK: - Modifier encoding

    @Test("Shift modifier on special key is encoded as bit 0")
    @MainActor func shiftOnSpecialKey() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 53, modifiers: .shift) else { return } // Shift+Escape
        view.keyDown(with: event)

        #expect(spy.keyPressCalls[0].modifiers & 0x01 != 0) // shift bit
    }

    @Test("Control modifier is encoded as bit 1")
    @MainActor func controlModifier() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        // Ctrl+Left arrow
        guard let event = keyEvent(keyCode: 123, modifiers: .control) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls[0].modifiers & 0x02 != 0) // control bit
    }

    @Test("Option modifier is encoded as bit 2")
    @MainActor func optionModifier() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 123, modifiers: .option) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls[0].modifiers & 0x04 != 0) // option bit
    }

    @Test("Command modifier is encoded as bit 3")
    @MainActor func commandModifier() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        guard let event = keyEvent(keyCode: 123, modifiers: .command) else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls[0].modifiers & 0x08 != 0) // command bit
    }

    // MARK: - Control key bypass

    @Test("Ctrl+A sends character codepoint with control modifier")
    @MainActor func ctrlA() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        // Ctrl+A: keyCode 0, charactersIgnoringModifiers "a"
        guard let event = keyEvent(keyCode: 0, modifiers: .control,
                                   characters: "\u{01}",
                                   charactersIgnoringModifiers: "a") else { return }
        view.keyDown(with: event)

        #expect(spy.keyPressCalls.count == 1)
        // Ctrl+A sends 'a' with control modifier (shift stripped)
        #expect(spy.keyPressCalls[0].codepoint == UnicodeScalar("a").value)
        #expect(spy.keyPressCalls[0].modifiers & 0x02 != 0) // control bit set
    }

    // MARK: - Function keys

    @Test("F1-F4 send correct Kitty codepoints")
    @MainActor func functionKeys() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        let fkeys: [(keyCode: UInt16, expected: UInt32)] = [
            (122, 57364), // F1
            (120, 57365), // F2
            (99, 57366),  // F3
            (118, 57367), // F4
        ]

        for (keyCode, _) in fkeys {
            guard let event = keyEvent(keyCode: keyCode) else { continue }
            view.keyDown(with: event)
        }

        #expect(spy.keyPressCalls.count == 4)
        for (i, (_, expected)) in fkeys.enumerated() {
            #expect(spy.keyPressCalls[i].codepoint == expected)
        }
    }
}
