import SwiftUI
import MingaProtocol

/// One tool call in the conversation: the state's mark and the sentence the BEAM wrote ("Read native.ex", "Stopped while editing chrome_state.ex"), on one line with no card. Clicking the line shows or hides the call's output, and a retained output offers its reader below the line (docs/design/surfaces.md, Conversation and composer).
public struct AgentToolCallCard: View {
    public enum Action: Equatable, Sendable {
        case toggle(messageID: UInt32)
        case readRetainedOutput(messageID: UInt32, offer: Wire.RetainedOutputOffer)
    }

    public init(messageID: Int, name: String, summary: String, step: Wire.ToolStep, collapsed: Bool, autoApprovedScope: UInt8, result: String? = nil, resultLines: [[Wire.StyledTextRun]]? = nil, previewLines: [String], retainedOutputOffer: Wire.RetainedOutputOffer? = nil, sendAction: ViewActionHandler<Action>?) {
        self.messageID = messageID
        self.name = name
        self.summary = summary
        self.step = step
        self.collapsed = collapsed
        self.autoApprovedScope = autoApprovedScope
        self.result = result
        self.resultLines = resultLines
        self.previewLines = previewLines
        self.retainedOutputOffer = retainedOutputOffer
        self.sendAction = sendAction
    }
    public let messageID: Int
    public let name: String
    public let summary: String
    public let step: Wire.ToolStep
    public let collapsed: Bool
    public let autoApprovedScope: UInt8
    public let result: String?
    public let resultLines: [[Wire.StyledTextRun]]?
    public let previewLines: [String]
    public let retainedOutputOffer: Wire.RetainedOutputOffer?
    @Environment(\.themeColors) private var theme
    public let sendAction: ViewActionHandler<Action>?

    /// The state the BEAM drew the step in; an unknown byte draws as working rather than inventing a word.
    private var state: SpineState { SpineState(wire: step.state) ?? .working }

    /// The sentence, falling back to the tool's name and arguments for a BEAM that sent none.
    private var sentence: String {
        if !step.text.isEmpty { return step.text }
        return summary.isEmpty ? name : "\(name) \(summary)"
    }

    private var hasResult: Bool { result?.isEmpty == false || resultLines?.isEmpty == false }

    /// The mark is a shape, which takes all the room it is offered, so the step gives it the modeline mark's size.
    static let markSize: CGFloat = Typography.Step.micro.rawValue

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                StateMark(state: state)
                    .frame(width: Self.markSize, height: Self.markSize)

                Text(sentence)
                    .font(Typography.font(.body))
                    .foregroundStyle(theme.agentTextFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if hasResult && sendAction != nil {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(Typography.font(.micro, weight: .medium))
                        .foregroundStyle(theme.agentMutedFg)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(state.word): \(sentence)")
            .onTapGesture {
                if hasResult, let messageID = UInt32(exactly: messageID), messageID != 0 {
                    sendAction?(.toggle(messageID: messageID))
                }
            }

            if let offer = retainedOutputOffer, let sendAction, let id = UInt32(exactly: messageID), id != 0 {
                Button("Read retained output") { sendAction(.readRetainedOutput(messageID: id, offer: offer)) }
                    .buttonStyle(.borderless)
                    .font(Typography.font(.small, weight: .medium))
            }

            if !collapsed {
                expandedDetail
            }
        }
    }

    // MARK: - Expanded output

    @ViewBuilder
    private var expandedDetail: some View {
        let visiblePreviewLines = Array(previewLines.prefix(8))

        if !visiblePreviewLines.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                ForEach(Array(visiblePreviewLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Typography.font(.caption, design: .monospaced))
                        .foregroundStyle(previewLineColor(line))
                        .truncationMode(.tail)
                }
            }
            .padding(.leading, Spacing.xl)
        }

        if hasResult {
            ScrollView([.horizontal, .vertical]) {
                if let lines = resultLines, !lines.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, runs in
                            AgentStyledLine(runs: runs, baseFontSize: Typography.Step.small.rawValue, monospaced: true)
                        }
                    }
                } else if let text = result, !text.isEmpty {
                    Text(text)
                        .font(Typography.font(.small, design: .monospaced))
                        .foregroundStyle(theme.agentSecondaryFg)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxHeight: 200)
            .padding(.leading, Spacing.xl)
        }
    }

    // A diff preview keeps its add and remove roles; any other line is secondary text.
    private func previewLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") { return theme.roleColor(.done) }
        if line.hasPrefix("-") { return theme.roleColor(.failure) }
        return theme.agentSecondaryFg
    }
}
