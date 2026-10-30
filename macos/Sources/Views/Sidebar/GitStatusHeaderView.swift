/// Git status header view for the unified toolbar.
///
/// Shows project name, branch name, and ahead/behind indicators. Rendered
/// inside the shared toolbar row so it shares the same background as the tab bar.

import SwiftUI

public struct GitStatusHeaderView: View {
    public init(state: GitStatusState, projectName: String, leadingPadding: CGFloat) {
        self.state = state
        self.projectName = projectName
        self.leadingPadding = leadingPadding
    }
    public let state: GitStatusState
    @Environment(\.themeColors) private var theme

    public let projectName: String
    public let leadingPadding: CGFloat

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            Text("\u{F0256}")
                .font(.custom("Symbols Nerd Font Mono", size: Typography.Step.body.rawValue))
                .foregroundStyle(theme.treeDirFg)

            Text(projectName)
                .font(Typography.font(.body, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            // Git branch icon (Nerd Font)
            Text("\u{E725}")
                .font(.custom("Symbols Nerd Font Mono", size: Typography.Step.body.rawValue))
                .foregroundStyle(theme.treeDirFg.opacity(0.7))

            Text(state.snapshot.branchName.isEmpty ? "No branch" : state.snapshot.branchName)
                .font(Typography.font(.body, weight: .regular))
                .foregroundStyle(theme.tabActiveFg.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)

            if state.snapshot.syncing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            }

            Spacer(minLength: 4)

            if state.snapshot.stashCount > 0 {
                stashBadge
            }

            if state.snapshot.ahead > 0 || state.snapshot.behind > 0 {
                aheadBehindBadge
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, Spacing.md)
    }

    private var stashBadge: some View {
        Text("Stashes: \(state.snapshot.stashCount)")
            .font(Typography.font(.caption, weight: .medium).monospacedDigit())
            .foregroundStyle(theme.tabActiveFg.opacity(0.7))
    }

    @ViewBuilder
    private var aheadBehindBadge: some View {
        HStack(spacing: Spacing.xs) {
            if state.snapshot.ahead > 0 {
                HStack(spacing: Spacing.pixel) {
                    Image(systemName: "arrow.up")
                        .font(Typography.font(.symbol, weight: .bold))
                    Text("\(state.snapshot.ahead)")
                        .font(Typography.font(.caption, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(theme.gitAddedFg)
            }
            if state.snapshot.behind > 0 {
                HStack(spacing: Spacing.pixel) {
                    Image(systemName: "arrow.down")
                        .font(Typography.font(.symbol, weight: .bold))
                    Text("\(state.snapshot.behind)")
                        .font(Typography.font(.caption, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(theme.gutterErrorFg)
            }
        }
    }
}
