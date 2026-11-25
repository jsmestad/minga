/// The which-key panel (docs/design/surfaces.md, docs/design/anatomy.md "Which-key panel").
///
/// One panel anchored above the modeline: the breadcrumb and the panel's own keys in a 24 pt header row, then one
/// column per section the BEAM sends, each with its name dim above it and as wide as its longest entry. Rows sit on the
/// 24 pt row pitch; keys sit in a fixed key column (the column's widest key plus `md`) in the accent colour, and group
/// names, plain counts and ⌘ keys in the text_muted role. A needs-you or error count draws in that state's role, as the
/// modeline does. Fades in within 120 ms, and not at all under Reduce Motion.
///
/// Every row and every breadcrumb crumb is a button (docs/design/surfaces.md, Mouse): a row presses its key, a crumb
/// goes back up to it. Each click names the panel's path, so the BEAM ignores one aimed at a panel that has moved on.

import SwiftUI
import MingaProtocol

public struct WhichKeyOverlay: View {
    public enum Action: Equatable, Sendable {
        case press(path: String, codepoint: UInt32, modifiers: UInt8)
        case back(path: String)
    }

    public init(state: WhichKeyState, sendAction: ViewActionHandler<Action>? = nil) {
        self.state = state
        self.sendAction = sendAction
    }
    public let state: WhichKeyState
    public let sendAction: ViewActionHandler<Action>?
    @Environment(\.themeColors) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// anatomy.md row pitch: every clickable row is 24 pt.
    static let rowPitch: CGFloat = 24
    /// A section taller than this splits into further columns, so the panel stays well inside the window.
    static let maxRowsPerColumn = 12
    /// The fade-in budget from surfaces.md.
    public static let fadeDuration: Double = 0.12

    /// The panel's fade-in: within 120 ms, and none under Reduce Motion (AC 5).
    public static func fadeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: fadeDuration)
    }

    public var body: some View {
        if state.visible && !state.entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                columns
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(theme.popupBg)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: -4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .anatomyPart("whichKey.panel")
            .transition(.opacity.animation(Self.fadeAnimation(reduceMotion: reduceMotion)))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            breadcrumb
            Spacer(minLength: Spacing.xl)
            // Hint to next hint is xl, as in drawer hints and the TUI's two columns (anatomy rule 6).
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xl) {
                ForEach(Array(state.hints.enumerated()), id: \.offset) { _, hint in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        hintKey(hint.key)
                        Text(hint.label)
                            .font(Typography.font(.caption))
                            .foregroundStyle(theme.roleColor(.textMuted))
                    }
                    .anatomyPart("whichKey.hint", text: "\(hint.key) \(hint.label)", font: .caption)
                }
            }
        }
        .frame(height: Self.rowPitch)
    }

    /// The colour role a count's tone names: the needs-you and failure state roles, as the modeline draws the same facts, or the secondary colour for a plain count.
    private func countColor(_ tone: Wire.WhichKeyCountTone) -> Color {
        switch tone {
        case .needsYou: theme.roleColor(.needsYou)
        case .error: theme.roleColor(.failure)
        case .muted: theme.roleColor(.textMuted)
        }
    }

    /// A hint's key. Backspace draws as the SF Symbol, because ⌫ in the monospaced face reads as a close control.
    @ViewBuilder
    private func hintKey(_ key: String) -> some View {
        if key == "⌫" {
            Image(systemName: "delete.left")
                .font(Typography.font(.caption))
                .foregroundStyle(theme.accent)
                .accessibilityLabel("Backspace")
        } else {
            Text(key)
                .font(Typography.monospacedSmall)
                .foregroundStyle(theme.accent)
        }
    }

    private var breadcrumbText: String {
        state.breadcrumb.map { $0.label.isEmpty ? $0.key : "\($0.key) \($0.label)" }.joined(separator: " › ")
    }

    private var breadcrumb: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            ForEach(Array(state.breadcrumb.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Text("›")
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.roleColor(.textMuted))
                }
                crumbButton(crumb)
            }
            if !state.count.isEmpty {
                Text(state.count)
                    .font(Typography.font(.caption))
                    .foregroundStyle(countColor(state.countTone))
            }
        }
        .lineLimit(1)
        .anatomyPart("whichKey.breadcrumb", text: breadcrumbText, font: .small)
    }

    /// A crumb above the open group goes back up to it; the open group's own crumb is plain text.
    @ViewBuilder
    private func crumbButton(_ crumb: Wire.WhichKeyCrumb) -> some View {
        let words = HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(crumb.key)
                .font(Typography.monospacedSmall)
                .foregroundStyle(theme.accent)
            if !crumb.label.isEmpty {
                Text(crumb.label)
                    .font(Typography.font(.small, weight: .semibold))
                    .foregroundStyle(theme.popupFg)
            }
        }
        if crumb.path == state.path {
            words
        } else {
            Button(action: { sendAction?(.back(path: crumb.path)) }) { words }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Back to \(crumb.path)")
                .accessibilityLabel("Back to \(crumb.label.isEmpty ? crumb.key : crumb.label)")
        }
    }

    // MARK: - Columns

    private var columns: some View {
        HStack(alignment: .top, spacing: Spacing.panel) {
            ForEach(WhichKeyLayout.columns(state.sections, maxRows: Self.maxRowsPerColumn)) { column in
                columnView(column)
            }
        }
    }

    private func columnView(_ column: WhichKeyLayout.Column) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if column.hasHeading {
                Text(column.title)
                    .font(Typography.font(.caption))
                    .foregroundStyle(theme.roleColor(.textMuted))
                    .lineLimit(1)
                    .anatomyPart("whichKey.groupName", text: column.title, font: .caption)
                    .padding(.bottom, Spacing.xs)
            }
            ForEach(Array(column.entries.enumerated()), id: \.offset) { _, entry in
                entryRow(entry, keyWidth: column.keyWidth)
            }
        }
        // A row fills its column so the whole row is the click target; the column itself stays as wide as its
        // longest entry, so the columns pack from the leading edge instead of sharing out the panel's width.
        .fixedSize(horizontal: true, vertical: false)
        .anatomyPart("whichKey.column")
    }

    private func entryRow(_ entry: Wire.WhichKeyEntry, keyWidth: CGFloat) -> some View {
        WhichKeyRowButton(action: {
            sendAction?(.press(path: state.path, codepoint: entry.codepoint, modifiers: entry.modifiers))
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(entry.key)
                    .font(Typography.monospacedSmall)
                    .foregroundStyle(theme.accent)
                    .anatomyPart("whichKey.entryKey", text: entry.key, font: .small, monospaced: true)
                    .frame(width: keyWidth, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    // Group rows arrive from the BEAM as Title Case labels with a trailing chevron ("Session ›") and
                    // draw in the group colour role (docs/design/keys.md); commands are plain text.
                    Text(entry.label)
                        .font(Typography.font(.body))
                        .foregroundStyle(entry.isGroup ? theme.roleColor(.group) : theme.popupFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .anatomyPart("whichKey.entryLabel", text: entry.label, font: .body)
                    if !entry.count.isEmpty {
                        Text(entry.count)
                            .font(Typography.font(.caption))
                            .foregroundStyle(countColor(entry.countTone))
                            .lineLimit(1)
                            .anatomyPart("whichKey.entryCount", text: entry.count, font: .caption)
                    }
                    if !entry.platformKey.isEmpty {
                        Text(entry.platformKey)
                            .font(Typography.monospacedSmall)
                            .foregroundStyle(theme.roleColor(.textMuted))
                            .anatomyPart("whichKey.platformKey", text: entry.platformKey, font: .small, monospaced: true)
                    }
                }
            }
        }
        // Key, label, count and ⌘ key share one baseline (anatomy rule 3), not one vertical centre.
        .frame(height: Self.rowPitch)
        .help(entry.isGroup ? "Open \(entry.label)" : "\(entry.label) · \(state.path) \(entry.key)")
        .accessibilityLabel(entry.label)
        .accessibilityHint("Press \(entry.key)")
        .anatomyPart("whichKey.entry", text: "\(entry.key) \(entry.label)")
    }
}

/// A which-key row as a plain button: the whole row is the target, and a hover tints it so the row a click will
/// press is the one under the pointer.
private struct WhichKeyRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.themeColors) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(hovered ? theme.popupSelBg : Color.clear)
                .padding(.horizontal, -Spacing.xs)
        )
        .onHover { hovered = $0 }
        .pointingHandCursor()
    }
}

/// Column layout for the which-key panel: each section becomes one column, split top to bottom into more columns
/// when it is taller than the row budget. Each column's key slot is its widest key plus `md`, so every label in the
/// column starts at the same edge (anatomy.md rule 2).
public enum WhichKeyLayout {
    public struct Column: Identifiable, Equatable {
        public let id: Int
        public let title: String
        public let hasHeading: Bool
        public let entries: [Wire.WhichKeyEntry]
        public let keyWidth: CGFloat
    }

    public static func columns(_ sections: [WhichKeySection], maxRows: Int) -> [Column] {
        let titled = sections.contains { !$0.title.isEmpty }
        var columns: [Column] = []
        for section in sections {
            let rows = max(maxRows, 1)
            var start = 0
            while start < section.entries.count {
                let chunk = Array(section.entries[start..<min(start + rows, section.entries.count)])
                let keyWidth = chunk.map { ModelineMetrics.textWidth($0.key, weight: .medium, monospaced: true) }.max() ?? 0
                columns.append(Column(
                    id: columns.count,
                    title: start == 0 ? section.title : "",
                    hasHeading: titled,
                    entries: chunk,
                    keyWidth: keyWidth + Spacing.md
                ))
                start += rows
            }
        }
        return columns
    }
}

#Preview("Which Key") {
    let theme = PreviewFixtures.theme()
    let entries: [Wire.WhichKeyEntry] = [
        .init(kind: 0, key: "a", label: "Agent view", section: "Tasks", count: "· 2"),
        .init(kind: 0, key: "n", label: "New session", section: "Tasks"),
        .init(kind: 0, key: "s", label: "Stop", section: "Tasks"),
        .init(kind: 0, key: "v", label: "Conversation split", section: "Conversation"),
        .init(kind: 1, key: "q", label: "Queue ›", section: "Conversation"),
        .init(kind: 0, key: "r", label: "Pending reviews", section: "Changes", count: "· 3"),
        .init(kind: 1, key: "S", label: "Session ›", section: "More"),
    ]
    let model = Wire.WhichKey(
        visible: true, path: "SPC a",
        breadcrumb: [.init(key: "SPC", path: "SPC"), .init(key: "a", label: "Minga", path: "SPC a")],
        count: "· 2",
        hints: [.init(key: "⌫", label: "back"), .init(key: "esc", label: "close")],
        entries: entries)
    return WhichKeyOverlay(state: WhichKeyState(model: model))
        .frame(width: 900, height: 320)
        .background(theme.editorBg)
        .environment(theme)
}
