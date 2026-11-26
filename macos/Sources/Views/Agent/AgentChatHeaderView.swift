import SwiftUI

public struct AgentChatHeaderView: View {
    public enum Action: Equatable, Sendable {
        case executeCommand(name: String)
    }

    public init(state: AgentChatState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }
    public let state: AgentChatState
    public let sendAction: ViewActionHandler<Action>?
    @Environment(\.themeColors) private var theme

    @State private var isModelHovered: Bool = false
    @State private var isThinkingHovered: Bool = false
    @State private var isHelpHovered: Bool = false

    public var body: some View {
        // The full row is chosen whenever its ideal width fits, so wide panes
        // keep every labelled control. Narrower panes first drop the labels,
        // then move the commands into one menu while the model name truncates.
        ViewThatFits(in: .horizontal) {
            fullRow
            iconRow
            compactRow
        }
        .background(theme.agentHeaderBg)

        Rectangle()
            .fill(theme.agentCodeBorder.opacity(0.3))
            .frame(height: 1)
    }

    private var fullRow: some View {
        HStack(spacing: Spacing.md) {
            statusIndicator

            modelPickerButton

            Text("·")
                .font(Typography.font(.small))
                .foregroundStyle(theme.agentDisabledFg)

            thinkingLevelMenu(compact: false)

            if state.isThinking {
                workingMark
            }

            Spacer()

            Text(state.statusLabel)
                .font(Typography.font(.small))
                .foregroundStyle(theme.agentMutedFg)
                .lineLimit(1)

            Button {
                send(.checklist)
            } label: {
                Label(HeaderCommand.checklist.title, systemImage: HeaderCommand.checklist.systemImage)
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.agentMutedFg)
                    .lineLimit(1)
                    .padding(Spacing.xs)
            }
            .buttonStyle(.plain)
            .help(HeaderCommand.checklist.help)
            .accessibilityLabel(HeaderCommand.checklist.accessibilityLabel)

            iconButton(.queuedInputs)
            iconButton(.retainedHistory)

            Button {
                send(.help)
            } label: {
                Image(systemName: HeaderCommand.help.systemImage)
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(theme.agentMutedFg)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.sm).fill(isHelpHovered ? theme.agentTextFg.opacity(0.06) : Color.clear))
            }
            .buttonStyle(.plain)
            .help(HeaderCommand.help.help)
            .accessibilityLabel(HeaderCommand.help.accessibilityLabel)
            .accessibilityHint("Shows keybinding cheatsheet")
            .accessibilityAddTraits(.isButton)
            .onHover { hovering in
                isHelpHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    /// Keeps each command as its own labelled icon button when labels no longer fit.
    private var iconRow: some View {
        HStack(spacing: Spacing.sm) {
            statusIndicator

            modelPickerButton
                .layoutPriority(-1)

            thinkingLevelMenu(compact: true)

            if state.isThinking {
                workingMark
            }

            Spacer(minLength: 0)

            ForEach(HeaderCommand.allCases, id: \.self) { command in
                iconButton(command)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    /// Keeps every control reachable in a narrow pane: the model name truncates,
    /// the thinking menu shows its icon, and the remaining commands share one menu.
    private var compactRow: some View {
        HStack(spacing: Spacing.sm) {
            statusIndicator

            modelPickerButton
                .layoutPriority(-1)

            thinkingLevelMenu(compact: true)

            if state.isThinking {
                workingMark
            }

            Spacer(minLength: 0)

            overflowMenu
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    /// The working mark of the state vocabulary (docs/design/marks.md), the one the modeline and a running step draw. It stands still under Reduce Motion and in captured frames, which a system spinner does not.
    private var workingMark: some View {
        StateMark(state: .working)
            .frame(width: AgentToolCallCard.markSize, height: AgentToolCallCard.markSize)
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Agent status: \(state.statusLabel)")
    }

    private func iconButton(_ command: HeaderCommand) -> some View {
        Button {
            send(command)
        } label: {
            Image(systemName: command.systemImage)
                .foregroundStyle(theme.agentMutedFg)
                .padding(Spacing.xs)
        }
        .buttonStyle(.plain)
        .help(command.help)
        .accessibilityLabel(command.accessibilityLabel)
        .accessibilityHint(command.accessibilityHint)
    }

    private var overflowMenu: some View {
        Menu {
            Text(state.statusLabel)
            Divider()
            ForEach(HeaderCommand.allCases, id: \.self) { command in
                Button {
                    send(command)
                } label: {
                    Label(command.title, systemImage: command.systemImage)
                }
                .accessibilityLabel(command.accessibilityLabel)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Typography.font(.emphasis))
                .foregroundStyle(theme.agentMutedFg)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Agent actions")
        .accessibilityLabel("More Agent actions")
        .accessibilityValue(state.statusLabel)
    }

    private func send(_ command: HeaderCommand) {
        sendAction?(.executeCommand(name: command.rawValue))
    }

    /// Header commands shared by the full row and the compact overflow menu.
    enum HeaderCommand: String, CaseIterable {
        case checklist = "agent_checklist"
        case queuedInputs = "agent_queued_inputs"
        case retainedHistory = "agent_retained_history"
        case help = "agent_toggle_help"

        var title: String {
            switch self {
            case .checklist: "Tasks"
            case .queuedInputs: "Queued Inputs"
            case .retainedHistory: "Retained History"
            case .help: "Keyboard Shortcuts"
            }
        }

        var systemImage: String {
            switch self {
            case .checklist: "checklist"
            case .queuedInputs: "list.bullet.rectangle"
            case .retainedHistory: "clock.arrow.circlepath"
            case .help: "questionmark.circle"
            }
        }

        var help: String {
            switch self {
            case .checklist: "Inspect Agent checklist (SPC a S k)"
            case .queuedInputs: "Inspect queued Agent inputs (SPC a q q)"
            case .retainedHistory: "Read retained messages (SPC a S H)"
            case .help: "Keyboard shortcuts (?)"
            }
        }

        /// Extra VoiceOver context, kept identical across the full, icon and compact rows.
        var accessibilityHint: String {
            switch self {
            case .help: "Shows keybinding cheatsheet"
            case .checklist, .queuedInputs, .retainedHistory: ""
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .checklist: "Agent checklist"
            case .queuedInputs: "Queued Agent inputs"
            case .retainedHistory: "Retained Agent history"
            case .help: "Agent help"
            }
        }
    }

    // MARK: - Model picker

    private var modelPickerButton: some View {
        Button {
            if !state.hasActiveTurn {
                sendAction?(.executeCommand(name: "agent_pick_model"))
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                if !state.displayProvider.isEmpty {
                    // The provider truncates before the model name in a narrow pane.
                    Text(state.displayProvider)
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.agentMutedFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Text("/")
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.agentDisabledFg)
                }
                Text(state.displayModel.isEmpty ? "Agent" : state.displayModel)
                    .font(Typography.font(.body, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typography.font(.micro, weight: .semibold))
            }
            .foregroundStyle(state.hasActiveTurn ? theme.agentSecondaryFg : theme.agentHeaderFg)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(isModelHovered && !state.hasActiveTurn ? theme.agentTextFg.opacity(0.06) : Color.clear))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!state.hasActiveTurn)
        .help("Pick model (SPC a S m)")
        .accessibilityLabel("Agent model")
        .accessibilityValue(modelAccessibilityValue)
        .accessibilityHint(state.hasActiveTurn ? "Disabled while the agent turn is active" : "Opens the model picker")
        .accessibilityAddTraits(.isButton)
        .onHover { isModelHovered = $0 }
        .modifier(HeaderControlPointingHandModifier(isEnabled: !state.hasActiveTurn))
    }

    /// Names the provider with the model, in the order a listener needs them.
    private var modelAccessibilityValue: String {
        let model = state.displayModel.isEmpty ? "Agent" : state.displayModel
        return state.displayProvider.isEmpty ? model : "\(model), \(state.displayProvider)"
    }

    // MARK: - Thinking level

    @ViewBuilder
    private func thinkingLevelMenu(compact: Bool) -> some View {
        if state.hasActiveTurn {
            thinkingLevelLabel(compact: compact)
                .help("Pick thinking level (SPC a S t)")
                .accessibilityLabel("Agent thinking level")
                .accessibilityValue(state.thinkingLabel)
                .accessibilityHint("Disabled while the agent turn is active")
                .accessibilityAddTraits(.isButton)
        } else {
            Menu {
                ForEach(["off", "low", "medium", "high"], id: \.self) { level in
                    Button {
                        sendAction?(.executeCommand(name: "agent_thinking_\(level)"))
                    } label: {
                        HStack {
                            Text(thinkingDisplayName(level))
                            if state.thinkingLevel == level {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityLabel("Set thinking level to \(thinkingDisplayName(level))")
                    .accessibilityHint("Changes the agent thinking level to \(thinkingDisplayName(level))")
                }
            } label: {
                thinkingLevelLabel(compact: compact)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick thinking level (SPC a S t)")
            .accessibilityLabel("Agent thinking level")
            .accessibilityValue(state.thinkingLabel)
            .accessibilityHint("Opens a menu of thinking levels")
            .accessibilityAddTraits(.isButton)
            .onHover { isThinkingHovered = $0 }
            .modifier(HeaderControlPointingHandModifier(isEnabled: true))
        }
    }

    private func thinkingLevelLabel(compact: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: state.thinkingIconName)
                .font(Typography.font(.body))
            if !compact {
                Text(state.thinkingLabel)
                    .font(Typography.font(.body, weight: .medium))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(Typography.font(.symbol, weight: .semibold))
        }
        .foregroundStyle(state.hasActiveTurn ? theme.agentSecondaryFg : theme.agentHeaderFg.opacity(0.9))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(isThinkingHovered && !state.hasActiveTurn ? theme.agentTextFg.opacity(0.06) : Color.clear))
    }

    private func thinkingDisplayName(_ level: String) -> String {
        switch level {
        case "off": return "Off"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        default: return level.capitalized
        }
    }

    // MARK: - Helpers

    /// The colour of the state the status speaks as, from the same table as its word; no state draws in the waiting role.
    private var statusColor: Color {
        theme.stateColor(state.status.spineState ?? .waiting)
    }

    private struct HeaderControlPointingHandModifier: ViewModifier {
        let isEnabled: Bool
        @State private var isHovered = false
        @State private var didPushCursor = false

        func body(content: Content) -> some View {
            content
                .onHover { hovering in
                    isHovered = hovering
                    syncCursor()
                }
                .onChange(of: isEnabled) { _, _ in
                    syncCursor()
                }
                .onDisappear {
                    popCursorIfNeeded()
                }
        }

        private func syncCursor() {
            let shouldPush = isHovered && isEnabled

            if shouldPush && !didPushCursor {
                NSCursor.pointingHand.push()
                didPushCursor = true
            } else if !shouldPush && didPushCursor {
                popCursorIfNeeded()
            }
        }

        private func popCursorIfNeeded() {
            if didPushCursor {
                NSCursor.pop()
                didPushCursor = false
            }
        }
    }
}
