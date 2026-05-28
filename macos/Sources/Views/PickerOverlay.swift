/// Native command palette / file finder with Helm-level density.
///
/// Centered floating panel with dense single-line items. Preview happens
/// in the editor area behind the picker (the BEAM switches the active
/// buffer on navigation), not in an inline pane. This matches Helm/Ivy's
/// approach: the picker is a fast selection tool, the editor is the preview.

import SwiftUI

struct PickerOverlay: View {
    let state: PickerState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let panelWidth: CGFloat = 600
    private let itemHeight: CGFloat = 24
    private let twoLineItemHeight: CGFloat = 40

    /// Transition animation duration. Respects reduced motion.
    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
    }

    var body: some View {
        if state.visible {
            GeometryReader { geo in
                ZStack {
                    // Dimmed background: click to dismiss (like Spotlight, Alfred, Xcode Open Quickly)
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                        .onTapGesture {
                            // Send Escape to the BEAM to dismiss the picker via the normal mode transition
                            encoder?.sendKeyPress(codepoint: 27, modifiers: 0)
                        }

                    VStack(spacing: 0) {
                        searchField

                        Divider()
                            .overlay(theme.popupBorder.opacity(0.3))

                        let totalItemsHeight = state.items.reduce(CGFloat(0)) { $0 + ($1.isTwoLine ? twoLineItemHeight : itemHeight) }
                        let listHeight = min(totalItemsHeight, max(geo.size.height * 0.5, 200))
                        resultsList(maxListHeight: listHeight)

                    }
                    .frame(width: panelWidth)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.popupBg)
                            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.popupBorder.opacity(0.4), lineWidth: 1)
                    )
                    .overlay(alignment: .center) {
                        if let menu = state.actionMenu {
                            actionMenuOverlay(menu)
                        }
                    }
                    .offset(y: -60)
                }
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
                Text("Searching...")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 48)
        } else if case .error(let message) = state.loadStatus {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 48)
        } else if state.items.isEmpty && !state.query.isEmpty {
            Text("No matches")
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 48)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(state.items) { item in
                            itemRow(item)
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
                .onChange(of: state.selectedIndex) { _, newIndex in
                    withAnimation(nil) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Item row

    @ViewBuilder
    private func itemRow(_ item: PickerItem) -> some View {
        let isSelected = item.id == state.selectedIndex

        Group {
            if item.isTwoLine {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        itemCheckmark(item)
                        itemIcon(item)
                        highlightedLabel(item)
                        Spacer(minLength: 4)
                        itemAnnotation(item)
                    }

                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.popupFg.opacity(0.35))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.leading, 44) // checkmark(14) + spacing(6) + icon(18) + spacing(6)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    itemCheckmark(item)
                    itemIcon(item)
                    highlightedLabel(item)

                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.popupFg.opacity(0.35))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Spacer(minLength: 4)
                    itemAnnotation(item)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: item.isTwoLine ? twoLineItemHeight : itemHeight)
        .background(selectionBackground(isSelected))
        .overlay(alignment: .leading) {
            if isSelected && item.isTwoLine {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
        .id(item.id)
    }

    // MARK: - Item row subviews

    @ViewBuilder
    private func itemCheckmark(_ item: PickerItem) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(theme.accent)
            .frame(width: 14)
            .opacity(item.isMarked ? 1 : 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func itemIcon(_ item: PickerItem) -> some View {
        if item.hasLeadingIcon {
            Text(item.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 13))
                .foregroundStyle(iconColor(item.iconColor))
                .frame(width: 18, alignment: .center)
        }
    }

    @ViewBuilder
    private func itemAnnotation(_ item: PickerItem) -> some View {
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
    private func highlightedLabel(_ item: PickerItem) -> some View {
        let label = item.displayLabel
        let matchSet = item.displayMatchPositions

        if matchSet.isEmpty {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg)
                .lineLimit(1)
        } else {
            let attributed = TextHighlighting.attributedString(
                label,
                matchPositions: matchSet,
                baseColor: Color(theme.popupFg),
                matchColor: Color(theme.accent)
            )
            Text(attributed)
                .lineLimit(1)
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
                        .foregroundStyle(isSelected ? Color.white : theme.popupFg)
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

    // MARK: - Helpers

    @ViewBuilder
    private func selectionBackground(_ isSelected: Bool) -> some View {
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

    private func segmentColor(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
