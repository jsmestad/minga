import SwiftUI
import MingaProtocol

/// A single Help presentation over the persistent editor body, never a composer owner.
public struct AgentHelpView: View {
    public enum Action: Equatable, Sendable {
        case dismiss
    }

    public let state: AgentHelpState
    public let sendAction: ViewActionHandler<Action>?
    @Environment(\.themeColors) private var theme

    public init(state: AgentHelpState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Text("Keyboard Shortcuts")
                    .font(Typography.font(.title, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button { sendAction?(.dismiss) } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sendAction == nil)
                .focusable(false)
                .accessibilityLabel("Close Help")
                .help("Close Help")
                .fixedSize()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    ForEach(state.groups.indices, id: \.self) { index in
                        helpGroup(state.groups[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .background(AgentHelpScrollProbe(attachment: state.scrollAttachment))
            }
        }
        .foregroundStyle(theme.agentTextFg)
        .background(theme.agentPanelBg.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(theme.agentCodeBorder.opacity(0.3), lineWidth: 1)
        }
        .padding(Spacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent help")
    }

    private func helpGroup(_ group: Wire.HelpGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(group.title)
                .font(Typography.font(.body, weight: .semibold))
                .foregroundStyle(theme.agentHeaderFg)
            ForEach(group.bindings.indices, id: \.self) { index in
                let binding = group.bindings[index]
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.md) {
                        Text(binding.key)
                            .font(Typography.font(.body, weight: .medium, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
                        Text(binding.description)
                            .font(Typography.font(.body))
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(binding.key)
                            .font(Typography.font(.body, weight: .medium, design: .monospaced))
                        Text(binding.description)
                            .font(Typography.font(.body))
                    }
                }
            }
        }
    }
}

#Preview("Independent Help", traits: .mingaChrome) {
    let state = AgentHelpState()
    state.update(visible: true, groups: [
        .init(title: "Review", bindings: [(key: "Tab", description: "Back to chat"), (key: "?", description: "Agent help")])
    ])
    return AgentHelpView(state: state, sendAction: { _ in })
        .frame(width: 320, height: 240)
}
