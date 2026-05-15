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
            HStack(spacing: 4) {
                Text("\u{E725}")
                    .font(.custom("Symbols Nerd Font Mono", size: 11))
                    .foregroundStyle(theme.treeDirFg.opacity(0.55))

                Text(branchName)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.tabActiveFg.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.treeHeaderFg.opacity(0.08), in: Capsule())
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            headerButton(systemName: "doc.badge.plus", tooltip: "New File…") {
                encoder?.sendFileTreeNewFile(parentIndex: UInt16(fileTreeState.selectedIndex))
            }
            headerButton(systemName: "folder.badge.plus", tooltip: "New Folder…") {
                encoder?.sendFileTreeNewFolder(parentIndex: UInt16(fileTreeState.selectedIndex))
            }
            headerButton(systemName: "arrow.clockwise", tooltip: "Refresh") {
                encoder?.sendFileTreeRefresh()
            }
            headerButton(systemName: "arrow.down.right.and.arrow.up.left", tooltip: "Collapse All") {
                encoder?.sendFileTreeCollapseAll()
            }
        }
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
}
