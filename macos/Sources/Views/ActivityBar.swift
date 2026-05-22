/// Vertical activity bar for switching sidebar panels in the macOS GUI.
///
/// The activity bar is intentionally separate from `SidebarContainer`: it stays visible when the sidebar content is collapsed so users can reopen the last panel with a click.

import SwiftUI

/// Sidebar panels exposed by the activity bar.
enum ActivityBarPanel: CaseIterable, Hashable {
    case fileTree
    case gitStatus

    var protocolPanel: UInt8 {
        switch self {
        case .fileTree: 0
        case .gitStatus: 2
        }
    }

    var systemImageName: String {
        switch self {
        case .fileTree: "folder"
        case .gitStatus: "point.3.filled.connected.trianglepath.dotted"
        }
    }

    var tooltip: String {
        switch self {
        case .fileTree: "File tree (SPC o p)"
        case .gitStatus: "Git status (SPC g g)"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .fileTree: "File tree"
        case .gitStatus: "Git status"
        }
    }
}

/// Thin VS Code-style icon strip for sidebar panel discovery and switching.
struct ActivityBar: View {
    let activePanel: ActivityBarPanel
    let gitStatusCount: Int
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let width: CGFloat = 32
    private let buttonSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ActivityBarPanel.allCases, id: \.self) { panel in
                activityButton(for: panel)
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
    private func activityButton(for panel: ActivityBarPanel) -> some View {
        let isActive = panel == activePanel
        let button = activityButtonBase(for: panel, isActive: isActive)
        let spokenValue = accessibilityValue(for: panel)

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

    private func activityButtonBase(for panel: ActivityBarPanel, isActive: Bool) -> some View {
        Button {
            encoder?.sendTogglePanel(panel: panel.protocolPanel)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: panel.systemImageName)
                    .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? theme.accent : theme.treeFg.opacity(0.45))
                    .frame(width: buttonSize, height: buttonSize)

                if let badgeText = badgeText(for: panel) {
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
        .help(panel.tooltip)
        .accessibilityLabel(panel.accessibilityLabel)
    }

    private func badgeText(for panel: ActivityBarPanel) -> String? {
        guard panel == .gitStatus, gitStatusCount > 0 else { return nil }
        return gitStatusCount > 99 ? "99+" : String(gitStatusCount)
    }

    private func accessibilityValue(for panel: ActivityBarPanel) -> String? {
        guard panel == .gitStatus, gitStatusCount > 0 else { return nil }
        let countText = gitStatusCount > 99 ? "99+" : String(gitStatusCount)
        return gitStatusCount == 1 ? "1 changed file" : "\(countText) changed files"
    }
}
