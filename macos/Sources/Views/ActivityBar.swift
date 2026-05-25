/// Vertical activity bar for switching sidebar panels in the macOS GUI.
///
/// The activity bar is intentionally separate from `SidebarContainer`: it stays visible when the sidebar content is collapsed so users can reopen the last panel with a click.

import SwiftUI

/// Thin VS Code-style icon strip for sidebar panel discovery and switching.
struct ActivityBar: View {
    let guiState: GUIState
    let sidebarHostState: SidebarHostState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let width: CGFloat = 32
    private let buttonSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 4) {
            ForEach(sidebarHostState.visibleSidebars) { item in
                activityButton(for: item)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(theme.treeHeaderBg)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.treeSeparatorFg.opacity(0.45))
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func activityButton(for item: SidebarItem) -> some View {
        let isActive = item.id == sidebarHostState.activeSidebar?.id
        let button = activityButtonBase(for: item, isActive: isActive)
        let spokenValue = accessibilityValue(for: item)

        if let spokenValue {
            if isActive {
                button
                    .accessibilityValue(spokenValue)
                    .accessibilityAddTraits(.isSelected)
            } else {
                button.accessibilityValue(spokenValue)
            }
        } else if isActive {
            button.accessibilityAddTraits(.isSelected)
        } else {
            button
        }
    }

    private func activityButtonBase(for item: SidebarItem, isActive: Bool) -> some View {
        let adapter = NativeSidebarRegistry.adapterOrFallback(for: item.semanticKind)

        return Button {
            adapter.sendPrimaryAction(encoder, item, isActive)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: item.icon.isEmpty ? adapter.fallbackIcon : item.icon)
                    .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? theme.accent : theme.treeFg.opacity(0.45))
                    .frame(width: buttonSize, height: buttonSize)

                if let badgeText = badgeText(for: item) {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.modeNormalFg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(theme.accent))
                        .offset(x: 3, y: -2)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? theme.accent.opacity(0.14) : Color.clear)
            }
            .overlay(alignment: .leading) {
                if isActive {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: 3, height: 18)
                        .offset(x: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.displayName)
        .accessibilityLabel(item.displayName)
    }

    private func badgeText(for item: SidebarItem) -> String? {
        let context = NativeSidebarContext(
            guiState: guiState,
            theme: theme,
            encoder: encoder,
            projectName: "",
            gitBranch: "",
            leadingPadding: 0
        )
        return NativeSidebarRegistry.adapterOrFallback(for: item.semanticKind).badgeText(context, item)
    }

    private func accessibilityValue(for item: SidebarItem) -> String? {
        guard item.semanticKind == "git_status", let count = item.badgeCount, count > 0 else { return nil }
        let countText = count > 99 ? "99+" : String(count)
        return count == 1 ? "1 changed file" : "\(countText) changed files"
    }
}
