import MingaUI
import AppKit
import Foundation

/// Shared policy for preview screenshots and snapshot-fixture layout.
enum PreviewSnapshotPolicy {
    private static let fullShellViews: Set<String> = ["EditorChromeView", "AgentChromeView", "DiagnosticsEditorView", "InsertModeEditorView", "HoverEditorView", "SignatureHelpEditorView"]
    private static let renderedWindowViews = fullShellViews
    private static let eagerLayoutViews: Set<String> = ["GitStatusView", "FileTreeView", "FileTreeEmpty", "FileTreeError", "FileTreeDeep", "GitStatusClean", "GitStatusConflict", "GitStatusDense", "FileTreeRename", "MessagesContentView"]

    static func size(named name: String) -> CGSize {
        switch name {
        case "EditorChromeView", "AgentChromeView", "InsertModeEditorView", "HoverEditorView", "SignatureHelpEditorView": CGSize(width: 1200, height: 704)
        case "GitStatusView", "FileTreeView",
             "FileTreeEmpty", "FileTreeError", "FileTreeDeep",
             "GitStatusClean", "GitStatusConflict", "GitStatusDense": CGSize(width: 280, height: 600)
        case "CompletionOverlay": CGSize(width: 400, height: 300)
        case "StatusBarView": CGSize(width: 800, height: 28)
        case "TabBarView": CGSize(width: 800, height: 36)
        case "EmptyStateView", "EmptyStateFirstRun": CGSize(width: 900, height: 640)
        case "NotificationCenterView", "NotificationStack": CGSize(width: 800, height: 600)
        case "BottomPanelView", "BottomPanelEmpty": CGSize(width: 800, height: 250)
        case "MessagesContentView": CGSize(width: 800, height: 360)
        case "SettingsView": CGSize(width: 600, height: 480)
        case "ObservatoryView": CGSize(width: 320, height: 640)
        case "AgentChatView", "AgentChatStreaming", "AgentChatApproval", "AgentChatError", "AgentChatCompletion", "AgentChatSummary": CGSize(width: 760, height: 600)
        case "PickerOverlay": CGSize(width: 600, height: 400)
        case "MinibufferView": CGSize(width: 600, height: 140)
        case "WhichKeyOverlay", "WhichKeyPaged": CGSize(width: 520, height: 300)
        case "LatencyHUDOverlay", "LatencyHUDEmpty": CGSize(width: 520, height: 120)
        case "SearchToolbar": CGSize(width: 800, height: 40)
        case "HoverPopupOverlay": CGSize(width: 500, height: 300)
        case "SignatureHelpOverlay": CGSize(width: 500, height: 200)
        case "DiagnosticsEditorView": CGSize(width: 1200, height: 704)
        case "TabBarOverflow": CGSize(width: 1200, height: 36)
        case "BottomPanelDiagnostics": CGSize(width: 800, height: 250)
        case "NotificationOverflow": CGSize(width: 800, height: 600)
        case "FileTreeRename": CGSize(width: 280, height: 600)
        // BEGIN chrome migration preview sizes
        case "AgentContextBar": CGSize(width: 1200, height: 64)
        case "WorkspaceIconPicker": CGSize(width: 240, height: 360)
        case "WorkspaceHeaderView": CGSize(width: 1100, height: 64)
        case "WorkspaceIndicatorView": CGSize(width: 500, height: 64)
        case "ExtensionOverlayView": CGSize(width: 520, height: 240)
        case "ExtensionPanelView": CGSize(width: 600, height: 560)
        case "FloatPopupOverlay": CGSize(width: 600, height: 360)
        case "ProtocolErrorOverlay": CGSize(width: 640, height: 400)
        case "ResyncOverlay": CGSize(width: 640, height: 160)
        case "EditTimelineFiles", "EditTimelineTrack": CGSize(width: 900, height: 80)
        case "EditorSettingsView", "KeybindingsSettingsView": CGSize(width: 600, height: 480)
        // END chrome migration preview sizes
        default: CGSize(width: 400, height: 200)
        }
    }

    static func expectedPixelSize(named name: String, scale: CGFloat) -> CGSize {
        let size = size(named: name)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func shouldUseRenderedWindowCapture(_ viewName: String) -> Bool {
        renderedWindowViews.contains(viewName)
    }

    static func requiresRenderedWindowCapture(_ viewName: String) -> Bool {
        fullShellViews.contains(viewName)
    }

    static func shouldUseEagerLayout(for viewName: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["PREVIEW_EAGER_LAYOUT"] == "1" else { return false }
        return eagerLayoutViews.contains(viewName)
    }
}
