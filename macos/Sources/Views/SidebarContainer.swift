/// Sidebar container that switches between File Tree and Source Control tabs.
///
/// Provides a segmented tab selector at the top when both panels have data.
/// Wraps the existing FileTreeView and GitStatusView without modifying them.

import SwiftUI

/// Which sidebar tab is active. Local UI state, not managed by BEAM.
enum SidebarTab: Int, CaseIterable {
    case files
    case sourceControl
}

struct SidebarContainer: View {
    let fileTreeState: FileTreeState
    let gitStatusState: GitStatusState
    let theme: ThemeColors
    let encoder: InputEncoder?

    @State private var activeTab: SidebarTab = .files

    /// When git status panel has data and file tree is visible, show the tab selector.
    private var showTabSelector: Bool {
        fileTreeState.visible && gitStatusState.visible
    }

    var body: some View {
        VStack(spacing: 0) {
            if showTabSelector {
                tabSelector
                Divider().background(theme.treeSeparatorFg)
            }

            switch activeTab {
            case .files:
                if fileTreeState.visible {
                    FileTreeView(
                        fileTreeState: fileTreeState,
                        theme: theme,
                        encoder: encoder
                    )
                } else {
                    // Files tab selected but no tree; switch to source control
                    GitStatusView(
                        state: gitStatusState,
                        theme: theme,
                        encoder: encoder
                    )
                }
            case .sourceControl:
                if gitStatusState.visible {
                    GitStatusView(
                        state: gitStatusState,
                        theme: theme,
                        encoder: encoder
                    )
                } else {
                    // Source control tab selected but no data; switch to files
                    FileTreeView(
                        fileTreeState: fileTreeState,
                        theme: theme,
                        encoder: encoder
                    )
                }
            }
        }
        .onChange(of: fileTreeState.visible) { _, visible in
            if !visible && activeTab == .files { activeTab = .sourceControl }
        }
        .onChange(of: gitStatusState.visible) { _, visible in
            if !visible && activeTab == .sourceControl { activeTab = .files }
        }
    }

    // MARK: - Tab selector

    @ViewBuilder
    private var tabSelector: some View {
        HStack(spacing: 0) {
            tabButton(.files, icon: "doc.text", label: "Files")
            tabButton(.sourceControl, icon: "point.3.filled.connected.trianglepath.dotted", label: "Source Control")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.treeBg)
    }

    @ViewBuilder
    private func tabButton(_ tab: SidebarTab, icon: String, label: String) -> some View {
        let isActive = activeTab == tab
        Button {
            activeTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isActive ? theme.treeActiveFg : theme.treeFg.opacity(0.6))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? theme.treeFg.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
