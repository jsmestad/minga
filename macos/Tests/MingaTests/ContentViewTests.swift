import AppKit
import Foundation
import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing
import ViewInspector

private final class MountedPreciseScrollEvent: NSEvent {
    var preciseDeltas = true
    private let mountedLocation: NSPoint
    private let mountedWindowNumber: Int
    private let mountedDeltaY: CGFloat
    private let mountedPhase: NSEvent.Phase
    private let mountedMomentumPhase: NSEvent.Phase

    init(
        locationInWindow: NSPoint,
        windowNumber: Int,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase = []
    ) {
        mountedLocation = locationInWindow
        mountedWindowNumber = windowNumber
        mountedDeltaY = deltaY
        mountedPhase = phase
        mountedMomentumPhase = momentumPhase
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
    override var hasPreciseScrollingDeltas: Bool { preciseDeltas }
    override var phase: NSEvent.Phase { mountedPhase }
    override var momentumPhase: NSEvent.Phase { mountedMomentumPhase }
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

@Suite("Content view", .serialized)
@MainActor
struct ContentViewTests {
    private func makeEditorNSView(
        gui: GUIState,
        dispatcher: CommandDispatcher,
        encoder: InputEncoder,
        reduceMotion: Bool = false
    ) throws -> EditorNSView {
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        let renderer = try #require(CoreTextMetalRenderer(factories: factories))
        renderer.setupRenderers(fontManager: fontManager)
        let view = EditorNSView(
            encoder: encoder,
            dispatcher: dispatcher,
            coreTextRenderer: renderer,
            fontManager: fontManager,
            reduceMotion: reduceMotion
        )
        view.editorInput = gui.editorInput
        return view
    }

    private func nativeInteractionContent(anchorTop: UInt32 = 10, fullRefresh: Bool = true, scrollSeq: UInt32 = 0, resident: Bool = true, extraRows: Int = 0) throws -> GUIWindowContent {
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(100)
        let range = resident ? 0..<100 : Int(anchorTop)..<(Int(anchorTop) + 24 + extraRows)
        for index in range {
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
                top: anchorTop,
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
            anchorTop: anchorTop,
            anchorLeft: 0,
            anchorVisualRowOffset: 0,
            visibleStartLine: anchorTop,
            visibleEndLine: anchorTop + 23,
            overscanStartLine: UInt32(range.lowerBound),
            overscanEndLine: UInt32(range.upperBound),
            contentEpoch: 1,
            layoutGeneration: 1,
            scrollSeq: scrollSeq
        )
        return try GUIWindowContent(
            windowId: 1,
            fullRefresh: fullRefresh,
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

    @Test("wheel input honors Reduce Motion without dropping scroll intent", arguments: [false, true], [-1, 1])
    func wheelRespectsReduceMotion(reduceMotion: Bool, direction: Int) throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy, reduceMotion: reduceMotion)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))

        let event = MountedPreciseScrollEvent(
            locationInWindow: editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight * 6), to: nil),
            windowNumber: 0, deltaY: -CGFloat(direction) * editor.cellHeight, phase: []
        )
        event.preciseDeltas = false
        editor.scrollWheel(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls.last?.button == (direction > 0 ? MOUSE_SCROLL_DOWN : MOUSE_SCROLL_UP))
        let expectedWindow: UInt16? = reduceMotion ? nil : 1
        #expect(editor.interactionSnapshot.scrollWindowId == expectedWindow)
        if reduceMotion {
            #expect(editor.interactionSnapshot.scrollOffset == .zero)
        }
    }

    @Test("ordinary scroll echoes preserve wheel easing and trackpad presentation", arguments: [false, true])
    func scrollEchoPreservesPresentation(precise: Bool) throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let initial = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorPresentation(snapshot: initial, localTransform: nil)

        var resetRequests = 0
        dispatcher.onScrollPresentationReset = { [weak editor] windowId in
            resetRequests += 1
            guard let editor else { return }
            editor.resetScrollPresentation(windowId: windowId)
        }
        let event = MountedPreciseScrollEvent(
            locationInWindow: editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight * 6), to: nil),
            windowNumber: 0,
            deltaY: -editor.cellHeight,
            phase: precise ? .began : []
        )
        event.preciseDeltas = precise
        editor.scrollWheel(with: event)
        let before = editor.interactionSnapshot
        #expect(spy.mouseEventCalls.last?.row == 6 || precise)
        try #require(before.scrollWindowId == 1)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        let echoedContent = try nativeInteractionContent(anchorTop: 11, fullRefresh: false)
        dispatcher.dispatch(.guiWindowRowsDelta(data: GUIWindowRowsDelta(
            windowId: 1, contentEpoch: 1, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            baseRowCount: 100, resultRowCount: 100, rowSplices: [],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [],
            paneGeometry: echoedContent.paneGeometry, cursorline: nil,
            scrollPresentation: echoedContent.scrollPresentation
        )))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        let committed = try #require(dispatcher.committedEditorSnapshot)
        let previousScroll = try #require(initial.content(for: 1)?.scrollPresentation)
        let nextScroll = try #require(committed.content(for: 1)?.scrollPresentation)
        #expect(committed.frameSeq == 2)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(nextScroll.anchorTop == previousScroll.anchorTop + 1)
        #expect(nextScroll.scrollSeq == previousScroll.scrollSeq)
        #expect(nextScroll.resetRequired == false)
        #expect(nextScroll.contentEpoch == previousScroll.contentEpoch)
        #expect(nextScroll.layoutGeneration == previousScroll.layoutGeneration)
        #expect(resetRequests == 0)
        let after = editor.interactionSnapshot
        #expect(after.scrollWindowId == 1)
        if precise {
            editor.draw(editor.bounds)
            #expect(editor.interactionSnapshot.scrollOffset.y == 0)
        }

        editor.resetScrollPresentation(windowId: 2)
        #expect(editor.interactionSnapshot.scrollWindowId == 1)
        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 2, generation: 1))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent(anchorTop: 40, scrollSeq: 1)))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))
        #expect(resetRequests == 1)
        #expect(editor.interactionSnapshot.scrollWindowId == nil)
        #expect(editor.interactionSnapshot.scrollOffset == .zero)

        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))
        editor.scrollWheel(with: event)
        #expect(editor.interactionSnapshot.scrollWindowId == 1)
        dispatcher.dispatch(.beginFrame(frameSeq: 4, baseFrameSeq: 3, generation: 1))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent(anchorTop: 30, scrollSeq: 0)))
        dispatcher.dispatch(.commitFrame(frameSeq: 4, seq: 0))
        #expect(resetRequests == 2)
        #expect(editor.interactionSnapshot.scrollWindowId == nil)
        #expect(editor.interactionSnapshot.scrollOffset == .zero)
    }

    @Test("wheel ticks around an undisplayed echo keep moving forward", arguments: [-1, 1])
    func wheelReconciliationUsesRenderedAnchor(direction: Int) throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let initial = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorPresentation(snapshot: initial, localTransform: nil)
        let event = MountedPreciseScrollEvent(
            locationInWindow: editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight * 6), to: nil),
            windowNumber: 0, deltaY: -CGFloat(direction) * editor.cellHeight, phase: []
        )
        event.preciseDeltas = false
        editor.scrollWheel(with: event)

        dispatcher.onScrollPresentationReset = { [weak editor] windowId in
            guard let editor else { return }
            editor.resetScrollPresentation(windowId: windowId)
        }
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        let echoedContent = try nativeInteractionContent(anchorTop: UInt32(10 + direction), fullRefresh: false)
        dispatcher.dispatch(.guiWindowRowsDelta(data: GUIWindowRowsDelta(
            windowId: 1, contentEpoch: 1, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            baseRowCount: 100, resultRowCount: 100, rowSplices: [],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [],
            paneGeometry: echoedContent.paneGeometry, cursorline: nil,
            scrollPresentation: echoedContent.scrollPresentation
        )))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        let next = try #require(dispatcher.committedEditorSnapshot)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)

        #expect(editor.interactionSnapshot.scrollWindowId == 1)
        // A second tick arrives after the first echo commits but before it is displayed.
        editor.scrollWheel(with: event)
        try #require(editor.interactionSnapshot.scrollWindowId == 1)
        editor.draw(editor.bounds)
        let firstOffset = editor.interactionSnapshot.scrollOffset.y
        let firstVisualTop = CGFloat(10 + direction) * editor.cellHeight + firstOffset
        dispatcher.promoteVisibleEditorPresentation(snapshot: next, localTransform: nil)
        editor.draw(editor.bounds)
        let secondOffset = editor.interactionSnapshot.scrollOffset.y
        let secondVisualTop = CGFloat(10 + direction) * editor.cellHeight + secondOffset
        #expect((firstVisualTop - CGFloat(10) * editor.cellHeight) * CGFloat(direction) >= 0)
        #expect((secondVisualTop - CGFloat(10) * editor.cellHeight) * CGFloat(direction) <= 2 * editor.cellHeight)
        #expect((secondVisualTop - firstVisualTop) * CGFloat(direction) >= 0)
    }

    @Test("windowed scrolling keeps unavailable rows hidden during live and settling frames", arguments: [false, true], [0, 2])
    func windowedScrollRespectsPayload(precise: Bool, extraRows: Int) throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: SpyEncoder())
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent(resident: false, extraRows: extraRows)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))
        let point = editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight * 6), to: nil)
        let event = MountedPreciseScrollEvent(locationInWindow: point, windowNumber: 0, deltaY: -editor.cellHeight * (precise ? 10 : 1), phase: precise ? .began : [])
        event.preciseDeltas = precise
        editor.scrollWheel(with: event)
        editor.draw(editor.bounds)
        #expect(editor.interactionSnapshot.scrollOffset.y <= CGFloat(extraRows) * editor.cellHeight)
        if precise {
            editor.scrollWheel(with: MountedPreciseScrollEvent(locationInWindow: point, windowNumber: 0, deltaY: 0, phase: .ended))
            editor.draw(editor.bounds)
            #expect(editor.interactionSnapshot.scrollOffset.y <= CGFloat(extraRows) * editor.cellHeight)
        }
    }

    private func nativeFoldInteractionContent(
        prefix: String,
        foldLine: UInt32,
        contentEpoch: UInt32,
        totalLines: UInt32 = 4,
        windowId: UInt16 = 1,
        paneCol: UInt16 = 0,
        paneWidth: UInt16 = 80,
        cursorRow: UInt16 = 1,
        cursorCol: UInt16 = 2
    ) throws -> GUIWindowContent {
        let rows = (0..<4).map { index in
            GUIVisualRow(
                rowType: .normal,
                rowId: UInt64(contentEpoch) * 10 + UInt64(index),
                bufLine: UInt32(index),
                contentHash: UInt32(contentEpoch) * 10 + UInt32(index),
                text: "\(prefix) row \(index)",
                spans: []
            )
        }
        let textCol = paneCol + 7
        let textWidth = paneWidth - 7
        let geometry = GUIPaneGeometry(
            windowId: windowId,
            totalRect: GUICellRect(row: 0, col: paneCol, width: paneWidth, height: 24),
            contentRect: GUICellRect(row: 0, col: paneCol, width: paneWidth, height: 24),
            textRect: GUICellRect(row: 0, col: textCol, width: textWidth, height: 24),
            gutterRect: GUICellRect(row: 0, col: paneCol, width: 7, height: 24),
            clipRect: GUICellRect(row: 0, col: textCol, width: textWidth, height: 24),
            viewport: GUIViewportSummary(
                top: 0,
                left: 0,
                rows: 4,
                cols: textWidth,
                totalLines: totalLines,
                visualRowOffset: 0,
                totalVisualRows: 4
            ),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 4, signColWidth: 3),
            hitRegions: [GUIHitRegion(kind: .gutter, rect: GUICellRect(row: 0, col: paneCol, width: 7, height: 24), windowId: windowId)]
        )
        return try GUIWindowContent(
            windowId: windowId,
            fullRefresh: true,
            contentEpoch: contentEpoch,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorShape: .block,
            rows: rows,
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            paneGeometry: geometry,
            scrollPresentation: GUIScrollPresentation(
                windowId: windowId,
                resetRequired: false,
                anchorTop: 0,
                anchorLeft: 0,
                anchorVisualRowOffset: 0,
                visibleStartLine: 0,
                visibleEndLine: 4,
                overscanStartLine: 0,
                overscanEndLine: totalLines,
                contentEpoch: contentEpoch,
                layoutGeneration: 1
            )
        )
    }

    private func nativeFoldGutter(
        foldLine: UInt32,
        windowId: UInt16 = 1,
        paneCol: UInt16 = 0,
        paneWidth: UInt16 = 80,
        isActive: Bool = true
    ) -> Wire.WindowGutter {
        Wire.WindowGutter(
            windowId: windowId,
            contentRow: 0,
            contentCol: paneCol,
            contentHeight: 24,
            isActive: isActive,
            contentWidth: paneWidth,
            cursorLine: foldLine,
            lineNumberStyle: .hybrid,
            lineNumberWidth: 4,
            signColWidth: 3,
            entries: [
                Wire.GutterEntry(bufLine: foldLine, displayType: .foldStart, signType: .none, foldEndLine: foldLine + 5),
                Wire.GutterEntry(bufLine: foldLine + 1, displayType: .normal, signType: .none),
                Wire.GutterEntry(bufLine: foldLine + 2, displayType: .normal, signType: .none),
                Wire.GutterEntry(bufLine: foldLine + 3, displayType: .normal, signType: .none)
            ]
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

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func framedKeyframe(generation: UInt32, frameSeq: UInt32) -> Data {
        var payload = Data([OP_BEGIN_FRAME])
        appendUInt32(frameSeq, to: &payload)
        appendUInt32(0, to: &payload)
        appendUInt32(generation, to: &payload)
        payload.append(OP_GUI_THEME)
        payload.append(UInt8(CommandDispatcher.requiredThemeSlots.count))
        for slot in CommandDispatcher.requiredThemeSlots {
            payload.append(contentsOf: [slot, slot, slot, slot])
        }
        payload.append(OP_COMMIT_FRAME)
        appendUInt32(frameSeq, to: &payload)
        appendUInt32(0, to: &payload)

        var framed = Data()
        appendUInt32(UInt32(payload.count), to: &framed)
        framed.append(payload)
        return framed
    }

    private func preciseScrollEvent(
        window: NSWindow,
        locationInWindow: NSPoint,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase = []
    ) -> NSEvent {
        MountedPreciseScrollEvent(
            locationInWindow: locationInWindow,
            windowNumber: window.windowNumber,
            deltaY: deltaY,
            phase: phase,
            momentumPhase: momentumPhase
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
        gui.tabBarState.install(WorkspacePresentationSnapshot(
            version: 1,
            activeWorkspaceId: 7,
            mode: 1,
            flags: 0,
            workspaces: [Wire.WorkspaceEntry(
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
        ))
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

        gui.tabBarState.install(WorkspacePresentationSnapshot(
            version: 1,
            activeWorkspaceId: 7,
            mode: 1,
            flags: 0,
            workspaces: [],
            visibleTabs: []
        ))
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
        "mounted editor interactions use visible snapshot while newer commit is unpresented",
        .timeLimit(.minutes(1))
    )
    func mountedEditorInteractionsUseVisibleSnapshotWhileNewerCommitIsUnpresented() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "visible", foldLine: 101, contentEpoch: 1, totalLines: 100)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 101)))
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

        let visibleSnapshot = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorPresentation(
            snapshot: visibleSnapshot,
            localTransform: EditorLocalPresentationTransform(windowId: 1, offset: CGPoint(x: 0, y: editorView.cellHeight))
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "committed", foldLine: 201, contentEpoch: 2, totalLines: 300)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 201)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(dispatcher.committedEditorSnapshot?.frameSeq == 2)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)

        #expect((editorView.accessibilityValue() as? String)?.contains("visible row 1") == true)
        #expect((editorView.accessibilityValue() as? String)?.contains("committed row") == false)
        #expect(editorView.accessibilityInsertionPointLineNumber() == 1)
        let scrollY = editorView.bounds.height * 0.75
        let visibleLine = EditorScrollTrack.line(
            forY: scrollY,
            viewHeight: editorView.bounds.height,
            totalLines: 100,
            visibleRows: 4,
            resident: true
        )
        let committedLine = EditorScrollTrack.line(
            forY: scrollY,
            viewHeight: editorView.bounds.height,
            totalLines: 300,
            visibleRows: 24,
            resident: true
        )
        #expect(visibleLine != committedLine)
        #expect(editorView.scrollTrackLineForTesting(y: scrollY) == visibleLine)

        let textPoint = NSPoint(x: editorView.cellWidth * 12.2, y: editorView.cellHeight * 0.5)
        let textEvent = try #require(mouseEvent(
            type: .leftMouseDown,
            locationInWindow: editorView.convert(textPoint, to: nil),
            windowNumber: window.windowNumber
        ))
        editorView.mouseDown(with: textEvent)
        #expect(spy.mouseEventCalls.last?.row == 1)
        #expect(spy.mouseEventCalls.last?.col == 9)

        let dragPoint = NSPoint(x: editorView.cellWidth * 14.2, y: editorView.cellHeight * 2.5)
        let dragEvent = try #require(mouseEvent(
            type: .leftMouseDragged,
            locationInWindow: editorView.convert(dragPoint, to: nil),
            windowNumber: window.windowNumber
        ))
        editorView.mouseDragged(with: dragEvent)
        #expect(spy.mouseEventCalls.last?.eventType == MOUSE_DRAG)
        #expect(spy.mouseEventCalls.last?.row == 3)
        #expect(spy.mouseEventCalls.last?.col == 11)

        dispatcher.promoteVisibleEditorPresentation(snapshot: visibleSnapshot, localTransform: nil)
        let foldPoint = NSPoint(x: editorView.cellWidth * 3.2, y: editorView.cellHeight * 0.5)
        let foldEvent = try #require(mouseEvent(
            type: .leftMouseDown,
            locationInWindow: editorView.convert(foldPoint, to: nil),
            windowNumber: window.windowNumber
        ))
        editorView.mouseDown(with: foldEvent)
        #expect(spy.guiActions.last == .foldToggleAtLine(windowId: 1, bufferLine: 101))

        let committedSnapshot = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorPresentation(snapshot: committedSnapshot, localTransform: nil)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 2)
        #expect((editorView.accessibilityValue() as? String)?.contains("committed row 1") == true)
        editorView.mouseDown(with: textEvent)
        #expect(spy.mouseEventCalls.last?.row == 0)
        #expect(spy.mouseEventCalls.last?.col == 9)
    }

    @Test(
        "active-pane input IME and accessibility move only after visible promotion",
        .timeLimit(.minutes(1))
    )
    func activePaneGeometryMovesAtomicallyAtVisiblePromotion() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "pane A", foldLine: 10, contentEpoch: 1, windowId: 1, paneCol: 0, paneWidth: 40, cursorRow: 0)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 10, windowId: 1, paneCol: 0, paneWidth: 40)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))

        let root = ContentView(gui: gui, encoder: { spy }, editorGeometry: { .preview }, chrome: .preview, onAgentChatVisibleChange: { _ in }) {
            EditorView(editorNSView: editorView)
        }
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))
        let localPoint = NSPoint(x: editorView.cellWidth * 45.2, y: editorView.cellHeight * 1.5)
        let windowPoint = editorView.convert(localPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let imeA = editorView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let characterA = editorView.characterIndex(for: screenPoint)
        let rangeA = editorView.accessibilitySelectedTextRange()
        #expect((editorView.accessibilityValue() as? String)?.contains("pane A row 0") == true)
        #expect(editorView.accessibilityInsertionPointLineNumber() == 0)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "pane B successor", foldLine: 20, contentEpoch: 2, windowId: 2, paneCol: 40, paneWidth: 40, cursorRow: 2, cursorCol: 4)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 20, windowId: 2, paneCol: 40, paneWidth: 40)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(editorView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) == imeA)
        #expect(editorView.characterIndex(for: screenPoint) == characterA)
        #expect(editorView.accessibilitySelectedTextRange() == rangeA)
        #expect(editorView.accessibilityInsertionPointLineNumber() == 0)
        #expect((editorView.accessibilityValue() as? String)?.contains("pane A row 0") == true)

        let click = try #require(mouseEvent(type: .leftMouseDown, locationInWindow: windowPoint, windowNumber: window.windowNumber))
        editorView.mouseDown(with: click)
        let visibleClick = try #require(spy.mouseEventCalls.last)

        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))
        let imeB = editorView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        #expect(imeB.minX > imeA.minX)
        #expect(editorView.characterIndex(for: screenPoint) != characterA)
        #expect(editorView.accessibilitySelectedTextRange() != rangeA)
        #expect(editorView.accessibilityInsertionPointLineNumber() == 2)
        #expect((editorView.accessibilityValue() as? String)?.contains("pane B successor row 0") == true)
        editorView.mouseDown(with: click)
        let promotedClick = try #require(spy.mouseEventCalls.last)
        #expect(promotedClick.row != visibleClick.row || promotedClick.col != visibleClick.col)
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
        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))

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

        let visibleContent = try #require(dispatcher.visibleEditorSnapshot?.surfaces.first?.content)
        let momentumEvents = [
            preciseScrollEvent(window: window, locationInWindow: locationInWindow, deltaY: -6, phase: [], momentumPhase: .began),
            preciseScrollEvent(window: window, locationInWindow: locationInWindow, deltaY: -5, phase: [], momentumPhase: .changed),
            preciseScrollEvent(window: window, locationInWindow: locationInWindow, deltaY: 0, phase: [], momentumPhase: .ended),
            preciseScrollEvent(window: window, locationInWindow: locationInWindow, deltaY: -4, phase: [], momentumPhase: .began),
            preciseScrollEvent(window: window, locationInWindow: locationInWindow, deltaY: -3, phase: [], momentumPhase: .changed),
            preciseScrollEvent(window: window, locationInWindow: locationInWindow, deltaY: -2, phase: .began),
        ]
        for event in momentumEvents { editorView.scrollWheel(with: event) }
        #expect(dispatcher.visibleEditorSnapshot?.surfaces.first?.content === visibleContent)

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

        editorView.replaceConnection(encoder: SpyEncoder())
        let replaced = editorView.interactionSnapshot
        #expect(replaced.hasMarkedText == false)
        #expect(replaced.markedRange.location == NSNotFound)
        #expect(replaced.markedRange.length == 0)
        #expect(replaced.hoverRow == -1)
        #expect(replaced.hoverCol == -1)
        #expect(replaced.selectionDragActive == false)
        #expect(replaced.selectionDragStarted == false)
        #expect(replaced.scrollWindowId == nil)
        #expect(replaced.scrollOffset == .zero)
    }

    @Test("connection replacement consumes old mouse gesture tails and admits fresh gestures")
    func connectionReplacementGatesMouseGestureTails() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let oldEncoder = SpyEncoder()
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: oldEncoder)
        editorView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let point = NSPoint(x: 20, y: 20)
        let leftDown = try #require(mouseEvent(type: .leftMouseDown, locationInWindow: point, windowNumber: 0))
        let leftDrag = try #require(mouseEvent(type: .leftMouseDragged, locationInWindow: point, windowNumber: 0))
        let leftUp = try #require(mouseEvent(type: .leftMouseUp, locationInWindow: point, windowNumber: 0))
        let middleDown = try #require(mouseEvent(type: .otherMouseDown, locationInWindow: point, windowNumber: 0))
        let middleUp = try #require(mouseEvent(type: .otherMouseUp, locationInWindow: point, windowNumber: 0))
        let rightUp = try #require(mouseEvent(type: .rightMouseUp, locationInWindow: point, windowNumber: 0))

        editorView.mouseDown(with: leftDown)
        editorView.otherMouseDown(with: middleDown)
        editorView.beginMousePressForTesting(button: MOUSE_BUTTON_RIGHT)
        let oldGeneration = editorView.interactionSnapshot.inputConnectionGeneration

        let intermediateEncoder = SpyEncoder()
        editorView.replaceConnection(encoder: intermediateEncoder)
        #expect(editorView.interactionSnapshot.consumesLeftGestureTail)
        #expect(editorView.interactionSnapshot.consumesRightGestureTail)
        #expect(editorView.interactionSnapshot.consumesMiddleGestureTail)

        let replacementEncoder = SpyEncoder()
        editorView.replaceConnection(encoder: replacementEncoder)
        #expect(editorView.interactionSnapshot.consumesLeftGestureTail)
        #expect(editorView.interactionSnapshot.consumesRightGestureTail)
        #expect(editorView.interactionSnapshot.consumesMiddleGestureTail)

        editorView.mouseDragged(with: leftDrag)
        editorView.mouseUp(with: leftUp)
        editorView.rightMouseUp(with: rightUp)
        editorView.otherMouseUp(with: middleUp)
        editorView.performContextMenuActionForTesting("select_all", connectionGeneration: oldGeneration)
        #expect(intermediateEncoder.mouseEventCalls.isEmpty)
        #expect(intermediateEncoder.guiActions.isEmpty)
        #expect(replacementEncoder.mouseEventCalls.isEmpty)
        #expect(replacementEncoder.guiActions.isEmpty)

        let replacementGeneration = editorView.interactionSnapshot.inputConnectionGeneration
        editorView.mouseDown(with: leftDown)
        editorView.mouseUp(with: leftUp)
        editorView.otherMouseDown(with: middleDown)
        editorView.otherMouseUp(with: middleUp)
        editorView.performContextMenuActionForTesting("select_all", connectionGeneration: replacementGeneration)

        #expect(replacementEncoder.mouseEventCalls.map(\.eventType) == [MOUSE_PRESS, MOUSE_RELEASE, MOUSE_PRESS, MOUSE_RELEASE])
        #expect(replacementEncoder.guiActions == [.executeCommand(name: "select_all")])
    }

    @Test("replacement protocol connection accepts a lower keyframe from controlled pipes", .timeLimit(.minutes(1)))
    func productionReconnectAcceptsControlledPipeKeyframe() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        dispatcher.replaceConnection(with: 1)
        dispatcher.dispatch(.beginFrame(frameSeq: 90, baseFrameSeq: 0, generation: 40))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 90, seq: 0))
        #expect(dispatcher.lastCommittedFrameSeq == 90)

        let oldOutput = Pipe()
        let oldEncoder = try ProtocolEncoder(output: oldOutput.fileHandleForWriting)
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: oldEncoder)
        let replacementInput = Pipe()
        let replacementOutput = Pipe()
        var currentConnectionID: UInt64 = 1
        let results = AsyncStream.makeStream(of: FrameTransactionResult.self, bufferingPolicy: .bufferingNewest(1))
        dispatcher.onTransactionResult = { results.continuation.yield($0) }
        let rejections = AsyncStream.makeStream(of: OutboundInputRejection.self, bufferingPolicy: .bufferingNewest(1))
        defer { rejections.continuation.finish() }

        oldEncoder.disconnect(reason: .expectedTeardown)
        currentConnectionID = 2
        dispatcher.replaceConnection(with: 2)
        editorView.invalidateConnection()
        let connection = try ProtocolConnection(
            connectionID: 2,
            readHandle: replacementInput.fileHandleForReading,
            writeHandle: replacementOutput.fileHandleForWriting,
            resourcePolicy: .default,
            isCurrent: { $0 == currentConnectionID },
            consume: { event, deliveredConnectionID in
                switch event {
                case .frame(let frame):
                    dispatcher.dispatch(frame, connectionID: deliveredConnectionID)
                case .failure(let failure):
                    dispatcher.decodedFrameFailed(failure, connectionID: deliveredConnectionID)
                }
            },
            onTransportFailure: { _ in },
            onInputRejection: { rejections.continuation.yield($0) },
            onReaderDisconnect: { encoder, _ in
                encoder.disconnect(reason: .unexpectedPeerClosure)
            }
        )
        editorView.installConnectionEncoder(connection.encoder)
        connection.start()
        #expect(editorView.interactionSnapshot.inputEnabled)

        connection.encoder.sendPasteEvent(text: String(repeating: "x", count: 65_536))
        var rejectionIterator = rejections.stream.makeAsyncIterator()
        let rejection = await rejectionIterator.next()
        #expect(rejection == .pasteTooLarge(limitBytes: 65_535, attemptedBytes: 65_536))
        #expect(editorView.interactionSnapshot.inputEnabled)

        try replacementInput.fileHandleForWriting.write(contentsOf: framedKeyframe(generation: 1, frameSeq: 1))
        var iterator = results.stream.makeAsyncIterator()
        let result = await iterator.next()

        #expect(result == .applied(generation: 1, frameSeq: 1))
        #expect(dispatcher.lastCommittedGeneration == 1)
        #expect(dispatcher.lastCommittedFrameSeq == 1)
        #expect(dispatcher.pendingPresentationFrame()?.connectionID == 2)
        let replacementSnapshot = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorPresentation(
            snapshot: replacementSnapshot,
            localTransform: nil,
            connectionID: 2
        )
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)

        connection.stop()
        replacementInput.fileHandleForWriting.closeFile()
        replacementOutput.fileHandleForReading.closeFile()
    }

    @Test("failed replacement construction leaves retired delivery and application input disabled", .timeLimit(.minutes(1)))
    func failedReplacementConstructionStaysRetired() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        dispatcher.replaceConnection(with: 1)
        dispatcher.dispatch(.beginFrame(frameSeq: 90, baseFrameSeq: 0, generation: 40))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.commitFrame(frameSeq: 90, seq: 0))
        let oldSnapshot = try #require(dispatcher.committedEditorSnapshot)

        let oldInput = Pipe()
        let oldOutput = Pipe()
        let replacementInput = Pipe()
        let replacementOutput = Pipe()
        var currentConnectionID: UInt64 = 1
        var oldDeliveries = 0
        let oldConnection = try ProtocolConnection(
            connectionID: 1,
            readHandle: oldInput.fileHandleForReading,
            writeHandle: oldOutput.fileHandleForWriting,
            resourcePolicy: .default,
            isCurrent: { $0 == currentConnectionID },
            consume: { _, _ in oldDeliveries += 1 },
            onTransportFailure: { _ in },
            onInputRejection: { _ in },
            onReaderDisconnect: { _, _ in }
        )
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: oldConnection.encoder)
        var activeEncoder: InputEncoder? = oldConnection.encoder
        var replacementDeliveries = 0
        var recoveryFailure: OutboundTransportInitializationError?
        oldConnection.start()
        try oldInput.fileHandleForWriting.write(contentsOf: framedKeyframe(generation: 40, frameSeq: 91))
        oldConnection.waitForBlockedReaderAdmissionForTesting()

        let replacement = ProtocolConnection.replacing(
            oldConnection,
            connectionID: 2,
            readHandle: replacementInput.fileHandleForReading,
            writeHandle: replacementOutput.fileHandleForWriting,
            resourcePolicy: .default,
            invalidate: {
                currentConnectionID = 2
                dispatcher.replaceConnection(with: 2)
                editorView.invalidateConnection()
                activeEncoder = nil
            },
            isCurrent: { $0 == currentConnectionID },
            consume: { _, _ in replacementDeliveries += 1 },
            onTransportFailure: { _ in },
            onInputRejection: { _ in },
            onReaderDisconnect: { _, _ in },
            onInitializationFailure: { recoveryFailure = $0 },
            encoderFactory: { _ in
                throw OutboundTransportInitializationError.nonBlockingSetupFailed(errorCode: EIO)
            }
        )

        #expect(replacement == nil)
        #expect(recoveryFailure == .nonBlockingSetupFailed(errorCode: EIO))
        #expect(oldConnection.isStoppedForTesting)
        #expect(oldConnection.acquireReaderAdmissionForTesting() == false)
        #expect(activeEncoder == nil)
        #expect(editorView.interactionSnapshot.inputEnabled == false)
        #expect(dispatcher.connectionID == 2)
        #expect(dispatcher.committedEditorSnapshot == nil)
        #expect(dispatcher.visibleEditorSnapshot == nil)
        dispatcher.promoteVisibleEditorPresentation(snapshot: oldSnapshot, localTransform: nil, connectionID: 1)
        #expect(dispatcher.visibleEditorSnapshot == nil)
        await Task.yield()
        #expect(oldDeliveries == 0)
        #expect(replacementDeliveries == 0)

        oldInput.fileHandleForWriting.closeFile()
        replacementInput.fileHandleForWriting.closeFile()
        oldOutput.fileHandleForReading.closeFile()
        replacementOutput.fileHandleForReading.closeFile()
    }

    @Test("SwiftUI editor updates preserve sidebar field-editor selection and IME composition")
    func swiftUIUpdatePreservesNativeSidebarEditing() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: SpyEncoder())
        let root = VStack {
            Text(gui.tabBarState.tabs.first?.label ?? "no tab")
            EditorView(editorNSView: editorView)
        }
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = frame
        let sidebarField = NSTextField(frame: NSRect(x: 12, y: 20, width: 180, height: 24))
        let container = NSView(frame: frame)
        container.addSubview(hostingView)
        container.addSubview(sidebarField)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        sidebarField.stringValue = "compose here"
        #expect(window.makeFirstResponder(sidebarField))
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        fieldEditor.setSelectedRange(NSRange(location: 2, length: 4))
        fieldEditor.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let selectedRange = fieldEditor.selectedRange()
        let markedRange = fieldEditor.markedRange()

        gui.tabBarState.update(activeIndex: 0, entries: [Wire.TabEntry(
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
            label: "updated.ex"
        )])
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()

        #expect(window.firstResponder === fieldEditor)
        #expect(fieldEditor.hasMarkedText())
        #expect(fieldEditor.selectedRange() == selectedRange)
        #expect(fieldEditor.markedRange() == markedRange)
    }

}
