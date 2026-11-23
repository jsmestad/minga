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
