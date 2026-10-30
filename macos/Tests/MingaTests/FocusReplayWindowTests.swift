import AppKit
import Foundation
import SwiftUI
import Testing
import MingaProtocol
import MingaUI

/// Uses production ContentView, EditorNSView and all three registered native
/// fields. No accessibility permission, signed release app or synthetic fields.
@Suite("Focus corpus in a production window", .serialized)
@MainActor
struct FocusReplayWindowTests {
    @Test("focus scenarios are enumerated for both consumers")
    func corpusIsEnumerated() {
        let entries = ConformanceTranscriptTests.loadIndex().filter { $0.category == "focus" && $0.go }
        #expect(Set(entries.map(\.name)) == [
            "picker_open_close", "search_open_close", "rename_confirm", "rename_cancel",
            "agent_toggle", "reattach_keyframe", "hover_and_empty"
        ])
        #expect(entries.allSatisfy { $0.swift && $0.go })
    }

    @Test("same shared frames establish responder and AX identity", arguments: conformanceSwiftEntries.filter { $0.category == "focus" && $0.go })
    func replay(_ entry: ConformanceIndexEntry) async throws {
        let application = try FocusTestApplicationScope(entry.name)
        defer { application.close() }
        var context = try FocusReplayWindowContext()
        defer { context.close() }
        try await context.waitUntilAttached()

        for (index, step) in try ConformanceTranscriptTests.loadSteps(entry.file).enumerated() {
            if step["reset_frontend"] as? Bool == true {
                context.close()
                context = try FocusReplayWindowContext()
                #expect(context.gui.focusOwnerState.decodedOwner == nil)
                #expect(context.editor.focusPolicy.decodedOwner == nil)
                try await context.waitUntilAttached()
            }
            let gui = context.gui
            let dispatcher = context.dispatcher
            let editor = context.editor
            let host = context.host
            let window = context.window
            let encoded = try #require(step["payload_base64"] as? String)
            let payload = try #require(Data(base64Encoded: encoded))
            dispatcher.dispatch(try decodeFrame(from: payload))
            let snapshot = try #require(dispatcher.committedEditorSnapshot)
            dispatcher.promoteVisibleEditorSnapshot(snapshot)
            if !context.firstFrameRendered {
                context.firstFrameRendered = true
                editor.focusPolicy.firstFrameDidRender()
                // MingaApp requests presentation focus after dismissing its first-frame overlay.
                // Reproduce that startup event once after attachment, rather than repairing focus while polling.
                let requested = editor.focusPolicy.requestPresentationFocus()
                print("[Focus \(entry.name) step \(index)] presentationRequested=\(requested) \(application.diagnostics)")
            }
            let expect = try #require(step["expect"] as? [String: Any])
            let target = try #require(expect["focus_target"] as? [String: Any])
            ConformanceTranscriptTests.assertFocusTarget(expect, gui: gui, index: index, name: entry.name)
            let kind = try #require(target["responder"] as? String)
            let responder = try await settle(kind: kind, editor: editor, host: host, window: window, application: application)
            try assertIdentity(responder, kind: kind, editor: editor, window: window)

            // Explicit lifecycle replay is separate from observing the frame's
            // production registration/update hooks establish focus above.
            editor.focusPolicy.beginNativeModal()
            editor.focusPolicy.beginNativeModal()
            window.endEditing(for: responder)
            try #require(window.makeFirstResponder(nil))
            editor.focusPolicy.pointerReturnedToEditor()
            #expect(!hasFocus(responder, in: window))
            editor.focusPolicy.endNativeModalAndRestore()
            #expect(!hasFocus(responder, in: window), "Nested modal must still suspend application")
            editor.focusPolicy.endNativeModalAndRestore()
            editor.focusPolicy.windowDidBecomeKey()
            editor.focusPolicy.pointerReturnedToEditor()
            editor.focusPolicy.fileDropDidComplete()
            _ = try await settle(kind: kind, editor: editor, host: host, window: window, application: application)
            try assertIdentity(responder, kind: kind, editor: editor, window: window)
        }
    }

    private func settle(
        kind: String, editor: EditorNSView, host: NSView, window: NSWindow,
        application: FocusTestApplicationScope
    ) async throws -> NSView {
        for _ in 0..<100 {
            if NSApp.isActive, window.isKeyWindow,
               let target = responder(kind: kind, editor: editor, host: host),
               target.window === window, hasFocus(target, in: window) {
                return target
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let target = try #require(responder(kind: kind, editor: editor, host: host), "Production field did not register: \(kind)")
        try #require(
            NSApp.isActive && window.isKeyWindow,
            "Production replay requires active/key presentation; visible=\(window.isVisible) canBecomeKey=\(window.canBecomeKey): \(application.diagnostics)"
        )
        try #require(target.window === window, "Committed responder must belong to the replay window")
        try #require(
            hasFocus(target, in: window),
            "Committed responder not focused: \(kind); attached=\(editor.window === window) visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive) pending=\(editor.focusPolicy.pendingOwnerApply) firstResponder=\(String(describing: window.firstResponder))"
        )
        return target
    }

    private func responder(kind: String, editor: EditorNSView, host: NSView) -> NSView? {
        if kind == "editor_view" { return editor }
        let identifiers = ["picker_query": "minga.picker.query", "search_query": "minga.search.query", "inline_edit": "minga.file-tree.inline-edit"]
        guard let identifier = identifiers[kind] else { return nil }
        return nativeFields(in: host).first { $0.accessibilityIdentifier() == identifier }
    }

    private func nativeFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { nativeFields(in: $0) }
    }

    private func hasFocus(_ target: NSView, in window: NSWindow) -> Bool {
        if window.firstResponder === target { return true }
        guard let field = target as? NSTextField, let fieldEditor = field.currentEditor() else { return false }
        return window.firstResponder === fieldEditor
    }

    private func assertIdentity(_ target: NSView, kind: String, editor: EditorNSView, window: NSWindow) throws {
        try #require(NSApp.isActive && window.isKeyWindow, "AX identity requires the actual active key window")
        try #require(target.window === window)
        #expect(hasFocus(target, in: window), "First responder must belong to \(kind)")
        if target === editor {
            let panes = try #require(editor.accessibilityChildren() as? [EditorPaneAccessibilityElement])
            let pane = try #require(panes.first)
            #expect(editor.accessibilityFocusedUIElement as? EditorPaneAccessibilityElement === pane)
        } else {
            let field = try #require(target as? NSTextField)
            let fieldEditor = try #require(field.currentEditor())
            #expect(window.firstResponder === fieldEditor)
            #expect(editor.accessibilityFocusedUIElement == nil)
            let selector = NSSelectorFromString("accessibilityFocusedUIElement")
            try #require(NSApp.responds(to: selector))
            let focused = NSApp.perform(selector)?.takeUnretainedValue()
            #expect(focused === field || focused === fieldEditor,
                    "AX focus must identify the same production native field as the responder")
        }
        print("[Focus identity] responder=\(kind) fieldID=\(target.accessibilityIdentifier() ?? "-") active=\(NSApp.isActive) key=\(window.isKeyWindow) owner=\(String(describing: editor.focusPolicy.decodedOwner)) firstResponder=\(String(describing: window.firstResponder))")
    }
}

/// One native consumer lifetime. Reattach replaces this entire context before
/// dispatching the keyframe, so no model, registration or responder survives.
@MainActor
private final class FocusReplayWindowContext {
    let gui: GUIState
    let dispatcher: CommandDispatcher
    let editor: EditorNSView
    let host: NSView
    let window: NSWindow
    var firstFrameRendered = false

    init() throws {
        _ = NSApplication.shared
        let gui = GUIState()
        let bridge = FocusReplayBridge()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui, applicationEffectSink: { effect in
            switch effect {
            case .focusOwnerChanged(let owner): bridge.editor?.focusPolicy.focusOwnerDidChange(owner)
            case .agentChatVisibilityChanged(let visible): bridge.editor?.setAgentChatVisible(visible)
            default: break
            }
        })
        let font = FontManager(name: "Menlo", size: 13, scale: 1)
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        let renderer = try #require(CoreTextMetalRenderer(factories: factories))
        renderer.setupRenderers(fontManager: font)
        let encoder = ClosureOutboundActionEncoder { _ in .accepted }
        let editor = EditorNSView(encoder: encoder, dispatcher: dispatcher, coreTextRenderer: renderer, fontManager: font)
        editor.editorInput = gui.editorInput
        bridge.editor = editor
        let root = ContentView(
            gui: gui, encoder: { encoder }, editorGeometry: { .preview }, chrome: .preview,
            onAgentChatVisibleChange: { editor.setAgentChatVisible($0) }
        ) { FocusReplayEditorSurface(editor: editor) }
            .environment(\.editorFocusPolicy, editor.focusPolicy)
            .focusable(false)
        let host = NSHostingView(rootView: root)
        let rect = NSRect(x: 0, y: 0, width: 900, height: 650)
        host.frame = rect
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        self.gui = gui
        self.dispatcher = dispatcher
        self.editor = editor
        self.host = host
        self.window = window
    }

    /// Production cannot receive a frame until the mounted EditorNSView has supplied its ready dimensions.
    /// NSHostingView mounts asynchronously in this standalone test window, so observe that prerequisite without laying out the hierarchy or invoking focus policy from the polling loop.
    func waitUntilAttached() async throws {
        for _ in 0..<100 {
            if editor.window === window, editor.bounds.width > 0, editor.bounds.height > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(editor.window === window, "Production EditorNSView did not attach before the first frame")
        try #require(editor.bounds.width > 0 && editor.bounds.height > 0, "Production EditorNSView has no ready dimensions")
    }

    func close() {
        editor.focusPolicy.detach()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class FocusReplayBridge {
    weak var editor: EditorNSView?
}

private struct FocusReplayEditorSurface: NSViewRepresentable {
    let editor: EditorNSView
    func makeNSView(context: Context) -> EditorNSView { editor }
    func updateNSView(_ nsView: EditorNSView, context: Context) { nsView.swiftUIUpdateDidOccur() }
}
