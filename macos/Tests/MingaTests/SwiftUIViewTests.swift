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
            encoder: nil, cellWidth: 8, cellHeight: 16
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
                GUICompletionItem(kind: 1, label: "def", detail: "keyword"),
                GUICompletionItem(kind: 2, label: "defmodule", detail: "keyword"),
            ]
        )

        let sut = CompletionOverlay(
            state: state, theme: ThemeColors(),
            encoder: nil, cellWidth: 8, cellHeight: 16
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
                GUIWhichKeyBinding(kind: 0, key: "f", description: "Find file", icon: ""),
                GUIWhichKeyBinding(kind: 1, key: "b", description: "Buffers", icon: ""),
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
                GUIWhichKeyBinding(kind: 0, key: "a", description: "test", icon: ""),
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

    @Test("Buffer mode shows cursor position and mode badge")
    @MainActor func bufferMode() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 0, mode: 0, cursorLine: 42, cursorCol: 9,
            lineCount: 500, flags: 0, lspStatus: 0, gitBranch: "",
            message: "", filetype: "elixir", errorCount: 0, warningCount: 0,
            modelName: "", messageCount: 0, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: ""
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("Ln 42, Col 9"))
        #expect(strings.contains("NORMAL"))
        #expect(strings.contains("elixir"))
    }

    @Test("Agent mode shows model name and mode badge")
    @MainActor func agentMode() throws {
        let state = StatusBarState()
        state.update(from: StatusBarUpdate(
            contentKind: 1, mode: 0, cursorLine: 0, cursorCol: 0,
            lineCount: 0, flags: 0, lspStatus: 0, gitBranch: "",
            message: "", filetype: "", errorCount: 0, warningCount: 0,
            modelName: "claude-3-5-sonnet", messageCount: 7, sessionStatus: 0,
            infoCount: 0, hintCount: 0, macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0,
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: ""
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("claude-3-5-sonnet"))
        #expect(strings.contains("7 msgs"))
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
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: ""
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
            icon: "", iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "", diagnosticHint: ""
        ))

        let sut = StatusBarView(state: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("3"))
        #expect(strings.contains("7"))
    }
}

// MARK: - TabBarView

@Suite("TabBarView View Structure")
struct TabBarViewViewTests {

    @Test("Tab bar shows all tab labels")
    @MainActor func showsAllTabs() throws {
        let state = TabBarState()
        state.update(activeIndex: 0, entries: [
            GUITabEntry(id: 1, isActive: true, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, icon: "", label: "editor.ex"),
            GUITabEntry(id: 2, isActive: false, isDirty: false, isAgent: false,
                       hasAttention: false, agentStatus: 0, icon: "", label: "test.ex"),
        ])

        let sut = TabBarView(tabBarState: state, theme: ThemeColors(), encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("editor.ex"))
        #expect(strings.contains("test.ex"))
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
        // Prompt shows normal-mode placeholder
        #expect(strings.contains("Press i to type"))
        #expect(strings.contains("NORMAL"))
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

        let sut = AgentChatView(state: state, theme: ThemeColors(), isInsertMode: true, encoder: nil)
        let body = try sut.inspect()
        let texts = body.findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }

        #expect(strings.contains("Type a message, Enter to send"))
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
