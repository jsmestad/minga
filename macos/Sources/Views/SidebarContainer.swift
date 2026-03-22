/// Sidebar container that renders the BEAM-active panel (file tree or git status).
///
/// The BEAM enforces mutual exclusivity: only one of fileTreeState.visible or
/// gitStatusState.visible can be true at a time. This container simply renders
/// whichever panel the BEAM says is visible. No local @State for tab selection.

import SwiftUI

struct SidebarContainer: View {
    let fileTreeState: FileTreeState
    let gitStatusState: GitStatusState
    let theme: ThemeColors
    let encoder: InputEncoder?

    var body: some View {
        VStack(spacing: 0) {
            // Render whichever panel the BEAM says is visible.
            // If somehow both are visible (should not happen after BEAM fix),
            // prefer file tree (it renders first and fills the space).
            if fileTreeState.visible {
                FileTreeView(
                    fileTreeState: fileTreeState,
                    theme: theme,
                    encoder: encoder
                )
            } else if gitStatusState.visible {
                GitStatusView(
                    state: gitStatusState,
                    theme: theme,
                    encoder: encoder
                )
            }
        }
    }
}
