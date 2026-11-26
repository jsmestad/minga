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

    @Environment(\.themeColors) private var theme

    /// The state an empty state's glyph is the shape of (docs/design/themes.md, "States"), such as Done for a clean tree's solid dot, or nil for any other glyph.
    static func glyphState(_ glyph: String) -> SpineState? {
        SpineState.allCases.first { $0.tuiGlyph == glyph }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EmptyStateMetrics.titleToWhy) {
            HStack(alignment: .firstTextBaseline, spacing: EmptyStateMetrics.glyphToTitle) {
                if !empty.glyph.isEmpty {
                    // The glyph is a state shape, so it is drawn in that state's colour role; any other glyph takes the title colour.
                    Text(empty.glyph)
                        .font(Typography.font(.emphasis, weight: .semibold))
                        .foregroundStyle(Self.glyphState(empty.glyph).map(theme.stateColor) ?? textColor)
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
        // A narrow panel, such as a sidebar, wraps the copy instead of cutting it off; a wrapped title hangs under its first word.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What you can do: the action list of an empty panel. A fixed key column in the accent colour, then the label; the preselected row carries the list-row selection, and every row is a native button with a hover highlight.
struct EmptyListActions: View {
    let empty: Wire.EmptyList
    let textColor: Color
    let accentColor: Color
    let selectionColor: Color
    var selectedTextColor: Color? = nil
    let activate: (Wire.EmptyListAction) -> Void

    @State private var hoveredID: String?

    var body: some View {
        let keyColumn = Self.keyColumnWidth(empty.actions)
        VStack(spacing: 0) {
            ForEach(Array(empty.actions.enumerated()), id: \.offset) { index, action in
                let selected = index == Int(empty.selected)
                let selectedInk = selected ? selectedTextColor : nil
                Button {
                    activate(action)
                } label: {
                    HStack(spacing: 0) {
                        Text(action.key)
                            .font(Typography.monospacedSmall)
                            .foregroundStyle(selectedInk ?? accentColor)
                            .frame(width: keyColumn, alignment: .leading)
                            .anatomyPart("emptyState.actionKey", text: action.key, font: .small, monospaced: true)
                        Text(action.label)
                            .font(Typography.font(.body))
                            .foregroundStyle(selectedInk ?? textColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .anatomyPart("emptyState.actionLabel", text: action.label, font: .body)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, EmptyStateMetrics.inset)
                    .padding(.trailing, EmptyStateMetrics.trailingInset)
                    .frame(height: EmptyStateMetrics.actionPitch)
                    .background(rowBackground(selected: selected, hovered: hoveredID == action.id))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredID = $0 ? action.id : nil }
                .accessibilityLabel(Text("\(action.label), \(action.key)"))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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

/// The whole empty-state anatomy in a sidebar panel (the file tree's empty folder, Git status's clean tree): what happened and why, then the next steps as list rows, with one set of insets from `EmptyStateMetrics` so every sidebar draws it the same way.
struct EmptyListPanel: View {
    let empty: Wire.EmptyList
    let textColor: Color
    let accentColor: Color
    let selectionColor: Color
    var mutedColor: Color? = nil
    var selectedTextColor: Color? = nil
    let activate: (Wire.EmptyListAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EmptyStateMetrics.whyToActions) {
            EmptyListHeader(empty: empty, textColor: textColor, mutedColor: mutedColor ?? textColor.opacity(0.78))
                .padding(.leading, EmptyStateMetrics.inset)
                .padding(.trailing, EmptyStateMetrics.trailingInset)
            EmptyListActions(
                empty: empty, textColor: textColor, accentColor: accentColor, selectionColor: selectionColor,
                selectedTextColor: selectedTextColor, activate: activate
            )
            Spacer(minLength: 0)
        }
        .padding(.top, EmptyStateMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
