import AppKit
import CoreText
import MingaProtocol
import SwiftUI

/// The overlay and its separate resident child reader are published by the same frame.
@Observable
public final class SubagentPeekState {
    public private(set) var metadata: Wire.SubagentPeek = .empty
    private(set) var stepsByEntryID: [Int: Wire.SubagentPeek.Step] = [:]
    public let transcript = AgentChatState()
    public private(set) var selectedStep: String?
    @ObservationIgnored private var visibleSteps: Set<String> = []

    public init() {}

    public func publish(metadata next: Wire.SubagentPeek?, transcript source: AgentTranscriptSnapshot?) {
        if let next, next != metadata {
            if metadata.steps != next.steps || metadata.parentWindowID != next.parentWindowID {
                stepsByEntryID.removeAll(keepingCapacity: true)
                for step in next.steps { stepsByEntryID[Int(step.entryID)] = step }
                if !next.steps.contains(where: { $0.token == selectedStep }) { selectedStep = nil }
            }
            metadata = next
        }
        if let source { transcript.publishTranscript(source) }
    }

    func setVisible(_ token: String, _ visible: Bool) {
        if visible {
            visibleSteps.insert(token)
        } else {
            visibleSteps.remove(token)
        }
    }

    public var visibleSelectedStep: String? {
        guard let selectedStep, visibleSteps.contains(selectedStep) else { return nil }
        return selectedStep
    }

    public func selectNextVisibleStep() -> Bool {
        var first: String?
        var passedSelection = visibleSelectedStep == nil
        for step in metadata.steps where visibleSteps.contains(step.token) {
            if first == nil { first = step.token }
            if passedSelection {
                selectedStep = step.token
                return true
            }
            passedSelection = step.token == selectedStep
        }
        selectedStep = first
        return first != nil
    }
}

struct SubagentPeekView: View {
    let pane: Wire.SubagentPeek.Pane
    let transcript: AgentChatState
    let sendAction: ViewActionHandler<AgentChatView.Action>?
    @Environment(\.themeColors) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("\(pane.parent) › \(pane.title)")
                    .font(Typography.font(.emphasis, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button { send(.close) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close subagent peek")
            }
            if let state = SpineState(wire: pane.state) {
                HStack(spacing: Spacing.sm) {
                    StateMark(state: state).frame(width: 12, height: 12)
                    Text("\(state.word) · \(pane.elapsed)")
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.agentMutedFg)
                }
            }
            HStack(spacing: Spacing.sm) {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(pane.siblings) { sibling in
                            Button { send(.sibling, target: sibling.token) } label: {
                                StateMark(state: SpineState(wire: sibling.state) ?? .working)
                                    .frame(width: 12, height: 12)
                                    .padding(Spacing.xs)
                                    .background(RoundedRectangle(cornerRadius: Radius.sm).fill(theme.agentCodeBg.opacity(pane.token == sibling.token ? 1 : 0)))
                            }
                            .buttonStyle(.plain)
                            .help(sibling.title)
                            .accessibilityLabel(sibling.title)
                            .accessibilityAddTraits(pane.token == sibling.token ? .isSelected : [])
                        }
                    }
                }
                Text("\(pane.index) of \(pane.siblings.count)")
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.agentMutedFg)
                    .fixedSize()
            }
            Divider()
            Button { send(.brief) } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: pane.briefOpen ? "chevron.down" : "chevron.right")
                    Text("Brief").font(Typography.font(.body, weight: .semibold))
                    Text("za").font(Typography.monospacedSmall).foregroundStyle(theme.agentMutedFg)
                }
            }
            .buttonStyle(.plain)
            if pane.briefOpen { detail(pane.brief) }

            Button { send(.inspect) } label: {
                Text("So far").font(Typography.font(.body, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            AgentConversationList(state: transcript, sendAction: nil, followStreamingRevisions: true)
                .id(pane.token)
                .layoutPriority(1)

            if pane.hasResult {
                Divider()
                Text("Result").font(Typography.font(.body, weight: .semibold)).accessibilityAddTraits(.isHeader)
                detail(pane.result)
            }
            composer
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(theme.agentTextFg)
        .background(theme.agentPanelBg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-peek")
    }

    private func detail(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text).textSelection(.enabled)
                .font(Typography.font(.small))
                .foregroundStyle(theme.agentSecondaryFg)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
        .frame(minHeight: 44, maxHeight: 120)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !pane.notice.isEmpty {
                Text(pane.notice).font(Typography.font(.small)).foregroundStyle(theme.agentSecondaryFg)
            }
            Text("Message this subagent").font(Typography.font(.small, weight: .medium))
            if !pane.prompt.isEmpty || pane.editing {
                ScrollViewReader { scroll in
                    ScrollView([.vertical, .horizontal]) {
                        let lines = pane.prompt.split(separator: "\n", omittingEmptySubsequences: false)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(lines.indices, id: \.self) { row in
                                draftLine(lines[row], row: row)
                                    .id(row)
                            }
                        }
                        .padding(Spacing.sm)
                    }
                    .frame(minHeight: 20, maxHeight: 80)
                    .onChange(of: pane.cursorRow, initial: true) { _, row in
                        if pane.editing { scroll.scrollTo(Int(row)) }
                    }
                }
            } else {
                Button("Compose") { send(.compose) }
                    .buttonStyle(.borderless)
                    .help("Message this subagent (i)")
            }
            if pane.sending {
                Text("Sending…").font(Typography.font(.small))
            } else if pane.editing {
                Button("Send") { send(.submit) }
                    .buttonStyle(.borderless)
                    .disabled(pane.prompt.isEmpty)
                    .help("Send to this subagent (Return)")
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(theme.agentCodeBg))
    }

    private func draftLine(_ value: Substring, row: Int) -> some View {
        let text = String(value)
        let font = NSFont.monospacedSystemFont(ofSize: Typography.Step.body.rawValue, weight: .regular)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let layout = CTLineCreateWithAttributedString(attributed)
        let cursor = pane.editing && row == Int(pane.cursorRow)
        let caret = cursor ? CTLineGetOffsetForStringIndex(layout, Self.utf16Index(atByte: Int(pane.cursorColumn), in: text), nil) : 0
        return Text(verbatim: text.isEmpty ? " " : text)
            .font(Font(font))
            .fixedSize()
            .overlay(alignment: .leading) {
                if cursor {
                    Rectangle().fill(theme.agentTextFg).frame(width: 1).offset(x: caret).allowsHitTesting(false)
                }
            }
            .padding(.trailing, Spacing.hairline)
            .contentShape(Rectangle())
            .onTapGesture { point in
                let character = CTLineGetStringIndexForPosition(layout, point)
                let byte = Self.byteIndex(atUTF16: character == kCFNotFound ? text.utf16.count : character, in: text)
                send(.compose, row: UInt32(clamping: row), column: UInt32(clamping: byte))
            }
    }

    private func send(_ action: Wire.SubagentPeek.Action, target: String = "", row: UInt32 = 0, column: UInt32 = 0) {
        sendAction?(.subagentPeek(action, windowID: pane.windowID, displayed: pane.token, target: target, row: row, column: column))
    }

    private static func utf16Index(atByte byte: Int, in text: String) -> Int {
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: min(byte, text.utf8.count))
        return String.Index(index, within: text).map { $0.utf16Offset(in: text) } ?? 0
    }

    private static func byteIndex(atUTF16 offset: Int, in text: String) -> Int {
        var utf16 = 0
        var bytes = 0
        for character in text {
            let grapheme = String(character)
            utf16 += grapheme.utf16.count
            if utf16 > offset { break }
            bytes += grapheme.utf8.count
        }
        return bytes
    }
}
