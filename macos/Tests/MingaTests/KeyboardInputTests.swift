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

import MingaUI
import Testing
import Foundation
import AppKit
import MingaProtocol

private enum FileTreeNavigationTestConstants {
    static let visibleFlag: UInt8 = 0x01
    static let focusedFlag: UInt8 = 0x02
    static let localNavigationFlag: UInt8 = 0x20
    static let readyState: UInt8 = 3
    static let keyCodeK: UInt16 = 40
    static let keyCodeDownArrow: UInt16 = 125
    static let keyCodeUpArrow: UInt16 = 126
    static let kittyLeftCodepoint: UInt32 = 57350
    static let kittyRightCodepoint: UInt32 = 57351
    static let kittyUpCodepoint: UInt32 = 57352
    static let kittyDownCodepoint: UInt32 = 57353
    static let characterKCodepoint: UInt32 = 0x6B
}

@Suite("EditorNSView Keyboard Input")
struct KeyboardInputTests {

    @MainActor
    private func makeView(spy: SpyEncoder) -> EditorNSView? {
        let fm = FontManager(name: "Menlo", size: 13.0, scale: 1.0)
        let guiState = GUIState()
        let disp = CommandDispatcher(cols: 80, rows: 24, guiState: guiState)
        guard let ctRenderer = CoreTextMetalRenderer() else { return nil }
        ctRenderer.setupRenderers(fontManager: fm)
        return EditorNSView(encoder: spy, dispatcher: disp,
                            coreTextRenderer: ctRenderer, fontManager: fm)
    }

    @MainActor
    private func makeWindowedView(spy: SpyEncoder) -> (view: EditorNSView, window: NSWindow, textField: NSTextField)? {
        guard let view = makeView(spy: spy) else { return nil }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: view.frame)
        let textField = NSTextField(frame: NSRect(x: 16, y: 16, width: 180, height: 24))
        container.addSubview(view)
        container.addSubview(textField)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        return (view, window, textField)
    }

    /// Creates a key event with the given keyCode and modifiers.
    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = "",
        charactersIgnoringModifiers: String = "",
        isRepeat: Bool = false,
        windowNumber: Int = 0,
        location: NSPoint = .zero
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: isRepeat,
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
            (123, FileTreeNavigationTestConstants.kittyLeftCodepoint),
            (124, FileTreeNavigationTestConstants.kittyRightCodepoint),
            (FileTreeNavigationTestConstants.keyCodeUpArrow, FileTreeNavigationTestConstants.kittyUpCodepoint),
            (FileTreeNavigationTestConstants.keyCodeDownArrow, FileTreeNavigationTestConstants.kittyDownCodepoint),
        ]

        for (keyCode, _) in arrows {
            guard let event = keyEvent(keyCode: keyCode) else { continue }
            view.keyDown(with: event)
        }

        #expect(spy.keyPressCalls.count == 4)
        for (index, (_, expected)) in arrows.enumerated() {
            #expect(spy.keyPressCalls[index].codepoint == expected,
                    "Arrow key at index \(index) should be \(expected)")
        }
    }

    @Test("Down arrow previews eligible file tree selection and still sends key")
    @MainActor func downArrowPreviewsFileTreeSelection() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let entries = [
            keyboardFileTreeEntry(pathHash: 1, isSelected: true, isFocused: true, id: "/project/a", path: "/project/a", name: "a", relPath: "a"),
            keyboardFileTreeEntry(pathHash: 2, isFocused: true, id: "/project/b", path: "/project/b", name: "b", relPath: "b")
        ]
        view.dispatcher.applyForTesting(
            .guiFileTree(
                version: 2,
                treeFlags: FileTreeNavigationTestConstants.visibleFlag |
                    FileTreeNavigationTestConstants.focusedFlag |
                    FileTreeNavigationTestConstants.localNavigationFlag,
                treeState: FileTreeNavigationTestConstants.readyState,
                selectedId: "/project/a",
                treeWidth: 30,
                rootPath: "/project",
                errorReason: "",
                entries: entries
            )
        )

        guard let event = keyEvent(keyCode: FileTreeNavigationTestConstants.keyCodeDownArrow) else { return }
        view.keyDown(with: event)

        #expect(view.dispatcher.guiState.fileTreeState.selectedId == "/project/b")
        #expect(view.dispatcher.guiState.fileTreeState.selectedIndex == 1)
        #expect(spy.keyPressCalls.count == 1)
        #expect(spy.keyPressCalls[0].codepoint == FileTreeNavigationTestConstants.kittyDownCodepoint)
    }

    @Test("k previews eligible file tree selection and still sends key")
    @MainActor func kKeyPreviewsFileTreeSelection() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let entries = [
            keyboardFileTreeEntry(pathHash: 1, isSelected: true, isFocused: true, id: "/project/a", path: "/project/a", name: "a", relPath: "a"),
            keyboardFileTreeEntry(pathHash: 2, isFocused: true, id: "/project/b", path: "/project/b", name: "b", relPath: "b")
        ]
        view.dispatcher.applyForTesting(
            .guiFileTree(
                version: 2,
                treeFlags: FileTreeNavigationTestConstants.visibleFlag |
                    FileTreeNavigationTestConstants.focusedFlag |
                    FileTreeNavigationTestConstants.localNavigationFlag,
                treeState: FileTreeNavigationTestConstants.readyState,
                selectedId: "/project/a",
                treeWidth: 30,
                rootPath: "/project",
                errorReason: "",
                entries: entries
            )
        )

        guard let event = keyEvent(keyCode: FileTreeNavigationTestConstants.keyCodeK, characters: "k", charactersIgnoringModifiers: "k") else { return }
        view.keyDown(with: event)

        #expect(view.dispatcher.guiState.fileTreeState.selectedId == "/project/b")
        #expect(view.dispatcher.guiState.fileTreeState.selectedIndex == 1)
        #expect(spy.keyPressCalls.count == 1)
        #expect(spy.keyPressCalls[0].codepoint == FileTreeNavigationTestConstants.characterKCodepoint)
    }

    @Test("Up arrow previews eligible file tree selection and still sends key")
    @MainActor func upArrowPreviewsFileTreeSelection() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let entries = [
            keyboardFileTreeEntry(pathHash: 1, isSelected: false, isFocused: true, id: "/project/a", path: "/project/a", name: "a", relPath: "a"),
            keyboardFileTreeEntry(pathHash: 2, isSelected: true, isFocused: true, id: "/project/b", path: "/project/b", name: "b", relPath: "b")
        ]
        view.dispatcher.applyForTesting(
            .guiFileTree(
                version: 2,
                treeFlags: FileTreeNavigationTestConstants.visibleFlag |
                    FileTreeNavigationTestConstants.focusedFlag |
                    FileTreeNavigationTestConstants.localNavigationFlag,
                treeState: FileTreeNavigationTestConstants.readyState,
                selectedId: "/project/b",
                treeWidth: 30,
                rootPath: "/project",
                errorReason: "",
                entries: entries
            )
        )

        guard let event = keyEvent(keyCode: FileTreeNavigationTestConstants.keyCodeUpArrow) else { return }
        view.keyDown(with: event)

        #expect(view.dispatcher.guiState.fileTreeState.selectedId == "/project/a")
        #expect(view.dispatcher.guiState.fileTreeState.selectedIndex == 0)
        #expect(spy.keyPressCalls.count == 1)
        #expect(spy.keyPressCalls[0].codepoint == FileTreeNavigationTestConstants.kittyUpCodepoint)
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
        for (index, (_, expected)) in keys.enumerated() {
            #expect(spy.keyPressCalls[index].codepoint == expected)
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

    @Test("System command shortcuts are yielded to AppKit")
    @MainActor func systemCommandShortcutsYield() throws {
        guard let quit = keyEvent(keyCode: 12, modifiers: .command, characters: "q", charactersIgnoringModifiers: "q") else { return }
        guard let paste = keyEvent(keyCode: 9, modifiers: .command, characters: "v", charactersIgnoringModifiers: "v") else { return }
        guard let saveAs = keyEvent(keyCode: 1, modifiers: [.command, .shift], characters: "S", charactersIgnoringModifiers: "s") else { return }
        guard let modifiedQuit = keyEvent(keyCode: 12, modifiers: [.command, .shift], characters: "Q", charactersIgnoringModifiers: "q") else { return }

        #expect(EditorNSView.shouldYieldSystemCommandShortcut(quit))
        #expect(EditorNSView.shouldYieldSystemCommandShortcut(paste))
        #expect(EditorNSView.shouldYieldSystemCommandShortcut(saveAs))
        #expect(!EditorNSView.shouldYieldSystemCommandShortcut(modifiedQuit))
    }

    @Test("native modal scope suspends focus reclamation and restores the editor")
    @MainActor func nativeModalFocusLifecycle() throws {
        let spy = SpyEncoder()
        guard let (view, window, textField) = makeWindowedView(spy: spy) else { return }
        window.makeFirstResponder(textField)

        view.focusPolicy.beginNativeModal()
        view.focusPolicy.pointerReturnedToEditor()
        #expect(window.firstResponder === textField)

        view.focusPolicy.endNativeModalAndRestore()
        #expect(window.firstResponder === view)
    }

    @Test("agent overlay routes key down, repeat, key up, and modifiers exactly once while yielding native input and system shortcuts")
    @MainActor func agentOverlayRoutesCompleteKeySequences() async throws {
        let spy = SpyEncoder()
        guard let (view, window, textField) = makeWindowedView(spy: spy) else { return }
        view.setAgentChatVisible(true)
        #expect(window.makeFirstResponder(view))

        let escape = try #require(keyEvent(keyCode: 53, windowNumber: window.windowNumber))
        let repeatEscape = try #require(keyEvent(keyCode: 53, isRepeat: true, windowNumber: window.windowNumber))
        let spaceDown = try #require(keyEvent(keyCode: 49, characters: " ", charactersIgnoringModifiers: " ", windowNumber: window.windowNumber))
        let spaceUp = try #require(keyEvent(type: .keyUp, keyCode: 49, characters: " ", charactersIgnoringModifiers: " ", windowNumber: window.windowNumber))
        let commandChanged = try #require(keyEvent(type: .flagsChanged, keyCode: 55, modifiers: .command, windowNumber: window.windowNumber, location: NSPoint(x: 40, y: 40)))
        let quit = try #require(keyEvent(keyCode: 12, modifiers: .command, characters: "q", charactersIgnoringModifiers: "q", windowNumber: window.windowNumber))

        #expect(view.focusPolicy.routeAgentOverlayEvent(escape) == nil)
        #expect(view.focusPolicy.routeAgentOverlayEvent(repeatEscape) == nil)
        #expect(view.focusPolicy.routeAgentOverlayEvent(spaceDown) == nil)
        #expect(view.focusPolicy.routeAgentOverlayEvent(spaceUp) == nil)
        #expect(view.focusPolicy.routeAgentOverlayEvent(commandChanged) == nil)
        #expect(view.focusPolicy.routeAgentOverlayEvent(quit) === quit)
        #expect(spy.keyPressCalls.map(\.codepoint) == [27, 27, 0x20])
        #expect(spy.mouseEventCalls.count == 1)

        view.setAgentChatVisible(false)
        await Task.yield()
        await Task.yield()
        #expect(window.firstResponder === view)

        view.setAgentChatVisible(true)
        #expect(window.makeFirstResponder(textField))
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        let callsBeforeNativeInput = spy.keyPressCalls.count
        #expect(view.focusPolicy.routeAgentOverlayEvent(escape) === escape)
        #expect(window.firstResponder === fieldEditor)
        #expect(spy.keyPressCalls.count == callsBeforeNativeInput)

        view.setAgentChatVisible(false)
        await Task.yield()
        await Task.yield()
        #expect(view.focusPolicy.routeAgentOverlayEvent(escape) === escape)
        #expect(window.firstResponder === fieldEditor)
    }

    @Test("Text input modes treat space as literal")
    func statusModesUsingLiteralSpace() throws {
        #expect(!EditorNSView.statusModeUsesLiteralSpace(statusMode: nil))
        #expect(!EditorNSView.statusModeUsesLiteralSpace(statusMode: 0))
        #expect(EditorNSView.statusModeUsesLiteralSpace(statusMode: 1))
        #expect(!EditorNSView.statusModeUsesLiteralSpace(statusMode: 2))
        #expect(EditorNSView.statusModeUsesLiteralSpace(statusMode: 3))
        #expect(!EditorNSView.statusModeUsesLiteralSpace(statusMode: 4))
        #expect(EditorNSView.statusModeUsesLiteralSpace(statusMode: 5))
        #expect(EditorNSView.statusModeUsesLiteralSpace(statusMode: 6))
    }

    @Test("Vim normal insert-entering keys use optimistic text input mode")
    func optimisticTextInputModeKeys() throws {
        let insertKeys: [(String, UInt32)] = [
            ("i", 0x69), ("I", 0x49), ("a", 0x61), ("A", 0x41), ("o", 0x6F),
            ("O", 0x4F), ("s", 0x73), ("S", 0x53), ("C", 0x43), ("R", 0x52)
        ]

        for (key, scalar) in insertKeys {
            #expect(EditorNSView.shouldOptimisticallyEnterTextInputMode(codepoint: scalar, statusMode: 0, cursorShape: .block), "\(key) should predict text input mode")
        }

        #expect(!EditorNSView.shouldOptimisticallyEnterTextInputMode(codepoint: UnicodeScalar("x").value, statusMode: 0, cursorShape: .block))
        #expect(!EditorNSView.shouldOptimisticallyEnterTextInputMode(codepoint: UnicodeScalar(" ").value, statusMode: 0, cursorShape: .block))
        #expect(!EditorNSView.shouldOptimisticallyEnterTextInputMode(codepoint: UnicodeScalar("s").value, statusMode: 0, cursorShape: .beam))
        #expect(!EditorNSView.shouldOptimisticallyEnterTextInputMode(codepoint: UnicodeScalar("i").value, statusMode: 1, cursorShape: .beam))
        #expect(!EditorNSView.shouldOptimisticallyEnterTextInputMode(codepoint: UnicodeScalar("i").value, statusMode: nil, cursorShape: .block))
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
        for (index, (_, expected)) in fkeys.enumerated() {
            #expect(spy.keyPressCalls[index].codepoint == expected)
        }
    }
}

private func keyboardFileTreeEntry(
    pathHash: UInt32,
    isSelected: Bool = false,
    isFocused: Bool = false,
    id: String,
    path: String,
    name: String,
    relPath: String
) -> Wire.FileTreeEntry {
    Wire.FileTreeEntry(
        pathHash: pathHash,
        id: id,
        path: path,
        isDir: false,
        isExpanded: false,
        isSelected: isSelected,
        isFocused: isFocused,
        isActive: false,
        isDirty: false,
        isEditing: false,
        isLastChild: false,
        depth: 0,
        gitStatus: 0,
        diagnosticErrorCount: 0,
        diagnosticWarningCount: 0,
        diagnosticInfoCount: 0,
        diagnosticHintCount: 0,
        guides: [],
        icon: "",
        iconColorR: 0x6D,
        iconColorG: 0x80,
        iconColorB: 0x86,
        name: name,
        relPath: relPath,
        editingType: 0xFF,
        editingText: ""
    )
}
