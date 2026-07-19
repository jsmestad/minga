import MingaUI
import SwiftUI
import MingaProtocol

@MainActor
extension PreviewRegistry {

    // MARK: - AgentChatView

    static func agentChatPreview() -> some View {
        agentChatView(width: 760, height: 600)
    }

    static func agentChatView(width: CGFloat, height: CGFloat) -> some View {
        let state = AgentChatState()
        let theme = PreviewFixtures.theme()
        state.update(
            visible: true,
            status: 2,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "Make the notification card use the configured theme",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 52,
            promptVimMode: 1,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: []
        )
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: PreviewFixtures.agentChatMessages())

        return AgentChatView(state: state, isInsertMode: true, encoder: nil, cellHeight: 18)
            .frame(width: width, height: height)
            .background(theme.agentPanelBg)
            .environment(theme)
    }

    // MARK: - AgentChatStreaming

    static func agentChatStreamingPreview() -> some View {
        let state = AgentChatState()
        let theme = PreviewFixtures.theme()
        state.update(
            visible: true,
            status: 1,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: []
        )
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Refactor the buffer module to separate read and write concerns into distinct GenServer processes.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "The buffer module currently mixes read-only queries (content, line count, syntax tree) with mutation operations (insert, delete, undo/redo). Splitting these would let readers proceed without blocking on writes, improving latency for completions and diagnostics that only need a snapshot.", collapsed: false)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "lib/minga/buffer/process.ex", status: 0, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 0, result: "", previewKind: 0, previewLines: [])),
            ]
        )

        return AgentChatView(state: state, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
            .environment(theme)
    }

    // MARK: - AgentChatApproval

    static func agentChatApprovalPreview() -> some View {
        let state = AgentChatState()
        let theme = PreviewFixtures.theme()
        state.update(
            visible: true,
            status: 2,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: []
        )
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Run the full test suite and fix any failures.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "I'll run the tests first to identify failures before making changes.", collapsed: true)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "mix.exs", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 62, result: "Read 48 lines", previewKind: 0, previewLines: [])),
                Wire.ChatMessage(beamId: 4, content: .approvalToolCall(name: "shell", summary: "mix test --trace", toolCallId: "tc-approve-1", previewKind: 2, previewLines: ["mix test --trace", "", "Runs the full test suite with verbose output.", "This command may take several minutes."])),
            ]
        )

        return AgentChatView(state: state, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
            .environment(theme)
    }

    // MARK: - AgentChatError

    static func agentChatErrorPreview() -> some View {
        let state = AgentChatState()
        let theme = PreviewFixtures.theme()
        state.update(
            visible: true,
            status: 3,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: []
        )
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Deploy the staging environment.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "I'll check the deployment configuration and run the staging deploy script.", collapsed: true)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "shell", summary: "mix release --env=staging", status: 1, isError: false, collapsed: true, autoApprovedScope: 2, durationMs: 4200, result: "Release built successfully", previewKind: 0, previewLines: [])),
                Wire.ChatMessage(beamId: 4, content: .toolCall(name: "shell", summary: "scripts/deploy.sh staging", status: 2, isError: true, collapsed: false, autoApprovedScope: 2, durationMs: 12400, result: "Error: SSH connection to staging-01.internal timed out after 30s\nexit code: 1", previewKind: 0, previewLines: [])),
                Wire.ChatMessage(beamId: 5, content: .system(text: "Tool execution failed. The deploy script could not reach the staging host.", isError: true)),
                Wire.ChatMessage(beamId: 6, content: .assistant(text: "The deploy failed because the staging host is unreachable. Check that the VPN is connected and that staging-01.internal is responding to SSH on port 22.")),
            ]
        )

        return AgentChatView(state: state, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
            .environment(theme)
    }

    // MARK: - AgentChatCompletion

    static func agentChatCompletionPreview() -> some View {
        let state = AgentChatState()
        let theme = PreviewFixtures.theme()
        state.update(
            visible: true,
            status: 0,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "/",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 1,
            promptVimMode: 1,
            promptVisibleRows: 1,
            promptCompletion: Wire.PromptCompletion(
                type: 1,
                selected: 1,
                anchorLine: 0,
                anchorCol: 0,
                candidates: [
                    (name: "/clear", description: "Clear conversation history"),
                    (name: "/compact", description: "Summarize and compact context"),
                    (name: "/cost", description: "Show session cost breakdown"),
                    (name: "/help", description: "Show available commands"),
                    (name: "/model", description: "Switch the active model"),
                    (name: "/thinking", description: "Set thinking level"),
                ]
            ),
            helpVisible: false,
            helpGroups: []
        )
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
                Wire.ChatMessage(beamId: 1, content: .system(text: "Agent session started.", isError: false)),
            ]
        )

        return AgentChatView(state: state, isInsertMode: true, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
            .environment(theme)
    }

    // MARK: - AgentChatSummary

    static func agentChatSummaryPreview() -> some View {
        let state = AgentChatState()
        let theme = PreviewFixtures.theme()
        state.update(
            visible: true,
            status: 0,
            model: "anthropic:claude-sonnet-4",
            thinkingLevel: "medium",
            prompt: "",
            promptLineCount: 1,
            promptCursorLine: 0,
            promptCursorCol: 0,
            promptVimMode: 0,
            promptVisibleRows: 1,
            promptCompletion: nil,
            helpVisible: false,
            helpGroups: []
        )
        state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [
                Wire.ChatMessage(beamId: 1, content: .user(text: "Add input validation to the user registration form.")),
                Wire.ChatMessage(beamId: 2, content: .thinking(text: "I need to add validation for email format, password strength, and required fields.", collapsed: true)),
                Wire.ChatMessage(beamId: 3, content: .toolCall(name: "read", summary: "lib/minga/accounts/registration.ex", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 95, result: "Read 82 lines", previewKind: 0, previewLines: [])),
                Wire.ChatMessage(beamId: 4, content: .toolCall(name: "edit", summary: "Add changeset validations", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 210, result: "Applied 3 edits", previewKind: 0, previewLines: [])),
                Wire.ChatMessage(beamId: 5, content: .toolCall(name: "edit", summary: "Add error message helpers", status: 1, isError: false, collapsed: true, autoApprovedScope: 1, durationMs: 145, result: "Applied 1 edit", previewKind: 0, previewLines: [])),
                Wire.ChatMessage(beamId: 6, content: .toolCall(name: "shell", summary: "mix test test/minga/accounts/registration_test.exs", status: 1, isError: false, collapsed: true, autoApprovedScope: 2, durationMs: 3400, result: "8 tests, 0 failures", previewKind: 0, previewLines: [])),
                Wire.ChatMessage(beamId: 7, content: .assistant(text: "I added input validation to the registration changeset: email format check via a regex, password minimum length of 8 characters with at least one digit, and validate_required on name, email, and password. All 8 tests pass.")),
                Wire.ChatMessage(beamId: 8, content: .usage(input: 96_000, output: 2_150, cacheRead: 48_000, cacheWrite: 960, costMicros: 287_000)),
            ]
        )

        return AgentChatView(state: state, isInsertMode: false, encoder: nil, cellHeight: 18)
            .frame(width: 760, height: 600)
            .background(theme.agentPanelBg)
            .environment(theme)
    }
}
