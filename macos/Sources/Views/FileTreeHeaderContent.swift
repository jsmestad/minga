/// File tree header content for the unified toolbar.
///
/// Shows the project name and action buttons (new file, new folder,
/// refresh, collapse all). Rendered inside the shared toolbar row
/// so it shares the same background as the tab bar.

import SwiftUI

struct FileTreeHeaderContent: View {
    let fileTreeState: FileTreeState
    let theme: ThemeColors
    let encoder: InputEncoder?

    var body: some View {
        HStack(spacing: 6) {
            Text("\u{F024B}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg)

            Text(projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            HStack(spacing: 2) {
                headerButton(systemName: "doc.badge.plus", tooltip: "New File…") {
                    encoder?.sendFileTreeNewFile()
                }
                headerButton(systemName: "folder.badge.plus", tooltip: "New Folder…") {
                    encoder?.sendFileTreeNewFolder()
                }
                headerButton(systemName: "arrow.clockwise", tooltip: "Refresh") {
                    encoder?.sendFileTreeRefresh()
                }
                headerButton(systemName: "arrow.down.right.and.arrow.up.left", tooltip: "Collapse All") {
                    encoder?.sendFileTreeCollapseAll()
                }
            }
        }
        .padding(.horizontal, 10)
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

    private var projectName: String {
        if !fileTreeState.projectRoot.isEmpty {
            return (fileTreeState.projectRoot as NSString).lastPathComponent
        }
        return "Project"
    }
}
