/// Native status bar at the bottom of the editor window.
///
/// Matches Zed's compact bottom bar: left icons, center message, right
/// position + mode indicator. All colors driven by BEAM theme.

import SwiftUI

@MainActor
@Observable
final class StatusBarState {
    /// 0 = buffer window, 1 = agent chat window.
    var contentKind: UInt8 = 0
    var mode: UInt8 = 0
    var cursorLine: UInt32 = 1
    var cursorCol: UInt32 = 1
    var lineCount: UInt32 = 1
    var flags: UInt8 = 0
    var lspStatus: UInt8 = 0
    var gitBranch: String = ""
    var message: String = ""
    var filetype: String = ""
    var errorCount: UInt16 = 0
    var warningCount: UInt16 = 0
    // Agent-only fields
    var modelName: String = ""
    var messageCount: UInt32 = 0
    var sessionStatus: UInt8 = 0

    func update(contentKind: UInt8, mode: UInt8, cursorLine: UInt32, cursorCol: UInt32,
                lineCount: UInt32, flags: UInt8, lspStatus: UInt8, gitBranch: String,
                message: String, filetype: String, errorCount: UInt16, warningCount: UInt16,
                modelName: String, messageCount: UInt32, sessionStatus: UInt8) {
        self.contentKind = contentKind
        self.mode = mode
        self.cursorLine = cursorLine
        self.cursorCol = cursorCol
        self.lineCount = lineCount
        self.flags = flags
        self.lspStatus = lspStatus
        self.gitBranch = gitBranch
        self.message = message
        self.filetype = filetype
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.modelName = modelName
        self.messageCount = messageCount
        self.sessionStatus = sessionStatus
    }

    var modeName: String {
        switch mode {
        case 0: return "NORMAL"
        case 1: return "INSERT"
        case 2: return "VISUAL"
        case 3: return "COMMAND"
        case 4: return "O-PENDING"
        case 5: return "SEARCH"
        case 6: return "REPLACE"
        default: return "NORMAL"
        }
    }

    var hasGit: Bool { flags & 0x02 != 0 }
    var hasLsp: Bool { flags & 0x01 != 0 }
    var isInsertMode: Bool { mode == 1 }
    var isAgentWindow: Bool { contentKind == 1 }

    var sessionStatusName: String {
        switch sessionStatus {
        case 0: return "idle"
        case 1: return "thinking"
        case 2: return "executing"
        case 3: return "error"
        default: return "idle"
        }
    }
}

struct StatusBarView: View {
    let state: StatusBarState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let barHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            if state.isAgentWindow {
                agentLeftSegment
            } else {
                leftSegment
            }

            Spacer()

            // Center: status message (buffer) or animated agent status indicator
            if state.isAgentWindow {
                AgentStatusIndicator(sessionStatus: state.sessionStatus, theme: theme)
            } else if !state.message.isEmpty {
                Text(state.message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Right: position + mode (buffer) or message count + mode (agent)
            if state.isAgentWindow {
                agentRightSegment
            } else {
                rightSegment
            }
        }
        .frame(height: barHeight)
        .background(theme.modelineBarBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    // MARK: - Agent segments

    @ViewBuilder
    private var agentLeftSegment: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.modelineBarFg.opacity(0.6))
            Text(state.modelName.isEmpty ? "Agent" : state.modelName)
                .font(.system(size: 11))
                .foregroundStyle(theme.modelineBarFg.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.leading, 6)
    }

    @ViewBuilder
    private var agentRightSegment: some View {
        HStack(spacing: 8) {
            Text("\(state.messageCount) msgs")
                .font(.system(size: 11))
                .foregroundStyle(theme.modelineBarFg.opacity(0.6))
            modeBadge
        }
        .padding(.trailing, 8)
    }

    // MARK: - Left segment

    @ViewBuilder
    private var leftSegment: some View {
        HStack(spacing: 2) {
            // File tree toggle
            StatusBarIconButton(
                icon: "sidebar.leading",
                barHeight: barHeight,
                barFg: theme.modelineBarFg
            ) {
                encoder?.sendTogglePanel(panel: 0)
            }

            // Git branch
            if state.hasGit && !state.gitBranch.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .medium))
                    Text(state.gitBranch)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(theme.modelineBarFg.opacity(0.6))
                .padding(.horizontal, 6)
            }

            // LSP status
            if state.hasLsp {
                lspIndicator
            }

            // Diagnostic counts
            if state.errorCount > 0 || state.warningCount > 0 {
                diagnosticIndicators
            }
        }
    }

    @ViewBuilder
    private var lspIndicator: some View {
        let (icon, color) = lspDisplay(state.lspStatus)
        Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var diagnosticIndicators: some View {
        HStack(spacing: 6) {
            if state.errorCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                    Text("\(state.errorCount)")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
            }
            if state.warningCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("\(state.warningCount)")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color(red: 0.92, green: 0.74, blue: 0.48))
            }
        }
        .padding(.horizontal, 4)
    }

    private func lspDisplay(_ status: UInt8) -> (String, Color) {
        switch status {
        case 1: return ("checkmark.circle.fill", Color(red: 0.60, green: 0.74, blue: 0.40))
        case 2: return ("arrow.triangle.2.circlepath", theme.modelineBarFg.opacity(0.5))
        case 3: return ("arrow.triangle.2.circlepath", theme.modelineBarFg.opacity(0.5))
        case 4: return ("exclamationmark.triangle.fill", Color(red: 1.0, green: 0.42, blue: 0.42))
        default: return ("circle", theme.modelineBarFg.opacity(0.3))
        }
    }

    // MARK: - Right segment

    @ViewBuilder
    private var rightSegment: some View {
        HStack(spacing: 8) {
            // Filetype
            if !state.filetype.isEmpty {
                Text(state.filetype)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.6))
            }

            // Cursor position
            Text("\(state.cursorLine):\(state.cursorCol)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.modelineBarFg.opacity(0.7))

            // Vim mode badge
            modeBadge
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var modeBadge: some View {
        let (bg, fg) = modeColors(state.mode)
        Text(state.modeName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(bg)
            )
    }

    private func modeColors(_ mode: UInt8) -> (Color, Color) {
        switch mode {
        case 0: return (theme.modeNormalBg, theme.modeNormalFg)
        case 1: return (theme.modeInsertBg, theme.modeInsertFg)
        case 2: return (theme.modeVisualBg, theme.modeVisualFg)
        default: return (theme.modelineInfoBg, theme.modelineInfoFg)
        }
    }

}

// MARK: - Reusable toolbar-style icon button with hover highlight

/// A compact icon button that shows a subtle rounded-rect fill on hover,
/// matching the Xcode / VS Code toolbar button aesthetic.
private struct StatusBarIconButton: View {
    let icon: String
    let barHeight: CGFloat
    let barFg: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(barFg.opacity(isHovered ? 0.9 : 0.6))
                .frame(width: 26, height: barHeight)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barFg.opacity(isHovered ? 0.10 : 0))
                        .padding(.horizontal, 2)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Animated agent session status indicator

/// Shows nothing for idle, a native spinner for active states, and a red
/// icon for error. Static text for an active state reads as "maybe broken" —
/// the spinner communicates liveness.
private struct AgentStatusIndicator: View {
    let sessionStatus: UInt8
    let theme: ThemeColors

    var body: some View {
        switch sessionStatus {
        case 1: // thinking
            HStack(spacing: 5) {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
                Text("thinking…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.65))
            }
        case 2: // tool executing
            HStack(spacing: 5) {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
                Text("executing…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.65))
            }
        case 3: // error
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                Text("error")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
            }
        default: // idle — show nothing; no need to announce inactivity
            EmptyView()
        }
    }
}
