/// The project home, `*home*` (#4056), shown in the editor window when it rests on the home.
///
/// Swapped in over the Metal editor surface (like `AgentChatView`) when `EmptyStateState.visible`.
/// A quiet, left-aligned resting view: the header says where you are (name, path, git line, an
/// optional note), then recent files or recent projects with their number keys, Minga's tasks with
/// their state marks, and the next actions with their keys in a fixed column. Keyboard still flows
/// to the BEAM; this view is display and mouse only. Activation (click) is BEAM-authoritative.

import SwiftUI
import MingaProtocol

public struct EmptyStateView: View {
    public enum Action: Equatable, Sendable {
        case activate(id: String)
    }

    public init(state: EmptyStateState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }

    public let state: EmptyStateState
    @Environment(\.themeColors) private var theme
    public let sendAction: ViewActionHandler<Action>?

    /// Row currently hovered by the mouse (for hover fills).
    @State private var hoverId: String?

    private let nerdFont = "Symbols Nerd Font Mono"

    /// Width of the key column: wide enough for "SPC SPC" in the monospaced key font.
    private let keyColumnWidth: CGFloat = 64
    private let numberColumnWidth: CGFloat = 12

    /// Rows never stretch past a readable measure on a wide window.
    private let maxContentWidth: CGFloat = 640

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header
                ForEach(state.sections) { section in
                    sectionView(section)
                }
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(theme.editorBg)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(state.title)
                .font(Typography.font(.heading, weight: .semibold))
                .foregroundStyle(theme.editorFg)
            ForEach([state.path, state.status, state.note].filter { !$0.isEmpty }, id: \.self) { line in
                Text(line)
                    .font(Typography.font(.body))
                    .foregroundStyle(theme.chromeMutedFg)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Sections

    private func sectionView(_ section: EmptyStateSectionModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            Text(section.title)
                .font(Typography.font(.emphasis, weight: .semibold))
                .foregroundStyle(theme.chromeMutedFg)
                .padding(.bottom, Spacing.xs)
            if section.items.isEmpty, !section.empty.isEmpty {
                Text(section.empty)
                    .font(Typography.font(.body))
                    .foregroundStyle(theme.chromeMutedFg)
            }
            ForEach(section.items) { item in
                row(item, keyWidth: keyColumnWidth(for: section))
            }
        }
    }

    // MARK: - Rows

    /// One row: the key column (number key, chord, or a task's state mark), the label, then muted
    /// detail and meta. The focused row carries the selection fill.
    private func row(_ item: EmptyStateItemModel, keyWidth: CGFloat) -> some View {
        rowButton(item) {
            HStack(spacing: Spacing.lg) {
                keyColumn(item)
                    .frame(width: keyWidth, alignment: .leading)
                if item.kindEnum == .recentFile, !item.icon.isEmpty {
                    Text(item.icon)
                        .font(.custom(nerdFont, size: Typography.Step.emphasis.rawValue))
                        .foregroundStyle(item.iconColor ?? theme.chromeMutedFg)
                        .frame(width: 18, alignment: .center)
                }
                Text(item.label)
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(theme.editorFg)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(Typography.font(.body))
                        .foregroundStyle(detailColor(item))
                        .lineLimit(1)
                }
                if !item.meta.isEmpty {
                    Text(item.meta)
                        .font(Typography.font(.body))
                        .foregroundStyle(theme.chromeMutedFg)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The key column is as wide as the section's widest key (anatomy, "Empty state"): a number key column is
    /// narrow, a chord column fits the longest chord.
    private func keyColumnWidth(for section: EmptyStateSectionModel) -> CGFloat {
        let widest = section.items.map(\.keyText.count).max() ?? 0
        return widest <= 1 ? numberColumnWidth : keyColumnWidth
    }

    @ViewBuilder
    private func keyColumn(_ item: EmptyStateItemModel) -> some View {
        if item.kindEnum == .task {
            StateMark(state: SpineState(rawValue: item.state) ?? .waiting)
                .frame(width: 10, height: 10)
        } else {
            Text(item.keyText)
                .font(Typography.monospacedSmall)
                .foregroundStyle(theme.accent)
        }
    }

    private func detailColor(_ item: EmptyStateItemModel) -> Color {
        if item.kindEnum == .task, let state = SpineState(rawValue: item.state) {
            return theme.stateColor(state)
        }
        return theme.chromeMutedFg
    }

    /// Wraps a row in the selection and hover fills and click activation.
    @ViewBuilder
    private func rowButton<Content: View>(_ item: EmptyStateItemModel, @ViewBuilder content: () -> Content) -> some View {
        let focused = state.isFocused(item.itemId)
        let hovered = hoverId == item.itemId
        content()
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(rowFill(focused: focused, hovered: hovered))
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoverId = item.itemId
                } else if hoverId == item.itemId {
                    hoverId = nil
                }
            }
            .pointingHandCursor(isEnabled: true)
            .onTapGesture {
                sendAction?(.activate(id: item.itemId))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }

    private func rowFill(focused: Bool, hovered: Bool) -> Color {
        if focused { return theme.selectionBg }
        if hovered { return theme.editorFg.opacity(0.06) }
        return Color.clear
    }
}
