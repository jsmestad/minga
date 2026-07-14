/// Native command palette / file finder anchored at the top of the window.
///
/// The panel drops down from the top-center (like VSCode/Zed), leaving the
/// editor area visible below for live file preview. The BEAM switches the
/// active buffer on navigation so the preview appears behind the picker.

import SwiftUI
import MingaProtocol

public struct PickerOverlay: View {
    public init(state: PickerState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    public let state: PickerState
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    public let encoder: InputEncoder?

    private let panelWidth: CGFloat = 600
    private let itemHeight: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animDuration: Double {
        reduceMotion ? 0 : 0.1
    }

    public var body: some View {
        let _ = frameVersion
        if state.visible {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        searchField

                        Divider()
                            .overlay(theme.popupBorder.opacity(0.3))

                        let totalItemsHeight = CGFloat(state.items.count) * itemHeight
                        let maxHeight = geo.size.height * 0.4
                        let listHeight = min(totalItemsHeight, max(maxHeight, 120))
                        resultsList(maxListHeight: listHeight)
                    }
                    .frame(width: min(panelWidth, geo.size.width - 40))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.popupBg)
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.popupBorder.opacity(0.4), lineWidth: 1)
                    )
                    .overlay(alignment: .center) {
                        if let menu = state.actionMenu {
                            actionMenuOverlay(menu)
                        }
                    }
                    .padding(.top, 1)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .transition(.opacity.animation(.easeInOut(duration: animDuration)))
        }
    }

    // MARK: - Search field

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg.opacity(0.4))

            if state.query.isEmpty {
                HStack(spacing: 6) {
                    if !state.modePrefix.isEmpty {
                        modePrefixBadge
                    }

                    Text(state.title.isEmpty ? "Search..." : state.title)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.popupFg.opacity(0.35))
                }
            } else {
                HStack(spacing: 6) {
                    if !state.modePrefix.isEmpty {
                        modePrefixBadge
                    }

                    Text(state.query)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.popupFg)
                }
            }

            Spacer()

            if state.markedCount > 0 {
                Text("\(state.markedCount) marked")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.accent.opacity(0.14))
                    )
            }

            if state.totalCount > 0 {
                Text("\(state.filteredCount)/\(state.totalCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var modePrefixBadge: some View {
        Text("[\(state.modePrefix)]")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(theme.accent.opacity(0.14))
            )
            .accessibilityLabel(Text("Picker mode \(state.modePrefix)"))
    }

    // MARK: - Results list

    @ViewBuilder
    private func resultsList(maxListHeight: CGFloat) -> some View {
        if case .loading = state.loadStatus {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(state.title.isEmpty ? "Loading..." : "\(state.title)...")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(maxHeight: maxListHeight)
            .frame(minHeight: 48)
        } else if case .error(let message) = state.loadStatus {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(maxHeight: maxListHeight)
                .frame(minHeight: 48)
        } else if state.items.isEmpty && !state.query.isEmpty {
            Text("No matches")
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(maxHeight: maxListHeight)
                .frame(minHeight: 48)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(state.items) { item in
                            PickerItemRow(
                                item: item,
                                isSelected: item.id == state.effectiveSelectedIndex,
                                query: state.query,
                                itemHeight: itemHeight
                            )
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
                .onChange(of: state.effectiveSelectedIndex) { _, newIndex in
                    withAnimation(nil) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onChange(of: state.items.count) { _, _ in
                    withAnimation(nil) {
                        proxy.scrollTo(state.effectiveSelectedIndex, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Action menu (C-o)

    @ViewBuilder
    private func actionMenuOverlay(_ menu: PickerActionMenu) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Actions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.popupFg.opacity(0.6))
                Spacer()
                Text("C-o")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Rectangle()
                .fill(theme.popupBorder.opacity(0.3))
                .frame(height: 1)

            ForEach(Array(menu.actions.enumerated()), id: \.offset) { idx, action in
                let isSelected = idx == menu.selectedIndex

                HStack {
                    Text(action)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? theme.popupSelFg : theme.popupFg)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected
                        ? RoundedRectangle(cornerRadius: 4).fill(theme.accent).padding(.horizontal, 4)
                        : nil
                )
            }
        }
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.popupBg)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
        )
    }

}

// MARK: - Picker item row (separate View for observation isolation)

private struct PickerItemRow: View {
    let item: PickerItem
    let isSelected: Bool
    let query: String
    let itemHeight: CGFloat

    @Environment(\.themeColors) private var theme

    var body: some View {
        HStack(spacing: 6) {
            itemCheckmark
            itemIcon
            highlightedLabel

            if !item.description.isEmpty {
                highlightedDescription
            }

            Spacer(minLength: 4)
            itemAnnotation
        }
        .padding(.horizontal, 10)
        .frame(height: itemHeight)
        .background(selectionBackground)
        .id(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.displayLabel + (item.description.isEmpty ? "" : ", " + item.description)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Subviews

    @ViewBuilder
    private var itemCheckmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(theme.accent)
            .frame(width: 14)
            .opacity(item.isMarked ? 1 : 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var itemIcon: some View {
        if item.hasLeadingIcon {
            Text(item.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 13))
                .foregroundStyle(iconColor(item.iconColor))
                .frame(width: 18, alignment: .center)
        }
    }

    @ViewBuilder
    private var itemAnnotation: some View {
        if !item.annotation.isEmpty {
            Text(item.annotation)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.popupFg.opacity(0.3))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.popupFg.opacity(0.06))
                )
        }
    }

    // MARK: - Match highlighting

    @ViewBuilder
    private var highlightedLabel: some View {
        let label = item.displayLabel
        let matchSet = item.displayMatchPositions
        let fg = isSelected ? theme.popupSelFg : theme.popupFg

        if matchSet.isEmpty {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(fg)
                .lineLimit(1)
        } else {
            Text(TextHighlighting.attributedString(
                label,
                matchPositions: matchSet,
                baseColor: Color(fg),
                matchColor: Color(theme.accent)
            ))
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var highlightedDescription: some View {
        let desc = item.description
        let descPositions = TextHighlighting.fuzzyMatchPositions(desc, query: query)
        let fg = isSelected ? theme.popupSelFg.opacity(0.6) : theme.popupFg.opacity(0.35)

        if descPositions.isEmpty {
            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(fg)
                .lineLimit(1)
                .truncationMode(.head)
        } else {
            Text(TextHighlighting.attributedString(
                desc,
                matchPositions: descPositions,
                baseFont: .system(size: 12),
                matchFont: .system(size: 12, weight: .semibold),
                baseColor: Color(fg),
                matchColor: Color(theme.accent)
            ))
            .lineLimit(1)
            .truncationMode(.head)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.popupSelBg.opacity(0.7))
                .padding(.horizontal, 2)
        } else {
            Color.clear
        }
    }

    private func iconColor(_ rgb: UInt32) -> Color {
        if rgb == 0 { return theme.popupFg.opacity(0.5) }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

@MainActor
private func pickerPreviewState() -> PickerState {
    let state = PickerState()
    state.update(
        visible: true,
        selectedIndex: 1,
        filteredCount: 5,
        totalCount: 42,
        markedCount: 0,
        title: "Find File",
        query: "edit",
        hasPreview: false,
        rawItems: [
            Wire.PickerItem(iconColor: 0x98BE65, flags: 0, label: "\u{f0e7}editor.ex", description: "lib/minga/editor.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0x98BE65, flags: 0x01, label: "\u{f0e7}editor_test.exs", description: "test/minga/editor_test.exs", annotation: "test", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0x51AFEF, flags: 0, label: "\u{f0e7}EditorNSView.swift", description: "macos/Sources/EditorNSView.swift", annotation: "swift", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0xECBE7B, flags: 0, label: "\u{f085}edit_mode.ex", description: "lib/minga/mode/edit_mode.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0xC678DD, flags: 0, label: "\u{f0e7}editor_config.ex", description: "lib/minga/editor/config.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
        ],
        actionMenu: nil,
        modePrefix: ""
    )
    return state
}

#Preview("Picker") {
    let theme = PreviewFixtures.theme()
    ZStack(alignment: .top) {
        theme.editorBg
        PickerOverlay(state: pickerPreviewState(), encoder: nil)
    }
    .frame(width: 700, height: 500)
    .clipped()
    .environment(\.themeColors, theme)
}
