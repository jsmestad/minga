import SwiftUI
import MingaProtocol

/// App composition injects a placement aperture, never a second text renderer.
public struct AgentPromptSurface: Sendable {
    public let makeAperture: @MainActor @Sendable (CGFloat) -> AnyView

    public init(makeAperture: @escaping @MainActor @Sendable (CGFloat) -> AnyView) {
        self.makeAperture = makeAperture
    }
}

private struct AgentPromptSurfaceKey: EnvironmentKey {
    static let defaultValue: AgentPromptSurface? = nil
}

extension EnvironmentValues {
    public var agentPromptSurface: AgentPromptSurface? {
        get { self[AgentPromptSurfaceKey.self] }
        set { self[AgentPromptSurfaceKey.self] = newValue }
    }
}

struct AgentPromptApertureKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    /// Absence is neutral; a fresh reduction still clears a removed producer.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

public struct AgentPromptView: View {
    public enum Action: Equatable, Sendable {
        case submit
        case queue(followUp: Bool, target: AgentQueueTarget)
        case abort(AgentStopTarget)
        case attachments
    }

    public init(state: AgentChatState, isInsertMode: Bool, sendAction: ViewActionHandler<Action>?, maximumHeight: CGFloat = 0) {
        self.state = state
        self.isInsertMode = isInsertMode
        self.sendAction = sendAction
        self.maximumHeight = maximumHeight
    }
    public let state: AgentChatState
    @Environment(\.themeColors) private var theme

    public let isInsertMode: Bool
    public let sendAction: ViewActionHandler<Action>?
    public let maximumHeight: CGFloat
    @Environment(\.agentPromptSurface) private var surface
    @State private var measuredHeight: CGFloat = 0

    private var textHeight: CGFloat {
        CGFloat(max(1, Int(state.promptVisibleRows))) * state.promptRowPitch
    }

    /// Capsule border color: accent when in insert mode, subtle border otherwise.
    private var capsuleBorderColor: Color {
        if isInsertMode { return theme.agentInputBorder.opacity(0.5) }
        return theme.agentCodeBorder.opacity(0.3)
    }

    /// Capsule background opacity shifts with mode.
    private var capsuleBgOpacity: Double {
        if isInsertMode { return 0.8 }
        if state.status.hasActiveTurn { return 0.6 }
        return 0.4
    }

    /// Vim mode label shown in the prompt border.
    private var modeLabel: String { state.promptMode.displayName }

    public var body: some View {
        VStack(spacing: 0) {
            // Prompt completion popup (floats above the prompt area)
            if let completion = state.promptCompletion {
                promptCompletionPopup(completion)
            }

            // Prompt area
            promptArea
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
    }

    // MARK: - Prompt area

    @ViewBuilder
    private var promptArea: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            promptCapsule
            HStack(spacing: Spacing.md) {
                AgentPromptActionButtons(state: state, sendAction: sendAction)
                Spacer(minLength: 0)
                Button {
                    sendAction?(.attachments)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "paperclip")
                        if state.draftAttachmentCount > 0 {
                            Text(state.draftAttachmentCount, format: .number)
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .frame(minWidth: 24, minHeight: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.agentInputBorder)
                .help("Draft attachments")
                .accessibilityLabel("Draft attachments")
                .accessibilityValue("\(state.draftAttachmentCount)")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent prompt")
    }

    @ViewBuilder
    private var promptCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode changes must not move text between clicks in one selection gesture.
            HStack(spacing: Spacing.xs) {
                Text(modeLabel)
                    .font(Typography.font(.micro, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.agentInputBorder)
                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.hairline)

            if let surface {
                surface.makeAperture(max(0, maximumHeight - measuredHeight + textHeight))
                    .frame(height: textHeight)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: AgentPromptApertureKey.self,
                                value: geometry.frame(in: .named("agentChat"))
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
            }
        }
        .backgroundPreferenceValue(AgentPromptApertureKey.self) { aperture in
            GeometryReader { geometry in
                let origin = geometry.frame(in: .named("agentChat")).origin
                Path { path in
                    path.addRoundedRect(
                        in: CGRect(origin: .zero, size: geometry.size),
                        cornerSize: CGSize(width: Radius.xl, height: Radius.xl)
                    )
                    if !aperture.isEmpty {
                        path.addRect(aperture.offsetBy(dx: -origin.x, dy: -origin.y))
                    }
                }
                .fill(theme.agentInputBg.opacity(capsuleBgOpacity), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl)
                .strokeBorder(capsuleBorderColor, lineWidth: 1)
        )
    }


    // MARK: - Prompt completion popup

    @ViewBuilder
    private func promptCompletionPopup(_ completion: Wire.PromptCompletion) -> some View {
        let isSlash = completion.type == 1

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completion.candidates.enumerated()), id: \.offset) { index, candidate in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isSlash ? "command" : "doc")
                        .font(Typography.font(.caption))
                        .foregroundStyle(theme.agentTextFg.opacity(0.4))
                        .frame(width: 14)

                    Text(candidate.name)
                        .font(Typography.font(.body, design: .monospaced))
                        .foregroundStyle(theme.agentTextFg)
                        .lineLimit(1)

                    if !candidate.description.isEmpty {
                        Text(candidate.description)
                            .font(Typography.font(.small))
                            .foregroundStyle(theme.agentTextFg.opacity(0.4))
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(index == Int(completion.selected) ? theme.agentInputBorder.opacity(0.15) : Color.clear)
            }
        }
        .frame(maxWidth: 400)
        .frame(maxHeight: CGFloat(completion.candidates.count) * 24)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(theme.agentCodeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(theme.agentCodeBorder.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: -4)
        .padding(.horizontal, Spacing.xl)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSlash ? "Slash command completion" : "File mention completion")
    }
}

/// The same controls occupy the same positions as a turn starts and settles.
struct AgentPromptActionButtons: View {
    let state: AgentChatState
    let sendAction: ViewActionHandler<AgentPromptView.Action>?
    @Environment(\.themeColors) private var theme

    var body: some View {
        let active = state.status.hasActiveTurn
        let hasDraft = state.promptPresentation != 0 && !state.prompt.isEmpty
        let queue = active && hasDraft ? state.queueTarget : nil
        let stop = active ? state.stopTarget : nil

        HStack(spacing: Spacing.md) {
            button("Send", icon: "arrow.up.circle.fill", action: hasDraft && !active ? .submit : nil)
            button("Steer", icon: "arrow.turn.up.right", action: queue.map { .queue(followUp: false, target: $0) })
            button("Queue Next", icon: "text.badge.plus", action: queue.map { .queue(followUp: true, target: $0) })
            button("Stop", icon: "stop.circle.fill", action: stop.map(AgentPromptView.Action.abort))
        }
    }

    private func button(_ label: String, icon: String, action: AgentPromptView.Action?) -> some View {
        Button {
            if let action { sendAction?(action) }
        } label: {
            Label(label, systemImage: icon)
                .font(Typography.font(.small))
                .foregroundStyle(action == nil ? theme.agentTextFg.opacity(0.4) : theme.agentInputBorder)
                .frame(minHeight: 24)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel(label)
        .help(label)
    }
}

