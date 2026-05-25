import Foundation
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

    @Test("rendered window capture is reserved for the shell and chrome previews")
    func renderedCapturePolicy() {
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("EditorChromeView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("AgentChromeView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("FileTreeView"))
        #expect(PreviewSnapshotPolicy.shouldUseRenderedWindowCapture("GitStatusView"))
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
        #expect(PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusView", environment: enabledEnv))
        #expect(!PreviewSnapshotPolicy.shouldUseEagerLayout(for: "EditorChromeView", environment: enabledEnv))
        #expect(!PreviewSnapshotPolicy.shouldUseEagerLayout(for: "AgentChromeView", environment: enabledEnv))
        #expect(!PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeView", environment: [:]))
    }
}
