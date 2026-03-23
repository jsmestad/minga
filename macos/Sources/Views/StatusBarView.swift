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

    /// Updates status bar properties, guarding each assignment with an
    /// equality check to prevent redundant `@Observable` notifications.
    /// During j/k scroll, only cursorLine changes; the other ~25 fields
    /// stay the same. Without guards, every write fires a notification
    /// that invalidates the SwiftUI sub-view reading that property.
    func update(from data: StatusBarUpdate) {
        if self.contentKind != data.contentKind { self.contentKind = data.contentKind }
        if self.mode != data.mode { self.mode = data.mode }
        if self.cursorLine != data.cursorLine { self.cursorLine = data.cursorLine }
        if self.cursorCol != data.cursorCol { self.cursorCol = data.cursorCol }
        if self.lineCount != data.lineCount { self.lineCount = data.lineCount }
        if self.flags != data.flags { self.flags = data.flags }
        if self.lspStatus != data.lspStatus { self.lspStatus = data.lspStatus }
        if self.gitBranch != data.gitBranch { self.gitBranch = data.gitBranch }
        if self.message != data.message { self.message = data.message }
        if self.filetype != data.filetype { self.filetype = data.filetype }
        if self.errorCount != data.errorCount { self.errorCount = data.errorCount }
        if self.warningCount != data.warningCount { self.warningCount = data.warningCount }
        if self.modelName != data.modelName { self.modelName = data.modelName }
        if self.messageCount != data.messageCount { self.messageCount = data.messageCount }
        if self.sessionStatus != data.sessionStatus { self.sessionStatus = data.sessionStatus }
        if self.infoCount != data.infoCount { self.infoCount = data.infoCount }
        if self.hintCount != data.hintCount { self.hintCount = data.hintCount }
        if self.macroRecording != data.macroRecording { self.macroRecording = data.macroRecording }
        if self.parserStatus != data.parserStatus { self.parserStatus = data.parserStatus }
        if self.agentStatus != data.agentStatus { self.agentStatus = data.agentStatus }
        if self.gitAdded != data.gitAdded { self.gitAdded = data.gitAdded }
        if self.gitModified != data.gitModified { self.gitModified = data.gitModified }
        if self.gitDeleted != data.gitDeleted { self.gitDeleted = data.gitDeleted }
        if self.icon != data.icon { self.icon = data.icon }
        if self.iconColorR != data.iconColorR { self.iconColorR = data.iconColorR }
        if self.iconColorG != data.iconColorG { self.iconColorG = data.iconColorG }
        if self.iconColorB != data.iconColorB { self.iconColorB = data.iconColorB }
        if self.filename != data.filename { self.filename = data.filename }
        if self.diagnosticHint != data.diagnosticHint { self.diagnosticHint = data.diagnosticHint }
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
    var isFileTreeVisible: Bool = false
    var isGitStatusVisible: Bool = false
    var isBottomPanelVisible: Bool = false
    var isAgentChatVisible: Bool = false

    private let barHeight: CGFloat = 24

    var body: some View {
        ZStack {
            // Center (lowest priority, truncates first)
            centerSegment

            // Left-aligned (unified: same layout for buffer and agent)
            HStack(spacing: 0) {
                leftSegment
                Spacer(minLength: 0)
            }

            // Right-aligned (unified: same layout for buffer and agent)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                rightSegment
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
        if state.isRecordingMacro, let reg = state.macroRegister {
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

    // MARK: - Left segment

    @ViewBuilder
    private var leftSegment: some View {
        HStack(spacing: 2) {
            // File tree toggle
            StatusBarIconButton(
                icon: "sidebar.leading",
                isActive: isFileTreeVisible,
                accentFg: theme.statusbarAccentFg,
                barHeight: barHeight,
                barFg: theme.modelineBarFg,
                tooltip: "Toggle file tree (SPC o p)"
            ) {
                encoder?.sendTogglePanel(panel: 0)
            }

            // Source control toggle
            StatusBarIconButton(
                icon: "point.3.filled.connected.trianglepath.dotted",
                isActive: isGitStatusVisible,
                accentFg: theme.statusbarAccentFg,
                barHeight: barHeight,
                barFg: theme.modelineBarFg,
                tooltip: "Git status (SPC g g)"
            ) {
                encoder?.sendTogglePanel(panel: 2)
            }

            // Bottom panel toggle
            StatusBarIconButton(
                icon: "rectangle.bottomhalf.inset.filled",
                isActive: isBottomPanelVisible,
                accentFg: theme.statusbarAccentFg,
                barHeight: barHeight,
                barFg: theme.modelineBarFg,
                tooltip: "Toggle messages (SPC b m)"
            ) {
                encoder?.sendTogglePanel(panel: 1)
            }

            // Divider between toggle icons and informational segments
            Rectangle()
                .fill(theme.modelineBarFg.opacity(0.1))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 4)

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

    @State private var gitCopied = false

    @ViewBuilder
    private var gitSegment: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(state.gitBranch, forType: .string)
            gitCopied = true
            // Clear the "Copied" indicator after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                gitCopied = false
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: gitCopied ? "checkmark" : "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .medium))
                Text(gitCopied ? "Copied!" : state.gitBranch)
                    .font(.system(size: 11))
                    .lineLimit(1)

                // Diff stats: +added ~modified -deleted
                if !gitCopied, state.hasGitDiffStats {
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
        }
        .buttonStyle(.plain)
        .help("Click to copy branch name")
        .padding(.horizontal, 6)
        .onHover { isHovered in
            if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - LSP indicator (theme-colored)

    @ViewBuilder
    private var lspIndicator: some View {
        let info = lspInfo(state.lspStatus)
        Image(systemName: info.icon)
            .font(.system(size: 9))
            .foregroundStyle(info.color)
            .padding(.horizontal, 4)
            .help(info.tooltip)
    }

    // MARK: - Diagnostic counts (all 4 levels, theme-colored)

    @ViewBuilder
    private var diagnosticIndicators: some View {
        let hasAny = state.errorCount > 0 || state.warningCount > 0 || state.infoCount > 0 || state.hintCount > 0
        if hasAny {
            Button(action: {
                encoder?.sendTogglePanel(panel: 1)
            }) {
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
            }
            .buttonStyle(.plain)
            .help("Show diagnostics (SPC c d)")
            .padding(.horizontal, 4)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    private func lspInfo(_ status: UInt8) -> (icon: String, tooltip: String, color: Color) {
        switch status {
        case 1:  return ("checkmark.circle.fill",         "LSP: ready",         theme.gitAddedFg)
        case 2:  return ("arrow.triangle.2.circlepath",   "LSP: initializing…", theme.modelineBarFg.opacity(0.5))
        case 3:  return ("arrow.triangle.2.circlepath",   "LSP: starting…",     theme.modelineBarFg.opacity(0.5))
        case 4:  return ("exclamationmark.triangle.fill", "LSP: error",         theme.gutterErrorFg)
        default: return ("circle",                        "LSP: inactive",      theme.modelineBarFg.opacity(0.3))
        }
    }

    // MARK: - Right segment

    @ViewBuilder
    private var rightSegment: some View {
        HStack(spacing: 8) {
            // Agent chat toggle
            StatusBarIconButton(
                icon: "bubble.left.and.text.bubble.right",
                isActive: isAgentChatVisible,
                accentFg: theme.statusbarAccentFg,
                barHeight: barHeight,
                barFg: theme.modelineBarFg,
                tooltip: "Toggle agent chat (SPC a a)"
            ) {
                encoder?.sendTogglePanel(panel: 3)
            }

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
                .help(state.filetype)
            }

            // Cursor position / message count
            if state.isAgentWindow {
                Text("\(state.messageCount) msgs")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.7))
            } else {
                Text("Ln \(state.cursorLine), Col \(state.cursorCol)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.7))
                    .help("Line \(state.cursorLine), Column \(state.cursorCol)")
            }

            // Vim mode badge
            modeBadge
                .help("\(state.modeName) mode")
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
/// matching the Xcode / VS Code toolbar button aesthetic. Supports an
/// active/inactive state for panel toggle icons: active shows the accent
/// color at full opacity, inactive dims to 0.45 opacity.
private struct StatusBarIconButton: View {
    let icon: String
    var isActive: Bool = false
    var accentFg: Color = .accentColor
    let barHeight: CGFloat
    let barFg: Color
    var tooltip: String = ""
    let action: () -> Void

    @State private var isHovered = false

    private var iconColor: Color {
        if isActive {
            return accentFg
        }
        return barFg.opacity(isHovered ? 0.7 : 0.45)
    }

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: barHeight)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barFg.opacity(isHovered ? 0.08 : 0))
                        .padding(.horizontal, 2)
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: isActive
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}


