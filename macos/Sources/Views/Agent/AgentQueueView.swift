import MingaProtocol
import SwiftUI

/// One scroll region for the queue, independent of the transcript and composer.
struct AgentQueueView: View {
    let queue: Wire.AgentQueue
    let maximumHeight: CGFloat
    let sendAction: ViewActionHandler<AgentQueueRequest>?

    @Environment(\.themeColors) private var theme
    @State private var contentHeight: CGFloat?

    private var accent: Color { theme.agentInputBorder }
    private var selection: Color { accent.opacity(0.18) }
    private var selectedID: UInt64? {
        queue.focused && maximumHeight > 0 ? queue.selectedRow?.id : nil
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                    header
                    if let empty = queue.empty {
                        EmptyListPanel(
                            empty: empty, textColor: theme.agentTextFg, accentColor: accent,
                            selectionColor: selection
                        ) { action in
                            if let request = queue.request(forEmptyAction: action) { sendAction?(request) }
                        }
                        .disabled(sendAction == nil)
                    }
                    ForEach(queue.pending) { row in
                        pendingRow(row)
                            .id(row.id)
                    }
                    if !queue.removedNote.isEmpty {
                        Text(queue.removedNote)
                            .font(Typography.font(.small))
                            .foregroundStyle(theme.agentMutedFg)
                            .fixedSize(horizontal: false, vertical: true)
                            .anatomyPart("queue.removedNote", text: queue.removedNote, font: .small)
                    }
                    ForEach(queue.removed) { row in
                        rowLabel(row, removed: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                contentHeight = height
            }
            .onChange(of: selectedID, initial: true) { _, id in
                if let id { scroll.scrollTo(id) }
            }
        }
        .frame(height: min(maximumHeight, contentHeight ?? maximumHeight))
        .background(theme.agentCodeBg)
        .clipShape(.rect(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(queue.focused ? accent.opacity(0.55) : theme.agentCodeBorder.opacity(0.35))
                .allowsHitTesting(false)
        }
        .padding(.horizontal, Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(queue.title))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.md) {
                    titleAndSummary
                    if !queue.hints.isEmpty {
                        Spacer(minLength: Spacing.md)
                        HStack(spacing: Spacing.md) { hints }
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    titleAndSummary
                    if !queue.hints.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Spacing.md) { hints }
                            VStack(alignment: .leading, spacing: Spacing.xs) { hints }
                        }
                    }
                }
            }
            Divider()
        }
    }

    private var titleAndSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text(queue.title)
                .font(Typography.font(.small, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.agentTextFg)
                .anatomyPart("queue.title", text: queue.title, font: .small, monospaced: true)
            Text(queue.summary)
                .font(Typography.font(.small, design: .monospaced))
                .foregroundStyle(theme.agentSecondaryFg)
                .anatomyPart("queue.summary", text: queue.summary, font: .small, monospaced: true)
        }
    }

    private var hints: some View {
        ForEach(queue.hints.indices, id: \.self) { index in
            let hint = queue.hints[index]
            let request = queue.request(for: hint.action)
            Button {
                if let request { sendAction?(request) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(hint.key)
                        .font(Typography.monospacedSmall)
                        .foregroundStyle(accent)
                        .anatomyPart("queue.hintKey", text: hint.key, font: .small, monospaced: true)
                    Text(hint.label)
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.agentSecondaryFg)
                        .anatomyPart("queue.hintLabel", text: hint.label, font: .small)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(request == nil || sendAction == nil)
            .accessibilityLabel(Text("\(hint.label), \(hint.key)"))
        }
    }

    private func pendingRow(_ row: Wire.AgentQueue.Row) -> some View {
        let selected = queue.focused && queue.selectedID == row.id
        let request = queue.select(row)
        return Button {
            sendAction?(request)
        } label: {
            rowLabel(row, removed: false)
                .background(selected ? selection : .clear, in: .rect(cornerRadius: Radius.sm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sendAction == nil)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func rowLabel(_ row: Wire.AgentQueue.Row, removed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(row.label)
                .font(Typography.monospacedSmall)
                .foregroundStyle(theme.agentMutedFg)
                .frame(minWidth: 18, alignment: .leading)
                .anatomyPart("queue.rowLabel", text: row.label, font: .small, monospaced: true)
            Text(row.preview)
                .font(Typography.font(.small, design: .monospaced))
                .foregroundStyle(removed ? theme.agentMutedFg : theme.agentTextFg)
                .lineLimit(1)
                .anatomyPart("queue.rowPreview", text: row.preview, font: .small, monospaced: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.attachmentCount > 0 {
                Label("\(row.attachmentCount)", systemImage: "paperclip")
                    .font(Typography.font(.caption, design: .monospaced))
                    .foregroundStyle(theme.agentSecondaryFg)
                    .fixedSize()
                    .accessibilityLabel("Attachments")
                    .accessibilityValue(Text(row.attachmentCount, format: .number))
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.hairline)
    }
}
