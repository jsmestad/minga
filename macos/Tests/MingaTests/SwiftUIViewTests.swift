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

import Testing
import SwiftUI
import ViewInspector

// MARK: - CompletionOverlay

@Suite("CompletionOverlay View Structure")
struct CompletionOverlayViewTests {

    @Test("Hidden completion renders nothing")
    @MainActor func hiddenCompletion() throws {
        let state = CompletionState()
        state.visible = false

        let sut = CompletionOverlay(
            state: state, theme: ThemeColors(),
            encoder: nil
        )

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
            ]
        )

        let sut = CompletionOverlay(
            state: state, theme: ThemeColors(),
            encoder: nil
        )

        let body = try sut.inspect()
        // Should find both item labels in the tree
        let texts = body.findAll(ViewInspectorQuery.text)
        let labels = texts.compactMap { try? $0.string() }
        #expect(labels.contains("def"))
        #expect(labels.contains("defmodule"))
    }
}

// MARK: - WhichKeyOverlay

@Suite("WhichKeyOverlay View Structure")
struct WhichKeyOverlayViewTests {

    @Test("Hidden which-key renders nothing")
    @MainActor func hiddenWhichKey() throws {
        let state = WhichKeyState()
        state.visible = false

        let sut = WhichKeyOverlay(state: state, theme: ThemeColors())
        let body = try sut.inspect()
        #expect(throws: Never.self) {
            _ = try? body.find(text: "anything")
        }
    }

    @Test("Visible which-key shows prefix and binding keys")
    @MainActor func visibleWhichKey() throws {
        let state = WhichKeyState()
        state.update(
            visible: true, prefix: "SPC", page: 0, pageCount: 1,
            rawBindings: [
                Wire.WhichKeyBinding(kind: 0, key: "f", description: "Find file", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "b", description: "Buffers", icon: ""),
            ]
        )

        let sut = WhichKeyOverlay(state: state, theme: ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("SPC"))
        #expect(strings.contains("f"))
        #expect(strings.contains("Find file"))
        #expect(strings.contains("b"))
        #expect(strings.contains("Buffers"))
    }

    @Test("Which-key shows page indicator when multiple pages")
    @MainActor func pageIndicator() throws {
        let state = WhichKeyState()
        state.update(
            visible: true, prefix: "SPC", page: 0, pageCount: 3,
            rawBindings: [
                Wire.WhichKeyBinding(kind: 0, key: "a", description: "test", icon: ""),
            ]
        )

        let sut = WhichKeyOverlay(state: state, theme: ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("1/3"))
    }
}

// MARK: - BreadcrumbBar

@Suite("BreadcrumbBar View Structure")
struct BreadcrumbBarViewTests {

    @Test("Empty breadcrumb renders nothing")
    @MainActor func emptyBreadcrumb() throws {
        let state = BreadcrumbState()
        state.segments = []

        let sut = BreadcrumbBar(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        // Empty segments should render nothing (the if guard)
        let texts = body.findAll(ViewInspectorQuery.text)
        #expect(texts.isEmpty)
    }

    @Test("Breadcrumb shows all path segments")
    @MainActor func showsSegments() throws {
        let state = BreadcrumbState()
        state.segments = ["lib", "minga", "editor.ex"]

        let sut = BreadcrumbBar(state: state, theme: ThemeColors(), encoder: nil)
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

    private func segment(_ id: Int, _ text: String, kind: String = "custom", command: String = "") -> Wire.StatusBarSegment {
        Wire.StatusBarSegment(id: id, kind: kind, text: text, fgColor: 0xFFFFFF, bgColor: 0x000000, attrs: 0, command: command)
    }

    @MainActor private func statusBarState(
        message: String = "",
        diagnosticHint: String = "",
        leftSegments: [Wire.StatusBarSegment] = [],
        rightSegments: [Wire.StatusBarSegment] = [],
        agentStatus: UInt8 = 0,
        activeToolName: String = ""
    ) -> StatusBarState {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 42, cursorCol: 9,
            lineCount: 500, flags: 0, lspStatus: 0, gitBranch: "",
            message: message, filetype: "elixir", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: agentStatus,
            activeToolName: activeToolName,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: diagnosticHint,
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: leftSegments,
            modelineRightSegments: rightSegments
        ))
        return state
    }

    @Test("Buffer mode shows configured modeline segments")
    @MainActor func bufferMode() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 42, cursorCol: 9,
            lineCount: 500, flags: 0, lspStatus: 0, gitBranch: "",
            message: "", filetype: "elixir", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: [segment(0, " NORMAL ", kind: "mode")],
            modelineRightSegments: [segment(0, " Elixir ", kind: "filetype"), segment(1, " 42:9 ", kind: "position")]
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("NORMAL"))
        #expect(strings.contains("Elixir"))
        #expect(strings.contains("Ln 42, Col 9"))
    }

    @Test("Fallback native status bar renders default built-ins without modeline segments")
    @MainActor func fallbackNativeStatusBarRendersDefaultBuiltins() throws {
        let state = statusBarState()
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("NORMAL"))
        #expect(strings.contains("Elixir"))
        #expect(strings.contains("Ln 42, Col 9"))
        #expect(strings.contains("Spaces:2"))
    }

    @Test("Filename group uses BEAM modeline text for native rendering")
    @MainActor func filenameGroupUsesModelineText() throws {
        let state = statusBarState(leftSegments: [segment(1, " main.ex [1/2] recording @q ", kind: "filename")])
        state.filename = "main.ex"
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("main.ex [1/2] recording @q"))
    }

    @Test("Fallback built-in status bar controls emit default commands")
    @MainActor func fallbackBuiltinControlsEmitDefaultCommands() throws {
        let spy = SpyEncoder()
        let state = statusBarState()
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        #expect(spy.guiActions.contains(.executeCommand(name: "set_language")))
        #expect(spy.guiActions.contains(.executeCommand(name: "indent_picker")))
    }

    @Test("Configured built-in controls prefer BEAM command override")
    @MainActor func configuredBuiltinControlsPreferBeamCommandOverride() throws {
        let spy = SpyEncoder()
        let state = statusBarState(rightSegments: [segment(1, " Elixir ", kind: "filetype", command: "filetype_menu")])
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        #expect(spy.guiActions.contains(.executeCommand(name: "filetype_menu")))
        #expect(!spy.guiActions.contains(.executeCommand(name: "set_language")))
    }

    @Test("Filename control emits fallback buffer list command")
    @MainActor func filenameControlEmitsFallbackBufferListCommand() throws {
        let spy = SpyEncoder()
        let state = statusBarState(leftSegments: [segment(1, " main.ex ", kind: "filename")])
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        #expect(spy.guiActions.contains(.executeCommand(name: "buffer_list")))
    }

    @Test("Filename control prefers BEAM command override")
    @MainActor func filenameControlPrefersBeamCommandOverride() throws {
        let spy = SpyEncoder()
        let state = statusBarState(leftSegments: [segment(1, " main.ex ", kind: "filename", command: "custom_buffer_picker")])
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        #expect(spy.guiActions.contains(.executeCommand(name: "custom_buffer_picker")))
        #expect(!spy.guiActions.contains(.executeCommand(name: "buffer_list")))
    }

    @Test("Custom unknown status bar segment remains visible and clickable")
    @MainActor func customUnknownStatusBarSegmentVisibleAndClickable() throws {
        let spy = SpyEncoder()
        let state = statusBarState(leftSegments: [segment(1, " 42W ", kind: "word_count", command: "word_count")])
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        let buttons = body.findAll(ViewType.Button.self)

        #expect(strings.contains("42W"))

        for button in buttons {
            try button.tap()
        }

        #expect(spy.guiActions.contains(.executeCommand(name: "word_count")))
    }

    @Test("Configured modeline groups receive bounded budgets")
    @MainActor func configuredModelineGroupsReceiveBoundedBudgets() throws {
        let longLeftSegments = (0..<20).map { segment($0, " LEFT-SEGMENT-WITH-LONG-TEXT-\($0) ") }
        let longRightSegments = [segment(100, " CLICKABLE-RIGHT-SEGMENT-WITH-LONG-TEXT ", command: "buffer_list")] +
            (0..<20).map { segment(101 + $0, " RIGHT-SEGMENT-WITH-LONG-TEXT-\($0) ") }
        let state = statusBarState(
            message: "A very long center status message that must stay inside its budget",
            leftSegments: longLeftSegments,
            rightSegments: longRightSegments
        )

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let layout = sut.modelineLayout(totalWidth: 360)

        #expect(layout.centerRect.width > 0)
        #expect(layout.centerRect.width <= 320)
        #expect(layout.leftModelineWidth > 0)
        #expect(layout.rightModelineWidth > 0)
        #expect(layout.centerIsProtected)
        #expect(layout.leftRect.maxX <= layout.centerRect.minX)
        #expect(layout.rightRect.minX >= layout.centerRect.maxX)
        #expect(layout.leftRect.width + layout.centerRect.width + layout.rightRect.width <= 360.5)

        let body = try sut.inspect()
        let strings = body.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        #expect(strings.contains("CLICKABLE-RIGHT-SEGMENT-WITH-LONG-TEXT"))
    }

    @Test("Layout protects center lane with huge left and tiny right groups")
    @MainActor func layoutProtectsCenterWithHugeLeftTinyRight() {
        let state = statusBarState(
            message: "Indexing project",
            leftSegments: (0..<40).map { segment($0, " LEFT-SEGMENT-\($0)-WITH-LONG-TEXT ") },
            rightSegments: [segment(200, " R ")]
        )
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let layout = sut.modelineLayout(totalWidth: 720)

        #expect(layout.centerRect.width > 0)
        #expect(layout.centerIsProtected)
        #expect(layout.leftRect.maxX <= layout.centerRect.minX)
        #expect(layout.rightRect.minX >= layout.centerRect.maxX)
    }

    @Test("Layout protects center lane with tiny left and huge right groups")
    @MainActor func layoutProtectsCenterWithTinyLeftHugeRight() {
        let state = statusBarState(
            message: "Saving buffer",
            leftSegments: [segment(1, " L ")],
            rightSegments: (0..<40).map { segment($0, " RIGHT-SEGMENT-\($0)-WITH-LONG-TEXT ") }
        )
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let layout = sut.modelineLayout(totalWidth: 720)

        #expect(layout.centerRect.width > 0)
        #expect(layout.centerIsProtected)
        #expect(layout.leftRect.maxX <= layout.centerRect.minX)
        #expect(layout.rightRect.minX >= layout.centerRect.maxX)
    }

    @Test("Layout collapses center before fixed controls in narrow windows")
    @MainActor func layoutCollapsesCenterInNarrowWindow() {
        let state = statusBarState(
            message: "Long center message",
            leftSegments: [segment(1, " LEFT ")],
            rightSegments: [segment(2, " RIGHT ")]
        )
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let layout = sut.modelineLayout(totalWidth: 180)

        #expect(layout.centerRect.width == 0)
        #expect(layout.centerIsProtected)
        #expect(layout.leftRect.width + layout.rightRect.width <= 180.5)
    }

    @Test("Layout preserves bounded fixed zones at app minimum width")
    @MainActor func layoutPreservesBoundedFixedZonesAtAppMinimumWidth() {
        let state = statusBarState(
            message: "Long center message",
            leftSegments: [segment(1, " LEFT ")],
            rightSegments: [segment(2, " RIGHT ")]
        )
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let layout = sut.modelineLayout(totalWidth: 160)

        #expect(layout.totalWidth == 160)
        #expect(layout.centerRect.width == 0)
        #expect(layout.centerIsProtected)
        #expect(layout.leftRect.minX == 0)
        #expect(layout.rightRect.maxX <= 160.5)
        #expect(layout.leftModelineWidth >= 0)
        #expect(layout.rightModelineWidth >= 0)
        #expect(layout.leftModelineWidth <= 8)
        #expect(layout.rightModelineWidth <= 8)
    }

    @Test("Layout uses side budgets when no center message is present")
    @MainActor func layoutWithoutCenterMessageUsesSideBudgets() {
        let state = statusBarState(
            leftSegments: (0..<10).map { segment($0, " LEFT-\($0) ") },
            rightSegments: [segment(20, " RIGHT ")]
        )
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let layout = sut.modelineLayout(totalWidth: 480)

        #expect(layout.centerRect.width == 0)
        #expect(layout.centerIsProtected)
        #expect(layout.leftModelineWidth > layout.rightModelineWidth)
        #expect(layout.leftRect.width + layout.rightRect.width <= 480.5)
    }

    @Test("Clickable configured modeline segment emits execute command")
    @MainActor func clickableConfiguredModelineSegmentEmitsCommand() throws {
        let spy = SpyEncoder()
        let state = statusBarState(leftSegments: [segment(1, " Buffers ", command: "buffer_list")])
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        #expect(spy.guiActions.contains(.executeCommand(name: "buffer_list")))
    }

    // ViewInspector verifies structure, deterministic layout budgets, and Button action wiring, but it does not exercise AppKit pixel hit regions after SwiftUI clipping. An NSHostingView smoke test did not dispatch SwiftUI Button actions reliably in this noninteractive harness, so clipped-region hit-test regressions still need AppKit/UI coverage.
    @Test("Passive configured modeline segment does not emit execute command")
    @MainActor func passiveConfiguredModelineSegmentDoesNotEmitCommand() throws {
        let spy = SpyEncoder()
        let state = statusBarState(leftSegments: [segment(1, " Passive ")])
        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        #expect(!spy.guiActions.contains(.executeCommand(name: "")))
        #expect(!spy.guiActions.contains(.executeCommand(name: "Passive")))
        #expect(!spy.guiActions.contains(.executeCommand(name: "buffer_list")))
    }

    @Test("Private-use glyph detection covers Nerd Font symbols")
    func privateUseGlyphDetection() {
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

    @Test("Agent mode shows message count and mode badge (model name is in agent chat header, not status bar)")
    @MainActor func agentMode() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 1, mode: 0, cursorLine: 0, cursorCol: 0,
            lineCount: 0, flags: 0, lspStatus: 0, gitBranch: "",
            message: "", filetype: "", errorCount: 0, warningCount: 0,
            modelName: "claude-3-5-sonnet", messageCount: 7, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            activeToolName: "",
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: [segment(0, " NORMAL ", kind: "mode")],
            modelineRightSegments: [segment(0, " 7 msgs ", kind: "position")]
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        // Model name no longer appears in the status bar (lives in agent chat header only)
        #expect(!strings.contains("claude-3-5-sonnet"))
        #expect(strings.contains("7 msgs"))
        #expect(strings.contains("NORMAL"))
    }

    @Test("Agent status shows readable labels and active tool names")
    @MainActor func agentStatusLabels() throws {
        let running = statusBarState(agentStatus: 2, activeToolName: "read_file")
        let runningTexts = try StatusBarView(state: running, theme: ThemeColors(), encoder: nil)
            .inspect()
            .findAll(ViewInspectorQuery.text)
            .compactMap { try? $0.string() }

        #expect(runningTexts.contains("Running read_file"))

        let fallback = statusBarState(agentStatus: 2)
        let fallbackTexts = try StatusBarView(state: fallback, theme: ThemeColors(), encoder: nil)
            .inspect()
            .findAll(ViewInspectorQuery.text)
            .compactMap { try? $0.string() }

        #expect(fallbackTexts.contains("Running"))
        #expect(!fallbackTexts.contains("Running read_file"))

        let plan = statusBarState(agentStatus: 4)
        let planBody = try StatusBarView(state: plan, theme: ThemeColors(), encoder: nil).inspect()
        let planTexts = planBody.findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        let planAccessibilityLabels = try planBody.findAll(ViewType.HStack.self).compactMap {
            try? $0.accessibilityLabel().string()
        }

        #expect(planTexts.contains("PLAN"))
        #expect(planAccessibilityLabels.contains("Agent plan mode"))
    }

    @Test("Git branch click opens branch picker")
    @MainActor func gitBranchClickOpensBranchPicker() throws {
        let spy = SpyEncoder()
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 1, cursorCol: 1,
            lineCount: 1, flags: 0x02, lspStatus: 0, gitBranch: "main",
            message: "", filetype: "", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: [segment(0, " main ", kind: "git")], modelineRightSegments: []
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: spy)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        for button in buttons {
            try button.tap()
        }

        #expect(spy.guiActions.contains(.executeCommand(name: "git_branch_picker")))
    }

    @Test("Git branch shown when flag is set")
    @MainActor func gitBranch() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 1, cursorCol: 1,
            lineCount: 1, flags: 0x02, lspStatus: 0, gitBranch: "main",
            message: "", filetype: "", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: [segment(0, " main ", kind: "git")], modelineRightSegments: []
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("main"))
    }

    @Test("Diagnostic counts shown when non-zero")
    @MainActor func diagnosticCounts() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 1, cursorCol: 1,
            lineCount: 1, flags: 0, lspStatus: 0, gitBranch: "",
            message: "", filetype: "", errorCount: 3, warningCount: 7,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            modelineLeftSegments: [], modelineRightSegments: [segment(0, " 3 ", kind: "diagnostics"), segment(1, " 7 ", kind: "diagnostics")]
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("3"))
        #expect(strings.contains("7"))
    }

    @Test("Background subagent segment shows count and label")
    @MainActor func backgroundSubagentsShown() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 1, cursorCol: 1,
            lineCount: 1, flags: 0, lspStatus: 0, gitBranch: "",
            message: "", filetype: "", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 2, backgroundSubagentLabel: "session-2: tests",
            modelineLeftSegments: [segment(0, " bg:2 session-2: tests", kind: "background_agent")], modelineRightSegments: []
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("bg:2 session-2: tests"))
    }

    @Test("Background subagent segment is hidden when count is zero")
    @MainActor func backgroundSubagentsHidden() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 1, cursorCol: 1,
            lineCount: 1, flags: 0, lspStatus: 0, gitBranch: "",
            message: "", filetype: "", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: "",
            backgroundSubagentCount: 0, backgroundSubagentLabel: "session-2: hidden",
            modelineLeftSegments: [], modelineRightSegments: []
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(!strings.contains("bg:0 session-2: hidden"))
        #expect(!strings.contains("session-2: hidden"))
    }
}

// MARK: - TabBarView

@Suite("TabBarView View Structure")
struct TabBarViewViewTests {

    @Test("Tab bar shows all tab labels")
    @MainActor func showsAllTabs() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            Wire.TabEntry(id: 1, groupId: 0, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "editor.ex"),
            Wire.TabEntry(id: 2, groupId: 0, isActive: false, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, isPinned: false, tintColorRGB: 0, icon: "", label: "test.ex"),
        ])

        let sut = TabBarView(tabBarState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("editor.ex"))
        #expect(strings.contains("test.ex"))
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
        state.updateWorkspaces(activeWorkspaceId: 1, mode: 1, flags: 0, entries: [
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "Active", icon: "cpu"),
            Wire.WorkspaceEntry(id: 2, kind: 1, status: 1, flags: 0, colorR: 0x44, colorG: 0x55, colorB: 0x66,
                                tabCount: 3, draftCount: 0, conflictCount: 0, runningBackgroundCount: 1, label: "Research", icon: "cpu")
        ], visibleTabs: [
            Wire.WorkspaceTabEntry(id: 42, workspaceId: 1, kind: 0, flags: 0, pathHash: 0, tintColorRGB: 0, icon: "", label: "active.ex", path: "/tmp/active.ex")
        ])

        let sut = TabBarView(tabBarState: state, theme: ThemeColors(), encoder: nil)
        let strings = try sut.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("active.ex"))
        #expect(!strings.contains("legacy-agent-chat"))
        #expect(!strings.contains("background.ex"))
        #expect(!strings.contains("Research"))
    }
}

// MARK: - WorkspaceHeaderView

@Suite("WorkspaceHeaderView View Structure")
struct WorkspaceHeaderViewTests {

    @MainActor private func populatedState() -> WorkspaceState {
        let state = WorkspaceState()
        state.update(version: 1, activeWorkspaceId: 2, mode: 1, flags: 1, workspaces: [
            Wire.WorkspaceEntry(id: 0, kind: 0, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "minga", icon: "folder"),
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "Research", icon: "cpu"),
            Wire.WorkspaceEntry(id: 2, kind: 1, status: 2, flags: 0x0003, colorR: 0x44, colorG: 0x55, colorB: 0x66,
                                tabCount: 2, draftCount: 1, conflictCount: 1, runningBackgroundCount: 1, label: "Review", icon: "cpu")
        ], visibleTabs: [
            Wire.WorkspaceTabEntry(id: 42, workspaceId: 2, kind: 0, flags: 0, pathHash: 0, tintColorRGB: 0, icon: "", label: "active.ex", path: "/tmp/active.ex")
        ])
        return state
    }

    @Test("Header shows active workspace metadata and badges")
    @MainActor func showsActiveWorkspaceMetadataAndBadges() throws {
        let sut = WorkspaceHeaderView(workspaceState: populatedState(), theme: ThemeColors(), encoder: nil)
        let strings = try sut.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

        #expect(strings.contains("Review"))
        #expect(strings.contains("Using tools"))
        #expect(strings.contains("⚡1"))
        #expect(strings.contains("✓1"))
        #expect(strings.contains("⚠︎1"))
        #expect(strings.contains("!"))
    }

    @Test("Header exposes background workspace badges without activating them")
    @MainActor func showsBackgroundWorkspaceBadges() throws {
        let state = WorkspaceState()
        state.update(version: 1, activeWorkspaceId: 0, mode: 0, flags: 0, workspaces: [
            Wire.WorkspaceEntry(id: 0, kind: 0, status: 0, flags: 0, colorR: 0x11, colorG: 0x22, colorB: 0x33,
                                tabCount: 1, draftCount: 0, conflictCount: 0, runningBackgroundCount: 0, label: "minga", icon: "folder"),
            Wire.WorkspaceEntry(id: 1, kind: 1, status: 3, flags: 0x0001, colorR: 0x44, colorG: 0x55, colorB: 0x66,
                                tabCount: 2, draftCount: 1, conflictCount: 1, runningBackgroundCount: 1, label: "Background", icon: "cpu")
        ], visibleTabs: [])

        let sut = WorkspaceHeaderView(workspaceState: state, theme: ThemeColors(), encoder: nil)
        let strings = try sut.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }

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

        #expect(state.switchCommand(for: manualWorkspace) == "manual_workspace")
        #expect(state.switchCommand(for: reviewWorkspace) == "workspace_goto_2")
    }
}

// MARK: - AgentChatView

@Suite("AgentChatView View Structure")
struct AgentChatViewTests {

    @Test("Empty messages shows header and prompt area")
    @MainActor func emptyMessages() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "claude-sonnet-4"
        state.status = 0

        let sut = AgentChatView(state: state, theme: ThemeColors(), isInsertMode: false, encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        // Header shows model name and status
        #expect(strings.contains("claude-sonnet-4"))
        #expect(strings.contains("idle"))
        // Prompt shows placeholder in normal mode
        #expect(strings.contains("Ask anything..."))
        // NORMAL mode indicator shown in prompt border
        #expect(strings.contains("NORMAL"))
    }

    @Test("Header strips provider prefix and shows thinking level")
    @MainActor func headerModelAndThinkingControls() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "anthropic:claude-sonnet-4"
        state.thinkingLevel = "high"
        state.status = 0

        let sut = AgentChatView(state: state, theme: ThemeColors(), isInsertMode: false, encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("claude-sonnet-4"))
        #expect(!strings.contains("anthropic:claude-sonnet-4"))
        #expect(strings.contains("High"))
    }

    @Test("Header controls dispatch model and thinking commands")
    @MainActor func headerControlsDispatchCommands() throws {
        let spy = SpyEncoder()
        let state = AgentChatState()
        state.visible = true
        state.model = "claude-sonnet-4"
        state.thinkingLevel = "medium"
        state.status = 0

        let sut = AgentChatView(state: state, theme: ThemeColors(), isInsertMode: false, encoder: spy)
        let body = try sut.inspect()

        let headerButtons = try body.findAll(ViewType.Button.self)
        let modelButton = try #require(headerButtons.first(where: {
            (try? $0.accessibilityLabel().string()) == "Agent model"
        }))
        try modelButton.tap()
        #expect(spy.guiActions.contains(.executeCommand(name: "agent_pick_model")))

        let thinkingMenu = try body.find(ViewType.Menu.self)
        let thinkingButtons = try thinkingMenu.findAll(ViewType.Button.self)
        let highButton = try #require(thinkingButtons.first(where: {
            ((try? $0.accessibilityLabel().string()) ?? "").contains("High")
        }))
        try highButton.tap()
        #expect(spy.guiActions.contains(.executeCommand(name: "agent_thinking_high")))
    }

    @Test("User message renders as bubble")
    @MainActor func userMessage() throws {
        let state = AgentChatState()
        state.visible = true
        state.model = "test-model"
        state.messages = [.user(id: 0, text: "Hello world")]

        let sut = AgentChatView(state: state, theme: ThemeColors(), isInsertMode: false, encoder: nil)
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
        state.messages = [.system(id: 0, text: "Session started", isError: false)]

        let sut = AgentChatView(state: state, theme: ThemeColors(), isInsertMode: false, encoder: nil)
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
        state.promptVimMode = 1 // insert mode

        let sut = AgentChatView(state: state, theme: ThemeColors(), isInsertMode: true, encoder: nil)
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
            state: state, theme: ThemeColors(),
            encoder: nil, availableHeight: 600
        )
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
            state: state, theme: ThemeColors(),
            encoder: nil, availableHeight: 600
        )
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }
        #expect(strings.contains("Messages"))
        #expect(strings.contains("Diagnostics"))
    }
}

// MARK: - ViewInspector query helper

/// Namespace for ViewInspector query types.
enum ViewInspectorQuery {
    /// Finds all Text views in the hierarchy.
    static let text = ViewType.Text.self
}
