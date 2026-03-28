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
    private let maxListHeight: CGFloat = 440

    /// Transition animation duration. Respects reduced motion.
    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
    }

    var body: some View {
        if state.visible {
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

                    resultsList

                    if !state.items.isEmpty {
                        Divider()
                            .overlay(theme.popupBorder.opacity(0.3))
                        bottomBar
                    }
                }
                .frame(width: panelWidth)
                .background(
                    VibrancyBackground(material: .popover)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.popupBg.opacity(0.5))
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
                Text(state.title.isEmpty ? "Search..." : state.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            } else {
                Text(state.query)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.popupFg)
            }

            Spacer()

            if state.totalCount > 0 {
                Text("\(state.filteredCount)/\(state.totalCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Results list

    @ViewBuilder
    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(state.items) { item in
                        itemRow(item)
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(state.items.count) * itemHeight, maxListHeight))
            .onChange(of: state.selectedIndex) { _, newIndex in
                withAnimation(nil) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Single unified row (all items)

    @ViewBuilder
    private func itemRow(_ item: PickerItem) -> some View {
        let isSelected = item.id == state.selectedIndex

        HStack(spacing: 6) {
            // Multi-select checkmark
            if item.isMarked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                    .frame(width: 14)
            }

            // File type icon
            Text(item.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 13))
                .foregroundStyle(iconColor(item.iconColor))
                .frame(width: 18, alignment: .center)

            // Filename with match highlighting
            highlightedLabel(item)

            // Path (inline, dimmed) — Helm/Ivy style
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            // Annotation (keybinding)
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
        .padding(.horizontal, 10)
        .frame(height: itemHeight)
        .background(selectionBackground(isSelected))
        .id(item.id)
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

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 12) {
            let markedCount = state.items.filter { $0.isMarked }.count
            if markedCount > 0 {
                Text("\(markedCount) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
            }

            Spacer()

            Group {
                keyHint("↑↓", label: "navigate")
                keyHint("⏎", label: "open")
                keyHint("⇥", label: "mark")
                keyHint("⎋", label: "close")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.popupFg.opacity(0.45))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.popupFg.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.popupFg.opacity(0.3))
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
            VibrancyBackground(material: .popover)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.popupBg.opacity(0.5))
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
