import AppKit
import SwiftUI
import MingaProtocol

/// What happened and why, the first two parts of the empty-state anatomy (docs/design/anatomy.md, "Empty state").
///
/// The BEAM writes every word; this view only lays them out, left-aligned on the panel's leading edge.
struct EmptyListHeader: View {
    let empty: Wire.EmptyList
    let textColor: Color
    let mutedColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: EmptyStateMetrics.titleToWhy) {
            HStack(spacing: EmptyStateMetrics.glyphToTitle) {
                if !empty.glyph.isEmpty {
                    Text(empty.glyph)
                        .font(Typography.font(.emphasis, weight: .semibold))
                        .foregroundStyle(textColor)
                }
                Text(empty.title)
                    .font(Typography.font(.emphasis, weight: .semibold))
                    .foregroundStyle(textColor)
                    .anatomyPart("emptyState.title", text: empty.title, font: .emphasis)
            }
            if !empty.why.isEmpty {
                Text(empty.why)
                    .font(Typography.font(.body))
                    .foregroundStyle(mutedColor)
                    .anatomyPart("emptyState.why", text: empty.why, font: .body)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What you can do: the action list of an empty panel. A fixed key column in the accent colour, then the label;
/// the preselected row carries the list-row selection, and every row is a native button with a hover highlight.
struct EmptyListActions: View {
    let empty: Wire.EmptyList
    let textColor: Color
    let accentColor: Color
    let selectionColor: Color
    let activate: (Wire.EmptyListAction) -> Void

    @State private var hoveredID: String?

    var body: some View {
        let keyColumn = Self.keyColumnWidth(empty.actions)
        VStack(spacing: 0) {
            ForEach(Array(empty.actions.enumerated()), id: \.offset) { index, action in
                Button {
                    activate(action)
                } label: {
                    HStack(spacing: 0) {
                        Text(action.key)
                            .font(Typography.monospacedSmall)
                            .foregroundStyle(accentColor)
                            .frame(width: keyColumn, alignment: .leading)
                            .anatomyPart("emptyState.actionKey", text: action.key, font: .small, monospaced: true)
                        Text(action.label)
                            .font(Typography.font(.body))
                            .foregroundStyle(textColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .anatomyPart("emptyState.actionLabel", text: action.label, font: .body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, EmptyStateMetrics.inset)
                    .frame(height: EmptyStateMetrics.actionPitch)
                    .background(rowBackground(selected: index == Int(empty.selected), hovered: hoveredID == action.id))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredID = $0 ? action.id : nil }
                .accessibilityLabel(Text("\(action.label), \(action.key)"))
                .accessibilityAddTraits(index == Int(empty.selected) ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func rowBackground(selected: Bool, hovered: Bool) -> Color {
        if selected { return selectionColor }
        if hovered { return selectionColor.opacity(0.5) }
        return .clear
    }

    /// The widest key, measured in the key font, plus the gap before the labels.
    static func keyColumnWidth(_ actions: [Wire.EmptyListAction]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Typography.Step.small.rawValue, weight: .medium)
        let widest = actions.map { ($0.key as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + EmptyStateMetrics.keyColumnGap
    }
}
