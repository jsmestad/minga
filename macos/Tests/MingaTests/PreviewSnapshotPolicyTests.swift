import Foundation
import AppKit
@testable import MingaUI
import Testing

@Suite("PreviewSnapshotPolicy")
struct PreviewSnapshotPolicyTests {
    @Test("size table matches the snapshot fixtures")
    func sizeTable() {
        #expect(PreviewSnapshotPolicy.size(named: "EditorChromeView") == CGSize(width: 1200, height: 704))
        #expect(PreviewSnapshotPolicy.size(named: "AgentChromeView") == CGSize(width: 1200, height: 704))
        #expect(PreviewSnapshotPolicy.size(named: "FileTreeView") == CGSize(width: 280, height: 600))
        #expect(PreviewSnapshotPolicy.size(named: "GitStatusView") == CGSize(width: 280, height: 600))
        #expect(PreviewSnapshotPolicy.expectedPixelSize(named: "StatusBarView", scale: 2.0) == CGSize(width: 1600, height: 56))
    }

    @Test("rendered window capture is reserved for full-shell Metal previews")
    func renderedCapturePolicy() {
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("EditorChromeView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("AgentChromeView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("DiagnosticsEditorView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("InsertModeEditorView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("HoverEditorView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("SignatureHelpEditorView"))
        #expect(!PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("FileTreeView"))
        #expect(!PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("FileTreeEmpty"))
        #expect(!PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("GitStatusView"))
        #expect(!PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("GitStatusClean"))
        #expect(!PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("GitStatusConflict"))
        #expect(!PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("GitStatusDense"))
        #expect(!PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("StatusBarView"))
        #expect(PreviewSnapshotPolicy.requiresRenderedWindowCapture("EditorChromeView"))
        #expect(PreviewSnapshotPolicy.requiresRenderedWindowCapture("AgentChromeView"))
        #expect(!PreviewSnapshotPolicy.requiresRenderedWindowCapture("FileTreeView"))
        #expect(!PreviewSnapshotPolicy.requiresRenderedWindowCapture("GitStatusView"))
    }

    @Test("eager layout only turns on for isolated component snapshots")
    func eagerLayoutPolicy() {
        let enabledEnv = ["PREVIEW_EAGER_LAYOUT": "1"]
        #expect(PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeView", environment: enabledEnv))
        #expect(PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeRename", environment: enabledEnv))
        #expect(PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusView", environment: enabledEnv))
        #expect(PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusClean", environment: enabledEnv))
        #expect(!PreviewSnapshotPolicy.shouldUseEagerLayout(for: "EditorChromeView", environment: enabledEnv))
        #expect(!PreviewSnapshotPolicy.shouldUseEagerLayout(for: "AgentChromeView", environment: enabledEnv))
        #expect(!PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeView", environment: [:]))
    }

    @Test("agent widths reject unbounded and malformed requests")
    func boundedAgentWidths() throws {
        #expect(try PreviewSnapshotPolicy.agentWidth(nil) == 1200)
        #expect(try PreviewSnapshotPolicy.agentWidth("800") == 800)
        #expect(try PreviewSnapshotPolicy.agentWidth("1200") == 1200)
        for value in ["0", "-1", "801", "100000", "NaN", ""] {
            #expect(throws: PreviewSnapshotPolicy.CaptureError.self) {
                try PreviewSnapshotPolicy.agentWidth(value)
            }
        }
    }

    @Test("partial and oversized rendered frames cannot become successful crops")
    func rejectsIncorrectRenderedDimensions() throws {
        let expected = CGSize(width: 1600, height: 1408)
        try PreviewSnapshotPolicy.validateRenderedSize(actual: expected, expected: expected)
        for actual in [CGSize(width: 1599, height: 1408), CGSize(width: 1600, height: 1436), .zero] {
            #expect(throws: PreviewSnapshotPolicy.CaptureError.self) {
                try PreviewSnapshotPolicy.validateRenderedSize(actual: actual, expected: expected)
            }
        }
    }

    @Test("committed fixture theme keeps the production chat text readable")
    @MainActor
    func agentThemeContrast() throws {
        let theme = PreviewFixtures.theme()
        let background = try #require(NSColor(theme.agentPanelBg).usingColorSpace(.sRGB))
        let foreground = try #require(NSColor(theme.agentTextFg).usingColorSpace(.sRGB))
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: CGFloat) -> Double {
                let component = Double(value)
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent)
                + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        #expect((luminance(foreground) + 0.05) / (luminance(background) + 0.05) > 4.5)
    }
}
