/// Native status bar at the bottom of the editor window.
///
/// Matches Zed's compact bottom bar: left icons, center message, right
/// position + mode indicator. All colors driven by BEAM theme.

import SwiftUI

@MainActor
@Observable
final class StatusBarState {
    var mode: UInt8 = 0
    var cursorLine: UInt32 = 1
    var cursorCol: UInt32 = 1
    var lineCount: UInt32 = 1
    var flags: UInt8 = 0
    var lspStatus: UInt8 = 0
    var gitBranch: String = ""
    var message: String = ""
    var filetype: String = ""

    func update(mode: UInt8, cursorLine: UInt32, cursorCol: UInt32, lineCount: UInt32,
                flags: UInt8, lspStatus: UInt8, gitBranch: String, message: String, filetype: String) {
        self.mode = mode
        self.cursorLine = cursorLine
        self.cursorCol = cursorCol
        self.lineCount = lineCount
        self.flags = flags
        self.lspStatus = lspStatus
        self.gitBranch = gitBranch
        self.message = message
        self.filetype = filetype
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
}

struct StatusBarView: View {
    let state: StatusBarState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let barHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            // Left: panel toggle icons
            leftSegment

            Spacer()

            // Center: status message
            if !state.message.isEmpty {
                Text(state.message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Right: position + mode
            rightSegment
        }
        .frame(height: barHeight)
        .background(theme.modelineBarBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    // MARK: - Left segment

    @ViewBuilder
    private var leftSegment: some View {
        HStack(spacing: 2) {
            // File tree toggle
            statusButton(icon: "sidebar.leading") {
                (encoder as? ProtocolEncoder)?.sendTogglePanel(panel: 0)
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

    @ViewBuilder
    private func statusButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.modelineBarFg.opacity(0.6))
                .frame(width: 26, height: barHeight)
        }
        .buttonStyle(.plain)
    }
}
