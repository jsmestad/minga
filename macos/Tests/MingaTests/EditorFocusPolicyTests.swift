import AppKit
import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing

/// Uses real offscreen AppKit windows and field editors, not mocked responders.
@Suite("Editor focus policy", .serialized)
@MainActor
struct EditorFocusPolicyTests {
    @Test("an owner decoded before picker registration is applied when the window becomes key")
    func pickerBeforeKeyWindow() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        #expect(!fixture.window.isKeyWindow)
        fixture.policy.focusOwnerDidChange(owner(.pickerQuery, surface: 8, generation: 41))
        #expect(fixture.policy.pendingOwnerApply)
        fixture.policy.register(fixture.picker, as: .pickerQuery)
        fixture.window.makeKey()
        fixture.policy.windowDidBecomeKey()
        await settle()
        #expect(fixture.hasFocus(fixture.picker))
        #expect(!fixture.hasFocus(fixture.editor))
    }

    @Test("a native modal ending over a BEAM prompt restores the named editor responder")
    func promptAfterNativeModal() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try #require(fixture.window.makeFirstResponder(fixture.editor))
        fixture.policy.beginNativeModal()
        try #require(fixture.window.makeFirstResponder(nil))
        fixture.policy.focusOwnerDidChange(owner(.editorView, surface: 7))
        #expect(fixture.policy.pendingOwnerApply)
        #expect(!fixture.hasFocus(fixture.editor))
        fixture.policy.endNativeModalAndRestore()
        #expect(fixture.hasFocus(fixture.editor))
        #expect(fixture.state.decodedOwner?.surface == 7)
    }

    @Test("SwiftUI rebuild reclaims inline edit and old dismantle cannot unregister the replacement")
    func inlineHierarchyRebuild() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.register(fixture.inline, as: .inlineEdit)
        fixture.policy.focusOwnerDidChange(owner(.inlineEdit, surface: 5))
        try #require(fixture.hasFocus(fixture.inline))
        let replacement = NSTextField(frame: NSRect(x: 0, y: 120, width: 200, height: 24))
        fixture.container.addSubview(replacement)
        fixture.policy.register(replacement, as: .inlineEdit)
        fixture.policy.unregister(fixture.inline, as: .inlineEdit)
        fixture.window.endEditing(for: fixture.inline)
        try #require(fixture.window.makeFirstResponder(nil))
        fixture.inline.removeFromSuperview()
        fixture.policy.swiftUIUpdateDidOccur()
        await settle()
        #expect(fixture.hasFocus(replacement))
        #expect(!fixture.policy.pendingOwnerApply)
    }

    @Test("a keyframe with an unchanged owner restores first responder after frontend focus loss")
    func keyframeRestoresOwner() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.register(fixture.search, as: .searchQuery)
        let decoded = owner(.searchQuery, surface: 11, generation: 7)
        fixture.policy.focusOwnerDidChange(decoded)
        try #require(fixture.hasFocus(fixture.search))
        try #require(fixture.window.makeFirstResponder(nil))
        fixture.policy.focusOwnerDidChange(decoded)
        #expect(fixture.hasFocus(fixture.search))
        #expect(fixture.state.decodedOwner?.generation == 7)
    }

    @Test("an owner change during native field editing waits until editing ends")
    func nativeFieldDefersOwner() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.register(fixture.picker, as: .pickerQuery)
        fixture.policy.register(fixture.search, as: .searchQuery)
        fixture.policy.focusOwnerDidChange(owner(.pickerQuery, surface: 8))
        try #require(fixture.hasFocus(fixture.picker))
        try #require(fixture.window.firstResponder is NSText)
        fixture.policy.focusOwnerDidChange(owner(.searchQuery, surface: 11))
        #expect(fixture.hasFocus(fixture.picker))
        #expect(fixture.policy.pendingOwnerApply)
        fixture.window.endEditing(for: fixture.picker)
        try #require(fixture.window.makeFirstResponder(nil))
        fixture.policy.nativeTextEditingDidEnd()
        await settle()
        #expect(fixture.hasFocus(fixture.search))
    }

    @Test("dismantling a modeled text field ends its native editor and applies the pending owner")
    func dismantlingFieldAppliesPendingOwner() async throws {
        for kind in [Wire.FocusOwner.Responder.pickerQuery, .searchQuery, .inlineEdit] {
            let fixture = Fixture()
            defer { fixture.close() }
            let field: NSTextField
            let surface: UInt8
            switch kind {
            case .pickerQuery: field = fixture.picker; surface = 8
            case .searchQuery: field = fixture.search; surface = 11
            case .inlineEdit: field = fixture.inline; surface = 5
            case .editorView: return
            }
            fixture.policy.register(field, as: kind)
            fixture.policy.focusOwnerDidChange(owner(kind, surface: surface))
            try #require(fixture.hasFocus(field))
            fixture.policy.focusOwnerDidChange(owner(.editorView, surface: 0))
            #expect(fixture.hasFocus(field))
            fixture.policy.unregister(field, as: kind)
            fixture.window.endEditing(for: field)
            field.removeFromSuperview()
            fixture.policy.nativeTextEditingDidEnd()
            await settle()
            // No test-only responder write: the production dismantle sequence must suffice.
            #expect(fixture.hasFocus(fixture.editor))
            #expect(!fixture.policy.pendingOwnerApply)
        }
    }

    @Test("marked native text survives owner changes and composition finishing does not end the text lease")
    func markedTextDefersOwner() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.register(fixture.picker, as: .pickerQuery)
        fixture.policy.focusOwnerDidChange(owner(.pickerQuery, surface: 8))
        let fieldEditor = try #require(fixture.picker.currentEditor() as? NSTextView)
        fieldEditor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(fieldEditor.hasMarkedText())
        fixture.policy.focusOwnerDidChange(owner(.editorView, surface: 0))
        #expect(fixture.window.firstResponder === fieldEditor)
        #expect(fieldEditor.hasMarkedText())
        fieldEditor.unmarkText()
        fixture.policy.swiftUIUpdateDidOccur()
        await settle()
        #expect(fixture.window.firstResponder === fieldEditor)
        fixture.window.endEditing(for: fixture.picker)
        try #require(fixture.window.makeFirstResponder(nil))
        fixture.policy.nativeTextEditingDidEnd()
        await settle()
        #expect(fixture.hasFocus(fixture.editor))
    }

    @Test("workspace rename and icon search leases keep the latest decoded owner pending")
    func localLeasesDeferLatestOwner() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.register(fixture.search, as: .searchQuery)
        for lease in [LocalTextEditing.workspaceRename(42), .workspaceIconSearch] {
            fixture.policy.beginLocalTextEditing(lease)
            #expect(fixture.state.localTextEditing == lease)
            try #require(fixture.window.makeFirstResponder(fixture.picker))
            fixture.policy.focusOwnerDidChange(owner(.editorView, surface: 7))
            fixture.policy.focusOwnerDidChange(owner(.searchQuery, surface: 11, generation: 9))
            #expect(fixture.hasFocus(fixture.picker))
            #expect(fixture.policy.pendingOwnerApply)
            fixture.policy.endLocalTextEditing(.workspaceRename(99))
            #expect(fixture.state.localTextEditing == lease)
            fixture.window.endEditing(for: fixture.picker)
            try #require(fixture.window.makeFirstResponder(nil))
            fixture.policy.endLocalTextEditing(lease)
            await settle()
            #expect(fixture.state.localTextEditing == nil)
            #expect(fixture.hasFocus(fixture.search))
            #expect(fixture.state.decodedOwner?.generation == 9)
            try #require(fixture.window.makeFirstResponder(nil))
        }
    }

    @Test("production icon search takes an immediate SwiftUI focus mirror lease")
    func iconSearchMirrorFocusesNativeField() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.focusOwnerDidChange(owner(.editorView, surface: 0))
        let root = WorkspaceIconPicker(currentIcon: "folder", accentColor: .blue, onSelect: { _ in })
            .environment(\.editorFocusPolicy, fixture.policy)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 320)
        fixture.container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        await settle()
        #expect(fixture.state.localTextEditing == .workspaceIconSearch)
        #expect(fixture.window.firstResponder is NSText)
        let firstResponder = fixture.window.firstResponder
        fixture.policy.focusOwnerDidChange(owner(.editorView, surface: 7))
        #expect(fixture.window.firstResponder === firstResponder)
        #expect(fixture.policy.pendingOwnerApply)
        host.removeFromSuperview()
        fixture.policy.endLocalTextEditing(.workspaceIconSearch)
        try #require(fixture.window.makeFirstResponder(nil))
        fixture.policy.nativeTextEditingDidEnd()
        await settle()
        #expect(fixture.hasFocus(fixture.editor))
    }

    @Test("nested native modal and agent visibility lifecycle never infer an editor owner")
    func lifecycleAppliesOnlyDecodedOwner() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.register(fixture.inline, as: .inlineEdit)
        fixture.policy.beginNativeModal()
        fixture.policy.beginNativeModal()
        fixture.policy.focusOwnerDidChange(owner(.inlineEdit, surface: 5))
        fixture.policy.endNativeModalAndRestore()
        #expect(!fixture.hasFocus(fixture.inline))
        fixture.policy.endNativeModalAndRestore()
        try #require(fixture.hasFocus(fixture.inline))
        try #require(fixture.window.makeFirstResponder(nil))
        fixture.policy.agentOverlayVisibilityDidChange(true)
        fixture.policy.agentOverlayVisibilityDidChange(false)
        fixture.policy.fileDropDidComplete()
        fixture.policy.pointerReturnedToEditor()
        await settle()
        #expect(fixture.hasFocus(fixture.inline))
    }

    @Test("production inline rename selects the filename stem before the first keystroke")
    func inlineStemSelectionPrecedesTyping() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.focusOwnerDidChange(owner(.inlineEdit, surface: 5))
        let recorder = InlineCompletionRecorder()
        let host = mountProductionField(
            productionField(.inlineEdit, policy: fixture.policy, text: "original.swift", recorder: recorder),
            in: fixture
        )
        let field = try await waitForNativeField(in: host)
        try await waitForFocus(field, in: fixture)
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 8))
        editor.insertText("renamed", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "renamed.swift")
        #expect(recorder.commits.isEmpty)
        #expect(recorder.cancellations == 0)
    }

    @Test("production inline hierarchy rebuild does not submit the retiring edit and genuine Return still submits")
    func productionInlineRebuildDoesNotCommit() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.policy.focusOwnerDidChange(owner(.inlineEdit, surface: 5))
        let recorder = InlineCompletionRecorder()
        let host = mountProductionField(
            productionField(.inlineEdit, policy: fixture.policy, text: "original.swift", recorder: recorder),
            in: fixture
        )
        let original = try await waitForNativeField(in: host)
        try await waitForFocus(original, in: fixture)
        let originalEditor = try #require(original.currentEditor() as? NSTextView)
        originalEditor.insertText("edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        let editedText = originalEditor.string
        #expect(editedText == "edited.swift")

        host.rootView = productionField(
            .inlineEdit, policy: fixture.policy, text: editedText, identity: 1, recorder: recorder
        )
        let replacement = try await waitForNativeField(in: host, differentFrom: original)
        try await waitForFocus(replacement, in: fixture)
        #expect(replacement.stringValue == editedText)
        #expect(recorder.commits.isEmpty)
        #expect(recorder.cancellations == 0)

        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        fixture.window.sendEvent(enter)
        await settle()
        #expect(recorder.commits == [editedText])
        #expect(recorder.cancellations == 0)
    }

    @Test("all production native fields register existing views when focus policy is injected late")
    func productionFieldsRegisterAfterLateInjection() async throws {
        let rows: [(Wire.FocusOwner.Responder, UInt8)] = [
            (.inlineEdit, 5), (.pickerQuery, 8), (.searchQuery, 11)
        ]
        for (kind, surface) in rows {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.policy.focusOwnerDidChange(owner(kind, surface: surface))
            let recorder = InlineCompletionRecorder()
            let host = mountProductionField(
                productionField(kind, policy: nil, text: "query.swift", recorder: recorder),
                in: fixture
            )
            let original = try await waitForNativeField(in: host)
            try #require(fixture.window.makeFirstResponder(fixture.editor))
            #expect(fixture.policy.pendingOwnerApply)
            host.rootView = productionField(
                kind, policy: fixture.policy, text: "query.swift", recorder: recorder
            )
            try await waitForFocus(original, in: fixture)
            let current = try await waitForNativeField(in: host)
            #expect(current === original)
            #expect(!fixture.policy.pendingOwnerApply)
            #expect(recorder.commits.isEmpty)
            #expect(recorder.cancellations == 0)
        }
    }

    private func productionField(
        _ kind: Wire.FocusOwner.Responder, policy: (any EditorFocusControlling)?,
        text: String, identity: Int = 0, recorder: InlineCompletionRecorder
    ) -> ProductionFieldHost {
        ProductionFieldHost(
            kind: kind, policy: policy, text: text, identity: identity,
            searchState: SearchState(),
            onCommit: { recorder.commits.append($0) },
            onCancel: { recorder.cancellations += 1 }
        )
    }

    private func mountProductionField(
        _ root: ProductionFieldHost, in fixture: Fixture
    ) -> NSHostingView<ProductionFieldHost> {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 120, width: 300, height: 40)
        fixture.container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func nativeFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { nativeFields(in: $0) }
    }

    private func waitForNativeField(
        in host: NSView, differentFrom old: NSTextField? = nil
    ) async throws -> NSTextField {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let field = nativeFields(in: host).first(where: { $0 !== old }) { return field }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(nativeFields(in: host).first(where: { $0 !== old }))
    }

    private func waitForFocus(_ field: NSTextField, in fixture: Fixture) async throws {
        for _ in 0..<100 {
            if fixture.hasFocus(field) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(fixture.hasFocus(field))
    }

    @MainActor
    private final class InlineCompletionRecorder {
        var commits: [String] = []
        var cancellations = 0
    }

    @MainActor
    private struct ProductionFieldHost: View {
        let kind: Wire.FocusOwner.Responder
        let policy: (any EditorFocusControlling)?
        let text: String
        let identity: Int
        let searchState: SearchState
        let onCommit: (String) -> Void
        let onCancel: () -> Void

        private var style: InlineEditFieldStyle {
            InlineEditFieldStyle(
                textColor: .white, selectionBackgroundColor: .blue,
                selectionForegroundColor: .white, insertionPointColor: .white
            )
        }

        var body: some View {
            Group {
                switch kind {
                case .inlineEdit:
                    InlineEditField(
                        initialText: text, selectStem: true, style: style,
                        onCommit: onCommit, onCancel: onCancel
                    )
                case .pickerQuery:
                    PickerQueryField(
                        authoritativeText: text, generation: 1, acknowledgedEditSequence: 0,
                        placeholder: "Query", isEditable: true, style: style, sendAction: { _ in }
                    )
                case .searchQuery:
                    SearchQueryField(searchState: searchState, style: style, sendAction: { _ in })
                case .editorView:
                    EmptyView()
                }
            }
            .id(identity)
            .environment(\.editorFocusPolicy, policy)
        }
    }

    private func owner(_ responder: Wire.FocusOwner.Responder, surface: UInt8, generation: UInt32 = 0) -> Wire.FocusOwner {
        Wire.FocusOwner(responder: responder.rawValue, surface: surface, windowID: 1, generation: generation)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 360))
        let editor = FocusableEditorSurface(frame: NSRect(x: 0, y: 240, width: 400, height: 100))
        let picker = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let search = NSTextField(frame: NSRect(x: 0, y: 40, width: 200, height: 24))
        let inline = NSTextField(frame: NSRect(x: 0, y: 80, width: 200, height: 24))
        let state = FocusOwnerState()
        let policy: EditorFocusPolicy

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            policy = EditorFocusPolicy(editorView: editor, focusOwnerState: state)
            window.contentView = container
            let views: [NSView] = [editor, picker, search, inline]
            for view in views { container.addSubview(view) }
            policy.attach(to: window)
        }

        func hasFocus(_ view: NSView) -> Bool {
            if window.firstResponder === view { return true }
            guard let field = view as? NSTextField, let fieldEditor = field.currentEditor() else { return false }
            return window.firstResponder === fieldEditor
        }

        func close() {
            policy.detach()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    /// An actual AppKit view with the same responder acceptance as EditorNSView.
    private final class FocusableEditorSurface: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
