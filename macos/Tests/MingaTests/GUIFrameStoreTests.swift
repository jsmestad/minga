import MingaProtocol
@testable import MingaUI
import Observation
import Synchronization
import Testing

@Suite("GUI frame publication domains")
struct GUIFrameStoreTests {
    @Test("mutation and complete bundle precede channels in fixed order")
    @MainActor func publicationOrdering() {
        let store = GUIFrameStore()
        var backingValue = 0
        var events: [GUIFrameStore.PublicationEvent] = []
        var everyChannelSawFreshState = true

        store.onPublicationEvent = { event in
            events.append(event)
            if case .channel = event {
                everyChannelSawFreshState = everyChannelSawFreshState
                    && backingValue == 42
                    && store.installed.shell.lastCommitted?.frameSeq == 9
                    && store.installed.editor.lastCommitted?.frameSeq == 9
                    && store.installed.editorOverlay.lastCommitted?.frameSeq == 9
                    && store.installed.windowOverlay.lastCommitted?.frameSeq == 9
            }
        }

        store.publishCommitted(generation: 3, frameSeq: 9, impact: .all) {
            backingValue = 42
        }

        #expect(events == [
            .mutated,
            .installed,
            .channel(.shell),
            .channel(.editor),
            .channel(.editorOverlay),
            .channel(.windowOverlay)
        ])
        #expect(everyChannelSawFreshState)
        #expect(store.shell.value.revision == 1)
        #expect(store.editor.value.revision == 1)
        #expect(store.editorOverlay.value.revision == 1)
        #expect(store.windowOverlay.value.revision == 1)
    }

    @Test("focused publication leaves unrelated observable channels silent")
    @MainActor func unaffectedChannelsStaySilent() {
        let store = GUIFrameStore()
        let shellChanges = Mutex(0)
        let editorChanges = Mutex(0)
        let editorOverlayChanges = Mutex(0)
        let windowOverlayChanges = Mutex(0)

        withObservationTracking { _ = store.shell.value } onChange: { shellChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = store.editor.value } onChange: { editorChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = store.editorOverlay.value } onChange: { editorOverlayChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = store.windowOverlay.value } onChange: { windowOverlayChanges.withLock { $0 += 1 } }

        store.publishCommitted(generation: 1, frameSeq: 1, impact: .editorOverlay) {}

        #expect(shellChanges.withLock { $0 } == 0)
        #expect(editorChanges.withLock { $0 } == 0)
        #expect(editorOverlayChanges.withLock { $0 } == 1)
        #expect(windowOverlayChanges.withLock { $0 } == 0)
        #expect(store.installed.shell.lastCommitted?.frameSeq == 1)
        #expect(store.installed.editor.lastCommitted?.frameSeq == 1)
        #expect(store.installed.editorOverlay.lastCommitted?.frameSeq == 1)
        #expect(store.installed.windowOverlay.lastCommitted?.frameSeq == 1)
        #expect(store.shell.value.lastCommitted == nil)
        #expect(store.editor.value.lastCommitted == nil)
        #expect(store.editorOverlay.value.lastCommitted?.frameSeq == 1)
        #expect(store.windowOverlay.value.lastCommitted == nil)
    }

    @Test("impact-free valid commit installs identity without notifying channels")
    @MainActor func impactFreeCommit() {
        let store = GUIFrameStore()
        let channelValues = [
            store.shell.value,
            store.editor.value,
            store.editorOverlay.value,
            store.windowOverlay.value
        ]
        var events: [GUIFrameStore.PublicationEvent] = []
        store.onPublicationEvent = { events.append($0) }

        store.publishCommitted(generation: 2, frameSeq: 7, impact: []) {}

        #expect(events == [.mutated, .installed])
        #expect(store.installed.shell.lastCommitted?.frameSeq == 7)
        #expect(store.installed.editor.lastCommitted?.frameSeq == 7)
        #expect(store.installed.editorOverlay.lastCommitted?.frameSeq == 7)
        #expect(store.installed.windowOverlay.lastCommitted?.frameSeq == 7)
        #expect(store.shell.value == channelValues[0])
        #expect(store.editor.value == channelValues[1])
        #expect(store.editorOverlay.value == channelValues[2])
        #expect(store.windowOverlay.value == channelValues[3])
    }

    @Test("local publication preserves committed identity and false preview stays silent")
    @MainActor func localPublication() {
        let store = GUIFrameStore()
        store.publishCommitted(generation: 4, frameSeq: 12, impact: .shell) {}
        let shell = store.shell.value
        var events: [GUIFrameStore.PublicationEvent] = []
        store.onPublicationEvent = { events.append($0) }

        store.publishLocal(impact: .editorOverlay) {}

        #expect(store.editorOverlay.value.source == .local)
        #expect(store.editorOverlay.value.lastCommitted?.frameSeq == 12)
        #expect(store.shell.value == shell)
        #expect(events == [.mutated, .installed, .channel(.editorOverlay)])

        events.removeAll()
        let changed = store.publishLocalIfChanged(impact: .windowOverlay) { false }
        #expect(!changed)
        #expect(events.isEmpty)
    }

    @Test("shell and overlay publication preserve 65,536-row resident storage")
    @MainActor func focusedPublicationPreservesResidentStorage() throws {
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(65_536)
        for index in 0..<65_536 {
            let identity = UInt64(index + 1)
            let text = String(index)
            rows.append(GUIVisualRow(
                rowType: .normal,
                rowId: identity,
                bufLine: UInt32(index),
                contentHash: UInt32(index + 1),
                text: text,
                spans: []
            ))
        }
        let content = try GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            rows: rows,
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: []
        )
        let gui = GUIState(windowContents: [1: content])
        guard let original = gui.editorInput.windowContent(for: 1)?.rowStore else {
            Issue.record("resident window content missing before publication")
            return
        }

        gui.frameStore.publishLocal(impact: GUIFrameImpact.shell) {}
        guard let afterShell = gui.editorInput.windowContent(for: 1)?.rowStore else {
            Issue.record("resident window content missing after shell publication")
            return
        }
        #expect(afterShell.sharesStorage(with: original))

        gui.frameStore.publishLocal(impact: GUIFrameImpact.editorOverlay) {}
        guard let afterOverlay = gui.editorInput.windowContent(for: 1)?.rowStore else {
            Issue.record("resident window content missing after overlay publication")
            return
        }
        #expect(afterOverlay.sharesStorage(with: original))
    }

    @Test("semantic impact maps focused and implicit cross-region commands")
    func semanticImpact() throws {
        let content = try GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            rows: [],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: []
        )
        let cases: [(String, RenderCommand, GUIFrameImpact)] = [
            ("theme", .guiTheme(slots: []), .all),
            ("resident rows and geometry", .guiWindowContent(data: content), [.editor, .editorOverlay]),
            ("line spacing", .guiLineSpacing(spacing: 1.2), [.editor, .editorOverlay]),
            ("completion", .guiCompletion(visible: false, anchorRow: 0, anchorCol: 0, selectedIndex: 0, items: [], documentation: ""), .editorOverlay),
            ("hover", .guiHoverPopup(visible: false, anchorRow: 0, anchorCol: 0, focused: false, scrollOffset: 0, lines: []), .editorOverlay),
            ("sidebar", .guiFileTree(version: 1, treeFlags: 0, treeState: 0, selectedId: "", treeWidth: 0, rootPath: "", errorReason: "", entries: []), .shell),
            ("status", .guiStatusBar(status()), [.shell, .editor]),
            ("bottom panel inset", .guiBottomPanel(visible: false, activeTabIndex: 0, heightPercent: 0, filterPreset: 0, tabs: [], entries: []), [.shell, .windowOverlay]),
            ("extension panels", .guiExtensionPanel([]), [.shell, .windowOverlay]),
            ("resync overlay", .protocolError(message: "mismatch"), .windowOverlay),
            ("frame marker", .beginFrame(frameSeq: 1, baseFrameSeq: 0, generation: 1), []),
            ("window callback", .setWindowBg(r: 0, g: 0, b: 0), [])
        ]

        for (name, command, expected) in cases {
            #expect(GUIFrameImpact.impact(for: command) == expected, Comment(rawValue: name))
        }
    }

    private func status() -> StatusBarUpdate {
        StatusBarUpdate(
            contentKind: 0,
            mode: 0,
            cursorLine: 1,
            cursorCol: 1,
            lineCount: 1,
            flags: 0,
            lspStatus: 0,
            gitBranch: "",
            message: "",
            filetype: "",
            errorCount: 0,
            warningCount: 0,
            modelName: "",
            messageCount: 0,
            sessionStatus: 0,
            infoCount: 0,
            hintCount: 0,
            macroRecording: 0,
            parserStatus: 0,
            agentStatus: 0,
            gitAdded: 0,
            gitModified: 0,
            gitDeleted: 0,
            icon: "",
            iconColorR: 0,
            iconColorG: 0,
            iconColorB: 0,
            filename: "",
            diagnosticHint: "",
            backgroundSubagentCount: 0,
            backgroundSubagentLabel: ""
        )
    }
}

@Suite("GUI frame presentation metrics")
struct GUIFramePresentationMetricsTests {
    @Test("successful native draw and Metal milestones keep committed frame identity")
    @MainActor func successfulOutcomes() {
        let metrics = GUIFramePresentationMetrics()
        let frame = GUICommittedFrame(generation: 2, frameSeq: 8)
        let version = GUIFrameVersion(revision: 1, lastCommitted: frame, source: .committed)

        metrics.beginCommitted(frame: frame, impact: .all)
        #expect(metrics.snapshot().isEmpty)

        metrics.recordNativeDraw(domain: .shell, version: version)
        metrics.recordNativeDraw(domain: .editorOverlay, version: version)
        metrics.recordNativeDraw(domain: .windowOverlay, version: version)
        metrics.recordMetalSubmission(frameSeq: 7)
        #expect(metrics.snapshot().count == 3)

        metrics.recordMetalSubmission(frameSeq: 8)
        metrics.recordMetalPresented(frameSeq: 8)

        #expect(metrics.snapshot() == [
            .init(frame: frame, domain: .shell, outcome: .nativeDraw),
            .init(frame: frame, domain: .editorOverlay, outcome: .nativeDraw),
            .init(frame: frame, domain: .windowOverlay, outcome: .nativeDraw),
            .init(frame: frame, domain: .editor, outcome: .submitted),
            .init(frame: frame, domain: .editor, outcome: .presented)
        ])
    }

    @Test("superseded hidden unavailable and failed samples remain distinct")
    @MainActor func discardedOutcomes() {
        let metrics = GUIFramePresentationMetrics()
        let first = GUICommittedFrame(generation: 1, frameSeq: 1)
        let second = GUICommittedFrame(generation: 1, frameSeq: 2)

        metrics.beginCommitted(frame: first, impact: .all)
        metrics.beginCommitted(frame: second, impact: .shell)
        metrics.discard(domain: .shell, outcome: .hidden, frameSeq: 2)
        metrics.discard(domain: .editor, outcome: .unavailable, frameSeq: 1)
        metrics.discard(domain: .editorOverlay, outcome: .failed, frameSeq: 1)
        metrics.discard(domain: .windowOverlay, outcome: .superseded, frameSeq: 1)

        #expect(metrics.snapshot() == [
            .init(frame: first, domain: .shell, outcome: .superseded),
            .init(frame: second, domain: .shell, outcome: .hidden),
            .init(frame: first, domain: .editor, outcome: .unavailable),
            .init(frame: first, domain: .editorOverlay, outcome: .failed),
            .init(frame: first, domain: .windowOverlay, outcome: .superseded)
        ])
    }
}
