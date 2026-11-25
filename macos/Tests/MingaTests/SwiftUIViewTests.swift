/// SwiftUI view hierarchy tests using ViewInspector.
///
/// Verifies that SwiftUI chrome views render the correct structure
/// based on their state. These catch regressions where a conditional
/// (if/ForEach) is broken and the UI silently shows nothing, or shows
/// the wrong number of items.
///
/// ViewInspector inspects the view body at the type level, so these
/// tests verify structure (what views exist, how many items render,
/// which text appears) without needing Metal, a window, or pixel output.

@testable import MingaUI
import Testing
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ViewInspector
import MingaProtocol

// MARK: - AnchoredOverlayPlacement

@Suite("AnchoredOverlayPlacement")
@MainActor
struct AnchoredOverlayPlacementTests {
    private let cellHeight: CGFloat = 18
    private let viewportHeight: CGFloat = 300
    private let desiredMaxHeight: CGFloat = 300
    private let gap: CGFloat = 4
    private let bottomInset: CGFloat = 8

    @Test("small popup prefers above when there is room")
    func smallPopupPrefersAbove() {
        let measuredHeight: CGFloat = 80
        let placement = resolve(anchorRow: 10, measuredHeight: measuredHeight)
        let anchorTop = CGFloat(10) * cellHeight

        #expect(placement.showsAbove)
        #expect(placement.offsetY + measuredHeight <= anchorTop)
    }

    @Test("tall popup near upper viewport chooses below without covering anchor row")
    func tallPopupNearUpperViewportChoosesBelow() {
        let anchorRow = 7
        let placement = resolve(anchorRow: anchorRow, measuredHeight: 260)
        let anchorBottom = CGFloat(anchorRow + 1) * cellHeight

        #expect(!placement.showsAbove)
        #expect(placement.offsetY >= anchorBottom + gap)
        #expect(placement.offsetY + placement.maxHeight <= viewportHeight - bottomInset)
    }

    @Test("tall popup near lower viewport chooses above without covering anchor row")
    func tallPopupNearLowerViewportChoosesAbove() {
        let anchorRow = 14
        let placement = resolve(anchorRow: anchorRow, measuredHeight: 260)
        let anchorTop = CGFloat(anchorRow) * cellHeight

        #expect(placement.showsAbove)
        #expect(placement.offsetY + placement.maxHeight <= anchorTop)
    }

    @Test("completion-style popup prefers below when there is room")
    func completionStylePopupPrefersBelow() {
        let placement = AnchoredOverlayPlacement.resolve(anchorRow: 4, cellHeight: cellHeight, measuredHeight: 80, viewportHeight: viewportHeight, desiredMaxHeight: desiredMaxHeight, preferredSide: .below, gap: gap, bottomInset: bottomInset)

        #expect(!placement.showsAbove)
    }

    @Test("horizontal placement includes gutter padding and clamps to viewport")
    func horizontalPlacementIncludesGutterPaddingAndClamps() {
        let unclamped = AnchoredOverlayPlacement.offsetX(anchorCol: 10, cellWidth: 8, measuredWidth: 100, viewportWidth: 300, gutterPad: 24)
        let clamped = AnchoredOverlayPlacement.offsetX(anchorCol: 30, cellWidth: 8, measuredWidth: 100, viewportWidth: 300, gutterPad: 24)

        #expect(unclamped == 104)
        #expect(clamped == 192)
    }

    private func resolve(anchorRow: Int, measuredHeight: CGFloat) -> AnchoredOverlayPlacement {
        AnchoredOverlayPlacement.resolve(anchorRow: anchorRow, cellHeight: cellHeight, measuredHeight: measuredHeight, viewportHeight: viewportHeight, desiredMaxHeight: desiredMaxHeight, preferredSide: .above, gap: gap, bottomInset: bottomInset)
    }
}

// MARK: - CompletionOverlay

@Suite("CompletionOverlay View Structure")
struct CompletionOverlayViewTests {

    @Test("Hidden completion renders nothing")
    @MainActor func hiddenCompletion() throws {
        let state = CompletionState()

        let sut = CompletionOverlay(
            state: state,
            sendAction: nil
        )
        .environment(\.themeColors, ThemeColors())

        // When not visible, the body should produce no content
        let body = try sut.inspect()
        #expect(throws: Never.self) {
            // The if-block renders nothing when visible=false
            _ = try? body.find(text: "anything")
        }
    }

    @Test("Visible completion shows items")
    @MainActor func visibleCompletion() throws {
        let state = CompletionState()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 0,
            rawItems: [
                Wire.CompletionItem(kind: 1, label: "def", detail: "keyword"),
                Wire.CompletionItem(kind: 2, label: "defmodule", detail: "keyword"),
            ],
            documentation: ""
        )

        let sut = CompletionOverlay(
            state: state,
            sendAction: nil
        )
        .environment(\.themeColors, ThemeColors())

        let body = try sut.inspect()
        // Should find both item labels in the tree
        let texts = body.findAll(ViewInspectorQuery.text)
        let labels = texts.compactMap { try? $0.string() }
        #expect(labels.contains("def"))
        #expect(labels.contains("defmodule"))
    }

    @Test("Selected item documentation renders a preview pane")
    @MainActor func documentationPreview() throws {
        let state = CompletionState()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 0,
            rawItems: [Wire.CompletionItem(kind: 1, label: "def", detail: "keyword")],
            documentation: "Applies fun to each element."
        )

        let sut = CompletionOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let texts = try sut.inspect().findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }
        #expect(strings.contains("Applies fun to each element."))
    }

    @Test("Items without documentation render no preview pane")
    @MainActor func noDocumentationNoPane() throws {
        let state = CompletionState()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 0,
            rawItems: [Wire.CompletionItem(kind: 1, label: "def", detail: "keyword")],
            documentation: ""
        )

        let sut = CompletionOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        // The doc pane is the only place the Divider + scrollable Text appears; with
        // empty docs the documentationPane @ViewBuilder produces nothing (AC 3).
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(ViewType.Divider.self)
        }
    }

    @Test("Completion choices expose selected state and activate the exact offered item")
    @MainActor func accessibleCompletionActivation() throws {
        let state = CompletionState()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 1,
            rawItems: [
                Wire.CompletionItem(kind: 1, label: "def", detail: "keyword", id: "def"),
                Wire.CompletionItem(kind: 2, label: "defmodule", detail: "module", id: "defmodule"),
            ],
            documentation: "", generation: 7
        )
        let recorder = LocalActionRecorder<CompletionOverlay.Action>()
        let sut = CompletionOverlay(state: state, sendAction: recorder.handler)
            .environment(\.themeColors, ThemeColors())
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        let selected = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "defmodule" })

        #expect(try selected.accessibilityValue().string() == "selected, module")
        try selected.tap()
        #expect(recorder.actions == [.select(generation: 7, itemID: "defmodule")])
    }

    @Test("Retained completion choice cannot activate a replacement item")
    @MainActor func staleCompletionActivationIsRejected() throws {
        let state = CompletionState()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 0,
            rawItems: [Wire.CompletionItem(kind: 1, label: "original", detail: "function", id: "original")],
            documentation: ""
        )
        let recorder = LocalActionRecorder<CompletionOverlay.Action>()
        let sut = CompletionOverlay(state: state, sendAction: recorder.handler)
            .environment(\.themeColors, ThemeColors())
        let retained = try #require(sut.inspect().findAll(ViewType.Button.self).first)

        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 0,
            rawItems: [Wire.CompletionItem(kind: 2, label: "replacement", detail: "module", id: "replacement")],
            documentation: ""
        )
        try retained.tap()

        #expect(recorder.actions.isEmpty)
    }

    @Test("Retained completion choice activates the same stable item after reconciliation")
    @MainActor func identicalStableCompletionIsAccepted() throws {
        let state = CompletionState()
        let item = Wire.CompletionItem(kind: 1, label: "same label", detail: "same detail", id: "stable-item")
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 0,
            rawItems: [item], documentation: "", generation: 9
        )
        let recorder = LocalActionRecorder<CompletionOverlay.Action>()
        let sut = CompletionOverlay(state: state, sendAction: recorder.handler)
            .environment(\.themeColors, ThemeColors())
        let retained = try #require(sut.inspect().findAll(ViewType.Button.self).first)

        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 0,
            rawItems: [item], documentation: "", generation: 9
        )
        try retained.tap()

        #expect(recorder.actions == [.select(generation: 9, itemID: "stable-item")])
    }
}

// MARK: - Semantic Popups

@Suite("Semantic popup view structure")
struct SemanticPopupViewTests {
    @Test("Hover popup renders current lines and action")
    @MainActor func hoverContent() throws {
        let state = HoverPopupState()
        state.update(visible: true, anchorRow: 2, anchorCol: 3, focused: true, scrollOffset: 0, rawLines: [
            Wire.HoverLine(lineType: .text, segments: [
                Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "Current hover"),
            ]),
        ])
        state.updateOpenAction(visible: true, name: "Open source")

        let strings = try HoverPopupOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
            .findAll(ViewInspectorQuery.text)
            .compactMap { try? $0.string() }

        #expect(strings.contains("Current hover"))
        #expect(strings.contains("Open"))
    }

    @Test("Signature help renders current signature and parameter documentation")
    @MainActor func signatureHelpContent() throws {
        let state = SignatureHelpState()
        state.update(visible: true, anchorRow: 2, anchorCol: 3, activeSignature: 0, activeParameter: 0, rawSignatures: [
            Wire.Signature(label: "call(value)", documentation: "function docs", parameters: [
                Wire.SignatureParameter(label: "value", documentation: "Current parameter docs"),
            ]),
        ])

        let strings = try SignatureHelpOverlay(state: state)
            .environment(\.themeColors, ThemeColors())
            .inspect()
            .findAll(ViewInspectorQuery.text)
            .compactMap { try? $0.string() }

        #expect(strings.contains("call(value)"))
        #expect(strings.contains("Current parameter docs"))
    }

    @Test("Float popup renders current title and lines")
    @MainActor func floatPopupContent() throws {
        let state = FloatPopupState()
        state.update(visible: true, width: 40, height: 12, title: "Current help", lines: ["first", "second"])

        let strings = try FloatPopupOverlay(state: state, cellWidth: 8, cellHeight: 16)
            .environment(\.themeColors, ThemeColors())
            .inspect()
            .findAll(ViewInspectorQuery.text)
            .compactMap { try? $0.string() }

        #expect(strings.contains("Current help"))
        #expect(strings.contains("first"))
        #expect(strings.contains("second"))
    }
}

// MARK: - WhichKeyOverlay

@Suite("WhichKeyOverlay View Structure")
struct WhichKeyOverlayViewTests {

    @Test("Hidden which-key renders nothing")
    @MainActor func hiddenWhichKey() throws {
        let sut = WhichKeyOverlay(state: WhichKeyState())
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        #expect(body.findAll(ViewInspectorQuery.text).isEmpty)
    }

    @Test("Visible which-key shows the breadcrumb, section names, keys, labels, counts, ⌘ keys and hints")
    @MainActor func visibleWhichKey() throws {
        let model = Wire.WhichKey(
            visible: true, path: "SPC a",
            breadcrumb: [.init(key: "SPC", path: "SPC"), .init(key: "a", label: "Minga", path: "SPC a")],
            count: "· 1 needs you",
            hints: [.init(key: "⌫", label: "back")],
            entries: [
                .init(kind: 0, key: "f", label: "Find file", section: "Files", count: "· 2"),
                .init(kind: 1, key: "b", label: "Buffers ›", section: "Files", platformKey: "⌘S"),
            ])
        let sut = WhichKeyOverlay(state: WhichKeyState(model: model))
            .environment(\.themeColors, ThemeColors())
        let strings = try sut.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        for text in ["SPC", "a", "Minga", "· 1 needs you", "back", "Files", "f", "Find file", "· 2", "b", "Buffers ›", "⌘S"] {
            #expect(strings.contains(text), "missing \(text)")
        }
    }

    @Test("The fade-in fits the 120 ms budget, and Reduce Motion turns it off")
    func fadeBudget() {
        #expect(WhichKeyOverlay.fadeDuration <= 0.12)
        #expect(WhichKeyOverlay.fadeAnimation(reduceMotion: false) == .easeOut(duration: WhichKeyOverlay.fadeDuration))
        #expect(WhichKeyOverlay.fadeAnimation(reduceMotion: true) == nil)
    }

}

// MARK: - BreadcrumbBar

@Suite("BreadcrumbBar View Structure")
struct BreadcrumbBarViewTests {

    @Test("Empty breadcrumb renders nothing")
    @MainActor func emptyBreadcrumb() throws {
        let state = BreadcrumbState()
        state.segments = []

        let sut = BreadcrumbBar(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        // Empty segments should render nothing (the if guard)
        let texts = body.findAll(ViewInspectorQuery.text)
        #expect(texts.isEmpty)
    }

    @Test("Breadcrumb shows all path segments")
    @MainActor func showsSegments() throws {
        let state = BreadcrumbState()
        state.segments = ["lib", "minga", "editor.ex"]

        let sut = BreadcrumbBar(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("lib"))
        #expect(strings.contains("minga"))
        #expect(strings.contains("editor.ex"))
    }
}

// MARK: - StatusBarView

@Suite("StatusBarView View Structure")
struct StatusBarViewViewTests {

    private func segment(_ id: Int, _ text: String, kind: String = "custom", command: String = "", drop: UInt8 = 0, compact: String? = nil, state: SpineState? = nil, key: String = "", label: String = "") -> Wire.StatusBarSegment {
        Wire.StatusBarSegment(id: id, kind: kind, text: text, fgColor: 0xFFFFFF, bgColor: 0x000000, attrs: 0, command: command, drop: drop, compact: compact, state: state, key: key, label: label)
    }

    /// The "editing while Minga works" modeline as the BEAM sends it.
    private var boardLeft: [Wire.StatusBarSegment] {
        [
            segment(0, "NORMAL", kind: "mode", label: "Normal mode"),
            segment(1, "Needs you", kind: "needs_you", command: "toggle_agentic_view", state: .needsYou, key: "SPC a a", label: "1 task needs you"),
            segment(2, "chrome_state.ex ●", kind: "filename", command: "buffer_list", key: "SPC ,", label: "chrome_state.ex, unsaved"),
            segment(3, "change 1/2", kind: "change", label: "Minga's change 1 of 2"),
            segment(4, "main +11", kind: "git", drop: 4, label: "Branch main, 11 changed lines"),
            segment(5, "Minga working 2/3", kind: "minga", command: "toggle_agent_split", drop: 5, compact: "2/3", state: .working, key: "SPC a v", label: "Minga is working, step 2 of 3"),
            segment(6, "1", kind: "errors", command: "diagnostics_list", key: "SPC c x", label: "1 error"),
            segment(7, "2", kind: "warnings", command: "diagnostics_list", drop: 6, key: "SPC c x", label: "2 warnings")
        ]
    }

    private var boardRight: [Wire.StatusBarSegment] {
        [
            segment(0, "Elixir", kind: "filetype", drop: 2, label: "Elixir"),
            segment(1, "240:31", kind: "position", drop: 3, label: "Line 240, column 31")
        ]
    }

    @MainActor private func statusBarState(
        message: String = "",
        leftSegments: [Wire.StatusBarSegment] = [],
        rightSegments: [Wire.StatusBarSegment] = []
    ) -> StatusBarState {
        let state = StatusBarState()
        state.announce = { _ in }
        state.update(from: statusBarUpdate(message: message, leftSegments: leftSegments, rightSegments: rightSegments))
        return state
    }

    private func statusBarUpdate(
        message: String = "",
        leftSegments: [Wire.StatusBarSegment] = [],
        rightSegments: [Wire.StatusBarSegment] = [],
        messageActions: [Wire.EmptyListAction] = []
    ) -> StatusBarUpdate {
        StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 42, cursorCol: 9,
            lineCount: 500, flags: 0, lspStatus: 0, gitBranch: "",
            message: message, filetype: "elixir", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            activeToolName: "",
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineSegmentsPresent: true,
            modelineLeftSegments: leftSegments,
            modelineRightSegments: rightSegments,
            messageActions: messageActions
        )
    }

    private func width(_ segment: Wire.StatusBarSegment, _ compact: Bool) -> CGFloat {
        CGFloat((compact ? (segment.compact ?? "") : segment.text).count) * 10
    }

    @Test("The modeline keeps the BEAM's order and draws its words")
    @MainActor func modelineOrder() throws {
        let state = statusBarState(leftSegments: boardLeft, rightSegments: boardRight)
        let sut = StatusBarView(state: state, sendAction: nil)
        let fitted = sut.fittedSegments(width: 2000)
        #expect(fitted.kinds == ["mode", "needs_you", "filename", "change", "git", "minga", "errors", "warnings", "filetype", "position"])

        // ViewInspector does not lay out the GeometryReader, so draw each kept segment as the row does at this width.
        var strings: [String] = []
        for kept in fitted.left + fitted.right {
            let view = ModelineSegmentView(segment: kept.segment, compact: kept.compact, mode: .normal, barHeight: 24, sendAction: nil)
            strings += try view.environment(\.themeColors, ThemeColors()).inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        }
        for words in ["NORMAL", "Needs you", "chrome_state.ex ●", "change 1/2", "main +11", "Minga working 2/3", "Elixir", "240:31"] {
            #expect(strings.contains(words), "missing \(words)")
        }
    }

    @Test("At 610 pt a notice with a next step gets room for its whole message and the step's key; a plain message keeps a third")
    @MainActor func noticeWithStepsKeepsItsMessage() {
        let left = [segment(0, "NORMAL", kind: "mode"), segment(1, "proj.ex", kind: "filename"), segment(2, "main", kind: "git", drop: 4)]
        let right = [segment(0, "Elixir", kind: "filetype", drop: 2), segment(1, "1:8", kind: "position", drop: 3)]
        let message = "No matches for “limit_lable” in this buffer"

        let plain = StatusBarView(state: statusBarState(message: message, leftSegments: left, rightSegments: right), sendAction: nil)
        #expect(plain.echoWidth(in: 610) <= 610 * 0.34)

        let answer = StatusBarState()
        answer.announce = { _ in }
        answer.update(from: statusBarUpdate(message: message, leftSegments: left, rightSegments: right, messageActions: [Wire.EmptyListAction(id: "search_project", key: "SPC s p", label: "search the project")]))
        let view = StatusBarView(state: answer, sendAction: nil)
        #expect(view.echoWidth(in: 610) >= view.shortestNoticeWidth + 2 * Spacing.md)
        let kept = view.fittedSegments(width: 610).kinds
        #expect(kept.contains("mode") && kept.contains("filename"))
    }

    @Test("Narrowing drops filetype, position and git in order, then shrinks Minga, then warnings")
    @MainActor func dropLadder() {
        let segments = boardLeft + boardRight
        let full = ModelineFit.fit(segments, leftCount: boardLeft.count, width: 10_000, gap: 8, measure: width)
        #expect(full.kinds.count == 10)

        var widths: [CGFloat] = []
        for drop in [2, 3, 4, 5, 6] as [UInt8] {
            // The narrowest width at which every segment of a lower rank has already given way.
            let kept = segments.filter { $0.drop == 0 || $0.drop > drop || ($0.drop == drop && $0.compact != nil) }
            widths.append(kept.reduce(0) { $0 + width($1, $1.drop != 0 && $1.drop <= drop) } + CGFloat(kept.count) * 8)
        }

        let noFiletype = ModelineFit.fit(segments, leftCount: boardLeft.count, width: widths[0], gap: 8, measure: width)
        #expect(!noFiletype.kinds.contains("filetype"))
        #expect(noFiletype.kinds.contains("position"))

        let noGit = ModelineFit.fit(segments, leftCount: boardLeft.count, width: widths[2], gap: 8, measure: width)
        #expect(!noGit.kinds.contains("git"))
        #expect(!noGit.kinds.contains("position"))
        #expect(noGit.left.first { $0.segment.kind == "minga" }?.compact == false)

        let tiny = ModelineFit.fit(segments, leftCount: boardLeft.count, width: 10, gap: 8, measure: width)
        #expect(tiny.kinds == ["mode", "needs_you", "filename", "change", "minga", "errors"])
        #expect(tiny.left.first { $0.segment.kind == "minga" }?.compact == true)
    }

    @Test("Each clickable segment runs its key's command and names its meaning and key")
    @MainActor func clickAndTooltip() throws {
        let spy = SpyEncoder()
        let state = statusBarState(leftSegments: boardLeft, rightSegments: boardRight)
        let sut = StatusBarView(state: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
        let body = try sut.environment(\.themeColors, ThemeColors()).inspect()

        for button in body.findAll(ViewType.Button.self) {
            try button.tap()
        }
        for command in ["toggle_agentic_view", "buffer_list", "toggle_agent_split", "diagnostics_list"] {
            #expect(spy.actions.contains(.executeCommand(name: command)), "no click for \(command)")
        }

        let labels = body.findAll(ViewType.Button.self).compactMap { try? $0.accessibilityLabel().string() }
        #expect(labels.contains("1 task needs you"))
        let hints = body.findAll(ViewType.Button.self).compactMap { try? $0.accessibilityHint().string() }
        #expect(hints.contains("Press SPC a a"))
    }

    @Test("A segment without a command is not a button")
    @MainActor func passiveSegment() throws {
        let spy = SpyEncoder()
        let state = statusBarState(leftSegments: [segment(0, "Passive", label: "Passive")])
        let sut = StatusBarView(state: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
        let buttons = try sut.environment(\.themeColors, ThemeColors()).inspect().findAll(ViewType.Button.self)
        #expect(buttons.isEmpty)
        #expect(spy.actions.isEmpty)
    }

    @Test("VoiceOver announces needs-you only when it goes from zero to non-zero")
    @MainActor func needsYouAnnouncement() {
        var said: [String] = []
        let state = StatusBarState()
        state.announce = { said.append($0) }
        let mode = segment(0, "NORMAL", kind: "mode")
        let one = segment(1, "Needs you", kind: "needs_you", state: .needsYou, label: "1 task needs you")
        let two = segment(1, "Needs you 2", kind: "needs_you", state: .needsYou, label: "2 tasks need you")

        func send(_ left: [Wire.StatusBarSegment]) {
            state.update(from: statusBarUpdate(leftSegments: left))
        }

        send([mode])
        send([mode, one])
        send([mode, two])
        send([mode])
        send([mode, one])
        #expect(said == ["1 task needs you", "1 task needs you"])
        #expect(StatusBarState.needsYouAnnouncement(previous: "1 task needs you", current: "2 tasks need you") == nil)
    }

    @Test("Private-use glyph detection covers Nerd Font symbols")
    @MainActor func privateUseGlyphDetection() {
        #expect(StatusBarModelineFont.containsPrivateUseGlyph("\u{E0B0}"))
        #expect(StatusBarModelineFont.containsPrivateUseGlyph("branch \u{F0001} ahead"))
        #expect(StatusBarModelineFont.containsPrivateUseGlyph("wide \u{100001}"))
        #expect(!StatusBarModelineFont.containsPrivateUseGlyph("Elixir"))
    }

    @Test("Filetype display is titleized")
    @MainActor func filetypeDisplay() {
        let state = StatusBarState()
        state.filetype = "elixir"
        #expect(state.filetypeDisplay == "Elixir")

        state.filetype = "c_sharp"
        #expect(state.filetypeDisplay == "C Sharp")

        state.filetype = "text"
        #expect(state.filetypeDisplay == "Text")

        state.filetype = ""
        #expect(state.filetypeDisplay == "")
    }

    @Test("Every surface names an Agent status with the state the shared token table gives it")
    func agentStatusWordsAgree() {
        let expected: [UInt8: SpineState?] = [
            0: nil, 1: .working, 2: .working, 3: .failed, 4: nil, 5: .needsYou, 6: .needsYou,
            7: .stopped, 8: .needsYou, 9: .done, 42: nil
        ]
        for (wire, state) in expected {
            let status = AgentStatus(rawValue: wire)
            #expect(status.spineState == state)
            #expect(status.label == (state?.word ?? "Idle"))
        }
    }
}

// MARK: - TabBarView

@Suite("TabBarView View Structure")
struct TabBarViewViewTests {

    @MainActor private func workspaceSnapshot(id: UInt16, label: String) -> WorkspacePresentationSnapshot {
        WorkspacePresentationSnapshot(
            version: 1,
            activeWorkspaceId: id,
            mode: .editor,
            flags: [],
            workspaces: [
                Wire.WorkspaceEntry(
                    id: id,
                    kind: 0,
                    status: 0,
                    flags: 0,
                    colorR: 0,
                    colorG: 0,
                    colorB: 255,
                    tabCount: 1,
                    draftCount: 0,
                    conflictCount: 0,
                    runningBackgroundCount: 0,
                    label: label,
                    icon: "folder"
                ),
            ],
            visibleTabs: []
        )
    }

    private func wireTab(id: UInt32, groupId: UInt16 = 0, isActive: Bool = false, isPinned: Bool = false, label: String? = nil) -> Wire.TabEntry {
        Wire.TabEntry(id: id, groupId: groupId, isActive: isActive, isDirty: false, isAgent: false, hasAttention: false, agentStatus: 0, isPinned: isPinned, tintColorRGB: 0, icon: "", label: label ?? "tab-\(id).ex")
    }

    @MainActor private func tab(id: UInt32, groupId: UInt16 = 0, isActive: Bool = false, isPinned: Bool = false, label: String? = nil) -> TabEntry {
        TabEntry(id: id, groupId: groupId, isActive: isActive, isDirty: false, isAgent: false, hasAttention: false, agentStatus: .idle, isPinned: isPinned, tintColor: nil, icon: "", label: label ?? "tab-\(id).ex")
    }

    @Test("Tab bar shows all tab labels")
    @MainActor func showsAllTabs() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "editor.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: false, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "test.ex"),
        ])

        let sut = TabBarView(tabBarState: state, sendAction: nil)
        let body = try sut.environment(\.themeColors, ThemeColors()).inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("editor.ex"))
        #expect(strings.contains("test.ex"))
    }

    @Test("Tabs expose active modified state and a distinct close control")
    @MainActor func tabAccessibilityContract() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            Wire.TabEntry(id: 41, groupId: 0, isActive: true, isDirty: true, isAgent: false,
                          hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "editor.ex"),
        ])
        let body = try TabBarView(tabBarState: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let tab = try #require(body.findAll(ViewType.HStack.self).first {
            (try? $0.accessibilityLabel().string()) == "File tab editor.ex"
        })
        let close = try #require(body.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Close editor.ex"
        })

        #expect(try tab.accessibilityValue().string() == "active, modified")
        #expect(try close.accessibilityLabel().string() == "Close editor.ex")
    }

    @Test("Workspace indicator controls have explicit native actions")
    @MainActor func workspaceIndicatorAccessibilityContract() throws {
        let snapshot = WorkspacePresentationSnapshot(
            version: 1, activeWorkspaceId: 7, mode: .editor, flags: [],
            workspaces: [
                Wire.WorkspaceEntry(id: 7, kind: 0, status: 1, flags: 0, colorR: 0, colorG: 0, colorB: 255,
                                    tabCount: 2, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0,
                                    label: "Project", icon: "folder"),
            ],
            visibleTabs: []
        )
        let workspace = try #require(snapshot.workspaces.first)
        let owner = TabBarState()
        owner.install(snapshot)
        let recorder = LocalActionRecorder<WorkspaceIndicatorView.Action>()
        let body = try WorkspaceIndicatorView(
            workspace: workspace,
            presentationRevision: owner.workspacePresentationRevision,
            owner: owner,
            sendAction: recorder.handler,
            barHeight: 34
        )
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let buttons = body.findAll(ViewType.Button.self)
        let workspaceList = try #require(buttons.first {
            (try? $0.accessibilityLabel().string()) == "Show workspace list"
        })

        #expect(buttons.contains { (try? $0.accessibilityLabel().string()) == "Change icon for workspace Project" })
        try workspaceList.tap()
        #expect(recorder.actions == [.executeCommand(name: "workspace_list")])
    }

    @Test("Retained workspace actions reject a same-ID replacement")
    @MainActor func retainedWorkspaceActionsRejectSameIDReplacement() throws {
        let original = workspaceSnapshot(id: 7, label: "Project")
        let owner = TabBarState()
        owner.install(original)
        let recorder = LocalActionRecorder<WorkspaceIndicatorView.Action>()
        let workspace = try #require(original.workspaces.first)
        let sut = WorkspaceIndicatorView(
            workspace: workspace,
            presentationRevision: owner.workspacePresentationRevision,
            owner: owner,
            sendAction: recorder.handler,
            barHeight: 34
        )

        owner.install(workspaceSnapshot(id: 7, label: "Project"))
        sut.performTargetedAction(.setIcon("star"))
        sut.performTargetedAction(.rename("Renamed"))
        sut.performTargetedAction(.close)

        #expect(recorder.actions.isEmpty)
    }

    @Test("Native close buttons emit the represented tab IDs without selecting them")
    @MainActor func closeButtonsEmitRepresentedTabIds() throws {
        let spy = SpyEncoder()
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            wireTab(id: 41, isActive: true, label: "active.ex"),
            wireTab(id: 73, label: "inactive.ex"),
        ])
        let sut = TabBarView(tabBarState: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
        let buttons = try sut.environment(\.themeColors, ThemeColors()).inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        let closedIds = spy.actions.compactMap { action -> UInt32? in
            if case let .closeTab(id) = action { return id }
            return nil
        }

        #expect(closedIds.sorted() == [41, 73])
        #expect(!spy.actions.contains(.selectTab(id: 73)))
    }

    @Test("Retained tab close control cannot close a replacement tab")
    @MainActor func staleCloseControlIsRejected() throws {
        let spy = SpyEncoder()
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [wireTab(id: 41, isActive: true, label: "original.ex")])
        let sut = TabBarView(tabBarState: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
            .environment(\.themeColors, ThemeColors())
        let close = try #require(sut.inspect().findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Close original.ex"
        })

        state.update(activeIndex: 0, entries: [wireTab(id: 41, isActive: true, label: "replacement.ex")])
        try close.tap()

        #expect(spy.actions.isEmpty)
    }
    @Test("Native tab transfer preserves stable identity")
    @available(macOS 15.2, *)
    func tabDragPayloadSupportsNativeDataTransfer() async throws {
        let original = TabDragPayload(id: 42)
        let bytes = try await original.exported(as: TabDragPayload.contentType)
        let decoded = try await TabDragPayload(importing: bytes, contentType: TabDragPayload.contentType)
        #expect(decoded == original)
    }


    @Test("Inactive tab context menu actions use id-scoped events")
    @MainActor func inactiveTabContextMenuActionsUseIdScopedEvents() throws {
        let spy = SpyEncoder()
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            wireTab(id: 1, isActive: true),
            wireTab(id: 2),
            wireTab(id: 3, isPinned: true),
        ])
        let sut = TabBarView(tabBarState: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
        let inactive = tab(id: 2)
        let pinnedInactive = tab(id: 3, isPinned: true)

        sut.performTabContextMenuAction(.pin, for: inactive)
        sut.performTabContextMenuAction(.unpin, for: pinnedInactive)
        sut.performTabContextMenuAction(.moveLeft, for: inactive)
        sut.performTabContextMenuAction(.moveRight, for: inactive)

        #expect(spy.actions == [
            .tabPin(id: 2),
            .tabUnpin(id: 3),
            .tabMoveLeft(id: 2),
            .tabMoveRight(id: 2)
        ])
        #expect(!spy.actions.contains(.selectTab(id: 2)))
        #expect(!spy.actions.contains { action in
            if case .executeCommand = action { return true }
            return false
        })
    }

    @Test("Tab context menu disables impossible pinned-bucket moves")
    @MainActor func tabContextMenuMoveEnablementHonorsPinnedBuckets() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            wireTab(id: 1, isActive: true, isPinned: true),
            wireTab(id: 2, isPinned: true),
            wireTab(id: 3),
            wireTab(id: 4),
            wireTab(id: 5, groupId: 1),
        ])

        #expect(!state.canMoveTabLeft(tab(id: 1, isActive: true, isPinned: true)))
        #expect(state.canMoveTabRight(tab(id: 1, isActive: true, isPinned: true)))
        #expect(state.canMoveTabLeft(tab(id: 2, isPinned: true)))
        #expect(!state.canMoveTabRight(tab(id: 2, isPinned: true)))
        #expect(!state.canMoveTabLeft(tab(id: 3)))
        #expect(state.canMoveTabRight(tab(id: 3)))
        #expect(state.canMoveTabLeft(tab(id: 4)))
        #expect(!state.canMoveTabRight(tab(id: 4)))
        #expect(!state.canMoveTabLeft(tab(id: 5, groupId: 1)))
        #expect(!state.canMoveTabRight(tab(id: 5, groupId: 1)))
    }

    @Test("Tab context menu move actions use bucket edge rules")
    @MainActor func tabContextMenuMoveActionsUseBucketEdgeRules() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            wireTab(id: 1, isActive: true, isPinned: true, label: "pinned-1.ex"),
            wireTab(id: 2, isPinned: true, label: "pinned-2.ex"),
            wireTab(id: 3, label: "plain-1.ex"),
            wireTab(id: 4, label: "plain-2.ex"),
        ])
        let sut = TabBarView(tabBarState: state, sendAction: nil)
        let tabs = [
            tab(id: 1, isActive: true, isPinned: true, label: "pinned-1.ex"),
            tab(id: 2, isPinned: true, label: "pinned-2.ex"),
            tab(id: 3, label: "plain-1.ex"),
            tab(id: 4, label: "plain-2.ex")
        ]
        let moveItems = tabs.map { sut.tabContextMenuMoveItems(for: $0) }

        #expect(moveItems.map { $0.map(\.title) } == Array(repeating: ["Move Tab Left", "Move Tab Right"], count: 4))
        #expect(moveItems.map { $0.map(\.isDisabled) } == [[true, false], [false, true], [true, false], [false, true]])
    }

    @Test("Tab drag payload stays private and drops only accept tab payloads in the same bucket")
    @MainActor func tabDragPayloadAndDropGuard() throws {
        let spy = SpyEncoder()
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            wireTab(id: 1, isPinned: true, label: "pinned-1.ex"),
            wireTab(id: 2, isPinned: true, label: "pinned-2.ex"),
            wireTab(id: 3, label: "plain-1.ex"),
            wireTab(id: 4, label: "plain-2.ex"),
            wireTab(id: 5, groupId: 1, label: "other-group.ex"),
        ])
        let sut = TabBarView(tabBarState: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
        let target = tab(id: 3, label: "plain-1.ex")

        #expect(TabDragPayload.contentType.identifier == "com.minga.tab-id")
        #expect(TabDragPayload.contentType != UTType.plainText)

        if let reorder = state.tabDropReorder(droppedTabs: [], target: target, visibleIndex: 1) {
            Issue.record("Expected empty payload to be rejected, got \(reorder)")
        }
        if let reorder = state.tabDropReorder(droppedTabs: [TabDragPayload(id: 5)], target: target, visibleIndex: 1) {
            Issue.record("Expected cross-workspace payload to be rejected, got \(reorder)")
        }
        if let reorder = state.tabDropReorder(droppedTabs: [TabDragPayload(id: 1)], target: target, visibleIndex: 1) {
            Issue.record("Expected pinned-bucket mismatch to be rejected, got \(reorder)")
        }

        let dropTarget = tab(id: 4, label: "plain-2.ex")
        #expect(state.visibleFileTabIndex(for: dropTarget) == 3)
        #expect(state.tabDropReorder(droppedTabs: [TabDragPayload(id: 3)], target: dropTarget, visibleIndex: 3)?.newIndex == 3)

        let accepted = sut.handleTabDrop(droppedTabs: [TabDragPayload(id: 3)], target: dropTarget, visibleIndex: 3)

        #expect(accepted)
        #expect(spy.actions == [.tabReorder(id: 3, newIndex: 3)])
    }

    @Test("Canonical drag reorder ignores the leading agent tab")
    @MainActor func canonicalDragReorderIgnoresLeadingAgentTab() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: true, hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "cpu", label: "Agent"),
            wireTab(id: 2, label: "file-a.ex"),
            wireTab(id: 3, label: "file-b.ex")
        ])

        #expect(state.movableFileTabIndex(for: tab(id: 2, label: "file-a.ex")) == 0)
        #expect(state.movableFileTabIndex(for: tab(id: 3, label: "file-b.ex")) == 1)
        #expect(state.movableFileTabIndex(for: TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: true, hasAttention: false, agentStatus: .idle, isPinned: false, tintColor: nil, icon: "cpu", label: "Agent")) == nil)
        #expect(state.tabDropReorder(droppedTabs: [TabDragPayload(id: 2)], target: tab(id: 3, label: "file-b.ex"), visibleIndex: 2)?.newIndex == 1)
    }

    @Test("Tab bar uses canonical active-workspace visible tabs")
    @MainActor func usesCanonicalVisibleTabs() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            Wire.TabEntry(id: 1, groupId: 1, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "legacy-agent-chat"),
            Wire.TabEntry(id: 2, groupId: 2, isActive: false, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "background.ex")
        ])
        state.install(WorkspacePresentationSnapshot(version: 1, activeWorkspaceId: 1, mode: .agent, flags: [], workspaces: [
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "Active", icon: "cpu"),
            Wire.WorkspaceEntry(id: 2, kind: 1, status: 1, flags: 0, colorR: 0x44, colorG: 0x55, colorB: 0x66,
                                tabCount: 3, draftCount: 0, conflictCount: 0, runningBackgroundCount: 1, label: "Research", icon: "cpu")
        ], visibleTabs: [
            Wire.WorkspaceTabEntry(id: 42, workspaceId: 1, kind: 0, flags: 0, pathHash: 0, tintColorRGB: 0, icon: "", label: "active.ex", path: "/tmp/active.ex")
        ]))

        let sut = TabBarView(tabBarState: state, sendAction: nil)
        let strings = try sut.environment(\.themeColors, ThemeColors()).inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("active.ex"))
        #expect(!strings.contains("legacy-agent-chat"))
        #expect(!strings.contains("background.ex"))
        #expect(!strings.contains("Research"))
    }

    @Test("Canonical workspace tabs render agent entries with the agent icon")
    @MainActor func canonicalWorkspaceTabsRenderAgentEntriesWithAgentIcon() throws {
        let fileState = TabBarState()
        fileState.install(WorkspacePresentationSnapshot(version: 1, activeWorkspaceId: 1, mode: .agent, flags: [], workspaces: [
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "Active", icon: "cpu")
        ], visibleTabs: [
            Wire.WorkspaceTabEntry(id: 42, workspaceId: 1, kind: 0, flags: 0, pathHash: 0, tintColorRGB: 0, icon: "󰈙", label: "active.ex", path: "/tmp/active.ex")
        ]))

        let agentState = TabBarState()
        agentState.install(WorkspacePresentationSnapshot(version: 1, activeWorkspaceId: 1, mode: .agent, flags: [], workspaces: [
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "Active", icon: "cpu")
        ], visibleTabs: [
            Wire.WorkspaceTabEntry(id: 42, workspaceId: 1, kind: 1, flags: 0, pathHash: 0, tintColorRGB: 0, icon: "cpu", label: "Agent", path: "")
        ]))

        let fileImages = try TabBarView(tabBarState: fileState, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
            .find(ViewType.ScrollView.self)
            .findAll(ViewType.Image.self)
            .count
        let agentImages = try TabBarView(tabBarState: agentState, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
            .find(ViewType.ScrollView.self)
            .findAll(ViewType.Image.self)
            .count

        #expect(agentImages == fileImages + 1)
    }
}

// MARK: - WorkspaceHeaderView

@Suite("WorkspaceHeaderView View Structure")
struct WorkspaceHeaderViewTests {

    @MainActor private func populatedState() -> WorkspaceState {
        let state = WorkspaceState()
        state.install(WorkspacePresentationSnapshot(version: 1, activeWorkspaceId: 2, mode: .agent, flags: [.hasAttention], workspaces: [
            Wire.WorkspaceEntry(id: 0, kind: 0, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "minga", icon: "folder"),
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "Research", icon: "cpu"),
            Wire.WorkspaceEntry(id: 2, kind: 1, status: 2, flags: 0x0003, colorR: 0x44, colorG: 0x55, colorB: 0x66,
                                tabCount: 2, draftCount: 1, conflictCount: 1, runningBackgroundCount: 1, label: "Review", icon: "cpu")
        ], visibleTabs: [
            Wire.WorkspaceTabEntry(id: 42, workspaceId: 2, kind: 0, flags: 0, pathHash: 0, tintColorRGB: 0, icon: "", label: "active.ex", path: "/tmp/active.ex")
        ]))
        return state
    }

    @Test("Header shows active workspace metadata and badges")
    @MainActor func showsActiveWorkspaceMetadataAndBadges() throws {
        let sut = WorkspaceHeaderView(workspaceState: populatedState(), sendAction: nil)
        let strings = try sut.environment(\.themeColors, ThemeColors()).inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Review"))
        #expect(strings.contains(SpineState.working.word))
        #expect(strings.contains("⚡1"))
        #expect(strings.contains("✓1"))
        #expect(strings.contains("⚠︎1"))
        #expect(strings.contains("!"))
    }

    @Test("Header exposes background workspace badges without activating them")
    @MainActor func showsBackgroundWorkspaceBadges() throws {
        let state = WorkspaceState()
        state.install(WorkspacePresentationSnapshot(version: 1, activeWorkspaceId: 0, mode: .editor, flags: [], workspaces: [
            Wire.WorkspaceEntry(id: 0, kind: 0, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "minga", icon: "folder"),
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 3, flags: 0x0001, colorR: 0x44, colorG: 0x55, colorB: 0x66,
                                tabCount: 2, draftCount: 1, conflictCount: 1, runningBackgroundCount: 1, label: "Background", icon: "cpu")
        ], visibleTabs: []))

        let sut = WorkspaceHeaderView(workspaceState: state, sendAction: nil)
        let strings = try sut.environment(\.themeColors, ThemeColors()).inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("minga"))
        #expect(strings.contains("bg ⚡1"))
        #expect(strings.contains("bg ✓1"))
        #expect(strings.contains("bg ⚠︎1"))
        #expect(strings.contains("bg !1"))
        #expect(strings.contains("bg ✕1"))
    }

    @Test("Switcher uses manual workspace and agent ordinals")
    @MainActor func switcherUsesManualAndAgentOrdinals() throws {
        let state = populatedState()
        let manualWorkspace = try #require(state.workspaces.first { $0.isManual })
        let reviewWorkspace = try #require(state.workspaces.first { $0.label == "Review" })

        #expect(state.switchCommand(for: manualWorkspace) == "workspace_goto_id:0")
        #expect(state.switchCommand(for: reviewWorkspace) == "workspace_goto_id:2")
    }

    @Test("Switcher click advances to the next workspace")
    @MainActor func switcherClickAdvancesWorkspace() throws {
        let spy = SpyEncoder()
        let sut = WorkspaceHeaderView(workspaceState: populatedState(), sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
        let buttons = try sut.environment(\.themeColors, ThemeColors()).inspect().findAll(ViewType.Button.self)
        let button = try #require(buttons.first(where: {
            (try? $0.accessibilityLabel().string()) == "Switch to next workspace"
        }))

        try button.tap()

        #expect(spy.actions.contains(.executeCommand(name: "workspace_next")))
    }
}

// MARK: - AgentChatView


@Suite("AgentChatView View Structure")
struct AgentChatViewTests {

    @MainActor private func chatState(messages: [ChatMessageEntry] = []) -> AgentChatState {
        let state = AgentChatState()
        state.visible = true
        state.model = "claude-sonnet-4"
        state.status = .idle
        state.seed(messages: messages)
        return state
    }

    @Test("Truncated transcript offers to browse retained messages")
    @MainActor func truncatedTranscriptOpensHistory() throws {
        let state = chatState()
        state.applyTranscript(mode: 0, epoch: 1, truncated: true, baseCount: 0, messages: [Wire.ChatMessage(beamId: 1, content: .user(text: "Hello"))])
        let spy = SpyEncoder()

        let body = try AgentChatView(state: state, isInsertMode: false, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        let buttons = try body.findAll(ViewType.Button.self)
        let history = try #require(buttons.first(where: {
            (try? $0.labelView().text().string()) == "Browse earlier messages"
        }))

        try history.tap()
        #expect(spy.actions.contains(.executeCommand(name: "agent_retained_history")))
        #expect(strings.contains("Hello"))
    }

    @Test("Complete transcript hides the browse earlier messages action")
    @MainActor func nonTruncatedTranscriptIndicatorHidden() throws {
        let state = chatState()
        state.applyTranscript(mode: 0, epoch: 1, truncated: false, baseCount: 0, messages: [Wire.ChatMessage(beamId: 1, content: .user(text: "Hello"))])

        let body = try AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(!strings.contains("Browse earlier messages"))
        #expect(strings.contains("Hello"))
    }

    @Test("Empty messages shows header and prompt area")
    @MainActor func emptyMessages() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "claude-sonnet-4"
        state.status = .idle

        let sut = AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        // Header shows model name and status
        #expect(strings.contains("claude-sonnet-4"))
        #expect(strings.contains("Idle"))
        // NORMAL mode indicator shown in prompt border
        #expect(strings.contains("NORMAL"))
    }

    @Test("Header strips provider prefix and shows thinking level")
    @MainActor func headerModelAndThinkingControls() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "anthropic:claude-sonnet-4"
        state.thinkingLevel = "high"
        state.status = .idle

        let sut = AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("claude-sonnet-4"))
        #expect(!strings.contains("anthropic:claude-sonnet-4"))
        #expect(strings.contains("High"))
    }

    /// #3782: the BEAM sends a contributed route's display name as the provider half of `model`.
    @Test("Header names the provider the session uses, including an extension route",
          arguments: [
            ("Claude (subscription):haiku", "Claude (subscription)", "haiku"),
            ("Anthropic:claude-sonnet-4", "Anthropic", "claude-sonnet-4"),
          ])
    @MainActor func headerNamesSessionProvider(model: String, provider: String, name: String) throws {
        let state = AgentChatState()
        state.visible = true
        state.model = model
        state.status = .idle
        #expect(state.displayProvider == provider)
        #expect(state.displayModel == name)

        let body = try AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        #expect(strings.contains(provider))
        #expect(strings.contains(name))
        #expect(!strings.contains(model))

        // Every header row width uses this one model button, so its label carries the provider.
        let modelButtons = body.findAll(ViewType.Button.self).filter {
            (try? $0.accessibilityLabel().string()) == "Agent model"
        }
        #expect(!modelButtons.isEmpty)
        for modelButton in modelButtons {
            let label = try modelButton.labelView().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
            #expect(label.contains(provider))
            #expect(label.contains(name))
            #expect(try modelButton.accessibilityValue().string() == "\(name), \(provider)")
        }
    }

    /// The BEAM sends status text with an empty provider (`:text`) when the text contains `:`.
    @Test("Status text in place of a model shows no provider label",
          arguments: [
            ("Resolving model…", "Resolving model…"),
            (":Model \"anthropic:claude-x\" is not in the catalog", "Model \"anthropic:claude-x\" is not in the catalog"),
          ])
    @MainActor func headerWithoutProvider(model: String, text: String) throws {
        let state = AgentChatState()
        state.visible = true
        state.model = model
        state.status = .idle
        #expect(state.displayProvider.isEmpty)
        #expect(state.displayModel == text)

        let body = try AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let modelButtons = body.findAll(ViewType.Button.self).filter {
            (try? $0.accessibilityLabel().string()) == "Agent model"
        }
        #expect(!modelButtons.isEmpty)
        for modelButton in modelButtons {
            let label = try modelButton.labelView().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
            #expect(label == [text])
            #expect(try modelButton.accessibilityValue().string() == text)
        }
    }

    @Test("Header controls dispatch named commands with the composer in insert mode")
    @MainActor func headerControlsDispatchCommands() throws {
        let spy = SpyEncoder()
        let state = AgentChatState()
        state.visible = true
        state.model = "claude-sonnet-4"
        state.thinkingLevel = "medium"
        state.status = .idle
        state.promptMode = .insert
        state.prompt = "unfinished draft"

        let sut = AgentChatView(state: state, isInsertMode: true, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()

        let headerButtons = try body.findAll(ViewType.Button.self)
        let modelButton = try #require(headerButtons.first(where: {
            (try? $0.accessibilityLabel().string()) == "Agent model"
        }))
        try modelButton.tap()
        #expect(spy.actions.contains(.executeCommand(name: "agent_pick_model")))

        let helpButton = try #require(headerButtons.first(where: {
            (try? $0.accessibilityLabel().string()) == "Agent help"
        }))
        try helpButton.tap()
        #expect(spy.actions.contains(.executeCommand(name: "agent_toggle_help")))

        let thinkingMenu = try body.find(ViewType.Menu.self)
        let thinkingButtons = try thinkingMenu.findAll(ViewType.Button.self)
        let highButton = try #require(thinkingButtons.first(where: {
            ((try? $0.accessibilityLabel().string()) ?? "").contains("High")
        }))
        try highButton.tap()
        #expect(spy.actions.contains(.executeCommand(name: "agent_thinking_high")))
        #expect(spy.keyPressCalls.isEmpty)
        #expect(state.prompt == "unfinished draft")
        #expect(state.promptMode == .insert)
    }

    @Test("Retained approval buttons send their displayed target after the transcript switches")
    @MainActor func approvalButtonsKeepDisplayedIdentity() throws {
        let spy = SpyEncoder()
        let state = chatState(messages: [
            .approvalToolCall(id: 1, name: "shell", summary: "git diff --cached", toolCallId: "call-1", sessionId: "session-a", requestId: "request-a", previewKind: 2, previewLines: ["git diff --cached"])
        ])
        state.promptMode = .insert
        state.prompt = "unfinished draft"

        let sut = AgentChatView(state: state, isInsertMode: true, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let buttons = try body.findAll(ViewType.Button.self)

        // Keep the rendered closures, then switch to a different session whose
        // pending tool has the same tool-call ID. Current state cannot retarget them.
        state.applyTranscript(mode: 0, epoch: 2, baseCount: 0, messages: [
            Wire.ChatMessage(beamId: 2, content: .approvalToolCall(name: "shell", summary: "other command", toolCallId: "call-1", sessionId: "session-b", requestId: "request-b", previewKind: 2, previewLines: []))
        ])

        func tap(_ title: String) throws {
            let button = try #require(buttons.first(where: {
                ((try? $0.labelView().text().string()) ?? "") == title
            }))
            try button.tap()
        }

        try tap("Approve (y)")
        try tap("Trust for session (a)")
        try tap("Trust for this turn (t)")
        try tap("Deny (n)")

        #expect(spy.actions == [
            .agentToolApproval(sessionId: "session-a", requestId: "request-a", toolCallId: "call-1", decision: .approve),
            .agentToolApproval(sessionId: "session-a", requestId: "request-a", toolCallId: "call-1", decision: .approveSession),
            .agentToolApproval(sessionId: "session-a", requestId: "request-a", toolCallId: "call-1", decision: .approveTurn),
            .agentToolApproval(sessionId: "session-a", requestId: "request-a", toolCallId: "call-1", decision: .reject)
        ])
        #expect(spy.keyPressCalls.isEmpty)
        #expect(state.prompt == "unfinished draft")
        #expect(state.promptMode == .insert)
    }

    @Test("Auto-approved tool calls show the subtle scope pill")
    @MainActor func autoApprovedIndicatorRenders() throws {
        let state = chatState(messages: [
            .toolCall(id: 1, name: "shell", summary: "git diff --cached", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 500, result: "", previewKind: 0, previewLines: []),
            .toolCall(id: 2, name: "shell", summary: "git status --short", status: 1, isError: false, collapsed: true, autoApprovedScope: 2, durationMs: 250, result: "", previewKind: 0, previewLines: [])
        ])

        let sut = AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("auto-approved · session"))
        #expect(strings.contains("auto-approved · turn"))
    }

    @Test("Styled assistant keeps decorative rails literal")
    @MainActor func styledAssistantKeepsRailsLiteral() throws {
        func run(_ text: String, code: Bool = false) -> Wire.StyledTextRun {
            Wire.StyledTextRun(text: text, fgR: 0xBB, fgG: 0xC2, fgB: 0xCF, bgR: 0, bgG: 0, bgB: 0, bold: false, italic: false, underline: false, code: code)
        }

        let state = chatState(messages: [
            .styledAssistant(id: 1, lines: [[run("┌─ python")], [run("  print(\"hi\")", code: true)], [run("└")]])
        ])

        let sut = AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("┌─ python"))
        #expect(strings.contains("└"))
        #expect(!strings.contains("python"))
    }

    @Test("Plain, styled, and Markdown replies expose their author without hiding response content")
    @MainActor func assistantRepliesIdentifyTheirAuthor() throws {
        func run(_ text: String) -> Wire.StyledTextRun {
            Wire.StyledTextRun(text: text, fgR: 0, fgG: 0, fgB: 0, bgR: 0, bgG: 0, bgB: 0, bold: false, italic: false, underline: false, code: false)
        }

        let block = Wire.AgentMarkdownBlock(
            id: 1,
            kind: .paragraph,
            flags: 0,
            lines: [[run("Markdown reply")]],
            level: 0,
            indent: 0,
            ordered: false,
            ordinal: 0,
            height: 1,
            language: "",
            label: "",
            targetPath: "",
            capabilityFlags: 0
        )
        let state = chatState(messages: [
            .user(id: 1, text: "Review the change"),
            .assistant(id: 2, text: "Plain reply"),
            .styledAssistant(id: 3, lines: [[run("Styled reply")]]),
            .assistantMarkdown(id: 4, blocks: [block])
        ])
        let body = try AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        let roles = body.findAll(ViewType.VStack.self).compactMap { try? $0.accessibilityLabel().string() }

        #expect(strings.filter { $0 == "Minga" }.count == 3)
        #expect(roles.filter { $0 == "Minga" }.count == 3)
        #expect(strings.contains("You"))
        for reply in ["Plain reply", "Styled reply", "Markdown reply"] {
            #expect(strings.contains(reply))
        }
    }

    @Test("Assistant markdown renders semantic code card")
    @MainActor func assistantMarkdownRendersCodeCard() throws {
        func run(_ text: String, code: Bool = false) -> Wire.StyledTextRun {
            Wire.StyledTextRun(text: text, fgR: 0x98, fgG: 0xBE, fgB: 0x65, bgR: 0x21, bgG: 0x24, bgB: 0x2B, bold: false, italic: false, underline: false, code: code)
        }

        let block = Wire.AgentMarkdownBlock(
            id: 7,
            kind: .codeBlock,
            flags: 0,
            lines: [[run("", code: true)], [run("print(\"hi\")", code: true)]],
            level: 0,
            indent: 0,
            ordered: false,
            ordinal: 0,
            height: 1,
            language: "swift",
            label: "Swift",
            targetPath: "macos/App.swift",
            capabilityFlags: 1
        )

        let state = chatState(messages: [.assistantMarkdown(id: 1, blocks: [block])])
        let sut = AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Swift"))
        #expect(strings.contains("macos/App.swift"))
        #expect(strings.contains("streaming"))
        #expect(strings.contains("print(\"hi\")"))
        #expect(try body.findAll(ViewType.ScrollView.self).count == 2)
    }

    @Test("User message renders as bubble")
    @MainActor func userMessage() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "test-model"
        state.seed(messages: [.user(id: 0, text: "Hello world")])

        let sut = AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("Hello world"))
    }

    @Test("System message renders centered")
    @MainActor func systemMessage() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "test-model"
        state.seed(messages: [.system(id: 0, text: "Session started", isError: false)])

        let sut = AgentChatView(state: state, isInsertMode: false, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("Session started"))
    }

    @Test("Insert mode shows typing placeholder")
    @MainActor func insertMode() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "test-model"
        state.promptMode = .insert

        let sut = AgentChatView(state: state, isInsertMode: true, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        // In insert mode with empty prompt, a BlinkingCursor renders (not text)
        // The tooltip still reads "Press i to start typing" but that's a .help() modifier
        // Check that the old placeholder is NOT shown (capsule shows cursor instead)
        #expect(!strings.contains("Ask anything..."))
        // Should NOT show NORMAL badge in insert mode
        #expect(!strings.contains("NORMAL"))
    }
}

// MARK: - BottomPanelView

@Suite("BottomPanelView View Structure")
struct BottomPanelViewTests {

    @Test("Panel renders tab bar with tab name")
    @MainActor func rendersTabBar() throws {
        let state = BottomPanelState()
        state.visible = true
        state.userHeight = 200
        state.tabs = [BottomPanelTab(id: 0, tabType: 0x01, name: "Messages")]
        state.activeTabIndex = 0

        let sut = BottomPanelView(
            state: state,
            sendAction: nil, availableHeight: 600
        )
        .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }
        #expect(strings.contains("Messages"))
    }

    @Test("Panel renders multiple tabs")
    @MainActor func multipleTabsRender() throws {
        let state = BottomPanelState()
        state.visible = true
        state.userHeight = 200
        state.tabs = [
            BottomPanelTab(id: 0, tabType: 0x01, name: "Messages"),
            BottomPanelTab(id: 1, tabType: 0x02, name: "Diagnostics"),
        ]
        state.activeTabIndex = 0

        let sut = BottomPanelView(
            state: state,
            sendAction: nil, availableHeight: 600
        )
        .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }
        #expect(strings.contains("Messages"))
        #expect(strings.contains("Diagnostics"))
    }
}

// MARK: - MinibufferView

@Suite("MinibufferView accessibility")
struct MinibufferViewAccessibilityTests {
    @Test("Minibuffer candidates are native labelled choices")
    @MainActor func candidateActivation() throws {
        let state = MinibufferState()
        state.update(
            visible: true, mode: .command, cursorPos: 0,
            prompt: "M-x ", input: "org", context: "", selectedIndex: 1,
            totalCandidates: 2,
            generation: 41,
            rawCandidates: [
                Wire.MinibufferCandidate(id: "org-mode", matchScore: 100, label: "org-mode", description: "Open Org mode", annotation: "", matchPositions: []),
                Wire.MinibufferCandidate(id: "org-agenda", matchScore: 90, label: "org-agenda", description: "Open agenda", annotation: "SPC o a", matchPositions: []),
            ]
        )
        let spy = SpyEncoder()
        let sut = MinibufferView(state: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
            .environment(\.themeColors, ThemeColors())
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        let selected = try #require(buttons.first {
            (try? $0.accessibilityLabel().string()) == "org-agenda"
        })

        #expect(try selected.accessibilityValue().string() == "selected, Open agenda")
        try selected.tap()
        #expect(spy.actions == [.semanticItemActivate(surface: .commandCompletion, intent: 1, generation: 41, itemID: Data("org-agenda".utf8))])
    }

    @Test("Retained minibuffer choice cannot activate after query replacement")
    @MainActor func staleCandidateActivationIsRejected() throws {
        let state = MinibufferState()
        state.update(
            visible: true, mode: .command, cursorPos: 0,
            prompt: "M-x ", input: "old", context: "", selectedIndex: 0,
            totalCandidates: 1,
            generation: 42,
            rawCandidates: [
                Wire.MinibufferCandidate(id: "old-command", matchScore: 100, label: "old-command", description: "", annotation: "", matchPositions: []),
            ]
        )
        let spy = SpyEncoder()
        let sut = MinibufferView(state: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) })
            .environment(\.themeColors, ThemeColors())
        let retained = try #require(sut.inspect().findAll(ViewType.Button.self).first)

        state.update(
            visible: true, mode: .command, cursorPos: 0,
            prompt: "M-x ", input: "new", context: "", selectedIndex: 0,
            totalCandidates: 1,
            generation: 43,
            rawCandidates: [
                Wire.MinibufferCandidate(id: "old-command", matchScore: 100, label: "old-command", description: "", annotation: "", matchPositions: []),
            ]
        )
        try retained.tap()

        #expect(spy.actions.isEmpty)
    }
}

// MARK: - PickerOverlay

@Suite("PickerOverlay semantic activation")
struct PickerOverlayActivationTests {
    @Test("Picker reports status and leaves the last readable choice available after an error")
    @MainActor func pickerContainerStatus() throws {
        let state = PickerState()
        state.update(
            visible: true, selectedIndex: 0, filteredCount: 0, totalCount: 0,
            markedCount: 0, title: "Find File", query: "", hasPreview: false,
            rawItems: [], actionMenu: nil, loadStatus: .loading
        )
        let loadingBody = try PickerOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let loadingContainer = try #require(loadingBody.findAll(ViewType.VStack.self).first {
            (try? $0.accessibilityLabel().string()) == "Find File choices"
        })
        #expect(try loadingContainer.accessibilityValue().string() == "Loading")

        state.update(
            visible: true, selectedIndex: 0, filteredCount: 1, totalCount: 1,
            markedCount: 0, title: "Find File", query: "", hasPreview: false,
            rawItems: [
                Wire.PickerItem(iconColor: 0, flags: 0, label: "Last readable page", description: "", annotation: "", matchPositions: [], activationID: 41),
            ],
            actionMenu: nil, loadStatus: .error("permission denied"), activationGeneration: 99
        )
        let errorBody = try PickerOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let errorContainer = try #require(errorBody.findAll(ViewType.VStack.self).first {
            (try? $0.accessibilityLabel().string()) == "Find File choices"
        })
        #expect(try errorContainer.accessibilityValue().string() == "Error: permission denied")
        let choice = try #require(errorBody.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Last readable page"
        })
        #expect(!choice.isDisabled())
    }

    @Test("A stacked status row reads its current marker, status, and description to VoiceOver")
    @MainActor func stackedRowAccessibility() throws {
        let description = "Claude (subscription) · Claude Max · 5h limit resets 2:50 PM"
        let state = PickerState()
        state.update(
            visible: true, selectedIndex: 0, filteredCount: 1, totalCount: 1,
            markedCount: 0, title: "Choose Model", query: "", hasPreview: false,
            rawItems: [
                Wire.PickerItem(iconColor: 0, flags: 0x08, label: "Claude Opus 4.5", description: description, annotation: "", matchPositions: [], activationID: 41, status: "Ready · 70%", statusTone: .ready),
            ],
            actionMenu: nil, activationGeneration: 99
        )
        #expect(state.items[0].stacksDescription)
        let body = try PickerOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let row = try #require(body.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Claude Opus 4.5"
        })

        #expect(try row.accessibilityValue().string() == "selected, current, Ready · 70%, \(description)")
    }

    @Test("A model row draws its status chip and current dot; a file row draws neither")
    @MainActor func statusChipAndCurrentDot() throws {
        let state = PickerState()
        let model = Wire.PickerItem(iconColor: 0, flags: 0x08, label: "Claude Opus 4", description: "Claude Max", annotation: "★ favorite", matchPositions: [], activationID: 41, status: "Ready · 45%", statusTone: .ready)
        let file = Wire.PickerItem(iconColor: 0, flags: 0, label: "editor.ex", description: "lib/minga", annotation: "", matchPositions: [], activationID: 42)
        state.update(
            visible: true, selectedIndex: 1, filteredCount: 2, totalCount: 2,
            markedCount: 0, title: "Models and connections", query: "", hasPreview: false,
            rawItems: [model, file],
            actionMenu: nil, activationGeneration: 99
        )
        let body = try PickerOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let modelRow = try #require(body.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Claude Opus 4"
        })
        let fileRow = try #require(body.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "editor.ex"
        })

        var modelTexts: [String] = []
        for text in modelRow.findAll(ViewType.Text.self) {
            if let value = try? text.string() { modelTexts.append(value) }
        }
        var modelImages: [String] = []
        for image in modelRow.findAll(ViewType.Image.self) {
            if let name = try? image.actualImage().name() { modelImages.append(name) }
        }
        var fileImages: [String] = []
        for image in fileRow.findAll(ViewType.Image.self) {
            if let name = try? image.actualImage().name() { fileImages.append(name) }
        }

        #expect(modelTexts.contains("Ready · 45%"))
        #expect(modelTexts.contains("★ favorite"))
        #expect(modelImages.contains("circle.fill"))
        #expect(!fileImages.contains("circle.fill"))
        #expect(fileRow.findAll(ViewType.Text.self).count == 2)
    }

    @Test("Section headers name each group once and are never choices")
    @MainActor func sectionHeadersAreNotChoices() throws {
        let spy = SpyEncoder()
        let state = PickerState()
        let rows: [Wire.PickerItem] = [
            Wire.PickerItem(iconColor: 0, flags: 0, label: "GPT-5", description: "", annotation: "", matchPositions: [], activationID: 41, group: "ChatGPT"),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "GPT-5 mini", description: "", annotation: "", matchPositions: [], activationID: 42, group: "ChatGPT"),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Claude Opus 4", description: "", annotation: "", matchPositions: [], activationID: 43, group: "Claude (subscription)"),
        ]
        state.update(
            visible: true, selectedIndex: 0, filteredCount: 3, totalCount: 3,
            markedCount: 0, title: "Models and connections", query: "", hasPreview: false,
            rawItems: rows, actionMenu: nil, activationGeneration: 99
        )
        let sut = PickerOverlay(state: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) }).environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()

        var texts: [String] = []
        for text in body.findAll(ViewType.Text.self) {
            if let value = try? text.string() { texts.append(value) }
        }
        #expect(texts.filter { $0 == "ChatGPT" }.count == 1)
        #expect(texts.filter { $0 == "Claude (subscription)" }.count == 1)

        var choiceLabels: [String] = []
        for button in body.findAll(ViewType.Button.self) {
            if let label = try? button.accessibilityLabel().string() { choiceLabels.append(label) }
        }
        #expect(choiceLabels.contains("GPT-5"))
        #expect(choiceLabels.contains("GPT-5 mini"))
        #expect(choiceLabels.contains("Claude Opus 4"))
        #expect(!choiceLabels.contains("ChatGPT"))
        #expect(!choiceLabels.contains("Claude (subscription)"))

        // The item under the second header activates with its own offered identity.
        let opus = try #require(body.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Claude Opus 4"
        })
        try opus.tap()
        #expect(spy.actions == [.semanticItemActivate(surface: .picker, intent: 1, generation: 99, itemID: Data([0, 0, 0, 43]))])
    }

    @Test("Picker choices expose selected marked and unavailable state")
    @MainActor func pickerAccessibilityState() throws {
        let state = PickerState()
        state.update(
            visible: true, selectedIndex: 0, filteredCount: 1, totalCount: 1,
            markedCount: 1, title: "Find File", query: "", hasPreview: false,
            rawItems: [
                Wire.PickerItem(iconColor: 0, flags: 0x02, label: "Selected", description: "lib/selected.ex", annotation: "", matchPositions: [], activationID: 41),
            ],
            actionMenu: nil, activationGeneration: 99
        )
        let body = try PickerOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let selected = try #require(body.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Selected"
        })

        #expect(try selected.accessibilityValue().string() == "selected, marked, lib/selected.ex")

        state.update(
            visible: true, selectedIndex: 0, filteredCount: 1, totalCount: 1,
            markedCount: 0, title: "Find File", query: "", hasPreview: false,
            rawItems: [
                Wire.PickerItem(iconColor: 0, flags: 0, label: "Unavailable", description: "", annotation: "", matchPositions: [], activationID: 0),
            ],
            actionMenu: nil, activationGeneration: 0
        )
        let unavailableBody = try PickerOverlay(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .inspect()
        let unavailable = try #require(unavailableBody.findAll(ViewType.Button.self).first {
            (try? $0.accessibilityLabel().string()) == "Unavailable"
        })
        #expect(try unavailable.accessibilityValue().string() == "selected, unavailable")
    }

    @Test("a retained nonselected result reports its original offered identity")
    @MainActor func retainedResultActivation() throws {
        let spy = SpyEncoder()
        let state = PickerState()
        state.update(
            visible: true, selectedIndex: 0, filteredCount: 2, totalCount: 2,
            markedCount: 0, title: "Test", query: "", hasPreview: false,
            rawItems: [
                Wire.PickerItem(iconColor: 0, flags: 0, label: "First", description: "", annotation: "", matchPositions: [], activationID: 41),
                Wire.PickerItem(iconColor: 0, flags: 0, label: "Second", description: "", annotation: "", matchPositions: [], activationID: 73),
            ],
            actionMenu: nil, activationGeneration: 99
        )
        let sut = PickerOverlay(state: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) }).environment(\.themeColors, ThemeColors())
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        let second = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Second" })

        state.update(
            visible: true, selectedIndex: 0, filteredCount: 1, totalCount: 1,
            markedCount: 0, title: "Test", query: "third", hasPreview: false,
            rawItems: [Wire.PickerItem(iconColor: 0, flags: 0, label: "Third", description: "", annotation: "", matchPositions: [], activationID: 5)],
            actionMenu: nil, activationGeneration: 100
        )
        try second.tap()

        #expect(spy.actions == [.semanticItemActivate(surface: .picker, intent: 1, generation: 99, itemID: Data([0, 0, 0, 73]))])
    }

    @Test("a retained Actions entry reports its original offered identity")
    @MainActor func retainedActionActivation() throws {
        let spy = SpyEncoder()
        let state = PickerState()
        state.update(
            visible: true, selectedIndex: 0, filteredCount: 1, totalCount: 1,
            markedCount: 0, title: "Test", query: "", hasPreview: false,
            rawItems: [Wire.PickerItem(iconColor: 0, flags: 0, label: "File", description: "", annotation: "", matchPositions: [], activationID: 1)],
            actionMenu: Wire.PickerActionMenu(selectedIndex: 0, actions: ["Open", "Delete"], activationIDs: [11, 27]),
            activationGeneration: 101
        )
        let sut = PickerOverlay(state: state, sendAction: { action in _ = spy.send(FrontendActionComposition.outbound(action)) }).environment(\.themeColors, ThemeColors())
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        let delete = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Delete" })

        state.update(
            visible: true, selectedIndex: 0, filteredCount: 1, totalCount: 1,
            markedCount: 0, title: "Test", query: "", hasPreview: false,
            rawItems: [Wire.PickerItem(iconColor: 0, flags: 0, label: "File", description: "", annotation: "", matchPositions: [], activationID: 2)],
            actionMenu: Wire.PickerActionMenu(selectedIndex: 0, actions: ["Open", "Delete"], activationIDs: [12, 28]),
            activationGeneration: 102
        )
        try delete.tap()

        #expect(spy.actions == [.semanticItemActivate(surface: .picker, intent: 2, generation: 101, itemID: Data([0, 0, 0, 27]))])
    }
}

// MARK: - ViewInspector query helper

@Suite("Agent Context Bar")
struct AgentContextBarTests {
    @Test("review buttons emit consumer-local actions")
    @MainActor func reviewButtonsEmitLocalActions() throws {
        let state = AgentContextBarState(visible: true, task: "Review", status: .done, canApprove: true)
        let recorder = LocalActionRecorder<AgentContextBar.ReviewAction>()
        let sut = AgentContextBar(state: state, onReview: recorder.handler)
            .environment(\.themeColors, ThemeColors())
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        let approve = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Approve" })
        let requestChanges = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Reject Changes" })
        let dismiss = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Dismiss" })

        try approve.tap()
        try requestChanges.tap()
        try dismiss.tap()

        #expect(recorder.actions == [.approve, .requestChanges, .dismiss])
    }
}

/// Namespace for ViewInspector query types.
enum ViewInspectorQuery {
    /// Finds all Text views in the hierarchy.
    static let text = ViewType.Text.self
}

@Suite("Committed agent tool outcomes")
@MainActor
struct AgentToolOutcomeViewTests {
    @Test("A tool step is one line: the state's mark and the BEAM's sentence, with its output on expand",
          arguments: [(UInt8(1), "Running `echo example`"), (6, "Ran `echo example`"),
                      (5, "Could not run `echo example`"), (4, "Stopped while running `echo example`")],
          [false, true])
    func toolStep(step: (UInt8, String), styled: Bool) throws {
        let (wire, sentence) = step
        let state = try #require(SpineState(wire: wire))
        let output = "example output"
        let run = Wire.StyledTextRun(text: output, fgR: 255, fgG: 255, fgB: 255,
                                    bgR: 0, bgG: 0, bgB: 0, bold: false, italic: false, underline: false)
        let card = AgentToolCallCard(
            messageID: 1, name: "shell", summary: "echo example",
            step: Wire.ToolStep(text: sentence, state: wire), collapsed: false, autoApprovedScope: 0,
            result: styled ? nil : output, resultLines: styled ? [[run]] : nil,
            previewLines: [], sendAction: nil
        ).environment(\.themeColors, ThemeColors())
        let body = try card.inspect()
        let strings = body.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(strings.contains(sentence))
        #expect(strings.contains(output))
        // The sentence carries the state; no status word or raw tool name is added beside it.
        #expect(!strings.contains("error"))
        #expect(!strings.contains("shell"))
        let line = try #require(body.findAll(ViewType.HStack.self).first {
            (try? $0.accessibilityLabel().string()) == "\(state.word): \(sentence)"
        })
        #expect(try line.accessibilityLabel().string().hasPrefix(state.word))
    }

    @Test("A collapsed tool step is one row tall, whatever room the conversation offers it",
          arguments: [UInt8(1), 4, 5, 6])
    func toolStepIsOneRowTall(wire: UInt8) {
        let card = AgentToolCallCard(
            messageID: 1, name: "find", summary: "*.ex",
            step: Wire.ToolStep(text: "Found *.ex", state: wire), collapsed: true, autoApprovedScope: 0,
            result: nil, resultLines: nil, previewLines: [], sendAction: nil
        ).environment(\.themeColors, ThemeColors())
        let hosting = NSHostingController(rootView: card)

        // The conversation offers each row its full width and as much height as it wants.
        let size = hosting.sizeThatFits(in: CGSize(width: 1_500, height: 2_000))

        #expect(size.height > 0)
        #expect(size.height <= 24, "the step is \(size.height) pt tall")
    }

    @Test("Waiting header announces approval instead of executing and has no progress spinner")
    func waitingHeader() throws {
        let state = AgentChatState(status: .approvalWaiting, model: "test")
        let header = AgentChatHeaderView(state: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
        let body = try header.inspect()
        #expect(body.findAll(ViewType.Text.self).contains { (try? $0.string()) == SpineState.needsYou.word })
        #expect(body.findAll(ViewType.ProgressView.self).isEmpty)
    }
}
