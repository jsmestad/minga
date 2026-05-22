/// Git status header content for the unified toolbar.
///
/// Shows project name, branch name, and ahead/behind indicators. Rendered
/// inside the shared toolbar row so it shares the same background as the tab bar.

import SwiftUI

struct GitStatusHeaderContent: View {
    let state: GitStatusState
    let theme: ThemeColors
    let projectName: String
    let leadingPadding: CGFloat

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
                .layoutPriority(1)

            // Git branch icon (Nerd Font)
            Text("\u{E725}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg.opacity(0.7))

            Text(state.branchName.isEmpty ? "No branch" : state.branchName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.tabActiveFg.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)

            if state.syncing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            }

            Spacer(minLength: 4)

            if state.stashCount > 0 {
                stashBadge
            }

            if state.ahead > 0 || state.behind > 0 {
                aheadBehindBadge
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 10)
    }

    private var stashBadge: some View {
        Text("Stashes: \(state.stashCount)")
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(theme.tabActiveFg.opacity(0.7))
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
