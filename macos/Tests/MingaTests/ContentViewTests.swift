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

@MainActor
private final class ControlledPresentationWindow: NSWindow {
    var controlledOcclusionState: NSWindow.OcclusionState = .visible
    override var occlusionState: NSWindow.OcclusionState { controlledOcclusionState }
    override var isVisible: Bool { true }
}

@MainActor
private final class NativeCompletionQueue {
    typealias Completion = @MainActor @Sendable (Bool, Int) -> Void

    private(set) var completions: [Completion] = []
    private(set) var presentationCount = 0

    func append(_ completion: @escaping Completion) {
        completions.append(completion)
    }

    func complete(_ index: Int) {
        completions[index](true, Int(MTLCommandBufferStatus.completed.rawValue))
    }

    func present(_ drawable: CAMetalDrawable) {
        presentationCount += 1
        drawable.present()
    }
}

@MainActor
private struct NativeSaturationFixture {
    let dispatcher: CommandDispatcher
    let view: EditorNSView
    let window: ControlledPresentationWindow
    let completions: NativeCompletionQueue
}

enum NativeSurfaceCancellation: CaseIterable {
    case hidden
    case teardown
}

@Suite("Content view", .serialized)
@MainActor
struct ContentViewTests {
    private func makeEditorNSView(
        gui: GUIState,
        dispatcher: CommandDispatcher,
        encoder: OutboundActionEncoding,
        reduceMotionEnabled: Bool = false,
        factories overrideFactories: NativeRenderFactories? = nil
    ) throws -> EditorNSView {
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        var factories = overrideFactories ?? NativeRenderFactories.production
        if overrideFactories == nil {
            factories.makeLibrary = { device in
                Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
            }
        }
        let renderer = try #require(CoreTextMetalRenderer(factories: factories))
        renderer.setupRenderers(fontManager: fontManager)
        let view = EditorNSView(
            encoder: encoder,
            dispatcher: dispatcher,
            coreTextRenderer: renderer,
            fontManager: fontManager,
            reduceMotionEnabled: reduceMotionEnabled
        )
        view.editorInput = gui.editorInput
        return view
    }

    private func nativeInteractionContent(anchorTop: UInt32 = 10, contentEpoch: UInt32 = 1, fullRefresh: Bool = true, scrollSeq: UInt32 = 0, resident: Bool = true, extraRows: Int = 0) throws -> GUIWindowContent {
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
            contentEpoch: contentEpoch,
            layoutGeneration: 1,
            scrollSeq: scrollSeq
        )
        return try GUIWindowContent(
            windowId: 1,
            fullRefresh: fullRefresh,
            contentEpoch: contentEpoch,
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

    @Test("ordinary scroll echoes preserve wheel easing and trackpad presentation", arguments: [false, true])
    func scrollEchoPreservesPresentation(precise: Bool) throws {
        let gui = GUIState()
        var resetHandler: ((UInt16) -> Void)?
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 24, guiState: gui,
            applicationEffectSink: { effect in
                guard case .scrollPresentationReset(let windowID) = effect else { return }
                resetHandler?(windowID)
            }
        )
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
        resetHandler = { [weak editor] windowId in
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

    @Test("wrapped resident wheel reverses before EOF echoes without accumulating clamp debt", arguments: [false, true], [false, true])
    func wrappedWheelReversesAtEOF(precise: Bool, returnsToCommittedRank: Bool) throws {
        let gui = GUIState()
        var resetHandler: ((UInt16) -> Void)?
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 3, guiState: gui,
            applicationEffectSink: { effect in
                if case .scrollPresentationReset(let windowId) = effect { resetHandler?(windowId) }
            }
        )
        let fixture = WrappedScrollFixture()
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        var resets = 0
        resetHandler = { [weak editor] windowId in
            resets += 1
            editor?.resetScrollPresentation(windowId: windowId)
        }
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try fixture.content(top: returnsToCommittedRank ? 2 : 1, continuation: 0)))
        dispatcher.dispatch(.guiResidentSemantics(data: fixture.semantics(rows: fixture.rows)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let start = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorSnapshot(start)

        let point = editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight), to: nil)
        func wheel(_ rows: CGFloat, phase: NSEvent.Phase = []) {
            let event = MountedPreciseScrollEvent(
                locationInWindow: point, windowNumber: 0, deltaY: -rows * editor.cellHeight, phase: phase
            )
            event.preciseDeltas = precise
            editor.scrollWheel(with: event)
        }
        wheel(1, phase: precise ? .began : [])
        wheel(1, phase: precise ? .changed : [])
        wheel(1, phase: precise ? .changed : [])
        wheel(1, phase: precise ? .changed : [])
        #expect(editor.prepareLocalScrollPresentationForTesting(committedSnapshot: start).unconfirmedLines == (returnsToCommittedRank ? 1 : 2))
        wheel(-1, phase: precise ? .changed : [])
        let reversing = editor.prepareLocalScrollPresentationForTesting(committedSnapshot: start)
        #expect(reversing.unconfirmedLines == (returnsToCommittedRank ? 0 : 1))
        if precise {
            #expect(reversing.presentation?.offset.y == (returnsToCommittedRank ? 0 : reversing.cellHeight))
            #expect(spy.actions.last == .scrollBatch(windowID: 1, deltaLines: -1, direction: 1))
            wheel(0, phase: .ended)
        } else {
            #expect(spy.mouseEventCalls.last?.button == MOUSE_SCROLL_UP)
        }

        func echo(_ frameSeq: UInt32, continuation: UInt16, scrollSeq: UInt32 = 0) throws -> CommittedEditorSnapshot {
            dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: frameSeq - 1, generation: 1))
            dispatcher.dispatch(.guiWindowRowsDelta(data: fixture.delta(
                top: 2, continuation: continuation, scrollSeq: scrollSeq
            )))
            dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: 0))
            return try #require(dispatcher.committedEditorSnapshot)
        }
        // The first echo can reach the clamp before the reversal arrives. Keep
        // the display targeting rank 4 rather than jumping to rank 5 and back.
        let eof = try echo(2, continuation: 1)
        #expect(eof.content(for: 1)?.wrappedResidentAnchor == 5)
        let atEOF = editor.prepareLocalScrollPresentationForTesting(committedSnapshot: eof)
        #expect(atEOF.unconfirmedLines == -1)
        #expect(atEOF.lastConfirmedAnchorTop == 5)
        if precise { #expect(atEOF.presentation?.offset.y == -atEOF.cellHeight) }

        let reversed = try echo(3, continuation: 0)
        #expect(reversed.content(for: 1)?.scrollPresentation?.anchorTop == 2)
        #expect(editor.prepareLocalScrollPresentationForTesting(committedSnapshot: reversed).unconfirmedLines == 0)
        #expect(editor.prepareLocalScrollPresentationForTesting(committedSnapshot: reversed).unconfirmedLines == 0)
        #expect(resets == 0)
        dispatcher.promoteVisibleEditorSnapshot(reversed)
        wheel(1, phase: precise ? .began : [])
        #expect(editor.prepareLocalScrollPresentationForTesting(committedSnapshot: reversed).unconfirmedLines == 1)
        let authoritative = try echo(4, continuation: 0, scrollSeq: 1)
        #expect(resets == 1)
        #expect(editor.prepareLocalScrollPresentationForTesting(committedSnapshot: authoritative).presentation == nil)

        dispatcher.promoteVisibleEditorSnapshot(authoritative)
        wheel(1, phase: precise ? .began : [])
        #expect(editor.prepareLocalScrollPresentationForTesting(committedSnapshot: authoritative).unconfirmedLines == 1)
        let insert = GUIVisualRow(rowType: .wrapContinuation, rowId: 20, bufLine: 0, contentHash: 20, text: "added", spans: [])
        let grown = WrappedScrollFixture(groups: [4, 1, 4])
        var rows = fixture.rows
        rows.insert(insert, at: 3)
        dispatcher.dispatch(.beginFrame(frameSeq: 5, baseFrameSeq: 4, generation: 1))
        dispatcher.dispatch(.guiWindowRowsDelta(data: grown.delta(
            top: 2, continuation: 0, scrollSeq: 1, baseRowCount: 8,
            rowSplices: [GUIWindowRowSplice(startIndex: 3, deleteCount: 0, insertEntries: [.full(insert)])]
        )))
        dispatcher.dispatch(.guiResidentSemantics(data: grown.semantics(
            rows: rows, splices: [GUIResidentRowSplice(start: 3, deleteCount: 0, insertCount: 1)]
        )))
        dispatcher.dispatch(.commitFrame(frameSeq: 5, seq: 0))
        let edited = try #require(dispatcher.committedEditorSnapshot)
        #expect(edited.content(for: 1)?.wrappedResidentAnchor == 5)
        #expect(resets == 2)
        #expect(editor.prepareLocalScrollPresentationForTesting(committedSnapshot: edited).presentation == nil)
    }

    @Test("consecutive wrapped trackpad gestures survive one coalesced echo")
    func consecutiveWrappedTrackpadGesturesKeepPendingMotion() throws {
        let gui = GUIState()
        var resetHandler: ((UInt16) -> Void)?
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 3, guiState: gui,
            applicationEffectSink: { effect in
                if case .scrollPresentationReset(let windowId) = effect { resetHandler?(windowId) }
            }
        )
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy, reduceMotionEnabled: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = editor
        defer { window.contentView = nil }
        try #require(editor.window === window)
        resetHandler = { [weak editor] windowId in editor?.resetScrollPresentation(windowId: windowId) }

        let fixture = WrappedScrollFixture()
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try fixture.content(top: 0, continuation: 0)))
        dispatcher.dispatch(.guiResidentSemantics(data: fixture.semantics(rows: fixture.rows)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let initial = try #require(dispatcher.committedEditorSnapshot)
        #expect(initial.content(for: 1)?.wrappedResidentAnchor == 0)
        dispatcher.promoteVisibleEditorSnapshot(initial)

        let point = editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight), to: nil)
        func wheel(_ phase: NSEvent.Phase, deltaY: CGFloat) {
            editor.scrollWheel(with: MountedPreciseScrollEvent(
                locationInWindow: point, windowNumber: window.windowNumber, deltaY: deltaY, phase: phase
            ))
        }
        for expectedRank in 1...2 {
            wheel(.began, deltaY: -editor.cellHeight)
            wheel(.ended, deltaY: 0)
            let pending = editor.prepareLocalScrollPresentationForTesting(committedSnapshot: initial)
            #expect(pending.unconfirmedLines == expectedRank)
            #expect(pending.presentation?.offset.y == CGFloat(expectedRank) * pending.cellHeight)
            dispatcher.promoteVisibleEditorPresentation(snapshot: initial, localTransform: pending.presentation)
        }
        let batch = OutboundAction.scrollBatch(windowID: 1, deltaLines: 1, direction: 0)
        #expect(spy.actions.filter { $0 == batch }.count == 2)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiWindowRowsDelta(data: fixture.delta(top: 0, continuation: 2)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        let echo = try #require(dispatcher.committedEditorSnapshot)
        #expect(echo.frameSeq == 2)
        #expect(echo.content(for: 1)?.wrappedResidentAnchor == 2)

        let reconciled = editor.prepareLocalScrollPresentationForTesting(committedSnapshot: echo)
        #expect(reconciled.unconfirmedLines == 0)
        #expect((reconciled.presentation?.offset.y ?? 0) == 0)
    }

    @Test("mounted wrapped thumb draws and drags between continuations", .timeLimit(.minutes(1)))
    func mountedWrappedThumbTracksVisualRank() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 3, guiState: gui)
        let spy = SpyEncoder()
        let completions = QueuedCompletionCoordinator()
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        factories.observeCompletion = { completions.observeCompletion($0, $1) }
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy, factories: factories)
        let frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        let window = ControlledPresentationWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        editor.enableSetNeedsDisplay = false
        editor.autoResizeDrawable = false
        editor.frame = frame
        window.contentView = editor
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try #require(editor.window === window)

        let device = try #require(editor.device)
        let queue = try #require(device.makeCommandQueue())
        let scale = window.backingScaleFactor
        let width = Int(editor.bounds.width * scale)
        let height = Int(editor.bounds.height * scale)
        editor.drawableSize = CGSize(width: width, height: height)

        let fixture = WrappedScrollFixture() // Three logical lines fit, but their eight visual rows do not.
        func commit(_ sequence: UInt32, continuation: UInt16, lease: UInt64) throws -> CommittedEditorSnapshot {
            dispatcher.dispatch(.beginFrame(frameSeq: sequence, baseFrameSeq: sequence - 1, generation: 1))
            if sequence == 1 {
                dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
                dispatcher.dispatch(.setWindowBg(r: 0x10, g: 0x10, b: 0x10))
                dispatcher.dispatch(.guiGutterSeparator(col: 0, r: 0xEE, g: 0xEE, b: 0xEE))
                dispatcher.dispatch(.guiWindowContent(data: try fixture.content(top: 0, continuation: continuation)))
                dispatcher.dispatch(.guiResidentSemantics(data: fixture.semantics(rows: fixture.rows)))
            } else {
                dispatcher.dispatch(.guiWindowRowsDelta(data: fixture.delta(top: 0, continuation: continuation)))
            }
            dispatcher.dispatch(.guiTextPresentation(windowID: 1, presentationID: lease))
            dispatcher.dispatch(.commitFrame(frameSeq: sequence, seq: 0))
            let snapshot = try #require(dispatcher.committedEditorSnapshot)
            try #require(snapshot.frameSeq == sequence)
            return snapshot
        }

        func draw(_ sequence: UInt32) async throws -> ReadbackImage {
            let texture = try #require(OffscreenReadback.makeDrawableTexture(device: device, width: width, height: height))
            let drawable = ReadbackDrawable(texture: texture)
            editor.drawableProvider = { drawable }
            editor.draw(editor.bounds)
            try #require(editor.inFlightNativePresentationCountForTesting == 1)
            await completions.waitForPending(1)
            completions.flushFirst()
            try #require(editor.inFlightNativePresentationCountForTesting == 1)
            await completions.waitForPending(1)
            completions.flushFirst()
            try #require(dispatcher.visibleEditorSnapshot?.frameSeq == sequence)
            return try #require(await OffscreenReadback.read(texture: texture, queue: queue))
        }

        _ = try commit(1, continuation: 0, lease: 80)
        let first = try await draw(1)
        _ = try commit(2, continuation: 1, lease: 81)
        let next = try await draw(2)

        // The thumb is 3/8 of the track. At rank 1 its top moves by 1/8 of
        // the track despite the top logical line remaining 0.
        let x = width - Int(5 * scale)
        let nearTop = height / 16
        let belowInitialThumb = height * 7 / 16
        let thumbColor = first.pixel(x: x, y: nearTop)
        let trackColor = first.pixel(x: x, y: belowInitialThumb)
        #expect(thumbColor.rgbDistanceSquared(to: trackColor) > 0.001)
        #expect(next.pixel(x: x, y: nearTop) == trackColor)
        #expect(next.pixel(x: x, y: belowInitialThumb) == thumbColor)
        #expect(dispatcher.visibleEditorSnapshot?.content(for: 1)?.wrappedResidentAnchor == 1)

        func mouse(_ type: NSEvent.EventType, at trackFraction: CGFloat) throws -> NSEvent {
            let point = NSPoint(x: editor.bounds.width - 5, y: editor.bounds.height * trackFraction)
            return try #require(mouseEvent(
                type: type, locationInWindow: editor.convert(point, to: nil), windowNumber: window.windowNumber
            ))
        }
        editor.mouseDown(with: try mouse(.leftMouseDown, at: 3.0 / 16))
        #expect(spy.actions.last == .scrollToVisualRank(windowID: 1, presentationID: 81, rank: 1))

        // Refresh the displayed lease during the gesture, then leave a newer
        // commit unpresented. Neither the press lease nor the latest commit wins.
        let displayed = try commit(3, continuation: 1, lease: 82)
        dispatcher.promoteVisibleEditorSnapshot(displayed)
        _ = try commit(4, continuation: 1, lease: 83)
        editor.mouseDragged(with: try mouse(.leftMouseDragged, at: 5.0 / 16))
        #expect(editor.interactionSnapshot.scrollWindowId == 1)
        #expect(editor.interactionSnapshot.scrollOffset.y == editor.cellHeight)
        editor.mouseUp(with: try mouse(.leftMouseUp, at: 5.0 / 16))
        #expect(spy.actions.last == .scrollToVisualRank(windowID: 1, presentationID: 82, rank: 2))
    }

    @Test("wrapped fold clicks resolve visible resident rows at either gutter edge", arguments: [-1, 1])
    func wrappedGutterHitUsesDisplayedResidentRank(direction: Int) throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 2, guiState: gui)
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)

        let fixture = WrappedScrollFixture(groups: [2, 1, 1, 1, 1], fittedRows: 2)
        let rows = fixture.rows
        let scroll = fixture.scroll(top: 2, continuation: 0)
        let rect = GUICellRect(row: 0, col: 0, width: 80, height: 2)
        let gutterRect = GUICellRect(row: 0, col: 0, width: 7, height: 2)
        let geometry = GUIPaneGeometry(
            windowId: 1, totalRect: rect, contentRect: rect,
            textRect: GUICellRect(row: 0, col: 7, width: 73, height: 2), gutterRect: gutterRect, clipRect: rect,
            viewport: GUIViewportSummary(
                top: 2, left: 0, rows: 2, cols: 73, totalLines: UInt32(fixture.groups.count),
                visualRowOffset: 0, totalVisualRows: UInt32(rows.count)
            ),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 4, signColWidth: 3),
            hitRegions: [GUIHitRegion(kind: .gutter, rect: gutterRect, windowId: 1)]
        )
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: scroll.contentEpoch, cursorRow: 0, cursorCol: 0,
            cursorShape: .block, rowStoreMode: .sequentialWrapped, rows: rows, selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [], paneGeometry: geometry,
            scrollPresentation: scroll, accessibilityGeneration: 77
        )
        let entries = try #require(Wire.GutterEntries.resident(
            contentEpoch: scroll.contentEpoch, lineCount: UInt32(fixture.groups.count),
            overrides: (UInt32(1)...4).map { Wire.GutterEntry(bufLine: $0, displayType: .foldStart, signType: .none) }
        ))
        let gutter = Wire.WindowGutter(
            windowId: 1, contentRow: 0, contentCol: 0, contentHeight: 2, isActive: true, contentWidth: 80,
            cursorLine: 2, lineNumberStyle: .hybrid, lineNumberWidth: 4, signColWidth: 3, entries: entries
        )
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: content))
        dispatcher.dispatch(.guiResidentSemantics(data: fixture.semantics(rows: rows)))
        dispatcher.dispatch(.guiGutter(data: gutter))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let snapshot = try #require(dispatcher.committedEditorSnapshot)
        #expect(snapshot.surface(for: 1)?.visibleRowRange == 3..<5)
        dispatcher.promoteVisibleEditorPresentation(
            snapshot: snapshot,
            localTransform: EditorLocalPresentationTransform(
                windowId: 1, offset: CGPoint(x: editor.cellWidth * 2, y: CGFloat(direction) * editor.cellHeight)
            )
        )

        func click(row: CGFloat) throws {
            let point = NSPoint(
                x: CoreTextMetalRenderer.gutterLeftMarginPt + editor.cellWidth * 2.5,
                y: row * editor.cellHeight
            )
            editor.mouseDown(with: try #require(mouseEvent(
                type: .leftMouseDown, locationInWindow: editor.convert(point, to: nil), windowNumber: 0
            )))
        }
        try click(row: direction < 0 ? 0.5 : 1.5)
        #expect(spy.actions.last == .foldToggleAtLine(windowID: 1, generation: 77, bufferLine: direction < 0 ? 1 : 4))
        #expect(spy.mouseEventCalls.isEmpty)

        // The inverse transform maps this outside point to a fold inside the old viewport.
        try click(row: direction < 0 ? 2.5 : -0.5)
        let toggles = spy.actions.filter { action in
            if case .foldToggleAtLine = action { return true }
            return false
        }
        #expect(toggles.count == 1)
    }

    @Test("windowed wrapped wheel sends intent and waits for committed visual motion", arguments: [false, true])
    func windowedWrappedWheelIsCommitted(precise: Bool) throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 3, guiState: gui)
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let fixture = WrappedScrollFixture()
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try fixture.content(top: 2, continuation: 0, resident: false)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let start = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorSnapshot(start)
        let event = MountedPreciseScrollEvent(
            locationInWindow: editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight), to: nil),
            windowNumber: 0, deltaY: -editor.cellHeight, phase: precise ? .began : []
        )
        event.preciseDeltas = precise
        editor.scrollWheel(with: event)
        let pending = editor.prepareLocalScrollPresentationForTesting(committedSnapshot: start)
        #expect(pending.unconfirmedLines == 0)
        #expect((pending.presentation?.offset.y ?? 0) == 0)
        if precise {
            #expect(spy.actions.last == .scrollBatch(windowID: 1, deltaLines: 1, direction: 0))
        } else {
            #expect(spy.mouseEventCalls.last?.button == MOUSE_SCROLL_DOWN)
        }

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiWindowContent(data: try fixture.content(top: 2, continuation: 1, resident: false)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        let eof = try #require(dispatcher.committedEditorSnapshot)
        let surface = try #require(eof.surface(for: 1))
        #expect(surface.visibleRowRange == 0..<3)
        #expect(surface.content.rowStore.row(at: 0)?.rowId == 6)
        #expect((editor.prepareLocalScrollPresentationForTesting(committedSnapshot: eof).presentation?.offset.y ?? 0) == 0)
    }

    @Test("wheel ticks around an undisplayed echo keep moving forward", arguments: [-1, 1])
    func wheelReconciliationUsesRenderedAnchor(direction: Int) throws {
        let gui = GUIState()
        var resetHandler: ((UInt16) -> Void)?
        let dispatcher = CommandDispatcher(
            cols: 80, rows: 24, guiState: gui,
            applicationEffectSink: { effect in
                guard case .scrollPresentationReset(let windowID) = effect else { return }
                resetHandler?(windowID)
            }
        )
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

        resetHandler = { [weak editor] windowId in
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

    @Test("Reduce Motion sends discrete wheel input without local presentation")
    func reduceMotionSuppressesDiscreteWheelPresentation() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy, reduceMotionEnabled: true)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent()))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        let initial = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorPresentation(snapshot: initial, localTransform: nil)
        let event = MountedPreciseScrollEvent(
            locationInWindow: editor.convert(NSPoint(x: editor.cellWidth * 8, y: editor.cellHeight * 6), to: nil),
            windowNumber: 0, deltaY: -editor.cellHeight, phase: []
        )
        event.preciseDeltas = false

        editor.scrollWheel(with: event)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(editor.interactionSnapshot.scrollWindowId == nil)
        #expect(editor.interactionSnapshot.scrollOffset == .zero)
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
            ),
            accessibilityGeneration: UInt64(contentEpoch),
            accessibilityCursor: GUIAccessibilityCursor(row: cursorRow, utf16: UInt32(cursorCol))
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

    private func commitScrollFrame(
        _ dispatcher: CommandDispatcher,
        frameSeq: UInt32,
        anchorTop: UInt32,
        inputSeq: UInt32 = 0
    ) throws -> CommittedEditorSnapshot {
        dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: frameSeq - 1, generation: 1))
        if frameSeq == 1 {
            dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        }
        dispatcher.dispatch(.guiWindowContent(data: try nativeInteractionContent(anchorTop: anchorTop)))
        dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: inputSeq))
        return try #require(dispatcher.committedEditorSnapshot)
    }

    private func makeNativeSaturationFixture() throws -> NativeSaturationFixture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = CGSize(width: 640, height: 480)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let drawable = ReadbackDrawable(texture: texture)
        let completions = NativeCompletionQueue()
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        factories.observeCompletion = { _, completion in completions.append(completion) }
        factories.present = { completions.present($0) }

        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let view = try makeEditorNSView(
            gui: gui,
            dispatcher: dispatcher,
            encoder: ClosureOutboundActionEncoder { _ in .accepted },
            factories: factories
        )
        view.drawableProvider = { drawable }
        view.autoResizeDrawable = false
        view.frame = NSRect(origin: .zero, size: size)
        let window = ControlledPresentationWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.drawableSize = size
        return NativeSaturationFixture(
            dispatcher: dispatcher,
            view: view,
            window: window,
            completions: completions
        )
    }

    private func saturateNativePresentation(_ fixture: NativeSaturationFixture) throws {
        _ = try commitScrollFrame(fixture.dispatcher, frameSeq: 1, anchorTop: 10)
        for _ in 0..<3 { fixture.view.draw(fixture.view.bounds) }
        #expect(fixture.completions.completions.count == 3)
        #expect(fixture.view.inFlightNativePresentationCountForTesting == 3)

        _ = try commitScrollFrame(fixture.dispatcher, frameSeq: 2, anchorTop: 11)
        fixture.view.draw(fixture.view.bounds)
        #expect(fixture.view.hasPendingCapacityRedraw)
        #expect(fixture.completions.completions.count == 3)
    }

    private func establishVisibleFrameAndQueueSecondPresentationStage(
        _ fixture: NativeSaturationFixture
    ) {
        fixture.completions.complete(0)
        #expect(fixture.completions.completions.count == 4)
        guard fixture.completions.completions.count == 4 else { return }
        fixture.completions.complete(3)
        #expect(fixture.dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(fixture.completions.presentationCount == 1)
        #expect(fixture.view.hasCapacityRetryTaskForTesting)

        fixture.completions.complete(1)
        #expect(fixture.completions.completions.count == 5)
        #expect(fixture.view.inFlightNativePresentationCountForTesting == 2)
    }

    @Test("duplicate Agent dismissal cannot invalidate an in-flight replacement editor frame")
    func duplicateAgentDismissalPreservesReplacementPresentation() throws {
        let fixture = try makeNativeSaturationFixture()
        defer {
            fixture.window.orderOut(nil)
            fixture.window.contentView = nil
        }
        fixture.view.needsDisplay = false
        fixture.view.setAgentChatVisible(true)
        #expect(fixture.view.needsDisplay)
        fixture.view.setAgentChatVisible(true)

        _ = try commitScrollFrame(fixture.dispatcher, frameSeq: 1, anchorTop: 10)
        fixture.view.draw(fixture.view.bounds)
        try #require(fixture.completions.completions.count == 1)

        fixture.view.needsDisplay = false
        fixture.view.setAgentChatVisible(false)
        #expect(fixture.view.needsDisplay, "A genuine availability transition must schedule its replacement")
        _ = try commitScrollFrame(fixture.dispatcher, frameSeq: 2, anchorTop: 11)
        fixture.view.draw(fixture.view.bounds)
        try #require(fixture.completions.completions.count == 2)

        // AppKit owns redraw flags; duplicate dismissal must preserve both replacement completion stages.
        fixture.view.setAgentChatVisible(false)
        fixture.completions.complete(1)
        try #require(fixture.completions.completions.count == 3, "Duplicate dismissal must not discard the replacement before its drawable copy")
        fixture.view.setAgentChatVisible(false)
        fixture.completions.complete(2)
        #expect(fixture.dispatcher.visibleEditorSnapshot?.frameSeq == 2)
        #expect(fixture.completions.presentationCount == 1)

        fixture.completions.complete(0)
        #expect(fixture.completions.completions.count == 3, "The superseded Agent attempt must remain invalidated")
        #expect(fixture.dispatcher.visibleEditorSnapshot?.frameSeq == 2)
        #expect(fixture.view.inFlightNativePresentationCountForTesting == 0)
    }


    @Test("native saturation coalesces the newest committed snapshot and retries after complete slot release")
    func saturatedNativePresentationRetriesLatestCommit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device is required for deferred redraw coverage")
            return
        }
        let size = CGSize(width: 640, height: 480)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let drawable = ReadbackDrawable(texture: texture)
        typealias Completion = @MainActor @Sendable (Bool, Int) -> Void
        var completions: [Completion] = []
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        factories.observeCompletion = { _, completion in completions.append(completion) }
        factories.present = { $0.present() }

        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let view = try makeEditorNSView(
            gui: gui,
            dispatcher: dispatcher,
            encoder: ClosureOutboundActionEncoder { _ in .accepted },
            factories: factories
        )
        view.drawableProvider = { drawable }
        view.frame = NSRect(origin: .zero, size: size)
        view.drawableSize = size

        let firstInput = dispatcher.latency.stamp()
        _ = try commitScrollFrame(dispatcher, frameSeq: 1, anchorTop: 10, inputSeq: firstInput)
        for _ in 0..<3 { view.draw(view.bounds) }
        #expect(completions.count == 3)
        #expect(dispatcher.capturePresentationInputSeq() == 0)

        let deferredInput = dispatcher.latency.stamp()
        _ = try commitScrollFrame(dispatcher, frameSeq: 2, anchorTop: 11, inputSeq: deferredInput)
        view.draw(view.bounds)
        #expect(view.hasPendingCapacityRedraw)
        #expect(dispatcher.capturePresentationInputSeq() == deferredInput)
        #expect(completions.count == 3)

        let latestInput = dispatcher.latency.stamp()
        _ = try commitScrollFrame(dispatcher, frameSeq: 3, anchorTop: 12, inputSeq: latestInput)
        #expect(view.hasPendingCapacityRedraw)
        #expect(dispatcher.capturePresentationInputSeq() == latestInput)

        completions[0](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(completions.count == 4)
        completions[3](true, Int(MTLCommandBufferStatus.completed.rawValue))
        for _ in 0..<20 where view.capacityRetryScheduleCount == 0 {
            await Task.yield()
        }
        #expect(view.capacityRetryScheduleCount == 1)

        view.draw(view.bounds)
        #expect(completions.count == 5)
        #expect(!view.hasPendingCapacityRedraw)
        #expect(dispatcher.capturePresentationInputSeq() == 0)

        completions[4](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(completions.count == 6)
        completions[5](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 3)

        completions[1](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(completions.count == 7)
        completions[6](true, Int(MTLCommandBufferStatus.completed.rawValue))
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 3)
    }

    @Test("connection replacement cancels a deferred native redraw and old completions only release slots")
    func reconnectCancelsDeferredNativeRedraw() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = CGSize(width: 640, height: 480)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let drawable = ReadbackDrawable(texture: texture)
        typealias Completion = @MainActor @Sendable (Bool, Int) -> Void
        var completions: [Completion] = []
        var factories = NativeRenderFactories.production
        factories.makeLibrary = { device in
            Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
        }
        factories.observeCompletion = { _, completion in completions.append(completion) }
        factories.present = { $0.present() }

        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        dispatcher.replaceConnection(with: 1)
        let view = try makeEditorNSView(
            gui: gui,
            dispatcher: dispatcher,
            encoder: ClosureOutboundActionEncoder { _ in .accepted },
            factories: factories
        )
        view.drawableProvider = { drawable }
        view.frame = NSRect(origin: .zero, size: size)
        view.drawableSize = size

        _ = try commitScrollFrame(dispatcher, frameSeq: 1, anchorTop: 10)
        for _ in 0..<4 { view.draw(view.bounds) }
        #expect(view.hasPendingCapacityRedraw)
        #expect(completions.count == 3)

        view.invalidateConnection()
        dispatcher.replaceConnection(with: 2)
        #expect(!view.hasPendingCapacityRedraw)
        completions[0](true, Int(MTLCommandBufferStatus.completed.rawValue))
        await Task.yield()
        await Task.yield()

        #expect(view.capacityRetryScheduleCount == 0)
        #expect(completions.count == 3)
        #expect(dispatcher.visibleEditorSnapshot == nil)
    }

    @Test("occlusion retains one saturated redraw without a retry loop or late promotion")
    func occlusionRetainsOneDeferredNativeRedraw() async throws {
        let fixture = try makeNativeSaturationFixture()
        defer { fixture.window.contentView = nil }
        try saturateNativePresentation(fixture)
        establishVisibleFrameAndQueueSecondPresentationStage(fixture)

        fixture.window.controlledOcclusionState = []
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: fixture.window
        )
        fixture.completions.complete(4)
        #expect(fixture.view.inFlightNativePresentationCountForTesting == 1)
        fixture.completions.complete(2)
        #expect(fixture.completions.completions.count == 5)
        #expect(fixture.view.inFlightNativePresentationCountForTesting == 0)

        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.view.hasPendingCapacityRedraw)
        #expect(!fixture.view.hasCapacityRetryTaskForTesting)
        #expect(fixture.view.capacityRetryScheduleCount == 0)
        #expect(fixture.completions.presentationCount == 1)
        #expect(fixture.dispatcher.visibleEditorSnapshot?.frameSeq == 1)
    }

    @Test(
        "hidden state and teardown cancel a saturated redraw task and reject late promotion",
        arguments: NativeSurfaceCancellation.allCases
    )
    func unavailableSurfaceCancelsDeferredNativeRedraw(
        transition: NativeSurfaceCancellation
    ) async throws {
        let fixture = try makeNativeSaturationFixture()
        try saturateNativePresentation(fixture)
        establishVisibleFrameAndQueueSecondPresentationStage(fixture)

        switch transition {
        case .hidden:
            fixture.view.isHidden = true
        case .teardown:
            fixture.window.contentView = nil
        }
        #expect(!fixture.view.hasPendingCapacityRedraw)
        #expect(!fixture.view.hasCapacityRetryTaskForTesting)

        fixture.completions.complete(4)
        #expect(fixture.view.inFlightNativePresentationCountForTesting == 1)
        fixture.completions.complete(2)
        #expect(fixture.completions.completions.count == 5)
        #expect(fixture.view.inFlightNativePresentationCountForTesting == 0)

        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.view.capacityRetryScheduleCount == 0)
        #expect(fixture.completions.presentationCount == 1)
        #expect(fixture.dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        if transition == .hidden {
            fixture.window.contentView = nil
        }
    }

    @Test("draw reconciles a live trackpad prediction against its captured committed snapshot exactly once")
    @MainActor func liveTrackpadDrawUsesCapturedCommit() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: ClosureOutboundActionEncoder { _ in .accepted })
        let visible = try commitScrollFrame(dispatcher, frameSeq: 1, anchorTop: 10)
        dispatcher.promoteVisibleEditorSnapshot(visible)
        editorView.seedTrackpadReconciliationForTesting(windowId: 1, unconfirmedLines: 2, confirmedAnchorTop: 10, settling: false)

        let firstCommitted = try commitScrollFrame(dispatcher, frameSeq: 2, anchorTop: 11)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        let firstDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: firstCommitted)
        #expect(firstDraw.unconfirmedLines == 1)
        #expect(firstDraw.lastConfirmedAnchorTop == 11)
        #expect(firstDraw.presentation?.offset.y == firstDraw.cellHeight)

        let repeatedDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: firstCommitted)
        #expect(repeatedDraw.unconfirmedLines == 1)
        #expect(repeatedDraw.presentation?.offset.y == repeatedDraw.cellHeight)

        let secondCommitted = try commitScrollFrame(dispatcher, frameSeq: 3, anchorTop: 12)
        let secondDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: secondCommitted)
        #expect(secondDraw.unconfirmedLines == 0)
        #expect(secondDraw.presentation?.offset.y == 0)
    }

    @Test("draw reconciles gesture settle against the captured commit before deriving its offset")
    @MainActor func settleDrawUsesCapturedCommit() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: ClosureOutboundActionEncoder { _ in .accepted })
        let visible = try commitScrollFrame(dispatcher, frameSeq: 1, anchorTop: 10)
        dispatcher.promoteVisibleEditorSnapshot(visible)
        editorView.seedTrackpadReconciliationForTesting(windowId: 1, unconfirmedLines: 2, confirmedAnchorTop: 10, settling: true)

        let committed = try commitScrollFrame(dispatcher, frameSeq: 2, anchorTop: 11)
        let draw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: committed)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(draw.unconfirmedLines == 1)
        #expect(draw.presentation?.offset.y == draw.cellHeight)
    }

    @Test("conformance geometry uses spaced rows in the production IME and hit-test path", arguments: [Float(1), Float(1.2), Float(2)])
    func conformanceSpacedInputGeometry(spacing: Float) throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher,
                                          encoder: ClosureOutboundActionEncoder { _ in .accepted })
        let base = try nativeInteractionContent(anchorTop: 0)
        let content = try GUIWindowContent(
            windowId: 1, fullRefresh: true, contentEpoch: 1,
            cursorRow: 4, cursorCol: 3, cursorShape: .block,
            rows: base.rows, selection: nil, searchMatches: [],
            diagnosticUnderlines: [], documentHighlights: [], paneGeometry: base.paneGeometry)
        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiLineSpacing(spacing: spacing))
        dispatcher.dispatch(.guiWindowContent(data: content))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))

        // No window is needed for the production NSTextInputClient cursor rect.
        let rect = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let spacedHeight = editor.cellHeight * CGFloat(spacing)
        // CI mutation evidence accepts only these behavioral assertions, never renderer/setup failures.
        #expect(abs(rect.minY - 4 * spacedHeight) < 0.001, "[pixels3520.spacing.ime-row]")
        #expect(abs(rect.height - spacedHeight) < 0.001, "[pixels3520.spacing.ime-height]")

        // An unshown window supplies the screen conversion used by characterIndex;
        // it is neither ordered front nor granted Accessibility trust.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = editor
        let point = NSPoint(x: editor.cellWidth * 3.5, y: spacedHeight * 4.5)
        let screenPoint = window.convertPoint(toScreen: editor.convert(point, to: nil))
        #expect(editor.characterIndex(for: screenPoint) == 4 * 80 + 3, "[pixels3520.spacing.hit-test]")
        window.contentView = nil
    }

    @Test("conformance scroll publication consumes only the newly drawn echo")
    func conformanceScrollPublicationUsesCapturedCommit() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editor = try makeEditorNSView(gui: gui, dispatcher: dispatcher,
                                          encoder: ClosureOutboundActionEncoder { _ in .accepted })
        let initial = try commitScrollFrame(dispatcher, frameSeq: 1, anchorTop: 10)
        dispatcher.promoteVisibleEditorSnapshot(initial)
        editor.seedTrackpadReconciliationForTesting(
            windowId: 1, unconfirmedLines: 2, confirmedAnchorTop: 10, settling: false)
        let echo = try commitScrollFrame(dispatcher, frameSeq: 2, anchorTop: 11)
        // CI mutation evidence requires a marked captured-commit assertion and its evaluated expression.
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == initial.frameSeq, "[pixels3520.scroll.unpresented]")
        let draw = editor.prepareLocalScrollPresentationForTesting(committedSnapshot: echo)
        #expect(draw.unconfirmedLines == 1, "[pixels3520.scroll.acknowledged-lines]")
        #expect(draw.lastConfirmedAnchorTop == 11, "[pixels3520.scroll.confirmed-anchor]")
        #expect(draw.presentation?.offset.y == draw.cellHeight, "[pixels3520.scroll.draw-offset]")
        dispatcher.promoteVisibleEditorPresentation(snapshot: echo, localTransform: draw.presentation)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == echo.frameSeq, "[pixels3520.scroll.published-echo]")
        let repeated = editor.prepareLocalScrollPresentationForTesting(committedSnapshot: echo)
        #expect(repeated.unconfirmedLines == 1, "[pixels3520.scroll.repeated-lines]")
        #expect(repeated.presentation?.offset.y == draw.cellHeight, "[pixels3520.scroll.repeated-offset]")
    }

    @Test("draw reconciles upward batched commits against the latest captured snapshot exactly once")
    @MainActor func upwardBatchedCommitsUseLatestCapturedCommit() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: ClosureOutboundActionEncoder { _ in .accepted })
        let visible = try commitScrollFrame(dispatcher, frameSeq: 1, anchorTop: 10)
        dispatcher.promoteVisibleEditorSnapshot(visible)
        editorView.seedTrackpadReconciliationForTesting(windowId: 1, unconfirmedLines: -3, confirmedAnchorTop: 10, settling: false)

        _ = try commitScrollFrame(dispatcher, frameSeq: 2, anchorTop: 9)
        let latestCommitted = try commitScrollFrame(dispatcher, frameSeq: 3, anchorTop: 8)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        let firstDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: latestCommitted)
        #expect(firstDraw.unconfirmedLines == -1)
        #expect(firstDraw.lastConfirmedAnchorTop == 8)
        #expect(firstDraw.presentation?.offset.y == -firstDraw.cellHeight)

        let repeatedDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: latestCommitted)
        #expect(repeatedDraw.unconfirmedLines == -1)
        #expect(repeatedDraw.presentation?.offset.y == -repeatedDraw.cellHeight)
    }

    @Test("draw advances thumb-drag reconciliation from its captured commit")
    @MainActor func thumbDragDrawUsesCapturedCommit() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: ClosureOutboundActionEncoder { _ in .accepted })
        let visible = try commitScrollFrame(dispatcher, frameSeq: 1, anchorTop: 10)
        dispatcher.promoteVisibleEditorSnapshot(visible)
        editorView.seedThumbDragReconciliationForTesting(windowId: 1, targetLine: 12, committedAnchorTop: 10)

        let firstCommitted = try commitScrollFrame(dispatcher, frameSeq: 2, anchorTop: 11)
        let firstDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: firstCommitted)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(firstDraw.presentation?.offset.y == firstDraw.cellHeight)
        let repeatedDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: firstCommitted)
        #expect(repeatedDraw.presentation?.offset.y == repeatedDraw.cellHeight)

        let secondCommitted = try commitScrollFrame(dispatcher, frameSeq: 3, anchorTop: 12)
        let secondDraw = editorView.prepareLocalScrollPresentationForTesting(committedSnapshot: secondCommitted)
        #expect(secondDraw.presentation == nil)
    }

    @Test("resolves the current encoder instead of retaining the startup value")
    func currentEncoder() {
        let first = ClosureOutboundActionEncoder { _ in .accepted }
        let second = ClosureOutboundActionEncoder { _ in .accepted }
        var current: OutboundActionEncoding? = first

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
            mode: .agent,
            flags: [],
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
            mode: .agent,
            flags: [],
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

        let visiblePane = try #require(editorView.accessibilityChildren()?.first as? EditorPaneAccessibilityElement)
        #expect((visiblePane.accessibilityValue() as? String)?.contains("visible row 1") == true)
        #expect((visiblePane.accessibilityValue() as? String)?.contains("committed row") == false)
        #expect(visiblePane.accessibilityInsertionPointLineNumber() == 0)
        let scrollY = editorView.bounds.height * 0.75
        // The resident logical range is 0...99 for the visible frame, not
        // 0...299 from the unpresented commit.
        #expect(editorView.scrollTrackTargetForTesting(y: scrollY) == 74)

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
        #expect(spy.actions.last == .foldToggleAtLine(windowID: 1, generation: visibleSnapshot.content(for: 1)?.accessibilityGeneration ?? 0, bufferLine: 101))

        let committedSnapshot = try #require(dispatcher.committedEditorSnapshot)
        dispatcher.promoteVisibleEditorPresentation(snapshot: committedSnapshot, localTransform: nil)
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 2)
        let committedPane = try #require(editorView.accessibilityChildren()?.first as? EditorPaneAccessibilityElement)
        #expect((committedPane.accessibilityValue() as? String)?.contains("committed row 1") == true)
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
        let paneA = try #require(editorView.accessibilityChildren()?.first as? EditorPaneAccessibilityElement)
        let rangeA = paneA.accessibilitySelectedTextRange()
        #expect((paneA.accessibilityValue() as? String)?.contains("pane A row 0") == true)
        #expect(paneA.accessibilityInsertionPointLineNumber() == 0)

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "pane B successor", foldLine: 20, contentEpoch: 2, windowId: 2, paneCol: 40, paneWidth: 40, cursorRow: 2, cursorCol: 4)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 20, windowId: 2, paneCol: 40, paneWidth: 40)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(dispatcher.visibleEditorSnapshot?.frameSeq == 1)
        #expect(editorView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) == imeA)
        #expect(editorView.characterIndex(for: screenPoint) == characterA)
        let stillPaneA = try #require(editorView.accessibilityChildren()?.first as? EditorPaneAccessibilityElement)
        #expect(stillPaneA === paneA)
        #expect(stillPaneA.accessibilitySelectedTextRange() == rangeA)
        #expect(stillPaneA.accessibilityInsertionPointLineNumber() == 0)
        #expect((stillPaneA.accessibilityValue() as? String)?.contains("pane A row 0") == true)

        let click = try #require(mouseEvent(type: .leftMouseDown, locationInWindow: windowPoint, windowNumber: window.windowNumber))
        editorView.mouseDown(with: click)
        let visibleClick = try #require(spy.mouseEventCalls.last)

        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))
        let imeB = editorView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        #expect(imeB.minX > imeA.minX)
        #expect(editorView.characterIndex(for: screenPoint) != characterA)
        let paneB = try #require(editorView.accessibilityChildren()?.first as? EditorPaneAccessibilityElement)
        #expect(paneB !== paneA)
        #expect(paneA.accessibilityValue() == nil)
        #expect(paneB.accessibilitySelectedTextRange() != rangeA)
        #expect(paneB.accessibilityInsertionPointLineNumber() == 2)
        #expect((paneB.accessibilityValue() as? String)?.contains("pane B successor row 0") == true)
        editorView.mouseDown(with: click)
        let promotedClick = try #require(spy.mouseEventCalls.last)
        #expect(promotedClick.row != visibleClick.row || promotedClick.col != visibleClick.col)
    }

    @Test("composition commit is rejected after the active editor target changes")
    func compositionCommitCannotCrossEditorTargets() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(
            prefix: "original", foldLine: 10, contentEpoch: 1, windowId: 1
        )))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 10, windowId: 1)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        editorView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(
            prefix: "replacement", foldLine: 20, contentEpoch: 2, windowId: 2
        )))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 20, windowId: 2)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))

        editorView.insertText(
            "仮名",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(spy.keyPressCalls.isEmpty)
        #expect(editorView.hasMarkedText() == false)
    }

    @Test("editor group exposes stable pane text areas and preserves native focus semantics")
    @MainActor
    func editorPaneAccessibilityElements() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let spy = SpyEncoder()
        let editorView = try makeEditorNSView(gui: gui, dispatcher: dispatcher, encoder: spy)

        dispatcher.dispatch(.beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "left", foldLine: 10, contentEpoch: 1, windowId: 1, paneCol: 0, paneWidth: 40)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 10, windowId: 1, paneCol: 0, paneWidth: 40, isActive: true)))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "right", foldLine: 20, contentEpoch: 2, windowId: 2, paneCol: 40, paneWidth: 40)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 20, windowId: 2, paneCol: 40, paneWidth: 40, isActive: false)))
        dispatcher.dispatch(.commitFrame(frameSeq: 1, seq: 0))
        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editorView.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(nil))
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        #expect(editorView.accessibilityRole() == .group)
        #expect(editorView.accessibilityValue() == nil)
        let initialChildren = try #require(editorView.accessibilityChildren() as? [EditorPaneAccessibilityElement])
        #expect(initialChildren.count == 2)
        #expect(initialChildren.map { $0.accessibilityRole() } == [.textArea, .textArea])
        #expect(initialChildren.allSatisfy { $0.isAccessibilityEnabled() })
        #expect(initialChildren[0].accessibilityIdentifier() == "minga.editor.\(dispatcher.connectionID).1.1")
        #expect(initialChildren[1].accessibilityIdentifier() == "minga.editor.\(dispatcher.connectionID).2.2")
        #expect(initialChildren.compactMap { $0.accessibilityLabel() } == ["Editor pane 1", "Editor pane 2"])
        #expect(initialChildren[0].accessibilityFrame().maxX <= initialChildren[1].accessibilityFrame().minX)
        #expect((initialChildren[0].accessibilityValue() as? String)?.contains("left row 0") == true)
        #expect((initialChildren[1].accessibilityValue() as? String)?.contains("right row 0") == true)
        #expect(!initialChildren[0].isAccessibilityFocused())
        #expect(editorView.accessibilityFocusedUIElement == nil)
        let focusedElementSelector = NSSelectorFromString("accessibilityFocusedUIElement")
        #expect(editorView.responds(to: focusedElementSelector))
        #expect(editorView.perform(focusedElementSelector) == nil)

        #expect(window.makeFirstResponder(editorView))
        #expect(initialChildren[0].isAccessibilityFocused() == (NSApp.isActive && window.isKeyWindow))
        #expect(!initialChildren[1].isAccessibilityFocused())
        if NSApp.isActive && window.isKeyWindow {
            #expect(editorView.accessibilityFocusedUIElement as? EditorPaneAccessibilityElement === initialChildren[0])
            let selectorFocusedElement = editorView.perform(focusedElementSelector)?.takeUnretainedValue()
            #expect(selectorFocusedElement as? EditorPaneAccessibilityElement === initialChildren[0])

            let nativeTextField = NSTextField(frame: NSRect(x: 16, y: 16, width: 160, height: 24))
            editorView.addSubview(nativeTextField)
            #expect(window.makeFirstResponder(nativeTextField))
            _ = try #require(window.firstResponder as? NSTextView)
            #expect(editorView.accessibilityFocusedUIElement == nil)
            #expect(editorView.perform(focusedElementSelector) == nil)
            #expect(window.makeFirstResponder(editorView))
            nativeTextField.removeFromSuperview()
        } else {
            #expect(editorView.accessibilityFocusedUIElement == nil)
        }
        window.orderOut(nil)
        #expect(!initialChildren[0].isAccessibilityFocused())
        #expect(editorView.accessibilityFocusedUIElement == nil)
        let focusActionCount = spy.actions.count
        initialChildren[1].setAccessibilityFocused(true)
        await Task.yield()
        await Task.yield()
        #expect(window.isVisible)
        #expect(window.firstResponder === editorView)
        if NSApp.isActive && window.isKeyWindow {
            #expect(spy.actions.last == .focusWindow(windowID: 2, generation: 2))
        } else {
            #expect(spy.actions.count == focusActionCount)
        }
        #expect(!initialChildren[1].isAccessibilityFocused())

        let sameFrameChildren = try #require(editorView.accessibilityChildren() as? [EditorPaneAccessibilityElement])
        #expect(sameFrameChildren[0] === initialChildren[0])
        #expect(sameFrameChildren[1] === initialChildren[1])

        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "left", foldLine: 10, contentEpoch: 1, windowId: 1, paneCol: 0, paneWidth: 40)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 10, windowId: 1, paneCol: 0, paneWidth: 40, isActive: false)))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "right", foldLine: 20, contentEpoch: 2, windowId: 2, paneCol: 40, paneWidth: 40)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 20, windowId: 2, paneCol: 40, paneWidth: 40, isActive: true)))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))

        let switchedChildren = try #require(editorView.accessibilityChildren() as? [EditorPaneAccessibilityElement])
        #expect(switchedChildren[0] === initialChildren[0])
        #expect(switchedChildren[1] === initialChildren[1])
        if NSApp.isActive && window.isKeyWindow {
            #expect(editorView.accessibilityFocusedUIElement as? EditorPaneAccessibilityElement === initialChildren[1])
        } else {
            #expect(editorView.accessibilityFocusedUIElement == nil)
        }

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 0, generation: 1))
        dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        dispatcher.dispatch(.guiWindowContent(data: try nativeFoldInteractionContent(prefix: "replacement", foldLine: 30, contentEpoch: 3, windowId: 2, paneCol: 0, paneWidth: 80)))
        dispatcher.dispatch(.guiGutter(data: nativeFoldGutter(foldLine: 30, windowId: 2, paneCol: 0, paneWidth: 80, isActive: true)))
        dispatcher.dispatch(.commitFrame(frameSeq: 3, seq: 0))
        dispatcher.promoteVisibleEditorSnapshot(try #require(dispatcher.committedEditorSnapshot))

        let replacement = try #require(editorView.accessibilityChildren()?.first as? EditorPaneAccessibilityElement)
        #expect(replacement !== initialChildren[1])
        #expect(replacement.isAccessibilityEnabled())
        #expect(replacement.accessibilityRole() == .textArea)
        #expect(replacement.accessibilityIdentifier() == "minga.editor.\(dispatcher.connectionID).2.3")
        #expect(!initialChildren[0].isAccessibilityEnabled())
        #expect(!initialChildren[1].isAccessibilityEnabled())
        #expect(initialChildren[1].accessibilityRole() == .textArea)
        #expect(initialChildren[1].accessibilityIdentifier() == "minga.editor.\(dispatcher.connectionID).2.2")
        #expect(initialChildren[1].accessibilityValue() == nil)
        if NSApp.isActive && window.isKeyWindow {
            #expect(editorView.accessibilityFocusedUIElement as? EditorPaneAccessibilityElement === replacement)
        } else {
            #expect(editorView.accessibilityFocusedUIElement == nil)
        }
        let actionCount = spy.actions.count
        initialChildren[1].setAccessibilityFocused(true)
        #expect(spy.actions.count == actionCount)

        editorView.invalidateConnection()
        #expect(!replacement.isAccessibilityEnabled())
        #expect(replacement.accessibilityValue() == nil)
        #expect(replacement.accessibilityIdentifier() == "minga.editor.\(dispatcher.connectionID).2.3")
        #expect(editorView.accessibilityFocusedUIElement == nil)
        window.contentView = nil
        #expect(editorView.accessibilityFocusedUIElement == nil)
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
        #expect(intermediateEncoder.actions.isEmpty)
        #expect(replacementEncoder.mouseEventCalls.isEmpty)
        #expect(replacementEncoder.actions.isEmpty)

        let replacementGeneration = editorView.interactionSnapshot.inputConnectionGeneration
        editorView.mouseDown(with: leftDown)
        editorView.mouseUp(with: leftUp)
        editorView.otherMouseDown(with: middleDown)
        editorView.otherMouseUp(with: middleUp)
        editorView.performContextMenuActionForTesting("select_all", connectionGeneration: replacementGeneration)

        #expect(replacementEncoder.mouseEventCalls.map(\.eventType) == [MOUSE_PRESS, MOUSE_RELEASE, MOUSE_PRESS, MOUSE_RELEASE])
        #expect(replacementEncoder.actions.last == .executeCommand(name: "select_all"))
        #expect(replacementEncoder.actions.count == 5)
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

        connection.encoder.send(.paste(String(repeating: "x", count: 65_536)))
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
        var activeEncoder: OutboundActionEncoding? = oldConnection.encoder
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
