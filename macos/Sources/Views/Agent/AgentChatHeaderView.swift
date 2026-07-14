import SwiftUI

public struct AgentChatHeaderView: View {
    public init(state: AgentChatState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    public let state: AgentChatState
    public let encoder: InputEncoder?
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    @State private var isModelHovered: Bool = false
    @State private var isThinkingHovered: Bool = false
    @State private var isHelpHovered: Bool = false

    public var body: some View {
        let _ = frameVersion
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Agent status: \(state.statusLabel)")

            modelPickerButton

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(theme.agentDisabledFg)

            thinkingLevelMenu

            if state.isThinking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }

            Spacer()

            Text(state.statusLabel)
                .font(.system(size: 11))
                .foregroundStyle(theme.agentMutedFg)

            Button {
                // Send '?' to toggle help overlay
                encoder?.sendKeyPress(codepoint: 0x3F, modifiers: 0)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(state.helpVisible ? theme.agentHeaderFg : theme.agentMutedFg)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isHelpHovered ? theme.agentTextFg.opacity(0.06) : Color.clear))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.agentHeaderBg)

        Rectangle()
            .fill(theme.agentCodeBorder.opacity(0.3))
            .frame(height: 1)
    }

    // MARK: - Model picker

    private var modelPickerButton: some View {
        Button {
            if !state.isThinking {
                encoder?.sendExecuteCommand(name: "agent_pick_model")
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.displayModel.isEmpty ? "Agent" : state.displayModel)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(state.isThinking ? theme.agentSecondaryFg : theme.agentHeaderFg)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(isModelHovered && !state.isThinking ? theme.agentTextFg.opacity(0.06) : Color.clear))
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
                        encoder?.sendExecuteCommand(name: "agent_thinking_\(level)")
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
        HStack(spacing: 4) {
            Image(systemName: state.thinkingIconName)
                .font(.system(size: 12))
            Text(state.thinkingLabel)
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(state.isThinking ? theme.agentSecondaryFg : theme.agentHeaderFg.opacity(0.9))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(isThinkingHovered && !state.isThinking ? theme.agentTextFg.opacity(0.06) : Color.clear))
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
        case 0: return Color.gray
        case 1: return theme.agentHeaderFg
        case 2: return Color.orange
        case 3: return Color.red
        default: return Color.gray
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
