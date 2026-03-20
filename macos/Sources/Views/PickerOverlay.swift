/// Native command palette / file finder with Zed-quality visual polish
/// and Helm-level features.
///
/// Centered floating panel with:
/// - Search field with candidate count (X/Y)
/// - Match highlighting (matched characters in accent color)
/// - Two-line layout for file items (name + path)
/// - Keybinding annotations for commands
/// - Multi-select checkmarks
/// - Optional preview pane (split layout when source supports preview)

import SwiftUI

struct PickerOverlay: View {
    let state: PickerState
    let theme: ThemeColors

    private let panelWidth: CGFloat = 560
    private let previewPanelWidth: CGFloat = 900
    private let maxVisibleItems = 14
    private let singleLineItemHeight: CGFloat = 28
    private let twoLineItemHeight: CGFloat = 44

    /// Effective panel width: wider when preview is shown.
    private var effectiveWidth: CGFloat {
        state.hasPreview ? previewPanelWidth : panelWidth
    }

    /// Width ratio for the item list when preview is active.
    private let listWidthRatio: CGFloat = 0.4

    var body: some View {
        if state.visible {
            ZStack {
                // Dimmed background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Centered panel
                VStack(spacing: 0) {
                    // Search field with candidate count
                    searchField

                    // Separator
                    Rectangle()
                        .fill(theme.popupBorder.opacity(0.3))
                        .frame(height: 1)

                    // Main content: list + optional preview
                    if state.hasPreview && !state.previewLines.isEmpty {
                        HStack(spacing: 0) {
                            resultsList
                                .frame(width: effectiveWidth * listWidthRatio)

                            // Vertical divider
                            Rectangle()
                                .fill(theme.popupBorder.opacity(0.3))
                                .frame(width: 1)

                            previewPane
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        resultsList
                    }

                    // Bottom bar
                    if !state.items.isEmpty {
                        Rectangle()
                            .fill(theme.popupBorder.opacity(0.3))
                            .frame(height: 1)

                        bottomBar
                    }
                }
                .frame(width: effectiveWidth)
                .overlay(alignment: .center) {
                    // Action menu overlay (C-o)
                    if let menu = state.actionMenu {
                        actionMenuOverlay(menu)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.popupBg)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.popupBorder.opacity(0.4), lineWidth: 1)
                )
                .offset(y: -60)  // Slightly above center, like Zed
            }
            .allowsHitTesting(false)  // BEAM handles all picker input
            .transition(.opacity.animation(.easeInOut(duration: 0.1)))
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
                    .font(.system(size: 14))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            } else {
                Text(state.query)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(theme.popupFg)
            }

            Spacer()

            // Candidate count: "3/127"
            if state.totalCount > 0 {
                Text("\(state.filteredCount)/\(state.totalCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Results list

    @ViewBuilder
    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(state.items.prefix(maxVisibleItems)) { item in
                        if item.isTwoLine {
                            twoLineRow(item)
                        } else {
                            singleLineRow(item)
                        }
                    }
                }
            }
            .frame(maxHeight: computeListHeight())
            .onChange(of: state.selectedIndex) { _, newIndex in
                withAnimation(nil) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    /// Compute the total height for the results list.
    private func computeListHeight() -> CGFloat {
        let visibleItems = state.items.prefix(maxVisibleItems)
        let height = visibleItems.reduce(CGFloat(0)) { total, item in
            total + (item.isTwoLine ? twoLineItemHeight : singleLineItemHeight)
        }
        return min(height, CGFloat(maxVisibleItems) * singleLineItemHeight)
    }

    // MARK: - Single-line row (commands)

    @ViewBuilder
    private func singleLineRow(_ item: PickerItem) -> some View {
        let isSelected = item.id == state.selectedIndex

        HStack(spacing: 8) {
            // Multi-select checkmark
            if item.isMarked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
            }

            // File type icon
            Text(item.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 14))
                .foregroundStyle(iconColor(item.iconColor))
                .frame(width: 20, alignment: .center)

            // Label with match highlighting
            highlightedLabel(item)

            Spacer()

            // Annotation (keybinding)
            if !item.annotation.isEmpty {
                Text(item.annotation)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.3))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.popupFg.opacity(0.06))
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: singleLineItemHeight)
        .background(selectionBackground(isSelected))
        .id(item.id)
    }

    // MARK: - Two-line row (files, buffers)

    @ViewBuilder
    private func twoLineRow(_ item: PickerItem) -> some View {
        let isSelected = item.id == state.selectedIndex

        HStack(alignment: .center, spacing: 8) {
            // Multi-select checkmark
            if item.isMarked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
            }

            // File type icon (vertically centered)
            Text(item.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 16))
                .foregroundStyle(iconColor(item.iconColor))
                .frame(width: 22, alignment: .center)

            // Two-line text
            VStack(alignment: .leading, spacing: 1) {
                // Primary: filename with match highlighting
                highlightedLabel(item)

                // Secondary: path (dimmed, smaller)
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.popupFg.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Annotation
            if !item.annotation.isEmpty {
                Text(item.annotation)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.3))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: twoLineItemHeight)
        .background(selectionBackground(isSelected))
        .id(item.id)
    }

    // MARK: - Match highlighting

    /// Renders the display label with matched characters highlighted.
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
            // Build an AttributedString with highlighted matches
            let attributed = buildHighlightedText(label, matchPositions: matchSet)
            Text(attributed)
                .lineLimit(1)
        }
    }

    /// Builds an AttributedString with matched characters in accent color and bold.
    private func buildHighlightedText(_ text: String, matchPositions: Set<Int>) -> AttributedString {
        var result = AttributedString()
        let chars = Array(text)

        for (idx, char) in chars.enumerated() {
            var segment = AttributedString(String(char))
            segment.font = .system(size: 13)

            if matchPositions.contains(idx) {
                segment.foregroundColor = Color(theme.accent)
                segment.font = .system(size: 13, weight: .semibold)
            } else {
                segment.foregroundColor = Color(theme.popupFg)
            }

            result.append(segment)
        }

        return result
    }

    // MARK: - Preview pane

    @ViewBuilder
    private var previewPane: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.previewLines) { line in
                    HStack(spacing: 0) {
                        // Line number
                        Text("\(line.id + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.popupFg.opacity(0.2))
                            .frame(width: 36, alignment: .trailing)
                            .padding(.trailing, 8)

                        // Content segments
                        ForEach(line.segments) { segment in
                            Text(segment.text)
                                .font(.system(size: 12, weight: segment.bold ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(segmentColor(segment.fgColor))
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(height: 18)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .background(theme.popupBg.opacity(0.95))
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Show marked count if multi-select is active
            let markedCount = state.items.filter { $0.isMarked }.count
            if markedCount > 0 {
                Text("\(markedCount) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
            }

            Spacer()

            // Keyboard hints
            Group {
                keyHint("↑↓", label: "navigate")
                keyHint("⏎", label: "open")
                keyHint("⇥", label: "mark")
                keyHint("⎋", label: "close")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
            // Header
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

            // Action items
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
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.popupSelBg.opacity(0.6))
                .padding(.horizontal, 4)
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
