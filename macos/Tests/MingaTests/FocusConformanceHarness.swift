import AppKit
import MingaProtocol
import MingaUI
import SwiftUI
import Testing

/// Replays native events through the production policy and a real offscreen responder chain.
@MainActor
final class FocusConformanceHarness {
    static let eventMethods: [String: String] = [
        "window_did_become_key": "windowDidBecomeKey",
        "native_modal_began": "beginNativeModal",
        "native_modal_ended": "endNativeModalAndRestore",
        "native_modal_restored": "restoreAfterNativeModal",
        "swiftui_hierarchy_rebuilt": "swiftUIUpdateDidOccur",
        "file_drop_completed": "fileDropDidComplete",
        "pointer_returned": "pointerReturnedToEditor",
        "agent_overlay_visibility_changed": "agentOverlayVisibilityDidChange",
        "local_text_editing_began": "beginLocalTextEditing",
        "local_text_editing_ended": "endLocalTextEditing",
        "responder_registered": "register",
        "responder_unregistered": "unregister",
        "native_text_editing_ended": "nativeTextEditingDidEnd",
        "first_frame_rendered": "firstFrameDidRender"
    ]

    let window: NSWindow
    let policy: EditorFocusPolicy
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 360))
    private let editor = FocusConformanceEditor(frame: NSRect(x: 0, y: 240, width: 400, height: 100))
    private let picker = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    private let search = NSTextField(frame: NSRect(x: 0, y: 40, width: 200, height: 24))
    private let inline = NSTextField(frame: NSRect(x: 0, y: 80, width: 200, height: 24))
    private var localHost: NSHostingView<FocusConformanceLocalField>?

    init(unregistered: Set<String>) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        policy = EditorFocusPolicy(editorView: editor, focusOwnerState: FocusOwnerState())
        window.contentView = container
        for view in [editor, picker, search, inline] { container.addSubview(view) }
        policy.attach(to: window)
        for (name, kind) in Self.responderKinds where !unregistered.contains(name) {
            if let field = field(for: kind) { policy.register(field, as: kind) }
        }
    }

    func close() {
        policy.detach()
        localHost = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Lets deferred policy and SwiftUI work settle without bypassing the policy's public API.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func perform(event: String, args: [String: Any]) async throws {
        switch event {
        case "window_did_become_key":
            window.makeKey()
            policy.windowDidBecomeKey()
        case "native_modal_began": policy.beginNativeModal()
        case "native_modal_ended": policy.endNativeModalAndRestore()
        case "native_modal_restored": policy.restoreAfterNativeModal()
        case "swiftui_hierarchy_rebuilt": policy.swiftUIUpdateDidOccur()
        case "file_drop_completed": policy.fileDropDidComplete()
        case "pointer_returned": policy.pointerReturnedToEditor()
        case "agent_overlay_visibility_changed":
            let visible = try #require(args["visible"] as? Bool)
            policy.agentOverlayVisibilityDidChange(visible)
        case "local_text_editing_began":
            let lease = try localLease(args)
            let host = NSHostingView(rootView: FocusConformanceLocalField(policy: policy, lease: lease))
            host.frame = NSRect(x: 0, y: 120, width: 240, height: 30)
            localHost = host
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            policy.beginLocalTextEditing(lease)
        case "local_text_editing_ended":
            let lease = try localLease(args)
            if let host = localHost {
                window.endEditing(for: host)
                host.removeFromSuperview()
            }
            localHost = nil
            policy.endLocalTextEditing(lease)
        case "responder_registered":
            let kind = try responderKind(args)
            let field = try #require(self.field(for: kind))
            if field.superview == nil { container.addSubview(field) }
            policy.register(field, as: kind)
        case "responder_unregistered":
            let kind = try responderKind(args)
            let field = try #require(self.field(for: kind))
            policy.unregister(field, as: kind)
            window.endEditing(for: field)
            field.removeFromSuperview()
        case "native_text_editing_ended":
            window.endEditing(for: nil)
            policy.nativeTextEditingDidEnd()
        case "first_frame_rendered": policy.firstFrameDidRender()
        default: throw ConformanceError.badTranscript("unknown native_event \(event)")
        }
        await settle()
    }

    var firstResponder: String {
        if hasFocus(editor) { return "editor_view" }
        if hasFocus(picker) { return "picker_query" }
        if hasFocus(search) { return "search_query" }
        if hasFocus(inline) { return "inline_edit" }
        if let host = localHost, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: host) { return "local_text_field" }
        if localHost != nil, let editor = window.firstResponder as? NSTextView,
           let field = editor.delegate as? NSView, let host = localHost,
           field.isDescendant(of: host) { return "local_text_field" }
        return window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil"
    }

    private func hasFocus(_ view: NSView) -> Bool {
        if window.firstResponder === view { return true }
        guard let field = view as? NSTextField, let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    private static let responderKinds: [String: Wire.FocusOwner.Responder] = [
        "picker_query": .pickerQuery, "search_query": .searchQuery, "inline_edit": .inlineEdit
    ]

    private func responderKind(_ args: [String: Any]) throws -> Wire.FocusOwner.Responder {
        let name = try #require(args["kind"] as? String)
        return try #require(Self.responderKinds[name])
    }

    private func field(for kind: Wire.FocusOwner.Responder) -> NSTextField? {
        switch kind {
        case .editorView: nil
        case .pickerQuery: picker
        case .searchQuery: search
        case .inlineEdit: inline
        }
    }

    private func localLease(_ args: [String: Any]) throws -> LocalTextEditing {
        switch args["kind"] as? String {
        case "workspace_rename": .workspaceRename(1)
        case "workspace_icon_search": .workspaceIconSearch
        default: throw ConformanceError.badTranscript("invalid local text lease")
        }
    }
}

private final class FocusConformanceEditor: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Uses the same read-only policy mirror as frontend-local workspace text fields.
private struct FocusConformanceLocalField: View {
    let policy: EditorFocusPolicy
    let lease: LocalTextEditing
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Local text", text: $text)
            .focused($focused)
            .onChange(of: policy.focusOwnerState.localTextEditing, initial: true) { _, editing in
                focused = editing == lease
            }
    }
}

@Suite("Focus lifecycle conformance")
struct FocusLifecycleConformanceTests {
    @Test("every public focus lifecycle entry point has a replayed native event")
    @MainActor
    func lifecycleCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Views/Editor/EditorFocusPolicy.swift"), encoding: .utf8)
        // Stop at the policy's top-level closing brace, not the diagnostic helper that follows it.
        let policySource = source.components(separatedBy: "\n}").first ?? source
        let pattern = try NSRegularExpression(pattern: #"(?m)^    (?:(?:public|internal|static|final|nonisolated)\s+)*func (\w+)\("#)
        let text = policySource as NSString
        let methods = Set(pattern.matches(in: policySource, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) })
        // Queries, attachment lifetime, key routing, and committed-frame input have separate contracts.
        let excluded: Set<String> = ["nativeTextEditingIsActive", "presentationFocusReady", "requestAccessibilityFocus", "requestPresentationFocus", "routeAgentOverlayEvent", "attach", "detach", "focusOwnerDidChange", "shouldYieldSystemCommandShortcut"]
        let mapped = Set(FocusConformanceHarness.eventMethods.values)
        #expect(methods.subtracting(excluded) == mapped, "unmapped lifecycle methods: \(methods.subtracting(excluded).subtracting(mapped)); obsolete mappings: \(mapped.subtracting(methods))")
        var recorded: Set<String> = []
        let entries = ConformanceTranscriptTests.loadIndex().filter { $0.category == "focus" && !$0.go }
        #expect(!entries.isEmpty, "missing focus corpus; run mix conformance.gen")
        for entry in entries {
            for step in try ConformanceTranscriptTests.loadSteps(entry.file) where step["kind"] as? String == "native_event" {
                let event = try #require(step["event"] as? String)
                recorded.insert(event)
            }
        }
        #expect(recorded == Set(FocusConformanceHarness.eventMethods.keys), "missing lifecycle transcripts: \(Set(FocusConformanceHarness.eventMethods.keys).subtracting(recorded)); unmapped events: \(recorded.subtracting(FocusConformanceHarness.eventMethods.keys))")
    }
}
