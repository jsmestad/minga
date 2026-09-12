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

        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 0, authoritativeText: "")
        field.stringValue = "café"
        editor.string = "café"
        coordinator.handleTextChange(field: field, editor: editor)

        #expect(encoder.pickerQueryCalls == [SpyEncoder.PickerQuery(generation: 7, editSeq: 1, text: "café")])

        editor.setSelectedRange(NSRange(location: 1, length: 2))
        coordinator.reconcile(field: field, editor: editor, generation: 7, acknowledgedSequence: 0, authoritativeText: "")
        #expect(field.stringValue == "café")
        #expect(editor.string == "café")
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

    @Test("menu undo and redo use semantic editor commands outside native fields")
    @MainActor func menuUndoRedoEditorFallback() {
        let encoder = SpyEncoder()
        let editorResponder = NSView()

        NativeMenuHistoryRouter.route(.undo, encoder: encoder, responder: editorResponder) { _, _ in
            Issue.record("The editor surface must not use native text history")
            return true
        }
        NativeMenuHistoryRouter.route(.redo, encoder: encoder, responder: editorResponder) { _, _ in
            Issue.record("The editor surface must not use native text history")
            return true
        }

        #expect(encoder.guiActions == [
            .executeCommand(name: "undo"),
            .executeCommand(name: "redo")
        ])
        #expect(encoder.keyPressCalls.isEmpty)
    }

    @Test("menu undo and redo remain native for picker and Settings field editors")
    @MainActor func menuUndoRedoNativeFieldOwnership() {
        let encoder = SpyEncoder()
        let pickerQueryFieldEditor = NSTextView()
        let settingsSearchFieldEditor = NSTextView()

        for fieldEditor in [pickerQueryFieldEditor, settingsSearchFieldEditor] {
            var routedSelectors: [String] = []

            NativeMenuHistoryRouter.route(.undo, encoder: encoder, responder: fieldEditor) { selector, target in
                #expect(target === fieldEditor)
                routedSelectors.append(NSStringFromSelector(selector))
                return false
            }
            NativeMenuHistoryRouter.route(.redo, encoder: encoder, responder: fieldEditor) { selector, target in
                #expect(target === fieldEditor)
                routedSelectors.append(NSStringFromSelector(selector))
                return false
            }

            #expect(routedSelectors == ["undo:", "redo:"])
        }

        #expect(encoder.guiActions.isEmpty)
        #expect(encoder.keyPressCalls.isEmpty)
    }

    @Test("disconnected editor fallback is harmless")
    @MainActor func disconnectedEditorFallback() {
        NativeMenuHistoryRouter.route(.undo, encoder: nil, responder: nil) { _, _ in
            Issue.record("No native responder is available")
            return true
        }
        NativeMenuHistoryRouter.route(.redo, encoder: nil, responder: NSView()) { _, _ in
            Issue.record("The editor surface must not use native text history")
            return true
        }
    }

    @Test("disconnected editor preserves native field history ownership")
    @MainActor func disconnectedNativeFieldOwnership() {
        let fieldEditor = NSTextView()
        var routedSelectors: [String] = []

        NativeMenuHistoryRouter.route(.undo, encoder: nil, responder: fieldEditor) { selector, target in
            #expect(target === fieldEditor)
            routedSelectors.append(NSStringFromSelector(selector))
            return true
        }
        NativeMenuHistoryRouter.route(.redo, encoder: nil, responder: fieldEditor) { selector, target in
            #expect(target === fieldEditor)
            routedSelectors.append(NSStringFromSelector(selector))
            return true
        }

        #expect(routedSelectors == ["undo:", "redo:"])
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
