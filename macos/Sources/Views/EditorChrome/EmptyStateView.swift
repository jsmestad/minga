/// Native launchpad view, shown when zero buffers are open.
///
/// Swapped in over the Metal editor surface (like `AgentChatView`) when
/// `EmptyStateState.visible`. Renders a centered ~480pt column over a large,
/// low-opacity MingaLogo watermark: a titled-border hero card (session resume
/// or get-started), small-caps section rules with recent files and action
/// rows, and a dim footer. Keyboard still flows to the BEAM; this view is
/// display + mouse only. Activation (click) is BEAM-authoritative.

import SwiftUI
import MingaProtocol

public struct EmptyStateView: View {
    public init(state: EmptyStateState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }

    public let state: EmptyStateState
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let encoder: InputEncoder?

    /// Fixed column width for the launchpad content (GUI sibling of the TUI's ~56 columns).
    private let columnWidth: CGFloat = 480

    /// Row currently hovered by the mouse (for hover fills).
    @State private var hoverId: String?
    /// Drives the ~120ms fade-in on appear.
    @State private var appeared = false

    private let nerdFont = "Symbols Nerd Font Mono"

    public var body: some View {
        let _ = frameVersion
        ZStack {
            // Solid backdrop so the hidden Metal surface never shows through.
            theme.editorBg

            watermark

            VStack(alignment: .leading, spacing: Spacing.xl) {
                ForEach(state.sections) { section in
                    sectionView(section)
                }
            }
            .frame(width: columnWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.12)) { appeared = true }
            }
        }
    }

    // MARK: - Watermark

    private var watermark: some View {
        Image("MingaLogo")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(theme.editorFg)
            .frame(width: 540)
            .opacity(0.09)
            .allowsHitTesting(false)
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: EmptyStateSectionModel) -> some View {
        switch section.kindEnum {
        case .session:
            cardSection(section)
        case .recent:
            rowsSection(section) { recentRow($0) }
        case .start:
            rowsSection(section) { actionRow($0) }
        case .footer:
            footerView(section)
        case .none:
            rowsSection(section) { actionRow($0) }
        }
    }

    /// A small-caps section label with a trailing hairline rule (RECENT / START).
    private func ruleLabel(_ title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(theme.chromeMutedFg)
            Rectangle()
                .fill(theme.popupBorder.opacity(0.09))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func rowsSection<Row: View>(_ section: EmptyStateSectionModel, @ViewBuilder row: @escaping (EmptyStateItemModel) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ruleLabel(section.title)
                .padding(.bottom, Spacing.xs)
            ForEach(section.items) { item in
                row(item)
            }
        }
    }

    // MARK: - Hero card (session resume / get-started)

    private func cardSection(_ section: EmptyStateSectionModel) -> some View {
        let focused = section.items.contains { state.isFocused($0.itemId) }
        // Only one accent border exists at a time: the card brightens to accent
        // solely while a row inside it is focused. Crash tints border + title warning.
        let borderColor = state.crashed
            ? theme.gutterWarningFg
            : (focused ? theme.accent : theme.popupBorder)
        let titleColor = state.crashed
            ? theme.gutterWarningFg
            : (focused ? theme.accent : theme.chromeMutedFg)

        return VStack(spacing: 2) {
            ForEach(section.items) { item in
                cardRow(item)
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.sm)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            // Title embedded in the top border edge (VSCode titled-border style).
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(titleColor)
                .padding(.horizontal, 5)
                .background(theme.editorBg)
                .offset(x: 14, y: -7)
        }
        .padding(.top, 7)
    }

    private func cardRow(_ item: EmptyStateItemModel) -> some View {
        // Cards default to Enter activation; show the jump key if one exists,
        // else a return glyph indicating Enter activates the focused card.
        let leadingChip = item.jumpKey.isEmpty ? "\u{21B5}" : item.jumpKey
        return rowButton(item) {
            HStack(spacing: Spacing.md) {
                keycap(leadingChip)
                Text(item.label)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.editorFg)
                Spacer(minLength: Spacing.md)
                detailVisual(item)
            }
        }
    }

    // MARK: - Recent rows

    private func recentRow(_ item: EmptyStateItemModel) -> some View {
        rowButton(item) {
            HStack(spacing: Spacing.md) {
                if item.jumpKey.isEmpty {
                    Color.clear.frame(width: keycapWidth, height: 1)
                } else {
                    keycap(item.jumpKey)
                }
                devicon(item)
                Text(item.label)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.editorFg)
                    .lineLimit(1)
                Spacer(minLength: Spacing.md)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.chromeMutedFg)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Action rows

    private func actionRow(_ item: EmptyStateItemModel) -> some View {
        rowButton(item) {
            HStack(spacing: Spacing.md) {
                devicon(item)
                Text(item.label)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.editorFg)
                Spacer(minLength: Spacing.md)
                inputVisual(item)
            }
        }
    }

    // MARK: - Footer

    private func footerView(_ section: EmptyStateSectionModel) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Text("\u{00B7}")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.chromeDisabledFg)
                }
                HStack(spacing: 5) {
                    // The hint's key leads: a jump keycap chip (`i` write) or
                    // an accent ex command (`:q` quit); the verb stays muted.
                    if !item.jumpKey.isEmpty {
                        keycap(item.jumpKey)
                    } else if item.detail.hasPrefix(":") {
                        Text(item.detail)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.accent)
                    }
                    if !item.label.isEmpty {
                        Text(item.label)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.chromeMutedFg)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Spacing.xs)
    }

    // MARK: - Input visuals (three teaching classes)

    /// Right-side visual for action rows.
    /// jump_key -> single keycap chip; chord -> one chip per token; a `:` detail
    /// -> bold accent monospace text with no chip.
    @ViewBuilder
    private func inputVisual(_ item: EmptyStateItemModel) -> some View {
        if !item.chord.isEmpty {
            HStack(spacing: Spacing.xs) {
                ForEach(Array(item.chordTokens.enumerated()), id: \.offset) { _, token in
                    keycap(token)
                }
            }
        } else if !item.jumpKey.isEmpty {
            keycap(item.jumpKey)
        } else if item.detail.hasPrefix(":") {
            Text(item.detail)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accent)
        } else if !item.detail.isEmpty {
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.chromeMutedFg)
        }
    }

    /// Trailing visual for card/recent rows whose jump key is a leading chip:
    /// a `:` detail is accent monospace text; any other detail is dim.
    @ViewBuilder
    private func detailVisual(_ item: EmptyStateItemModel) -> some View {
        if item.isExCommandDetail || (item.jumpKey.isEmpty && item.detail.hasPrefix(":")) {
            Text(item.detail)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accent)
        } else if !item.detail.isEmpty {
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.chromeMutedFg)
        }
    }

    // MARK: - Primitives

    private let keycapWidth: CGFloat = 22

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.editorFg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.editorFg.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.popupBorder.opacity(0.6), lineWidth: 1)
            )
    }

    private func devicon(_ item: EmptyStateItemModel) -> some View {
        Text(item.icon.isEmpty ? "\u{2022}" : item.icon)
            .font(.custom(nerdFont, size: 13))
            .foregroundStyle(item.iconColor ?? theme.chromeMutedFg)
            .frame(width: 18, alignment: .center)
    }

    /// Wraps a row in the picker-style focus/hover highlight and click activation.
    /// Hint rows are non-interactive.
    @ViewBuilder
    private func rowButton<Content: View>(_ item: EmptyStateItemModel, @ViewBuilder content: () -> Content) -> some View {
        let activatable = item.kindEnum != .hint
        let focused = state.isFocused(item.itemId)
        let hovered = hoverId == item.itemId
        content()
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowFill(focused: focused, hovered: hovered))
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                guard activatable else { return }
                if hovering {
                    hoverId = item.itemId
                } else if hoverId == item.itemId {
                    hoverId = nil
                }
            }
            .pointingHandCursor(isEnabled: activatable)
            .onTapGesture {
                guard activatable else { return }
                encoder?.sendEmptyStateActivate(id: item.itemId)
            }
    }

    private func rowFill(focused: Bool, hovered: Bool) -> Color {
        if focused { return theme.selectionBg }
        if hovered { return theme.editorFg.opacity(0.06) }
        return Color.clear
    }
}
