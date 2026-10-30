import SwiftUI

public struct AgentChatHeaderView: View {
    public enum Action: Equatable, Sendable {
        case keyPress(codepoint: UInt32, modifiers: UInt8, sequence: UInt32)
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
        HStack(spacing: Spacing.md) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Agent status: \(state.statusLabel)")

            modelPickerButton

            Text("·")
                .font(Typography.font(.small))
                .foregroundStyle(theme.agentDisabledFg)

            thinkingLevelMenu

            if state.isThinking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }

            Spacer()

            Text(state.statusLabel)
                .font(Typography.font(.small))
                .foregroundStyle(theme.agentMutedFg)

            Button {
                // Send '?' to toggle help overlay
                sendAction?(.keyPress(codepoint: 0x3F, modifiers: 0, sequence: 0))
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(state.helpVisible ? theme.agentHeaderFg : theme.agentMutedFg)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.sm).fill(isHelpHovered ? theme.agentTextFg.opacity(0.06) : Color.clear))
            }
            .buttonStyle(.plain)
            .help("Keyboard shortcuts (?)")
            .accessibilityLabel("Agent help")
            .accessibilityHint("Shows keybinding cheatsheet")
            .accessibilityAddTraits(.isButton)
            .onHover { hovering in
                isHelpHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(theme.agentHeaderBg)

        Rectangle()
            .fill(theme.agentCodeBorder.opacity(0.3))
            .frame(height: 1)
    }

    // MARK: - Model picker

    private var modelPickerButton: some View {
        Button {
            if !state.isThinking {
                sendAction?(.executeCommand(name: "agent_pick_model"))
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(state.displayModel.isEmpty ? "Agent" : state.displayModel)
                    .font(Typography.font(.body, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typography.font(.micro, weight: .semibold))
            }
            .foregroundStyle(state.isThinking ? theme.agentSecondaryFg : theme.agentHeaderFg)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(isModelHovered && !state.isThinking ? theme.agentTextFg.opacity(0.06) : Color.clear))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!state.isThinking)
        .help("Pick model (SPC a m)")
        .accessibilityLabel("Agent model")
        .accessibilityValue(state.displayModel.isEmpty ? "Agent" : state.displayModel)
        .accessibilityHint(state.isThinking ? "Disabled while the agent is streaming" : "Opens the model picker")
        .accessibilityAddTraits(.isButton)
        .onHover { isModelHovered = $0 }
        .modifier(HeaderControlPointingHandModifier(isEnabled: !state.isThinking))
    }

    // MARK: - Thinking level

    @ViewBuilder
    private var thinkingLevelMenu: some View {
        if state.isThinking {
            thinkingLevelLabel
                .help("Pick thinking level (SPC a T)")
                .accessibilityLabel("Agent thinking level")
                .accessibilityValue(state.thinkingLabel)
                .accessibilityHint("Disabled while the agent is streaming")
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
                thinkingLevelLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick thinking level (SPC a T)")
            .accessibilityLabel("Agent thinking level")
            .accessibilityValue(state.thinkingLabel)
            .accessibilityHint("Opens a menu of thinking levels")
            .accessibilityAddTraits(.isButton)
            .onHover { isThinkingHovered = $0 }
            .modifier(HeaderControlPointingHandModifier(isEnabled: true))
        }
    }

    private var thinkingLevelLabel: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: state.thinkingIconName)
                .font(Typography.font(.body))
            Text(state.thinkingLabel)
                .font(Typography.font(.body, weight: .medium))
            Image(systemName: "chevron.down")
                .font(Typography.font(.symbol, weight: .semibold))
        }
        .foregroundStyle(state.isThinking ? theme.agentSecondaryFg : theme.agentHeaderFg.opacity(0.9))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(isThinkingHovered && !state.isThinking ? theme.agentTextFg.opacity(0.06) : Color.clear))
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

    private var statusColor: Color {
        switch state.status {
        case .idle: return Color.gray
        case .thinking: return theme.agentHeaderFg
        case .executingTool: return Color.orange
        case .error: return Color.red
        case .planning: return theme.agentStatusNeedsYou
        case .unknown: return Color.gray
        }
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
