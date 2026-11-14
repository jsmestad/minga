import AppKit
import CoreText
import Metal
import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing
import ViewInspector
@testable import Minga

private final class PromptWheelEvent: NSEvent {
    let point: CGPoint
    let delta: CGFloat
    let precise: Bool
    let eventWindowNumber: Int

    init(point: CGPoint, delta: CGFloat, precise: Bool, windowNumber: Int) {
        self.point = point
        self.delta = delta
        self.precise = precise
        self.eventWindowNumber = windowNumber
        super.init()
    }

    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { eventWindowNumber }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { .began }
    override var momentumPhase: NSEvent.Phase { [] }
}

/// Observes removal of the actual aperture, not a SwiftUI onDisappear surrogate.
@MainActor
private final class PromptApertureRemovalProbeNSView: NSView {
    private let removed: AsyncStream<Void>.Continuation
    private var hasEnteredWindow = false

    init(removed: AsyncStream<Void>.Continuation) {
        self.removed = removed
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            hasEnteredWindow = true
        } else if hasEnteredWindow {
            removed.yield(())
        }
    }
}

@MainActor
private struct PromptModeObservationProbe: View {
    let state: AgentChatState
    let changed: AsyncStream<PromptMode>.Continuation

    var body: some View {
        Color.clear.onChange(of: state.promptMode) { _, mode in
            changed.yield(mode)
        }
    }
}

@Suite("Canonical multiline agent prompt", .serialized)
@MainActor
struct AgentPromptPresentationTests {
    private let generation: UInt64 = 0x0102030405060708

    /// These are already composed BEAM visual rows, not strings for the frontend to wrap.
    private func content(_ texts: [String], selection: Bool = false, cursorRow: UInt16 = 0, viewportTop: UInt32 = 0, visualRowOffset: UInt16 = 0, bufferLines: [UInt32]? = nil, sourceRow: UInt16 = 2) throws -> GUIWindowContent {
        let rect = GUICellRect(row: sourceRow, col: 3, width: 24, height: UInt16(texts.count))
        let geometry = GUIPaneGeometry(
            windowId: 65534, totalRect: rect, contentRect: rect, textRect: rect,
            gutterRect: GUICellRect(row: sourceRow, col: 3, width: 0, height: UInt16(texts.count)), clipRect: rect,
            viewport: GUIViewportSummary(top: viewportTop, left: 0, rows: UInt16(texts.count), cols: 24, totalLines: bufferLines.map { ($0.max() ?? viewportTop) + 1 } ?? (viewportTop + 1), visualRowOffset: visualRowOffset, totalVisualRows: 19),
            gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0), hitRegions: []
        )
        return try GUIWindowContent(
            windowId: 65534, fullRefresh: true, contentEpoch: 7, cursorRow: cursorRow, cursorCol: 0, cursorShape: .beam,
            rows: texts.enumerated().map { index, text in
                GUIVisualRow(rowType: .normal, rowId: UInt64(index + 1), bufLine: bufferLines?[index] ?? viewportTop, contentHash: UInt32(index + 1), text: text,
                    spans: [GUIHighlightSpan(startCol: 0, endCol: 24, fg: 0xFFFFFF, bg: 0, attrs: 0, fontWeight: 0, fontId: 0)])
            },
            selection: selection ? GUISelectionOverlay(type: .char, startRow: 0, startCol: 0, endRow: UInt16(texts.count - 1), endCol: 1) : nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [], paneGeometry: geometry,
            accessibilityLabel: "Agent prompt", accessibilityGeneration: 9,
            accessibilityCursor: GUIAccessibilityCursor(row: cursorRow, utf16: 0),
            accessibilitySelectionRanges: selection ? texts.enumerated().map { index, text in
                GUIAccessibilityRange(row: UInt16(index), startUTF16: 0, endUTF16: UInt32(text.utf16.count))
            } : []
        )
    }

    private func commit(_ content: GUIWindowContent, dispatcher: CommandDispatcher, frame: UInt32 = 1) throws -> CommittedEditorSnapshot {
        dispatcher.dispatch(.beginFrame(frameSeq: frame, baseFrameSeq: frame - 1, generation: 1))
        if frame == 1 {
            dispatcher.dispatch(.guiTheme(slots: PreviewFixtures.themeSlots))
        }
        dispatcher.dispatch(.guiLineSpacing(spacing: 1.25))
        dispatcher.dispatch(.guiWindowContent(data: content))
        dispatcher.dispatch(.guiTextPresentation(windowID: 65534, presentationID: generation + UInt64(frame - 1)))
        dispatcher.dispatch(.guiAgentChat(
            visible: true, status: .idle, model: "test", thinkingLevel: "medium", prompt: "read-only metadata",
            promptLineCount: 1, promptCursorLine: 0, promptCursorCol: 0, promptMode: .insert,
            promptVisibleRows: UInt8(content.paneGeometry?.viewport.rows ?? 1), promptCompletion: nil,
            pendingToolName: nil, pendingToolSummary: "", helpVisible: false, helpGroups: []
        ))
        dispatcher.dispatch(.commitFrame(frameSeq: frame, seq: 0))
        let snapshot = try #require(dispatcher.committedEditorSnapshot)
        try #require(snapshot.frameSeq == frame, "The fixture must publish the requested frame, not retain an older accepted snapshot")
        return snapshot
    }

    @Test("aperture preference callbacks keep defaults neutral and replace valid resized rectangles")
    func aperturePreferenceReduction() {
        let initial = CGRect(x: 20, y: 200, width: 240, height: 40)
        let resized = CGRect(x: 30, y: 100, width: 180, height: 80)
        let cases: [([CGRect], CGRect)] = [
            ([.zero, initial], initial),
            ([initial, .zero], initial),
            ([initial, resized], resized),
            ([.zero, .zero], .zero),
        ]
        for (inputs, expected) in cases {
            var reduced = AgentPromptApertureKey.defaultValue
            for input in inputs {
                AgentPromptApertureKey.reduce(value: &reduced, nextValue: { input })
            }
            #expect(reduced == expected)
        }
    }

    @Test("capacity uses maximum allocation, never the collapsed aperture height")
    func physicalFit() throws {
        let collapsed = AgentPromptPlacement(rect: CGRect(x: 20, y: 200, width: 243, height: 25), maximumHeight: 225)
        let grown = AgentPromptPlacement(rect: CGRect(x: 20, y: 25, width: 243, height: 200), maximumHeight: 225)
        let expected = OutboundAction.agentPromptFit(windowID: 65534, generation: generation, columns: 24, maxRows: 9)
        #expect(collapsed.fit(cellWidth: 10, rowPitch: 25, generation: generation) == expected)
        #expect(grown.fit(cellWidth: 10, rowPitch: 25, generation: generation) == expected)
        #expect(AgentPromptPlacement(rect: collapsed.rect, maximumHeight: 24).fit(cellWidth: 10, rowPitch: 25, generation: generation) == nil)
        let resized = AgentPromptPlacement(rect: CGRect(x: 0, y: 0, width: 149, height: 25), maximumHeight: 75)
        #expect(resized.fit(cellWidth: 10, rowPitch: 25, generation: generation) == .agentPromptFit(windowID: 65534, generation: generation, columns: 14, maxRows: 3))
    }

    @Test("one through eight committed visual rows retain Unicode, empty rows, and source identity", arguments: 1...8)
    func committedRows(count: Int) throws {
        let texts = Array(["ordinary soft wrap", "verylongwordcontinuation", "é界👩‍💻é", "", "explicit newline", "[paste 2 lines]", "expanded paste", ""].prefix(count))
        let bufferLines: [UInt32] = Array([0, 0, 0, 1, 2, 2, 3, 4].prefix(count))
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 60, rows: 30, guiState: gui)
        let font = FontManager(name: "Menlo", size: 13, scale: 1)
        dispatcher.fontManager = font
        let snapshot = try commit(content(texts, cursorRow: UInt16(count - 1), bufferLines: bufferLines), dispatcher: dispatcher)
        let surface = try #require(snapshot.surface(for: 65534))
        #expect(surface.content.rows.map(\.text) == texts)
        #expect(surface.content.rowStore.mode == .windowed)
        #expect(surface.content.scrollLeft == 0)
        #expect(snapshot.metadata.textPresentations[65534] == generation)
        #expect(gui.agentChatState.promptVisibleRows == UInt8(count))
        #expect(gui.agentChatState.promptRowPitch == CGFloat(font.cellHeight) * 1.25)
        let placement = AgentPromptPlacement(rect: CGRect(x: 40, y: 220, width: 240, height: CGFloat(count) * 25), maximumHeight: 200)
        let transform = AgentPromptPresentationTransform(placement: placement, surface: surface, cellWidth: 10, rowPitch: 25)
        let projection = EditorAccessibilityProjection.build(surface: surface, connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 10, cellHeight: 25, promptTransform: transform)
        #expect(projection.frameInView == placement.rect)
        #expect(projection.rows.count == count)
        #expect(projection.rows.last?.localOrigin.y == placement.rect.minY + CGFloat(count - 1) * 25)
        #expect(projection.insertionPointLineNumber == Int(bufferLines[count - 1]))
    }
    @Test("windowed continuation anchors and reverse caret motion retain the committed row origin")
    func windowedOverflowAndReverseMotion() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 60, rows: 30, guiState: gui)
        let scrolled = try commit(content(["continued", "tail"], selection: true, cursorRow: 1, viewportTop: 7, visualRowOffset: 4), dispatcher: dispatcher)
        let surface = try #require(scrolled.surface(for: 65534))
        #expect(surface.visibleRowRange == 0..<2)
        #expect(surface.paneGeometry.viewport.top == 7)
        #expect(surface.paneGeometry.viewport.visualRowOffset == 4)
        let projection = EditorAccessibilityProjection.build(surface: surface, connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 10, cellHeight: 25)
        #expect(projection.selectedText == "continuedtail")
        let reversed = try commit(content(["previous", "continued"], cursorRow: 0, viewportTop: 7, visualRowOffset: 3), dispatcher: dispatcher, frame: 2)
        let reversedSurface = try #require(reversed.surface(for: 65534))
        #expect(reversedSurface.visibleRowRange == 0..<2)
        #expect(reversed.metadata.textPresentations[65534] == generation + 1)
        #expect(reversedSurface.content.scrollLeft == 0)
        let reversedProjection = EditorAccessibilityProjection.build(surface: reversedSurface, connectionID: 1, isActivePane: true, localTransform: nil, cellWidth: 10, cellHeight: 25)
        #expect(reversedProjection.insertionPointLineNumber == 0)
        #expect(reversedProjection.value == "previouscontinued")
    }

    @Test("resize clips presented rows and captured drags, without wrapping or moving their caret")
    func resizeAndExactWidthCaret() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 60, rows: 30, guiState: gui)
        let snapshot = try commit(content([String(repeating: "x", count: 24), ""], cursorRow: 1), dispatcher: dispatcher)
        let surface = try #require(snapshot.surface(for: 65534))
        let sourceRows = surface.content.rows.enumerated().map { index, row in
            PresentedTextLayout.Row(
                rowIndex: UInt32(index), rowID: row.rowId, presentationRow: index,
                composedUTF16Start: 0, composedUTF16End: row.text.utf16.count,
                line: CTLineCreateWithAttributedString(NSAttributedString(string: row.text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])),
                origin: CGPoint(x: 30, y: 50 + CGFloat(index) * 25),
                rect: CGRect(x: 30, y: 50 + CGFloat(index) * 25, width: 240, height: 25)
            )
        }
        let pane = PresentedTextLayout.Pane(windowID: 65534, presentationID: generation, rect: CGRect(x: 30, y: 50, width: 240, height: 50), scrollOffset: .zero, rows: sourceRows)
        let fullPlacement = AgentPromptPlacement(rect: CGRect(x: 50, y: 200, width: 240, height: 50), maximumHeight: 200)
        let full = PresentedTextLayout(panes: [pane], promptTransform: AgentPromptPresentationTransform(placement: fullPlacement, surface: surface, cellWidth: 10, rowPitch: 25))
        #expect(full.cursor(windowID: 65534, row: 1, utf16: 0) == CGPoint(x: 50, y: 225))
        let narrowPlacement = AgentPromptPlacement(rect: CGRect(x: 80, y: 230, width: 120, height: 25), maximumHeight: 25)
        let narrow = PresentedTextLayout(panes: [pane], promptTransform: AgentPromptPresentationTransform(placement: narrowPlacement, surface: surface, cellWidth: 10, rowPitch: 25))
        #expect(narrow.panes.first?.rows.count == 1)
        #expect(narrow.cursor(windowID: 65534, row: 1, utf16: 0) == nil)
        let edge = try #require(narrow.hit(at: CGPoint(x: 600, y: 400), capturedWindowID: 65534))
        #expect(edge.target.rowID == 1 && edge.scrollY == 1)
        #expect(surface.content.rows[0].text.count == 24)
        #expect(surface.content.rows[1].text.isEmpty)
    }

    @Test("rejected prompt geometry cannot publish new composer height")
    func rejectedFrameRetainsChrome() throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 60, rows: 30, guiState: gui)
        let font = FontManager(name: "Menlo", size: 13, scale: 1)
        dispatcher.fontManager = font
        _ = try commit(content(["first", "second"]), dispatcher: dispatcher)
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        dispatcher.dispatch(.guiLineSpacing(spacing: 2.5))
        dispatcher.dispatch(.guiAgentChat(
            visible: true, status: .idle, model: "test", thinkingLevel: "medium", prompt: "rejected metadata",
            promptLineCount: 1, promptCursorLine: 0, promptCursorCol: 0, promptMode: .insert,
            promptVisibleRows: 8, promptCompletion: nil, pendingToolName: nil, pendingToolSummary: "",
            helpVisible: false, helpGroups: []
        ))
        dispatcher.dispatch(.guiGutter(data: Wire.WindowGutter(
            windowId: 42, contentRow: 0, contentCol: 0, contentHeight: 8, isActive: false,
            contentWidth: 24, cursorLine: 0, lineNumberStyle: .absolute, lineNumberWidth: 0, signColWidth: 0, entries: []
        )))
        dispatcher.dispatch(.commitFrame(frameSeq: 2, seq: 0))
        #expect(dispatcher.committedEditorSnapshot?.frameSeq == 1)
        #expect(gui.agentChatState.promptVisibleRows == 2)
        #expect(gui.agentChatState.prompt == "read-only metadata")
        #expect(gui.agentChatState.promptRowPitch == CGFloat(font.cellHeight) * 1.25)
    }


    @Test("production Metal draws retained source panes through the aperture after a drawable shrink", arguments: [UInt16(2), UInt16(26)])
    func productionPlacementAndInput(sourceRow: UInt16) async throws {
        _ = NSApplication.shared
        let font = FontManager(name: "Menlo", size: 13, scale: 1)
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 60, rows: 30, guiState: gui)
        let snapshot = try commit(content(["é界👩‍💻", "continuation", ""], selection: true, cursorRow: 2, sourceRow: sourceRow), dispatcher: dispatcher)
        let waiter = PresentationWaiter()
        var factories = offscreenNativeTestFactories()
        factories.reportFailure = { waiter.fail($0) }
        let renderer = try #require(makeOffscreenRenderer(factories: factories, fontManager: font))
        let spy = SpyEncoder()
        let editor = EditorNSView(encoder: spy, dispatcher: dispatcher, coreTextRenderer: renderer, fontManager: font)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 740, height: 620))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        container.addSubview(editor)
        // Attachment restores saved window configuration, so establish dimensions afterwards.
        window.setContentSize(CGSize(width: 740, height: 620))
        container.frame = CGRect(x: 0, y: 0, width: 740, height: 620)
        editor.frame = CGRect(x: 37, y: 53, width: 640, height: 480)
        editor.autoResizeDrawable = false
        editor.drawableSize = CGSize(width: 640, height: 480)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try #require(editor.window === window)
        try #require(editor.bounds.size == CGSize(width: 640, height: 480))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let texture = try #require(OffscreenReadback.makeDrawableTexture(device: device, width: 640, height: 480))
        let drawable = ReadbackDrawable(texture: texture, drawableID: 1)
        let pitch = CGFloat(font.cellHeight) * 1.25
        let placement = AgentPromptPlacement(rect: CGRect(x: 50, y: 250, width: font.cellWidth * 24, height: pitch * 3), maximumHeight: pitch * 8)
        let outcome = await waiter.awaitOutcome {
            renderer.render(snapshot: snapshot, fontManager: font, cursorBlinkVisible: true,
                drawableProvider: { drawable }, viewportSize: CGSize(width: 640, height: 480), contentScale: 1,
                promptPlacement: placement,
                onTextPresented: { snapshot, layout in
                    dispatcher.promoteVisibleEditorPresentation(snapshot: snapshot, localTransform: nil, textLayout: layout, connectionID: dispatcher.connectionID)
                    waiter.succeed(snapshot)
                })
        }
        guard case .presented = outcome else {
            Issue.record("Canonical prompt did not reach the production Metal surface: \(outcome)")
            return
        }
        let layout = try #require(dispatcher.visibleEditorPresentation?.textLayout)
        let pane = try #require(layout.panes.first)
        #expect(pane.windowID == 65534 && pane.presentationID == generation)
        #expect(pane.rect == placement.rect)
        #expect(pane.rows.count == 3)
        #expect(layout.cursor(windowID: 65534, row: 2, utf16: 0) == CGPoint(x: 50, y: 250 + pitch * 2))
        #expect(layout.hit(at: CGPoint(x: 51, y: 251))?.target.rowID == 1)
        let outside = CGPoint(x: 620, y: 470)
        let dragged = try #require(layout.hit(at: outside, capturedWindowID: 65534))
        #expect(dragged.target.rowID == 3 && dragged.scrollY == 1)
        #expect(layout.hit(at: outside) == nil)
        let image = try #require(await OffscreenReadback.read(texture: texture, queue: queue))
        let clear = image.pixel(x: 620, y: 470)
        #expect(clear.a == 0)
        #expect(image.occupancy(x0: 50, y0: 250, x1: Int(placement.rect.maxX), y1: Int(placement.rect.maxY), differingFrom: clear, thresholdSquared: 0.01) > 0)
        #expect(image.occupancy(x0: 0, y0: 0, x1: 640, y1: 240, differingFrom: clear, thresholdSquared: 0.01) == 0)
        var glyphPixels = 0
        for y in 250..<Int(placement.rect.maxY) {
            for x in 50..<Int(placement.rect.maxX) {
                let pixel = image.pixel(x: x, y: y)
                if pixel.r > 0.8, pixel.g > 0.8, pixel.b > 0.8 { glyphPixels += 1 }
            }
        }
        #expect(glyphPixels > 50, "The aperture must contain actual line-texture glyphs, not only its background or caret")

        let oldOwner = NSObject()
        let newOwner = NSObject()
        editor.setAgentPromptPlacement(placement, owner: ObjectIdentifier(oldOwner))
        editor.setAgentPromptPlacement(placement, owner: ObjectIdentifier(newOwner))
        editor.setAgentPromptPlacement(nil, owner: ObjectIdentifier(oldOwner))
        #expect(editor.agentPromptPlacement == placement)
        #expect(editor.layer?.isOpaque == false)
        let localPoint = CGPoint(x: 51, y: 251)
        #expect(editor.hitTest(editor.convert(localPoint, to: container)) === editor)
        #expect(editor.hitTest(editor.convert(CGPoint(x: 10, y: 10), to: container)) == nil)
        let windowPoint = editor.convert(localPoint, to: nil)
        let outsideWindowPoint = editor.convert(outside, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        editor.mouseDown(with: down)
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: outsideWindowPoint, modifierFlags: [], timestamp: 1.5, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        editor.mouseDragged(with: drag)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: outsideWindowPoint, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        editor.mouseUp(with: up)
        editor.insertText("typed 界", replacementRange: NSRange(location: NSNotFound, length: 0))
        let typed = spy.actions.compactMap { action -> UInt32? in
            if case .keyPress(let codepoint, _, _) = action { return codepoint }
            return nil
        }
        #expect(typed == "typed 界".unicodeScalars.map(\.value))
        let targets = spy.actions.compactMap { action -> EditorTextTarget? in
            if case .editorText(let target, _, _, _, _, _, _) = action { return target }
            return nil
        }
        #expect(targets.count == 3)
        #expect(targets.allSatisfy { $0.windowID == 65534 && $0.presentationID == generation })
        #expect(targets.last?.rowID == 3)
        #expect(!spy.actions.contains(.keyPress(codepoint: 0x69, modifiers: 0, sequence: 0)))
        let ime = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let localCaret = CGRect(x: 50, y: 250 + pitch * 2, width: font.cellWidth, height: pitch).intersection(placement.rect)
        let screenCaret = window.convertToScreen(editor.convert(localCaret, to: nil))
        #expect(abs(ime.minX - screenCaret.minX) < 0.001)
        #expect(abs(ime.minY - screenCaret.minY) < 0.001)
        #expect(abs(ime.width - screenCaret.width) < 0.001)
        #expect(abs(ime.height - screenCaret.height) < 0.001)
        let projection = try #require(editor.accessibilityChildren()?.first as? EditorPaneAccessibilityElement)
        let identifier = projection.accessibilityIdentifier()
        #expect(projection.isAccessibilityEnabled())
        #expect(projection.accessibilityRole() == .textArea)
        #expect(projection.accessibilityValue() as? String == "é界👩‍💻continuation")
        #expect(identifier == "minga.editor.\(dispatcher.connectionID).65534.9")
        #expect(projection.accessibilitySelectedText() == "é界👩‍💻continuation")
        editor.scrollWheel(with: PromptWheelEvent(point: windowPoint, delta: -pitch * 2, precise: true, windowNumber: window.windowNumber))
        editor.scrollWheel(with: PromptWheelEvent(point: windowPoint, delta: 1, precise: false, windowNumber: window.windowNumber))
        #expect(spy.actions.contains(.agentPromptScroll(windowID: 65534, generation: generation, deltaRows: 2)))
        #expect(spy.actions.contains(.agentPromptScroll(windowID: 65534, generation: generation, deltaRows: -1)))
        #expect(editor.interactionSnapshot.scrollOffset == .zero)
        editor.setAgentPromptPlacement(nil, owner: ObjectIdentifier(newOwner))
        #expect(editor.agentPromptPlacement == nil)
        #expect(editor.layer?.isOpaque == true)
        projection.invalidate()
        #expect(!projection.isAccessibilityEnabled())
        #expect(projection.accessibilityValue() == nil)
        #expect(projection.accessibilityRole() == .textArea)
        #expect(projection.accessibilityIdentifier() == identifier)
    }

    /// Mounted preference/placement evidence only, not final-window pixel evidence.
    @Test("production ContentView mounts one canonical prompt aperture and updates its preference on resize", .timeLimit(.minutes(1)))
    func mountedComposerPlacement() async throws {
        _ = NSApplication.shared
        let gui = GUIState()
        weak var editorReference: EditorNSView?
        let dispatcher = CommandDispatcher(
            cols: 60, rows: 30, guiState: gui,
            applicationEffectSink: { effect in
                if case .agentChatVisibilityChanged(let visible) = effect {
                    editorReference?.setAgentChatVisible(visible)
                }
            }
        )
        let font = FontManager(name: "Menlo", size: 13, scale: 1)
        dispatcher.fontManager = font
        let renderer = try #require(makeOffscreenRenderer(factories: offscreenNativeTestFactories(), fontManager: font))
        let editor = EditorNSView(encoder: SpyEncoder(), dispatcher: dispatcher, coreTextRenderer: renderer, fontManager: font)
        editorReference = editor
        editor.editorInput = gui.editorInput
        editor.statusBarState = gui.statusBarState
        _ = try commit(content(["canonical ", "continuation"], cursorRow: 1), dispatcher: dispatcher)
        gui.agentChatState.promptMode = .insert

        let apertureValues = AsyncStream.makeStream(of: CGRect.self, bufferingPolicy: .bufferingNewest(32))
        var preferences = apertureValues.stream.makeAsyncIterator()
        defer { apertureValues.continuation.finish() }
        let modeValues = AsyncStream.makeStream(of: PromptMode.self, bufferingPolicy: .bufferingNewest(8))
        var modes = modeValues.stream.makeAsyncIterator()
        defer { modeValues.continuation.finish() }
        let root = ContentView(
            gui: gui, encoder: { editor.encoder },
            editorGeometry: { EditorGeometry(editorNSView: editor) },
            chrome: .preview,
            onAgentChatVisibleChange: { editor.setAgentChatVisible($0) }
        ) {
            EditorView(editorNSView: editor)
        }
        .environment(\.editorFocusPolicy, editor.focusPolicy)
        .environment(\.agentPromptSurface, AgentPromptSurface(editor: editor))
        .onPreferenceChange(AgentPromptApertureKey.self) { rect in
            apertureValues.continuation.yield(rect)
        }
        .background(PromptModeObservationProbe(state: gui.agentChatState, changed: modeValues.continuation))
        let hostingView = NSHostingView(rootView: AnyView(root))
        let size = CGSize(width: 800, height: 600)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        defer {
            window.orderOut(nil)
            window.contentView = nil
            hostingView.rootView = AnyView(EmptyView())
        }

        let rowPitch = CGFloat(font.cellHeight) * 1.25
        hostingView.layoutSubtreeIfNeeded()
        var initialPreference: CGRect?
        while let value = await preferences.next() {
            if !value.isEmpty {
                initialPreference = value
                break
            }
        }
        let reported = try #require(initialPreference, "The production SwiftUI aperture preference must be delivered")
        hostingView.layoutSubtreeIfNeeded()
        let placement = try #require(editor.agentPromptPlacement)
        #expect(editor.window === window)
        #expect(editor.bounds.width > 0 && editor.bounds.height > 0)
        #expect(abs(placement.rect.width - reported.width) < 0.5)
        #expect(abs(placement.rect.height - reported.height) < 0.5)
        #expect(abs(placement.rect.height - rowPitch * 2) < 0.001)
        #expect(placement.maximumHeight > placement.rect.height)

        var descendants: [NSView] = []
        var pending: [NSView] = [hostingView]
        while let view = pending.popLast() {
            descendants.append(view)
            pending.append(contentsOf: view.subviews)
        }
        #expect(descendants.filter { $0 is EditorNSView }.count == 1)
        let aperture = try #require(descendants.compactMap { $0 as? AgentPromptApertureNSView }.first)
        #expect(aperture.editor === editor)
        #expect(!aperture.acceptsFirstResponder)
        #expect(!aperture.isAccessibilityElement())
        #expect(aperture.convert(aperture.bounds, to: editor) == placement.rect)
        for mode in [PromptMode.normal, .visual, .visualLine, .operatorPending, .insert] {
            gui.agentChatState.promptMode = mode
            let observedMode = await modes.next()
            try #require(observedMode == mode, "The mounted composer must process the mode change")
            hostingView.layoutSubtreeIfNeeded()
            #expect(aperture.convert(aperture.bounds, to: editor) == placement.rect, "Mode changes must preserve the text target beneath a selection gesture")
        }


        window.setContentSize(CGSize(width: 640, height: 480))
        hostingView.layoutSubtreeIfNeeded()
        var resizedPreference: CGRect?
        while let value = await preferences.next() {
            if !value.isEmpty, value.width < reported.width {
                resizedPreference = value
                break
            }
        }
        let resizedReported = try #require(resizedPreference, "Resize must deliver a changed outer aperture preference")
        hostingView.layoutSubtreeIfNeeded()
        let resized = try #require(editor.agentPromptPlacement)
        #expect(editor.window === window)
        #expect(aperture.editor === editor)
        #expect(resized.rect.width < placement.rect.width)
        #expect(resized.maximumHeight < placement.maximumHeight)
        #expect(abs(resized.rect.height - rowPitch * 2) < 0.001)
        #expect(abs(resized.rect.width - resizedReported.width) < 0.5)
        #expect(abs(resized.rect.height - resizedReported.height) < 0.5)
        #expect(aperture.convert(aperture.bounds, to: editor) == resized.rect)

        let removal = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        var removals = removal.stream.makeAsyncIterator()
        defer { removal.continuation.finish() }
        let removalProbe = PromptApertureRemovalProbeNSView(removed: removal.continuation)
        aperture.addSubview(removalProbe)
        try #require(removalProbe.window === window)
        hostingView.rootView = AnyView(EmptyView())
        hostingView.layoutSubtreeIfNeeded()
        let removed = await removals.next()
        try #require(removed != nil, "The actual native aperture must leave its mounted window")
        #expect(aperture.window == nil)
        #expect(editor.agentPromptPlacement == nil)
    }

    @Test("Send and Stop use explicit intents in insert, normal, visual and operator modes",
          arguments: [PromptMode.insert, .normal, .visual, .visualLine, .operatorPending])
    func completeControls(mode: PromptMode) throws {
        let state = AgentChatState(prompt: "a multiline\nprompt", promptMode: mode, promptVisibleRows: 2)
        var actions: [AgentPromptView.Action] = []
        let control = AgentPromptActionButton(state: state, sendAction: { actions.append($0) })
            .environment(\.themeColors, ThemeColors())
        try control.inspect().find(ViewType.Button.self).tap()
        #expect(actions == [.submit])
        state.status = .thinking
        try control.inspect().find(ViewType.Button.self).tap()
        #expect(actions == [.submit, .abort])
        state.prompt = ""
        try control.inspect().find(ViewType.Button.self).tap()
        #expect(actions == [.submit, .abort, .abort])
        state.status = .idle
        let idleButton = try control.inspect().find(ViewType.Button.self)
        #expect(idleButton.isDisabled())
        #expect(throws: InspectionError.self) { try idleButton.tap() }
        #expect(actions == [.submit, .abort, .abort])
    }
}
