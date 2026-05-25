import AppKit
import Foundation

/// Shared policy for preview screenshots and snapshot-fixture layout.
enum PreviewSnapshotPolicy {
    private static let fullShellViews: Set<String> = ["EditorChromeView", "AgentChromeView", "DiagnosticsEditorView"]
    private static let renderedWindowViews: Set<String> = ["EditorChromeView", "AgentChromeView", "DiagnosticsEditorView", "GitStatusView", "FileTreeView"]
    private static let eagerLayoutViews: Set<String> = ["GitStatusView", "FileTreeView"]

    static func size(named name: String) -> CGSize {
        switch name {
        case "EditorChromeView", "AgentChromeView": CGSize(width: 1200, height: 704)
        case "GitStatusView", "FileTreeView": CGSize(width: 280, height: 600)
        case "CompletionOverlay": CGSize(width: 400, height: 300)
        case "StatusBarView": CGSize(width: 800, height: 28)
        case "TabBarView": CGSize(width: 800, height: 36)
        case "NotificationCenterView": CGSize(width: 800, height: 600)
        case "ObservatoryView": CGSize(width: 320, height: 640)
        case "AgentChatView": CGSize(width: 760, height: 600)
        case "PickerOverlay": CGSize(width: 600, height: 400)
        case "MinibufferView": CGSize(width: 600, height: 140)
        case "WhichKeyOverlay": CGSize(width: 520, height: 300)
        case "SearchToolbar": CGSize(width: 800, height: 40)
        case "HoverPopupOverlay": CGSize(width: 500, height: 300)
        case "SignatureHelpOverlay": CGSize(width: 500, height: 200)
        case "DiagnosticsEditorView": CGSize(width: 1200, height: 704)
        case "TabBarOverflow": CGSize(width: 1200, height: 36)
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
