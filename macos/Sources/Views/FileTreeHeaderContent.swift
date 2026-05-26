/// File tree header content for the unified toolbar.
///
/// Shows the project name, git branch, and action buttons (new file,
/// new folder, refresh, collapse all). Rendered inside the shared toolbar row
/// so it shares the same background as the tab bar.

import SwiftUI

struct FileTreeHeaderContent: View {
    let fileTreeState: FileTreeState
    let theme: ThemeColors
    let encoder: InputEncoder?
    let branchName: String
    let leadingPadding: CGFloat

    @State private var isHovered = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var headerAnimationDuration: Double {
        reduceMotion ? 0 : 0.15
    }

    var body: some View {
        HStack(spacing: 8) {
            projectContext
                .layoutPriority(2)

            secondaryContext
                .layoutPriority(0)

            Spacer(minLength: 4)

            actionButtons
                .opacity(isHovered ? 1.0 : 0.72)
                .animation(reduceMotion ? nil : .easeInOut(duration: headerAnimationDuration), value: isHovered)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabelText)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeInOut(duration: headerAnimationDuration)) {
                    isHovered = hovering
                }
            }
        }
    }

    @ViewBuilder
    private var projectContext: some View {
        HStack(spacing: 6) {
            Text("\u{F024B}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg)

            Text(projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var secondaryContext: some View {
        if !branchName.isEmpty {
            secondaryLabel(icon: "\u{E725}", label: branchName)
        } else if let stateLabel = treeStateLabel {
            secondaryLabel(icon: treeStateIcon, label: stateLabel)
        }
    }

    private func secondaryLabel(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(icon)
                .font(.custom("Symbols Nerd Font Mono", size: 11))
                .foregroundStyle(theme.treeDirFg.opacity(0.48))

            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.tabActiveFg.opacity(0.56))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            headerButton(systemName: "doc.badge.plus", tooltip: "New File…") {
                encoder?.sendFileTreeNewFile(parentIndex: UInt16(fileTreeState.selectedIndex))
            }

            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("New Folder…") {
                encoder?.sendFileTreeNewFolder(parentIndex: UInt16(fileTreeState.selectedIndex))
            }
            Button("Refresh") {
                encoder?.sendFileTreeRefresh()
            }
            Button("Collapse All") {
                encoder?.sendFileTreeCollapseAll()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.tabInactiveFg.opacity(0.55))
                .frame(width: 28, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("More file tree actions")
        .accessibilityLabel("More file tree actions")
    }

    @ViewBuilder
    private func headerButton(systemName: String, tooltip: String, action: @escaping () -> Void) -> some View {
        SidebarHeaderButton(
            systemName: systemName,
            barFg: theme.tabInactiveFg,
            tooltip: tooltip,
            action: action
        )
    }

    var accessibilityLabelText: String {
        if branchName.isEmpty {
            return "File tree for \(projectName)"
        }
        return "File tree for \(projectName), branch \(branchName)"
    }

    private var projectName: String {
        if !fileTreeState.projectRoot.isEmpty {
            return (fileTreeState.projectRoot as NSString).lastPathComponent
        }
        return "Project"
    }

    private var treeStateLabel: String? {
        switch fileTreeState.treeState {
        case .loading: return "Loading"
        case .empty: return "Empty"
        case .error: return "Error"
        case .hidden, .ready: return nil
        }
    }

    private var treeStateIcon: String {
        switch fileTreeState.treeState {
        case .error: return "⚠"
        default: return ""
        }
    }
}
