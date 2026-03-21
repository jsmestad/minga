/// Native status bar at the bottom of the editor window.
///
/// Matches Zed's compact bottom bar: left icons, center message, right
/// position + mode indicator. All colors driven by BEAM theme.

import SwiftUI

/// Typed snapshot of status bar data from the BEAM. Constructed by
/// CommandDispatcher, consumed by StatusBarState.update(). Named fields
/// prevent the transposition bugs that a 15-parameter function invites.
struct StatusBarUpdate: Sendable {
    let contentKind: UInt8
    let mode: UInt8
    let cursorLine: UInt32
    let cursorCol: UInt32
    let lineCount: UInt32
    let flags: UInt8
    let lspStatus: UInt8
    let gitBranch: String
    let message: String
    let filetype: String
    let errorCount: UInt16
    let warningCount: UInt16
    // Agent-only fields
    let modelName: String
    let messageCount: UInt32
    let sessionStatus: UInt8
    // Extended fields (TUI modeline parity)
    let infoCount: UInt16
    let hintCount: UInt16
    let macroRecording: UInt8
    let parserStatus: UInt8
    let agentStatus: UInt8
    let gitAdded: UInt16
    let gitModified: UInt16
    let gitDeleted: UInt16
    let icon: String
    let iconColorR: UInt8
    let iconColorG: UInt8
    let iconColorB: UInt8
    let filename: String
    let diagnosticHint: String
}

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
    // Extended fields (TUI modeline parity)
    var infoCount: UInt16 = 0
    var hintCount: UInt16 = 0
    var macroRecording: UInt8 = 0
    var parserStatus: UInt8 = 0
    var agentStatus: UInt8 = 0
    var gitAdded: UInt16 = 0
    var gitModified: UInt16 = 0
    var gitDeleted: UInt16 = 0
    var icon: String = ""
    var iconColorR: UInt8 = 0
    var iconColorG: UInt8 = 0
    var iconColorB: UInt8 = 0
    var filename: String = ""
    var diagnosticHint: String = ""

    func update(from data: StatusBarUpdate) {
        self.contentKind = data.contentKind
        self.mode = data.mode
        self.cursorLine = data.cursorLine
        self.cursorCol = data.cursorCol
        self.lineCount = data.lineCount
        self.flags = data.flags
        self.lspStatus = data.lspStatus
        self.gitBranch = data.gitBranch
        self.message = data.message
        self.filetype = data.filetype
        self.errorCount = data.errorCount
        self.warningCount = data.warningCount
        self.modelName = data.modelName
        self.messageCount = data.messageCount
        self.sessionStatus = data.sessionStatus
        self.infoCount = data.infoCount
        self.hintCount = data.hintCount
        self.macroRecording = data.macroRecording
        self.parserStatus = data.parserStatus
        self.agentStatus = data.agentStatus
        self.gitAdded = data.gitAdded
        self.gitModified = data.gitModified
        self.gitDeleted = data.gitDeleted
        self.icon = data.icon
        self.iconColorR = data.iconColorR
        self.iconColorG = data.iconColorG
        self.iconColorB = data.iconColorB
        self.filename = data.filename
        self.diagnosticHint = data.diagnosticHint
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
    var isDirty: Bool { flags & 0x04 != 0 }
    var isInsertMode: Bool { mode == 1 }
    var isAgentWindow: Bool { contentKind == 1 }
    var isRecordingMacro: Bool { macroRecording > 0 }
    var hasGitDiffStats: Bool { gitAdded > 0 || gitModified > 0 || gitDeleted > 0 }

    /// The macro register character (a-z), or nil if not recording.
    var macroRegister: Character? {
        guard macroRecording > 0, macroRecording <= 26 else { return nil }
        return Character(UnicodeScalar(96 + macroRecording))
    }

    /// Icon color as a SwiftUI Color from the 24-bit RGB components.
    var iconColor: Color {
        Color(
            red: Double(iconColorR) / 255.0,
            green: Double(iconColorG) / 255.0,
            blue: Double(iconColorB) / 255.0
        )
    }

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
        ZStack {
            // Center (lowest priority, truncates first)
            centerSegment

            // Left-aligned
            HStack(spacing: 0) {
                if state.isAgentWindow {
                    agentLeftSegment
                } else {
                    leftSegment
                }
                Spacer(minLength: 0)
            }

            // Right-aligned
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if state.isAgentWindow {
                    agentRightSegment
                } else {
                    rightSegment
                }
            }
        }
        .frame(height: barHeight)
        .background(theme.modelineBarBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    // MARK: - Center segment (transient indicators)

    @ViewBuilder
    private var centerSegment: some View {
        if state.isAgentWindow {
            AgentStatusIndicator(sessionStatus: state.sessionStatus, theme: theme)
        } else if state.isRecordingMacro, let reg = state.macroRegister {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("recording @\(String(reg))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.8))
            }
        } else if !state.message.isEmpty {
            Text(state.message)
                .font(.system(size: 11))
                .foregroundStyle(theme.modelineBarFg.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
        } else if !state.diagnosticHint.isEmpty {
            Text(state.diagnosticHint)
                .font(.system(size: 11))
                .foregroundStyle(theme.modelineBarFg.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
        }
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

            // Bottom panel toggle
            StatusBarIconButton(
                icon: "rectangle.bottomhalf.inset.filled",
                barHeight: barHeight,
                barFg: theme.modelineBarFg
            ) {
                encoder?.sendTogglePanel(panel: 1)
            }

            // Agent status (thinking/executing/error; hidden when idle)
            agentStatusIcon

            // Git branch + diff stats
            if state.hasGit && !state.gitBranch.isEmpty {
                gitSegment
            }

            // Diagnostic counts (all 4 levels, theme-colored)
            diagnosticIndicators
        }
    }

    // MARK: - Agent status icon

    @ViewBuilder
    private var agentStatusIcon: some View {
        switch state.agentStatus {
        case 1: // thinking
            ProgressView()
                .scaleEffect(0.45)
                .frame(width: 14, height: barHeight)
        case 2: // executing
            Image(systemName: "bolt.fill")
                .font(.system(size: 9))
                .foregroundStyle(theme.statusbarAccentFg)
                .frame(width: 14, height: barHeight)
        case 3: // error
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(theme.gutterErrorFg)
                .frame(width: 14, height: barHeight)
        default: // idle: show nothing
            EmptyView()
        }
    }

    // MARK: - Git branch + diff stats

    @ViewBuilder
    private var gitSegment: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .medium))
            Text(state.gitBranch)
                .font(.system(size: 11))
                .lineLimit(1)

            // Diff stats: +added ~modified -deleted
            if state.hasGitDiffStats {
                HStack(spacing: 4) {
                    if state.gitAdded > 0 {
                        Text("+\(state.gitAdded)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.gitAddedFg)
                    }
                    if state.gitModified > 0 {
                        Text("~\(state.gitModified)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.gitModifiedFg)
                    }
                    if state.gitDeleted > 0 {
                        Text("-\(state.gitDeleted)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.gitDeletedFg)
                    }
                }
            }
        }
        .foregroundStyle(theme.modelineBarFg.opacity(0.6))
        .padding(.horizontal, 6)
    }

    // MARK: - LSP indicator (theme-colored)

    @ViewBuilder
    private var lspIndicator: some View {
        let (sfIcon, color) = lspDisplay(state.lspStatus)
        Image(systemName: sfIcon)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
    }

    // MARK: - Diagnostic counts (all 4 levels, theme-colored)

    @ViewBuilder
    private var diagnosticIndicators: some View {
        let hasAny = state.errorCount > 0 || state.warningCount > 0 || state.infoCount > 0 || state.hintCount > 0
        if hasAny {
            HStack(spacing: 6) {
                if state.errorCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                        Text("\(state.errorCount)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(theme.gutterErrorFg)
                }
                if state.warningCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("\(state.warningCount)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(theme.gutterWarningFg)
                }
                if state.infoCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 9))
                        Text("\(state.infoCount)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(theme.gutterInfoFg)
                }
                if state.hintCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 9))
                        Text("\(state.hintCount)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(theme.gutterHintFg)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func lspDisplay(_ status: UInt8) -> (String, Color) {
        switch status {
        case 1: return ("checkmark.circle.fill", theme.gitAddedFg)
        case 2: return ("arrow.triangle.2.circlepath", theme.modelineBarFg.opacity(0.5))
        case 3: return ("arrow.triangle.2.circlepath", theme.modelineBarFg.opacity(0.5))
        case 4: return ("exclamationmark.triangle.fill", theme.gutterErrorFg)
        default: return ("circle", theme.modelineBarFg.opacity(0.3))
        }
    }

    // MARK: - Right segment

    @ViewBuilder
    private var rightSegment: some View {
        HStack(spacing: 8) {
            // Parser status (only when degraded)
            parserStatusIcon

            // LSP status
            if state.hasLsp {
                lspIndicator
            }

            // Devicon + filetype
            if !state.filetype.isEmpty {
                HStack(spacing: 3) {
                    if !state.icon.isEmpty {
                        Text(state.icon)
                            .font(.custom("Symbols Nerd Font Mono", size: 11))
                            .foregroundStyle(state.iconColor)
                    }
                    Text(state.filetype)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.modelineBarFg.opacity(0.6))
                }
            }

            // Cursor position
            Text("Ln \(state.cursorLine), Col \(state.cursorCol)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.modelineBarFg.opacity(0.7))

            // Vim mode badge
            modeBadge
        }
        .padding(.trailing, 8)
    }

    // MARK: - Parser status (only when degraded)

    @ViewBuilder
    private var parserStatusIcon: some View {
        switch state.parserStatus {
        case 1: // unavailable
            Image(systemName: "leaf.fill")
                .font(.system(size: 9))
                .foregroundStyle(theme.gutterErrorFg)
                .help("Tree-sitter parser unavailable")
        case 2: // restarting
            Image(systemName: "leaf.fill")
                .font(.system(size: 9))
                .foregroundStyle(theme.gutterWarningFg)
                .help("Tree-sitter parser restarting")
        default: // available: show nothing
            EmptyView()
        }
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
                    .foregroundStyle(theme.gutterErrorFg)
                Text("error")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.gutterErrorFg)
            }
        default: // idle — show nothing; no need to announce inactivity
            EmptyView()
        }
    }
}
