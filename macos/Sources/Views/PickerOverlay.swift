/// Native command palette / file finder matching Zed's floating panel.
///
/// Centered floating panel with search field, file results with icons
/// and path breadcrumbs, and action buttons at the bottom. Rounded
/// corners, dark background with shadow.

import SwiftUI

struct PickerOverlay: View {
    let state: PickerState
    let theme: ThemeColors

    private let panelWidth: CGFloat = 560
    private let maxVisibleItems = 12
    private let itemHeight: CGFloat = 28

    var body: some View {
        if state.visible {
            ZStack {
                // Dimmed background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Centered panel
                VStack(spacing: 0) {
                    // Search field
                    searchField

                    // Separator
                    Rectangle()
                        .fill(theme.popupBorder.opacity(0.3))
                        .frame(height: 1)

                    // Results list
                    resultsList

                    // Bottom actions
                    if !state.items.isEmpty {
                        Rectangle()
                            .fill(theme.popupBorder.opacity(0.3))
                            .frame(height: 1)

                        bottomBar
                    }
                }
                .frame(width: panelWidth)
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
                        resultRow(item)
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(state.items.count, maxVisibleItems)) * itemHeight)
            .onChange(of: state.selectedIndex) { _, newIndex in
                withAnimation(nil) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ item: PickerItem) -> some View {
        let isSelected = item.id == state.selectedIndex

        HStack(spacing: 8) {
            // File type icon (first char of label, colored)
            Text(item.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 14))
                .foregroundStyle(iconColor(item.iconColor))
                .frame(width: 20, alignment: .center)

            // File name
            Text(item.displayLabel)
                .font(.system(size: 13))
                .foregroundStyle(theme.popupFg)
                .lineLimit(1)

            // Path description (muted)
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            // Recent indicator
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(theme.popupFg.opacity(0.2))
        }
        .padding(.horizontal, 12)
        .frame(height: itemHeight)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 4).fill(theme.popupSelBg.opacity(0.6))
                    .padding(.horizontal, 4)
                    .eraseToAnyView()
                : Color.clear.eraseToAnyView()
        )
        .id(item.id)
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            Spacer()
            Text("Open")
                .font(.system(size: 11))
                .foregroundStyle(theme.popupFg.opacity(0.5))
            Text("Split...")
                .font(.system(size: 11))
                .foregroundStyle(theme.popupFg.opacity(0.5))
                .padding(.leading, 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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

// Helper to erase view type for conditional backgrounds
extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}
