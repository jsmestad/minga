/// Git status header content for the unified toolbar.
///
/// Shows branch name and ahead/behind indicators. Rendered inside the
/// shared toolbar row so it shares the same background as the tab bar.

import SwiftUI

struct GitStatusHeaderContent: View {
    let state: GitStatusState
    let theme: ThemeColors

    var body: some View {
        HStack(spacing: 6) {
            // Git branch icon (Nerd Font)
            Text("\u{E725}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg)

            Text(state.branchName.isEmpty ? "No branch" : state.branchName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if state.ahead > 0 || state.behind > 0 {
                aheadBehindBadge
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var aheadBehindBadge: some View {
        HStack(spacing: 3) {
            if state.ahead > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(state.ahead)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(theme.gitAddedFg)
            }
            if state.behind > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(state.behind)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(theme.gutterErrorFg)
            }
        }
    }
}
