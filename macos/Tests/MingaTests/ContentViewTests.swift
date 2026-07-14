import AppKit
import Foundation
import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing
import ViewInspector

private final class MountedPreciseScrollEvent: NSEvent {
    private let mountedLocation: NSPoint
    private let mountedWindowNumber: Int
    private let mountedDeltaY: CGFloat
    private let mountedPhase: NSEvent.Phase

    init(locationInWindow: NSPoint, windowNumber: Int, deltaY: CGFloat, phase: NSEvent.Phase) {
        mountedLocation = locationInWindow
        mountedWindowNumber = windowNumber
        mountedDeltaY = deltaY
        mountedPhase = phase
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { mountedLocation }
    override var windowNumber: Int { mountedWindowNumber }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { mountedDeltaY }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { mountedPhase }
    override var momentumPhase: NSEvent.Phase { [] }
}

@MainActor
private final class MountedEditorRecorder {
    weak var view: MountedEditorNSView?

    private let updates: AsyncStream<Void>
    private let updateContinuation: AsyncStream<Void>.Continuation

    init() {
        let updateStream = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        updates = updateStream.stream
        updateContinuation = updateStream.continuation
    }

    func record(_ view: MountedEditorNSView) {
        self.view = view
        updateContinuation.yield()
    }

    func waitForPublishedValue(_ value: String) async {
        if view?.publishedValue == value {
            return
        }

        for await _ in updates where view?.publishedValue == value {
            return
        }
    }
}

@MainActor
private final class MountedEditorNSView: NSView {
    var publishedValue = ""
    var swiftUILocalState = UUID()
    var editorLocalState = ""

    override var acceptsFirstResponder: Bool { true }
}

private struct MountedEditorRepresentable: NSViewRepresentable {
    let publishedValue: String
    let swiftUILocalState: UUID
    let recorder: MountedEditorRecorder

    func makeNSView(context: Context) -> MountedEditorNSView {
        let view = MountedEditorNSView(frame: .zero)
        view.publishedValue = publishedValue
        view.swiftUILocalState = swiftUILocalState
        recorder.record(view)
        return view
    }

    func updateNSView(_ nsView: MountedEditorNSView, context: Context) {
        nsView.publishedValue = publishedValue
        nsView.swiftUILocalState = swiftUILocalState
        recorder.record(nsView)
    }
}

private struct MountedEditorSurface: View {
    let publishedValue: String
    let recorder: MountedEditorRecorder
    @State private var localState = UUID()

    var body: some View {
        MountedEditorRepresentable(
            publishedValue: publishedValue,
            swiftUILocalState: localState,
            recorder: recorder
        )
    }
}

@Suite("Content view")
@MainActor
struct ContentViewTests {
    private func makeEditorNSView(
        gui: GUIState,
        dispatcher: CommandDispatcher,
        encoder: InputEncoder
    ) throws -> EditorNSView {
        let face = FontFace(name: "Menlo", size: 13, scale: 1)
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        let renderer = try #require(CoreTextMetalRenderer(factories: factories))
        renderer.setupRenderers(fontManager: fontManager)
        let view = EditorNSView(
            encoder: encoder,
            fontFace: face,
            dispatcher: dispatcher,
            coreTextRenderer: renderer,
            fontManager: fontManager
        )
        view.editorInput = gui.editorInput
        return view
    }

    private func nativeInteractionContent() throws -> GUIWindowContent {
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(100)
        for index in 0..<100 {
            let rowID = UInt64(index + 1)
            let bufferLine = UInt32(index)
            let contentHash = UInt32(index + 1)
            let text = "line \(index)"
            rows.append(GUIVisualRow(
                rowType: .normal,
                rowId: rowID,
                bufLine: bufferLine,
                contentHash: contentHash,
                text: text,
                spans: []
            ))
        }
        let geometry = GUIPaneGeometry(
            windowId: 1,
            totalRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            contentRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            textRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            gutterRect: GUICellRect(row: 0, col: 0, width: 0, height: 24),
            clipRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
            viewport: GUIViewportSummary(
                top: 10,
                left: 0,
                rows: 24,
                cols: 80,
                totalLines: 100,
                visualRowOffset: 0,
                totalVisualRows: 100
            ),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0),
            hitRegions: []
        )
        let scroll = GUIScrollPresentation(
            windowId: 1,
            resetRequired: false,
            anchorTop: 10,
            anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: 10,
            visibleEndLine: 33,
            overscanStartLine: 0,
            overscanEndLine: 99,
            contentEpoch: 1,
            layoutGeneration: 1
        )
        return try GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            contentEpoch: 1,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            rows: rows,
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            paneGeometry: geometry,
            scrollPresentation: scroll
        )
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        locationInWindow: NSPoint,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func completeThemeSlots() -> [(UInt8, UInt8, UInt8, UInt8)] {
        CommandDispatcher.requiredThemeSlots.map { slot in
            (slot, slot, slot, slot)
        }
    }

    private func preciseScrollEvent(
        window: NSWindow,
        locationInWindow: NSPoint,
        deltaY: CGFloat,
        phase: NSEvent.Phase
    ) -> NSEvent {
        MountedPreciseScrollEvent(
            locationInWindow: locationInWindow,
            windowNumber: window.windowNumber,
            deltaY: deltaY,
            phase: phase
        )
    }

    @Test("resolves the current encoder instead of retaining the startup value")
    func currentEncoder() {
        let first = NullInputEncoder()
        let second = NullInputEncoder()
        var current: InputEncoder? = first

        let view = ContentView(
            gui: GUIState(),
            encoder: { current },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            Color.clear
        }

        #expect(view.encoder === first)
        current = second
        #expect(view.encoder === second)
    }

    @Test("toolbar mounting and rendering use canonical display tabs over legacy tabs")
    func canonicalDisplayTabsMountToolbar() throws {
        let gui = GUIState()
        gui.tabBarState.update(activeIndex: 0, entries: [
            Wire.TabEntry(
                id: 1,
                groupId: 0,
                isActive: true,
                isDirty: false,
                isAgent: false,
                hasAttention: false,
                agentStatus: 0,
                isPinned: false,
                tintColorRGB: 0,
                icon: "",
                label: "legacy.ex"
            )
        ])
        gui.tabBarState.updateWorkspaces(
            activeWorkspaceId: 7,
            mode: 1,
            flags: 0,
            entries: [Wire.WorkspaceEntry(
                id: 7,
                kind: 1,
                status: 0,
                flags: 0,
                colorR: 0x11,
                colorG: 0x22,
                colorB: 0x33,
                tabCount: 1,
                draftCount: 0,
                conflictCount: 0,
                runningBackgroundCount: 0,
                label: "Review",
                icon: "cpu"
            )],
            visibleTabs: [Wire.WorkspaceTabEntry(
                id: 42,
                workspaceId: 7,
                kind: 0,
                flags: 0,
                pathHash: 42,
                tintColorRGB: 0,
                icon: "",
                label: "canonical.ex",
                path: "/tmp/canonical.ex"
            )]
        )
        let root = ContentView(
            gui: gui,
            encoder: { nil },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            Color.clear
        }

        let strings = try root.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(strings.contains("canonical.ex"))
        #expect(!strings.contains("legacy.ex"))
        #expect((try? root.inspect().find(viewWithAccessibilityIdentifier: "workspace-tabbar")) != nil)

        gui.tabBarState.updateWorkspaces(
            activeWorkspaceId: 7,
            mode: 1,
            flags: 0,
            entries: [],
            visibleTabs: []
        )
        let canonicalEmptyRoot = ContentView(
            gui: gui,
            encoder: { nil },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            Color.clear
        }
        let canonicalEmptyStrings = try canonicalEmptyRoot.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        #expect(!canonicalEmptyStrings.contains("legacy.ex"))
        #expect((try? canonicalEmptyRoot.inspect().find(viewWithAccessibilityIdentifier: "workspace-tabbar")) == nil)

        let legacyOnlyGUI = GUIState()
        legacyOnlyGUI.tabBarState.update(activeIndex: 0, entries: [
            Wire.TabEntry(
                id: 9,
                groupId: 0,
                isActive: true,
                isDirty: false,
                isAgent: false,
                hasAttention: false,
                agentStatus: 0,
                isPinned: false,
                tintColorRGB: 0,
                icon: "",
                label: "fallback.ex"
            )
        ])
        let legacyOnlyRoot = ContentView(
            gui: legacyOnlyGUI,
            encoder: { nil },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            Color.clear
        }
        let legacyOnlyStrings = try legacyOnlyRoot.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        #expect(legacyOnlyStrings.contains("fallback.ex"))
        #expect((try? legacyOnlyRoot.inspect().find(viewWithAccessibilityIdentifier: "workspace-tabbar")) != nil)
    }

    @Test(
        "shell-only commit preserves mounted EditorNSView interaction ownership",
        .timeLimit(.minutes(1))
    )
    func focusedMountedPublicationPreservesEditorIdentity() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent()))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(
            id: 1,
            groupId: 0,
            isActive: true,
            isDirty: false,
            isAgent: false,
            hasAttention: false,
            agentStatus: 0,
            isPinned: false,
            tintColorRGB: 0,
            icon: "",
            label: "before.ex"
        )]))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        let root = ContentView(
            gui: gui,
            encoder: { spy },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            EditorView(editorNSView: editorView)
        }
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        #expect(editorView.window === window)
        #expect(editorView.bounds.width > 0)
        #expect(editorView.bounds.height > 0)
        #expect(window.makeFirstResponder(editorView))

        let localPoint = NSPoint(
            x: min(max(editorView.cellWidth * 8, 1), editorView.bounds.maxX - 1),
            y: min(max(editorView.cellHeight * 6, 1), editorView.bounds.maxY - 1)
        )
        let locationInWindow = editorView.convert(localPoint, to: nil)
        let hover = try #require(mouseEvent(
            type: .mouseMoved,
            locationInWindow: locationInWindow,
            windowNumber: window.windowNumber
        ))
        editorView.mouseMoved(with: hover)
        editorView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let scrollBegan = preciseScrollEvent(
            window: window,
            locationInWindow: locationInWindow,
            deltaY: -7,
            phase: .began
        )
        let scrollChanged = preciseScrollEvent(
            window: window,
            locationInWindow: locationInWindow,
            deltaY: -7,
            phase: .changed
        )
        #expect(scrollBegan.hasPreciseScrollingDeltas)
        #expect(scrollChanged.hasPreciseScrollingDeltas)
        #expect(scrollBegan.windowNumber == window.windowNumber)
        #expect(scrollBegan.locationInWindow == locationInWindow)
        editorView.scrollWheel(with: scrollBegan)
        editorView.scrollWheel(with: scrollChanged)

        let mouseDown = try #require(mouseEvent(
            type: .leftMouseDown,
            locationInWindow: locationInWindow,
            windowNumber: window.windowNumber
        ))
        let dragLocation = NSPoint(x: locationInWindow.x + 12, y: locationInWindow.y + 8)
        let mouseDrag = try #require(mouseEvent(
            type: .leftMouseDragged,
            locationInWindow: dragLocation,
            windowNumber: window.windowNumber
        ))
        editorView.mouseDown(with: mouseDown)
        editorView.mouseDragged(with: mouseDrag)

        let before = editorView.interactionSnapshot
        #expect(before.hasMarkedText)
        #expect(before.markedRange.location == 0)
        #expect(before.markedRange.length == 2)
        #expect(before.hoverRow >= 0)
        #expect(before.hoverCol >= 0)
        #expect(before.selectionDragActive)
        #expect(before.selectionDragStarted)
        #expect(before.scrollWindowId != nil)
        #expect(before.scrollOffset != .zero)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Wire.TabEntry(
            id: 2,
            groupId: 0,
            isActive: true,
            isDirty: false,
            isAgent: false,
            hasAttention: false,
            agentStatus: 0,
            isPinned: false,
            tintColorRGB: 0,
            icon: "",
            label: "after.ex"
        )]))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        let after = editorView.interactionSnapshot
        #expect(editorView.window === window)
        #expect(window.firstResponder === editorView)
        #expect(after.hasMarkedText == before.hasMarkedText)
        #expect(after.markedRange.location == before.markedRange.location)
        #expect(after.markedRange.length == before.markedRange.length)
        #expect(after.hoverRow == before.hoverRow)
        #expect(after.hoverCol == before.hoverCol)
        #expect(after.selectionDragActive == before.selectionDragActive)
        #expect(after.selectionDragStarted == before.selectionDragStarted)
        #expect(after.scrollWindowId == before.scrollWindowId)
        #expect(after.scrollOffset == before.scrollOffset)
    }

}
