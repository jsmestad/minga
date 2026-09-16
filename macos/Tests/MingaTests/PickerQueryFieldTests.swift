import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MingaUI

@Suite("Picker Native Query Editing")
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
        let encoder = SpyEncoder()
        let style = InlineEditFieldStyle(textColor: .primary, selectionBackgroundColor: .accentColor, selectionForegroundColor: .primary, insertionPointColor: .accentColor)
        let coordinator = PickerQueryField.Coordinator(encoder: encoder, style: style)
        let field = PickerNSTextField()
        let editor = NSTextView()
        field.isEditable = true
        let path = "/tmp/Folder Name/résumé.txt"

        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 0, authoritativeText: "")
        field.stringValue = path
        editor.string = path
        coordinator.handleTextChange(field: field, editor: editor)

        #expect(encoder.pickerQueryCalls == [SpyEncoder.PickerQuery(generation: 7, editSeq: 1, text: path)])

        editor.setSelectedRange(NSRange(location: 1, length: 2))
        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 0, authoritativeText: "")
        #expect(field.stringValue == path)
        #expect(editor.string == path)
        #expect(editor.selectedRange() == NSRange(location: 1, length: 2))
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
            fallbackEncoder.sendExecuteCommand(name: "select_all")
        }

        #expect(encoder.guiActions == [.executeCommand(name: "select_all")])
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

        #expect(encoder.guiActions.isEmpty)
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

    @Test("picker control bindings are forwarded while command editing shortcuts remain native")
    func keyRouting() {
        #expect(PickerQueryKeyRouting.controlBinding(characters: "d", modifiers: .control) == PickerQueryKeyCommand(codepoint: 100, modifiers: 0x02))
        #expect(PickerQueryKeyRouting.controlBinding(characters: "v", modifiers: .option) == PickerQueryKeyCommand(codepoint: 118, modifiers: 0x04))
        #expect(PickerQueryKeyRouting.controlBinding(characters: "v", modifiers: .command) == nil)
        #expect(PickerQueryKeyRouting.selectorBinding("moveDown:", fieldIsEmpty: false) == PickerQueryKeyCommand(codepoint: 57_353, modifiers: 0))
        #expect(PickerQueryKeyRouting.selectorBinding("deleteBackward:", fieldIsEmpty: true) == PickerQueryKeyCommand(codepoint: 127, modifiers: 0))
        #expect(PickerQueryKeyRouting.selectorBinding("deleteBackward:", fieldIsEmpty: false) == nil)
    }

    @Test("dragging picker text cannot move the window")
    @MainActor func windowDragSuppression() {
        #expect(PickerNSTextField().mouseDownCanMoveWindow == false)
    }
}
