/// Native tool manager panel for browsing, installing, and managing
/// LSP servers and formatters.
///
/// Designed as a centered floating overlay (like the picker) but with
/// a richer layout: filter tabs at the top, a scrollable tool list
/// with status badges, and action buttons. Aims to match the polish
/// of Mason for Neovim while feeling native to macOS.

import SwiftUI

struct ToolManagerView: View {
    let state: ToolManagerState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let panelWidth: CGFloat = 680
    private let panelMaxHeight: CGFloat = 520
    private let itemHeight: CGFloat = 64

    var body: some View {
        if state.visible {
            ZStack {
                // Dimmed background scrim
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Centered floating panel
                VStack(spacing: 0) {
                    // Header with title and stats
                    headerBar

                    // Filter tabs
                    filterBar

                    Divider()
                        .background(theme.popupBorder.opacity(0.3))

                    // Tool list
                    toolList

                    // Footer with keyboard hints
                    footerBar
                }
                .frame(width: panelWidth, maxHeight: panelMaxHeight)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.popupBg)
                        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(theme.popupBorder.opacity(0.35), lineWidth: 1)
                )
                .offset(y: -30)
            }
            .allowsHitTesting(false)  // BEAM handles all input
            .transition(.opacity.combined(with: .scale(scale: 0.97)).animation(.easeOut(duration: 0.15)))
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            // Icon and title
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.accent)

            Text("Tool Manager")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.popupFg)

            Spacer()

            // Status pills
            if state.installedCount > 0 {
                statusPill(
                    count: state.installedCount,
                    label: "installed",
                    color: Color(red: 0.31, green: 0.98, blue: 0.48)  // green
                )
            }

            if state.installingCount > 0 {
                statusPill(
                    count: state.installingCount,
                    label: "installing",
                    color: Color(red: 0.95, green: 0.98, blue: 0.55)  // yellow
                )
            }

            statusPill(
                count: state.availableCount,
                label: "available",
                color: theme.popupFg.opacity(0.5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func statusPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.popupFg.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
        )
    }

    // MARK: - Filter tabs

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(ToolFilter.allCases, id: \.rawValue) { filter in
                filterTab(filter)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func filterTab(_ filter: ToolFilter) -> some View {
        let isActive = filter == state.filter

        Text(filter.label)
            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? theme.accent : theme.popupFg.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? theme.accent.opacity(0.12) : Color.clear)
            )
    }

    // MARK: - Tool list

    @ViewBuilder
    private var toolList: some View {
        if state.tools.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.popupFg.opacity(0.2))
                Text("No tools match the current filter")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.tools.enumerated()), id: \.element.id) { index, tool in
                            toolRow(tool, isSelected: index == state.selectedIndex)
                                .id(index)
                        }
                    }
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    withAnimation(nil) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: ToolEntry, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            // Category icon
            categoryIcon(tool.category)

            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.popupFg)

                    // Method badge
                    methodBadge(tool.method)

                    Spacer()

                    // Status indicator
                    statusIndicator(tool)
                }

                Text(tool.description)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.popupFg.opacity(0.45))
                    .lineLimit(1)

                // Languages and commands
                HStack(spacing: 8) {
                    if !tool.languages.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "globe")
                                .font(.system(size: 9))
                            Text(tool.languages.joined(separator: ", "))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                    }

                    if !tool.provides.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "terminal")
                                .font(.system(size: 9))
                            Text(tool.provides.joined(separator: ", "))
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: itemHeight)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(theme.popupSelBg.opacity(0.5))
                    .padding(.horizontal, 6)
                : nil
        )
    }

    // MARK: - Status indicators

    @ViewBuilder
    private func statusIndicator(_ tool: ToolEntry) -> some View {
        switch tool.status {
        case .installed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.31, green: 0.98, blue: 0.48))
                if !tool.version.isEmpty {
                    Text("v\(tool.version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.4))
                }
            }

        case .installing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Installing...")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.95, green: 0.98, blue: 0.55))
            }

        case .updateAvailable:
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.42))
                Text("Update")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.42))
            }

        case .notInstalled:
            Text("Install")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .strokeBorder(theme.accent.opacity(0.4), lineWidth: 1)
                )
        }
    }

    // MARK: - Category icon

    @ViewBuilder
    private func categoryIcon(_ category: ToolCategory) -> some View {
        Image(systemName: category.icon)
            .font(.system(size: 16))
            .foregroundStyle(categoryColor(category))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(categoryColor(category).opacity(0.12))
            )
    }

    private func categoryColor(_ category: ToolCategory) -> Color {
        switch category {
        case .lspServer: return theme.accent
        case .formatter: return Color(red: 0.31, green: 0.98, blue: 0.48)
        case .linter: return Color(red: 1.0, green: 0.72, blue: 0.42)
        case .debugger: return Color(red: 1.0, green: 0.47, blue: 0.47)
        }
    }

    // MARK: - Method badge

    @ViewBuilder
    private func methodBadge(_ method: ToolMethod) -> some View {
        Text(method.label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.popupFg.opacity(0.35))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.popupFg.opacity(0.06))
            )
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerBar: some View {
        Divider()
            .background(theme.popupBorder.opacity(0.3))

        HStack(spacing: 16) {
            keyHint(key: "↵", action: "Install/Update")
            keyHint(key: "d", action: "Uninstall")
            keyHint(key: "Tab", action: "Filter")
            keyHint(key: "Esc", action: "Close")
            Spacer()
            Text("\(state.tools.count) tools")
                .font(.system(size: 10))
                .foregroundStyle(theme.popupFg.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func keyHint(key: String, action: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.popupKeyFg)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.popupFg.opacity(0.08))
                )
            Text(action)
                .font(.system(size: 10))
                .foregroundStyle(theme.popupFg.opacity(0.4))
        }
    }
}
