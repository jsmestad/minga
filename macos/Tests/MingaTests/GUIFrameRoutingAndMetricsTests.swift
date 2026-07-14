import MingaProtocol
@testable import MingaUI
import Observation
import Synchronization
import Testing

@Suite("GUI frame routing")
struct GUIFrameRoutingTests {
    @Test("direct shell and overlay updates preserve 65,536-row resident storage")
    @MainActor func directUpdatesPreserveResidentStorage() throws {
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(65_536)
        for index in 0..<65_536 {
            rows.append(GUIVisualRow(
                rowType: .normal,
                rowId: UInt64(index + 1),
                bufLine: UInt32(index),
                contentHash: UInt32(index + 1),
                text: String(index),
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
        let original = try #require(gui.editorInput.windowContent(for: 1)?.rowStore)

        gui.tabBarState.update(activeIndex: 0, entries: [])
        let afterShell = try #require(gui.editorInput.windowContent(for: 1)?.rowStore)
        #expect(afterShell.sharesStorage(with: original))

        gui.completionState.update(
            visible: false,
            anchorRow: 0,
            anchorCol: 0,
            selectedIndex: 0,
            rawItems: [],
            documentation: ""
        )
        let afterOverlay = try #require(gui.editorInput.windowContent(for: 1)?.rowStore)
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
    @Test("pending native correlation is observable without semantic frame state")
    @MainActor func pendingNativeCorrelationIsObservable() {
        let metrics = GUIFramePresentationMetrics()
        let notificationCount = Mutex(0)

        withObservationTracking {
            _ = metrics.pendingFrame(domain: .shell)
        } onChange: {
            notificationCount.withLock { $0 += 1 }
        }

        metrics.beginCommitted(
            frame: GUICommittedFrame(generation: 3, frameSeq: 5),
            impact: .shell
        )

        #expect(notificationCount.withLock { $0 } == 1)
    }

    @Test("stale native draw and availability callbacks cannot resolve a newer frame")
    @MainActor func staleNativeCallbacks() throws {
        let metrics = GUIFramePresentationMetrics()
        let first = GUICommittedFrame(generation: 7, frameSeq: 30)
        let second = GUICommittedFrame(generation: 7, frameSeq: 31)

        metrics.beginCommitted(frame: first, impact: .shell)
        let staleExpected = try #require(metrics.pendingFrame(domain: .shell))
        metrics.beginCommitted(frame: second, impact: .shell)
        let currentExpected = try #require(metrics.pendingFrame(domain: .shell))

        metrics.recordNativeDraw(domain: .shell, expectedFrame: staleExpected)
        metrics.discardNativeDraw(
            domain: .shell,
            outcome: .unavailable,
            expectedFrame: staleExpected
        )
        #expect(metrics.snapshot() == [
            .init(frame: first, domain: .shell, outcome: .superseded)
        ])

        metrics.recordNativeDraw(domain: .shell, expectedFrame: currentExpected)
        #expect(metrics.snapshot() == [
            .init(frame: first, domain: .shell, outcome: .superseded),
            .init(frame: second, domain: .shell, outcome: .nativeDraw)
        ])
    }

    @Test("reused frame sequences cannot resolve across BEAM generations")
    @MainActor func reusedFrameSequencesStayGenerationCorrelated() throws {
        let metrics = GUIFramePresentationMetrics()
        let stale = GUICommittedFrame(generation: 1, frameSeq: 30)
        let current = GUICommittedFrame(generation: 2, frameSeq: 30)

        metrics.beginCommitted(frame: stale, impact: .editor)
        let capturedStale = try #require(metrics.pendingEditorFrame())
        metrics.beginCommitted(frame: current, impact: .editor)
        let capturedCurrent = try #require(metrics.pendingEditorFrame())

        metrics.recordMetalSubmission(presentationFrame: capturedStale)
        metrics.recordMetalPresented(presentationFrame: capturedStale)
        metrics.discard(domain: .editor, outcome: .failed, frame: capturedStale)
        #expect(metrics.snapshot() == [
            .init(frame: stale, domain: .editor, outcome: .superseded)
        ])

        metrics.recordMetalSubmission(presentationFrame: capturedCurrent)
        metrics.recordMetalPresented(presentationFrame: capturedCurrent)
        #expect(metrics.snapshot() == [
            .init(frame: stale, domain: .editor, outcome: .superseded),
            .init(frame: current, domain: .editor, outcome: .submitted),
            .init(frame: current, domain: .editor, outcome: .presented)
        ])
    }

    @Test("successful native draw and Metal milestones keep committed frame identity")
    @MainActor func successfulOutcomes() throws {
        let frame = GUICommittedFrame(generation: 2, frameSeq: 8)
        #expect(try successfulOutcomeSamples() == [
            .init(frame: frame, domain: .shell, outcome: .nativeDraw),
            .init(frame: frame, domain: .editorOverlay, outcome: .nativeDraw),
            .init(frame: frame, domain: .windowOverlay, outcome: .nativeDraw),
            .init(frame: frame, domain: .editor, outcome: .submitted),
            .init(frame: frame, domain: .editor, outcome: .presented)
        ])
    }

    @Test("superseded hidden unavailable and failed samples remain distinct")
    @MainActor func discardedOutcomes() {
        let first = GUICommittedFrame(generation: 1, frameSeq: 1)
        let second = GUICommittedFrame(generation: 1, frameSeq: 2)
        #expect(discardedOutcomeSamples() == [
            .init(frame: first, domain: .shell, outcome: .superseded),
            .init(frame: second, domain: .shell, outcome: .hidden),
            .init(frame: first, domain: .editor, outcome: .unavailable),
            .init(frame: first, domain: .editorOverlay, outcome: .failed),
            .init(frame: first, domain: .windowOverlay, outcome: .superseded)
        ])
    }

    @Test("exercised metrics outcomes exactly match the declared outcome cases")
    @MainActor func outcomeCoverageIsExhaustive() throws {
        let exercised = Set((try successfulOutcomeSamples() + discardedOutcomeSamples()).map(\.outcome))
        #expect(exercised == Set(GUIFramePresentationMetrics.Outcome.allCases))
    }

    @MainActor
    private func successfulOutcomeSamples() throws -> [GUIFramePresentationMetrics.Sample] {
        let metrics = GUIFramePresentationMetrics()
        let frame = GUICommittedFrame(generation: 2, frameSeq: 8)

        metrics.beginCommitted(frame: frame, impact: .all)
        #expect(metrics.snapshot().isEmpty)

        let shell = try #require(metrics.pendingFrame(domain: .shell))
        let editorOverlay = try #require(metrics.pendingFrame(domain: .editorOverlay))
        let windowOverlay = try #require(metrics.pendingFrame(domain: .windowOverlay))
        metrics.recordNativeDraw(domain: .shell, expectedFrame: shell)
        metrics.recordNativeDraw(domain: .editorOverlay, expectedFrame: editorOverlay)
        metrics.recordNativeDraw(domain: .windowOverlay, expectedFrame: windowOverlay)
        metrics.recordMetalSubmission(
            presentationFrame: GUICommittedFrame(generation: 1, frameSeq: frame.frameSeq)
        )
        #expect(metrics.snapshot().count == 3)

        metrics.recordMetalSubmission(presentationFrame: frame)
        metrics.recordMetalPresented(presentationFrame: frame)
        return metrics.snapshot()
    }

    @MainActor
    private func discardedOutcomeSamples() -> [GUIFramePresentationMetrics.Sample] {
        let metrics = GUIFramePresentationMetrics()
        let first = GUICommittedFrame(generation: 1, frameSeq: 1)
        let second = GUICommittedFrame(generation: 1, frameSeq: 2)

        metrics.beginCommitted(frame: first, impact: .all)
        metrics.beginCommitted(frame: second, impact: .shell)
        metrics.discard(domain: .shell, outcome: .hidden, frame: second)
        metrics.discard(domain: .editor, outcome: .unavailable, frame: first)
        metrics.discard(domain: .editorOverlay, outcome: .failed, frame: first)
        metrics.discard(domain: .windowOverlay, outcome: .superseded, frame: first)
        return metrics.snapshot()
    }
}
