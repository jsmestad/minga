import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MingaUI

@Suite("Picker Native Query Editing")
@MainActor
struct PickerQueryFieldTests {
    @Test("stale BEAM echoes do not overwrite a newer local edit")
    func staleEchoReconciliation() {
        var reconciler = PickerQueryReconciler()

        #expect(reconciler.reconcile(generation: 7, acknowledgedSequence: 0, authoritativeText: "") == "")
        let edit = reconciler.recordLocalEdit("café")
        #expect(edit == PickerQueryReconciler.Edit(generation: 7, sequence: 1, text: "café"))
        #expect(reconciler.reconcile(generation: 7, acknowledgedSequence: 0, authoritativeText: "") == nil)
        #expect(reconciler.reconcile(generation: 7, acknowledgedSequence: 1, authoritativeText: "café") == "café")
    }

    @Test("a new picker generation supersedes unacknowledged local text")
    func generationReplacement() {
        var reconciler = PickerQueryReconciler()

        _ = reconciler.reconcile(generation: 7, acknowledgedSequence: 0, authoritativeText: "old")
        _ = reconciler.recordLocalEdit("local")

        #expect(reconciler.reconcile(generation: 8, acknowledgedSequence: 0, authoritativeText: "new") == "new")
        #expect(reconciler.recordLocalEdit("next") == PickerQueryReconciler.Edit(generation: 8, sequence: 1, text: "next"))
    }

    @Test("the AppKit coordinator sends complete correlated edits and rejects stale echoes")
    @MainActor func coordinatorEditingPath() {
        let recorder = LocalActionRecorder<PickerQueryField.Action>()
        let style = InlineEditFieldStyle(textColor: .primary, selectionBackgroundColor: .accentColor, selectionForegroundColor: .primary, insertionPointColor: .accentColor)
        let coordinator = PickerQueryField.Coordinator(sendAction: recorder.handler, style: style)
        let field = PickerNSTextField()
        let editor = NSTextView()
        field.isEditable = true
        let path = "/tmp/Folder Name/résumé.txt"

        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 0, authoritativeText: "")
        field.stringValue = path
        editor.string = path
        coordinator.handleTextChange(field: field, editor: editor)

        #expect(recorder.actions == [.queryChanged(generation: 7, editSequence: 1, text: path)])

        editor.setSelectedRange(NSRange(location: 1, length: 2))
        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 0, authoritativeText: "")
        #expect(field.stringValue == path)
        #expect(editor.string == path)
        #expect(editor.selectedRange() == NSRange(location: 1, length: 2))
    }

    @Test("the native field adopts a BEAM-completed query with the caret at its end")
    @MainActor func adoptsCompletedQuery() {
        let recorder = LocalActionRecorder<PickerQueryField.Action>()
        let style = InlineEditFieldStyle(textColor: .primary, selectionBackgroundColor: .accentColor, selectionForegroundColor: .primary, insertionPointColor: .accentColor)
        let coordinator = PickerQueryField.Coordinator(sendAction: recorder.handler, style: style)
        let field = PickerNSTextField()
        let editor = NSTextView()
        field.isEditable = true

        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 0, authoritativeText: "")
        field.stringValue = "~/pro"
        editor.string = "~/pro"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.handleTextChange(field: field, editor: editor)
        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 1, authoritativeText: "~/pro")

        // Tab is a key press, not a query edit, so the completed query arrives with the same acknowledgement.
        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 1, authoritativeText: "~/projects/")

        #expect(field.stringValue == "~/projects/")
        #expect(editor.string == "~/projects/")
        #expect(editor.selectedRange() == NSRange(location: 11, length: 0))
        #expect(recorder.actions == [.queryChanged(generation: 7, editSequence: 1, text: "~/pro")])
    }

    @Test("adopted text keeps a caret at the end and clamps any other selection")
    func adoptedSelection() {
        #expect(PickerQueryReconciler.adoptedSelection(NSRange(location: 5, length: 0), previousText: "~/pro", adoptedText: "~/projects/") == NSRange(location: 11, length: 0))
        #expect(PickerQueryReconciler.adoptedSelection(NSRange(location: 2, length: 0), previousText: "~/pro", adoptedText: "~/projects/") == NSRange(location: 2, length: 0))
        #expect(PickerQueryReconciler.adoptedSelection(NSRange(location: 1, length: 4), previousText: "~/pro", adoptedText: "~/p") == NSRange(location: 1, length: 2))
    }

    @Test("native text command routing covers standard editing operations")
    @MainActor func nativeTextCommands() {
        let editor = NSTextView()
        var routed: [String] = []

        for command in NativeTextCommandRouter.Command.allCases {
            let handled = NativeTextCommandRouter.route(command, to: editor) { selector, target in
                #expect(target === editor)
                routed.append(NSStringFromSelector(selector))
                return true
            }
            #expect(handled)
        }

        #expect(routed == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        #expect(!NativeTextCommandRouter.route(.copy, to: NSTextField()) { _, _ in true })
    }

    @Test("standard Edit actions use exactly one editor fallback outside native fields")
    @MainActor func menuEditorFallback() {
        let encoder = SpyEncoder()
        let editorResponder = NSView()
        var fallbacks: [NativeTextCommandRouter.Command] = []

        for command in NativeTextCommandRouter.Command.allCases {
            NativeMenuTextRouter.route(command, encoder: encoder, responder: editorResponder) { _, _ in
                Issue.record("The editor surface must not use native text actions")
                return true
            } fallback: { _ in
                fallbacks.append(command)
            }
        }

        #expect(fallbacks == NativeTextCommandRouter.Command.allCases)
    }

    @Test("editor Select All sends the semantic document command")
    @MainActor func editorSelectAll() {
        let encoder = SpyEncoder()

        NativeMenuTextRouter.route(.selectAll, encoder: encoder, responder: NSView()) { _, _ in
            Issue.record("The editor surface must not use native text actions")
            return true
        } fallback: { fallbackEncoder in
            fallbackEncoder.send(.executeCommand(name: "select_all"))
        }

        #expect(encoder.actions == [.executeCommand(name: "select_all")])
    }

    @Test("native field ownership consumes unavailable actions without falling through to the editor")
    @MainActor func menuNativeFieldOwnership() {
        let encoder = SpyEncoder()
        let pickerQueryFieldEditor = NSTextView()
        let settingsSearchFieldEditor = NSTextView()

        for fieldEditor in [pickerQueryFieldEditor, settingsSearchFieldEditor] {
            var routedSelectors: [String] = []

            for command in NativeTextCommandRouter.Command.allCases {
                NativeMenuTextRouter.route(command, encoder: encoder, responder: fieldEditor) { selector, target in
                    #expect(target === fieldEditor)
                    routedSelectors.append(NSStringFromSelector(selector))
                    return false
                } fallback: { _ in
                    Issue.record("A native field action must never fall through to the editor")
                }
            }

            #expect(routedSelectors == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        }

        #expect(encoder.actions.isEmpty)
        #expect(encoder.keyPressCalls.isEmpty)
    }

    @Test("disconnected editor fallback is harmless")
    @MainActor func disconnectedEditorFallback() {
        for command in NativeTextCommandRouter.Command.allCases {
            NativeMenuTextRouter.route(command, encoder: nil, responder: nil) { _, _ in
                Issue.record("No native responder is available")
                return true
            } fallback: { _ in
                Issue.record("No editor connection is available")
            }
            #expect(!NativeMenuTextRouter.isAvailable(command, encoder: nil, responder: NSView()) { _, _ in nil })
        }
    }

    @Test("disconnected editor preserves native field ownership")
    @MainActor func disconnectedNativeFieldOwnership() {
        let fieldEditor = NSTextView()
        var routedSelectors: [String] = []

        for command in NativeTextCommandRouter.Command.allCases {
            NativeMenuTextRouter.route(command, encoder: nil, responder: fieldEditor) { selector, target in
                #expect(target === fieldEditor)
                routedSelectors.append(NSStringFromSelector(selector))
                return true
            } fallback: { _ in
                Issue.record("A disconnected native field must not call an editor fallback")
            }
        }

        #expect(routedSelectors == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
    }

    @Test("Select All operates on the focused native field without a backend")
    @MainActor func disconnectedNativeFieldSelectAll() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 280, height: 24))
        field.stringValue = "disposable query"
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(field))
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        fieldEditor.allowsUndo = true
        let undoManager = try #require(fieldEditor.undoManager)
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        let isAvailable: (NativeTextCommandRouter.Command) -> Bool = { command in
            NativeMenuTextRouter.isAvailable(command, encoder: nil, responder: fieldEditor) { selector, responder in
                NSApp.target(forAction: selector, to: responder, from: nil)
            }
        }

        #expect(!isAvailable(.undo))
        #expect(!isAvailable(.redo))

        NativeMenuTextRouter.route(.selectAll, encoder: nil, responder: fieldEditor) { selector, target in
            target.tryToPerform(selector, with: nil)
        } fallback: { _ in
            Issue.record("The native field owns Select All")
        }

        #expect(fieldEditor.selectedRange() == NSRange(location: 0, length: fieldEditor.string.utf16.count))

        fieldEditor.string = "replacement"
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: fieldEditor) { _ in }
        undoManager.endUndoGrouping()
        #expect(isAvailable(.undo))
        #expect(!isAvailable(.redo))
        window.orderOut(nil)
    }

    @Test("query payloads stay within the complete UTF-8 wire limit")
    func queryWireLimit() {
        #expect(PickerQueryReconciler.queryFitsWire(String(repeating: "a", count: Int(UInt16.max))))
        #expect(!PickerQueryReconciler.queryFitsWire(String(repeating: "😀", count: 20_000)))
    }

    @Test("selection preservation clamps against UTF-16 text length")
    func selectionClamping() {
        #expect(PickerQueryReconciler.clampSelection(NSRange(location: 1, length: 5), to: "a😀") == NSRange(location: 1, length: 2))
        #expect(PickerQueryReconciler.clampSelection(NSRange(location: 20, length: 1), to: "abc") == NSRange(location: 3, length: 0))
    }

    /// The keys the BEAM sends for an unmodified picker scope, plus a user's ⌃N for the next row.
    private static let listed: Set<[UInt32]> = [[106, 2], [107, 2], [46, 2], [13, 0], [27, 0], [9, 0], [57_352, 0], [57_353, 0], [57_362, 0], [57_363, 0], [110, 2]]

    private func route(_ codepoint: UInt32?, _ modifiers: UInt8, _ selector: String, empty: Bool = false, listed: Set<[UInt32]> = PickerQueryFieldTests.listed) -> PickerQueryKeyRouting.Route {
        PickerQueryKeyRouting.route(
            identity: codepoint.map { KeyPressIdentity(codepoint: $0, modifiers: modifiers) },
            selectorName: selector,
            fieldIsEmpty: empty,
            binds: { listed.contains([$0, UInt32($1)]) }
        )
    }

    @Test("the field forwards exactly the keys the BEAM lists and keeps the others for the text")
    func keyRouting() {
        let forward = { (codepoint: UInt32, modifiers: UInt8) in PickerQueryKeyRouting.Route.forward(KeyPressIdentity(codepoint: codepoint, modifiers: modifiers)) }

        // Listed keys go to the BEAM, whatever Cocoa would have done with them.
        #expect(route(106, 2, "insertLineBreak:") == forward(106, 2))
        #expect(route(107, 2, "deleteToEndOfParagraph:") == forward(107, 2))
        #expect(route(46, 2, "noop:") == forward(46, 2))
        #expect(route(13, 0, "insertNewline:") == forward(13, 0))
        #expect(route(27, 0, "cancelOperation:") == forward(27, 0))
        #expect(route(57_353, 0, "moveDown:") == forward(57_353, 0))
        #expect(route(57_363, 0, "scrollPageDown:") == forward(57_363, 0))
        // A key the user bound is listed like any other.
        #expect(route(110, 2, "moveDown:") == forward(110, 2))

        // Unlisted keys stay with the field: ⌃A, ⌃E, the arrows that move the caret, and ⌃P, which no picker binds.
        #expect(route(97, 2, "moveToBeginningOfParagraph:") == .native)
        #expect(route(101, 2, "moveToEndOfParagraph:") == .native)
        #expect(route(57_350, 0, "moveLeft:") == .native)
        #expect(route(112, 2, "moveUp:") == .native)
        // The same key with another modifier is another key.
        #expect(route(57_353, 1, "moveDownAndModifySelection:") == .native)
        // A command without a key event behind it is the field's own.
        #expect(route(nil, 0, "moveRight:") == .native)

        // The readline edits Cocoa does not bind.
        #expect(route(119, 2, "noop:") == .lineEdit(.deleteWordBackward))
        #expect(route(117, 2, "noop:") == .lineEdit(.deleteToLineStart))

        // Backspace is the field's, except on an empty query, where the BEAM handles it.
        #expect(route(127, 0, "deleteBackward:") == .native)
        #expect(route(127, 0, "deleteBackward:", empty: true) == forward(127, 0))
    }

    @Test("a key the user unbound stops reaching the BEAM, and one that would end editing does nothing")
    func unboundKeys() {
        let withoutEnterAndCtrlJ = PickerQueryFieldTests.listed.subtracting([[13, 0], [106, 2], [27, 0]])

        #expect(route(13, 0, "insertNewline:", listed: withoutEnterAndCtrlJ) == .ignore)
        #expect(route(106, 2, "insertLineBreak:", listed: withoutEnterAndCtrlJ) == .ignore)
        #expect(route(27, 0, "cancelOperation:", listed: withoutEnterAndCtrlJ) == .ignore)
        #expect(route(9, 0, "insertTab:", listed: []) == .ignore)
        // An unbound arrow moves the caret in the field, which is harmless.
        #expect(route(57_353, 0, "moveDown:", listed: []) == .native)
    }

    @Test("a user's binding wins over the field's own edit of the same chord")
    func userBindingWinsOverLineEdit() {
        let listed = PickerQueryFieldTests.listed.union([[119, 2]])

        #expect(route(119, 2, "noop:", listed: listed) == .forward(KeyPressIdentity(codepoint: 119, modifiers: 2)))
    }

    @Test("a key event has the identity the editor view sends for it", arguments: [
        // key code, characters ignoring modifiers, flags, codepoint, modifiers
        (UInt16(38), "j", NSEvent.ModifierFlags.control, UInt32(106), UInt8(2)),
        (47, ".", .control, 46, 2),
        // Shift is in the character, not in the modifier bits, for a Control chord.
        (38, "J", [.control, .shift], 74, 2),
        (36, "\r", [], 13, 0),
        (53, "\u{1b}", [], 27, 0),
        (125, "\u{F701}", [.function, .numericPad], 57_353, 0),
        (125, "\u{F701}", [.shift, .function, .numericPad], 57_353, 1),
        (121, "\u{F72D}", .function, 57_363, 0)
    ] as [(UInt16, String, NSEvent.ModifierFlags, UInt32, UInt8)])
    func keyPressIdentity(keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags, codepoint: UInt32, modifiers: UInt8) {
        #expect(KeyPressIdentity.command(keyCode: keyCode, charactersIgnoringModifiers: characters, flags: flags) == KeyPressIdentity(codepoint: codepoint, modifiers: modifiers))
    }

    @Test("plain text, Option and Command combinations have no command identity: they are text or belong to the menus")
    func textHasNoCommandIdentity() {
        #expect(KeyPressIdentity.command(keyCode: 38, charactersIgnoringModifiers: "j", flags: []) == nil)
        #expect(KeyPressIdentity.command(keyCode: 38, charactersIgnoringModifiers: "j", flags: .option) == nil)
        #expect(KeyPressIdentity.command(keyCode: 9, charactersIgnoringModifiers: "v", flags: .command) == nil)
        #expect(KeyPressIdentity.command(keyCode: 9, charactersIgnoringModifiers: "v", flags: [.control, .command]) == nil)
    }

    @Test("dragging picker text cannot move the window")
    @MainActor func windowDragSuppression() {
        #expect(PickerNSTextField().mouseDownCanMoveWindow == false)
    }
}
