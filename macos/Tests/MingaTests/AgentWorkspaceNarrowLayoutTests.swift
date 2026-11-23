import AppKit
import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing
import ViewInspector

/// A narrow window is a supported geometry (#3926). Every view in the Agent
/// workspace must be able to shrink below the window width; one rigid child
/// forces the whole window content wider and clips it on both sides.
@Suite("Agent workspace narrow layout")
@MainActor
struct AgentWorkspaceNarrowLayoutTests {
    private let narrowWindowWidth: CGFloat = 420
    private let activityBarWidth: CGFloat = 32

    @Test("The Agent workspace shell fits a 420 point window")
    func shellFitsNarrowWindow() {
        let gui = agentWorkspaceGUI()
        let root = ContentView(
            gui: gui,
            encoder: { nil },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            Color.clear
        }

        #expect(minimumWidth(root) <= narrowWindowWidth)
    }

    @Test("Each Agent pane element fits beside the activity bar in a 420 point window")
    func paneElementsFitNarrowWindow() {
        let gui = agentWorkspaceGUI()
        let pane = narrowWindowWidth - activityBarWidth
        let chat = gui.agentChatState

        #expect(minimumWidth(AgentChatHeaderView(state: chat, sendAction: nil)) <= pane)
        #expect(minimumWidth(AgentPromptView(state: chat, isInsertMode: true, sendAction: nil)) <= pane)
        #expect(minimumWidth(AgentChatView(state: chat, isInsertMode: true, sendAction: nil)) <= pane)
        #expect(minimumWidth(AgentContextBar(state: gui.agentContextBarState, onReview: { _ in })) <= pane)
        #expect(minimumWidth(EditTimelineView(state: gui.editTimelineState, sendAction: nil)) <= pane)
    }

    @Test("A wide workspace header keeps its ideal width up to 280 points")
    func workspaceHeaderKeepsIdealWidthWhenRoomy() {
        let gui = agentWorkspaceGUI()
        let header = WorkspaceHeaderView(workspaceState: gui.workspaceState, sendAction: nil)
        let rigid = header.frame(maxWidth: 280).fixedSize(horizontal: true, vertical: false)
        let compressible = header.compressibleIdealWidth(maximum: 280)

        #expect(width(compressible, offered: 900) == width(rigid, offered: 900))
        #expect(width(compressible, offered: 200) <= 200)
        #expect(minimumWidth(compressible) < minimumWidth(rigid))
    }

    @Test("With the sidebar open, the shell and its toolbar fit a 420 point window")
    func shellWithSidebarFitsNarrowWindow() {
        let gui = agentWorkspaceGUI()
        showFileTreeSidebar(gui)

        let shell = minimumWidth(contentView(gui))
        #expect(shell <= narrowWindowWidth, "shell minimum width \(shell)")
    }

    @Test("Every sidebar header and body fits the narrowest presented sidebar",
          arguments: ["file_tree", "git_status", "observatory", "unknown_kind"])
    func sidebarFitsNarrowestWidth(kind: String) {
        let gui = agentWorkspaceGUI()
        showFileTreeSidebar(gui)
        PreviewFixtures.populateGitStatus(gui.gitStatusState)
        let item = SidebarItem(Wire.SidebarMetadata(
            id: kind, displayName: "Sidebar", semanticKind: kind, icon: "folder",
            order: 10, visible: true, focused: true, preferredWidth: 30, badgeCount: nil
        ))
        let titleBarInset: CGFloat = 36
        let resizeHandleWidth: CGFloat = 8
        let header = minimumWidth(NativeSidebarHeader(
            input: gui.shellInput, item: item, sendAction: nil,
            projectName: "minga", gitBranch: "main", leadingPadding: titleBarInset
        ))
        let body = minimumWidth(NativeSidebarBody(input: gui.shellInput, item: item, sendAction: nil, frameProbe: nil))

        #expect(header <= SidebarSizing.narrowMinWidth + resizeHandleWidth, "header minimum width \(header)")
        #expect(body <= SidebarSizing.narrowMinWidth, "body minimum width \(body)")
    }

    @Test("The narrow file tree header keeps New File in its overflow menu")
    func narrowFileTreeHeaderKeepsNewFile() throws {
        let recorder = LocalActionRecorder<FileTreeHeaderView.Action>()
        let fileTree = FileTreeState()
        PreviewFixtures.populateFileTree(fileTree)
        let header = FileTreeHeaderView(fileTreeState: fileTree, sendAction: recorder.handler, branchName: "main", leadingPadding: 36)
            .environment(\.themeColors, ThemeColors())
        let menus = try header.inspect().findAll(ViewType.Menu.self) { menu in
            (try? menu.accessibilityLabel().string()) == "More file tree actions"
        }
        let newFile = try #require(menus.lazy.compactMap { menu in
            try? menu.find(ViewType.Button.self) { button in
                (try? button.labelView().text().string()) == "New File…"
            }
        }.first)

        try newFile.tap()

        #expect(recorder.actions == [.newFile(generation: fileTree.generation, parentID: "")])
    }

    @Test("The narrow tab bar menu dispatches both split commands",
          arguments: [("Split Right", "split_vertical"), ("Split Below", "split_horizontal")])
    func narrowTabBarMenuDispatchesSplits(label: String, command: String) throws {
        let recorder = LocalActionRecorder<TabBarView.Action>()
        let tabs = TabBarState()
        PreviewFixtures.populateTabBar(tabs)
        let tabBar = TabBarView(tabBarState: tabs, sendAction: recorder.handler)
            .environment(\.themeColors, ThemeColors())
        let button = try tabBar.inspect().find(ViewType.Button.self) { button in
            (try? button.find(text: label)) != nil
        }

        try button.tap()

        #expect(recorder.actions == [.executeCommand(name: command)])
    }

    @Test("With the sidebar open in a 420 point window, the Agent pane keeps a readable width")
    func agentPaneStaysReadableWithSidebar() {
        let gui = agentWorkspaceGUI()
        showFileTreeSidebar(gui)

        let pane = editorColumnWidth(gui, windowWidth: narrowWindowWidth)

        #expect(pane >= SidebarSizing.contentMinWidth, "Agent pane width \(pane)")
        // The BEAM said the sidebar is open, so it stays presented, only narrower.
        #expect(pane <= narrowWindowWidth - activityBarWidth - SidebarSizing.narrowMinWidth, "Agent pane width \(pane)")
    }

    @Test("With the sidebar open in a wide window, the sidebar keeps the user's width",
          arguments: [900, 1200] as [CGFloat])
    func wideWindowKeepsSidebarWidth(windowWidth: CGFloat) {
        let gui = agentWorkspaceGUI()
        showFileTreeSidebar(gui)
        let resizeHandleWidth: CGFloat = 8
        let fullSidebar = activityBarWidth + SidebarSizing.defaultWidth + resizeHandleWidth

        #expect(editorColumnWidth(gui, windowWidth: windowWidth) == windowWidth - fullSidebar)
    }

    @Test("The sidebar column yields width only below its ideal plus the content minimum")
    func presentedLeadingWidth() {
        let ideal: CGFloat = 280
        let minimum: CGFloat = 140
        let content = SidebarSizing.contentMinWidth
        let width = { (available: CGFloat) in
            SidebarSizing.presentedLeadingWidth(available: available, ideal: ideal, minimum: minimum, contentMinimum: content)
        }

        #expect(width(1200) == ideal)
        #expect(width(ideal + content) == ideal)
        #expect(width(ideal + content - 1) == ideal - 1)
        #expect(width(420) == 420 - content)
        #expect(width(minimum + content) == minimum)
        #expect(width(200) == minimum)
    }

    @Test("The narrow header menu dispatches every header command",
          arguments: AgentChatHeaderView.HeaderCommand.allCases)
    func overflowMenuDispatchesCommands(command: AgentChatHeaderView.HeaderCommand) throws {
        let recorder = LocalActionRecorder<AgentChatHeaderView.Action>()
        let state = AgentChatState(status: .idle, model: "claude-sonnet-4")
        let header = AgentChatHeaderView(state: state, sendAction: recorder.handler)
            .environment(\.themeColors, ThemeColors())
        let menu = try header.inspect().find(ViewType.Menu.self) { menu in
            (try? menu.accessibilityLabel().string()) == "More Agent actions"
        }
        let button = try menu.find(ViewType.Button.self) { button in
            (try? button.accessibilityLabel().string()) == command.accessibilityLabel
        }

        try button.tap()

        #expect(recorder.actions == [.executeCommand(name: command.rawValue)])
    }

    private func agentWorkspaceGUI() -> GUIState {
        let gui = GUIState()
        PreviewFixtures.populateAgentChat(gui.agentChatState)
        PreviewFixtures.populateAgentWorkspace(gui)
        return gui
    }

    private func contentView(_ gui: GUIState, editorSurface: some View = Color.clear) -> some View {
        ContentView(
            gui: gui,
            encoder: { nil },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            editorSurface
        }
    }

    private func showFileTreeSidebar(_ gui: GUIState) {
        PreviewFixtures.populateFileTree(gui.fileTreeState)
        gui.fileTreeState.visible = true
        gui.sidebarHostState.update(activeId: "file_tree", sidebars: [
            Wire.SidebarMetadata(
                id: "file_tree", displayName: "File Tree", semanticKind: "file_tree", icon: "folder",
                order: 10, visible: true, focused: true, preferredWidth: 30, badgeCount: nil
            )
        ])
    }

    /// Lays the shell out in a window of `windowWidth` and returns the width given to the editor column, which hosts the Agent pane.
    private func editorColumnWidth(_ gui: GUIState, windowWidth: CGFloat) -> CGFloat {
        let probe = WidthProbe()
        let surface = Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            probe.width = width
        }
        let root = contentView(gui, editorSurface: surface).environment(\.themeColors, PreviewFixtures.theme())
        let frame = NSRect(x: 0, y: 0, width: windowWidth, height: 700)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = frame
        hostingView.layoutSubtreeIfNeeded()
        return probe.width
    }

    private func minimumWidth<V: View>(_ view: V) -> CGFloat {
        width(view, offered: 1)
    }

    private func width<V: View>(_ view: V, offered: CGFloat) -> CGFloat {
        let themed = view.environment(\.themeColors, PreviewFixtures.theme())
        let host = NSHostingController(rootView: themed)
        let size = host.sizeThatFits(in: CGSize(width: offered, height: 4000))
        return size.width
    }
}

@MainActor
private final class WidthProbe {
    var width: CGFloat = 0
}
