/// Native status bar at the bottom of the editor window.
///
/// Matches Zed's compact bottom bar: left icons, center message, right
/// position + mode indicator. All colors driven by BEAM theme.

import SwiftUI

private extension StatusBarUpdate.IndentInfo {
    var label: String {
        kind == 1 ? "Tabs" : "Spaces"
    }
}

private extension StatusBarUpdate.SelectionInfo {
    var isActive: Bool {
        mode != 0 && size > 0
    }

    var displayText: String {
        switch mode {
        case 1: return "\(size) chars"
        case 2: return "\(size) lines"
        default: return ""
        }
    }
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
    var backgroundSubagentCount: UInt16 = 0
    var backgroundSubagentLabel: String = ""
    var indent: StatusBarUpdate.IndentInfo = .init(kind: 0, size: 2)
    var modelineLeftSegments: [Wire.StatusBarSegment] = []
    var modelineRightSegments: [Wire.StatusBarSegment] = []
    var selection: StatusBarUpdate.SelectionInfo = .init(mode: 0, size: 0)

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
        if self.backgroundSubagentCount != data.backgroundSubagentCount { self.backgroundSubagentCount = data.backgroundSubagentCount }
        if self.backgroundSubagentLabel != data.backgroundSubagentLabel { self.backgroundSubagentLabel = data.backgroundSubagentLabel }
        if self.indent != data.indent { self.indent = data.indent }
        if self.modelineLeftSegments != data.modelineLeftSegments { self.modelineLeftSegments = data.modelineLeftSegments }
        if self.modelineRightSegments != data.modelineRightSegments { self.modelineRightSegments = data.modelineRightSegments }
        if self.selection != data.selection { self.selection = data.selection }
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
    var hasRunningBackgroundSubagents: Bool { backgroundSubagentCount > 0 }

    /// The macro register character (a-z), or nil if not recording.
    var macroRegister: Character? {
        guard macroRecording > 0, macroRecording <= 26 else { return nil }
        return Character(UnicodeScalar(96 + macroRecording))
    }

    /// Titleized filetype for display (e.g., "elixir" → "Elixir", "c_sharp" → "C Sharp").
    var filetypeDisplay: String {
        filetype
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
        case 4: return "plan"
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
    var gitSyncing: Bool = false

    private let barHeight: CGFloat = 24
    private let sideSpacing: CGFloat = 8
    private let leftFixedControlsWidth: CGFloat = 101
    private let rightFixedControlsWidth: CGFloat = 34
    private let maxCenterStatusWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let layout = modelineLayout(totalWidth: proxy.size.width)

            HStack(spacing: 0) {
                leftStatusZone(layout)
                    .frame(width: layout.leftRect.width, height: barHeight, alignment: .leading)
                    .clipped()
                    .contentShape(Rectangle())

                centerSegment
                    .frame(width: layout.centerRect.width, height: barHeight, alignment: .center)
                    .clipped()
                    .contentShape(Rectangle())

                rightStatusZone(layout)
                    .frame(width: layout.rightRect.width, height: barHeight, alignment: .trailing)
                    .clipped()
                    .contentShape(Rectangle())
            }
            .frame(width: layout.totalWidth, height: barHeight, alignment: .leading)
        }
        .frame(height: barHeight)
        .background(theme.modelineBarBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    func modelineLayout(totalWidth: CGFloat) -> StatusBarModelineLayout {
        StatusBarModelineLayout.compute(
            totalWidth: totalWidth,
            barHeight: barHeight,
            hasCenter: hasCenterStatus,
            leftFixedWidth: leftFixedControlsWidth,
            rightFixedWidth: rightFixedControlsWidth,
            sideSpacing: sideSpacing,
            maxCenterWidth: maxCenterStatusWidth,
            leftWeight: segmentTextWeight(state.modelineLeftSegments),
            rightWeight: segmentTextWeight(state.modelineRightSegments)
        )
    }

    func modelineLayoutBudgets(totalWidth: CGFloat) -> (leftModeline: CGFloat, rightModeline: CGFloat, center: CGFloat) {
        let layout = modelineLayout(totalWidth: totalWidth)
        return (layout.leftModelineWidth, layout.rightModelineWidth, layout.centerRect.width)
    }

    private var hasCenterStatus: Bool {
        state.isRecordingMacro || !state.message.isEmpty || !state.diagnosticHint.isEmpty
    }

    private func segmentTextWeight(_ segments: [Wire.StatusBarSegment]) -> CGFloat {
        CGFloat(max(0, segments.reduce(0) { $0 + $1.text.count }))
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

    // MARK: - Left fixed controls

    @ViewBuilder
    private var leftFixedControls: some View {
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
        }
    }

    // MARK: - Right fixed controls

    @ViewBuilder
    private var rightFixedControls: some View {
        HStack(spacing: 0) {
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
        }
        .padding(.trailing, 8)
    }

    private func leftStatusZone(_ layout: StatusBarModelineLayout) -> some View {
        HStack(spacing: sideSpacing) {
            leftFixedControls
                .frame(width: min(leftFixedControlsWidth, layout.leftRect.width), height: barHeight, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())


            boundedConfiguredModelineSegments(
                state.modelineLeftSegments,
                width: layout.leftModelineWidth,
                alignment: .leading
            )
        }
        .frame(width: layout.leftRect.width, height: barHeight, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }

    private func rightStatusZone(_ layout: StatusBarModelineLayout) -> some View {
        HStack(spacing: sideSpacing) {
            boundedConfiguredModelineSegments(
                state.modelineRightSegments,
                width: layout.rightModelineWidth,
                alignment: .trailing
            )

            rightFixedControls
                .frame(width: min(rightFixedControlsWidth, layout.rightRect.width), height: barHeight, alignment: .trailing)
                .clipped()
                .contentShape(Rectangle())
        }
        .frame(width: layout.rightRect.width, height: barHeight, alignment: .trailing)
        .clipped()
        .contentShape(Rectangle())
    }

    private func boundedConfiguredModelineSegments(_ segments: [Wire.StatusBarSegment], width: CGFloat, alignment: Alignment) -> some View {
        configuredModelineSegments(segments)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, height: barHeight, alignment: alignment)
            .contentShape(Rectangle())
            .clipped()
    }

    private func configuredModelineSegments(_ segments: [Wire.StatusBarSegment]) -> some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                StatusBarModelineSegmentView(segment: segment, encoder: encoder)
            }
        }
        .contentShape(Rectangle())
    }

}

struct StatusBarModelineLayout: Equatable {
    let totalWidth: CGFloat
    let leftRect: CGRect
    let centerRect: CGRect
    let rightRect: CGRect
    let leftModelineWidth: CGFloat
    let rightModelineWidth: CGFloat

    var centerIsProtected: Bool {
        leftRect.maxX <= centerRect.minX && rightRect.minX >= centerRect.maxX
    }

    static func compute(
        totalWidth: CGFloat,
        barHeight: CGFloat,
        hasCenter: Bool,
        leftFixedWidth: CGFloat,
        rightFixedWidth: CGFloat,
        sideSpacing: CGFloat,
        maxCenterWidth: CGFloat,
        leftWeight: CGFloat,
        rightWeight: CGFloat
    ) -> StatusBarModelineLayout {
        let safeWidth = max(0, totalWidth)
        let leftMinimum = leftFixedWidth + sideSpacing
        let rightMinimum = rightFixedWidth + sideSpacing
        let sideMinimum = max(leftMinimum, rightMinimum)
        let centerCapacity = max(0, safeWidth - (sideMinimum * 2))
        let centerWidth = hasCenter ? min(maxCenterWidth, safeWidth * 0.34, centerCapacity) : 0

        if centerWidth > 0 {
            let sideWidth = max(0, (safeWidth - centerWidth) / 2)
            let centerX = sideWidth
            let rightX = centerX + centerWidth
            return StatusBarModelineLayout(
                totalWidth: safeWidth,
                leftRect: CGRect(x: 0, y: 0, width: sideWidth, height: barHeight),
                centerRect: CGRect(x: centerX, y: 0, width: centerWidth, height: barHeight),
                rightRect: CGRect(x: rightX, y: 0, width: max(0, safeWidth - rightX), height: barHeight),
                leftModelineWidth: max(0, sideWidth - leftMinimum),
                rightModelineWidth: max(0, sideWidth - rightMinimum)
            )
        }

        let leftZoneWidth = noCenterLeftZoneWidth(
            safeWidth: safeWidth,
            leftMinimum: leftMinimum,
            rightMinimum: rightMinimum,
            leftWeight: leftWeight,
            rightWeight: rightWeight
        )
        let rightZoneWidth = max(0, safeWidth - leftZoneWidth)

        return StatusBarModelineLayout(
            totalWidth: safeWidth,
            leftRect: CGRect(x: 0, y: 0, width: leftZoneWidth, height: barHeight),
            centerRect: CGRect(x: leftZoneWidth, y: 0, width: 0, height: barHeight),
            rightRect: CGRect(x: leftZoneWidth, y: 0, width: rightZoneWidth, height: barHeight),
            leftModelineWidth: max(0, leftZoneWidth - leftMinimum),
            rightModelineWidth: max(0, rightZoneWidth - rightMinimum)
        )
    }

    private static func noCenterLeftZoneWidth(
        safeWidth: CGFloat,
        leftMinimum: CGFloat,
        rightMinimum: CGFloat,
        leftWeight: CGFloat,
        rightWeight: CGFloat
    ) -> CGFloat {
        if safeWidth <= leftMinimum {
            return safeWidth
        }

        if safeWidth <= leftMinimum + rightMinimum {
            return leftMinimum
        }

        let flexibleWidth = safeWidth - leftMinimum - rightMinimum
        let totalWeight = leftWeight + rightWeight
        let leftFlexibleWidth = totalWeight > 0 ? flexibleWidth * (leftWeight / totalWeight) : flexibleWidth / 2
        return leftMinimum + leftFlexibleWidth
    }
}

// MARK: - Configured modeline segment

enum StatusBarModelineFont {
    static func containsPrivateUseGlyph(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            isPrivateUseScalar(scalar.value)
        }
    }

    private static func isPrivateUseScalar(_ value: UInt32) -> Bool {
        (value >= 0xE000 && value <= 0xF8FF) ||
            (value >= 0xF0000 && value <= 0xFFFFD) ||
            (value >= 0x100000 && value <= 0x10FFFD)
    }
}

private struct StatusBarModelineSegmentView: View {
    let segment: Wire.StatusBarSegment
    let encoder: InputEncoder?

    var body: some View {
        if segment.command.isEmpty {
            segmentText
                .contentShape(Rectangle())
        } else {
            Button(action: {
                encoder?.sendExecuteCommand(name: segment.command)
            }) {
                segmentText
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(segment.command)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    @ViewBuilder
    private var segmentText: some View {
        let text = Text(segment.text)
            .font(segmentFont)
            .fontWeight(segmentFontWeight)
            .foregroundStyle(color(segment.fgColor))
            .lineLimit(1)
            .truncationMode(.tail)
            .underline(segment.isUnderline)

        if segment.isItalic {
            text
                .italic()
                .frame(minHeight: 24, maxHeight: 24, alignment: .center)
                .background(color(segment.bgColor))
                .contentShape(Rectangle())
                .clipped()
        } else {
            text
                .frame(minHeight: 24, maxHeight: 24, alignment: .center)
                .background(color(segment.bgColor))
                .contentShape(Rectangle())
                .clipped()
        }
    }

    private var segmentFont: Font {
        if StatusBarModelineFont.containsPrivateUseGlyph(segment.text) {
            return .custom("Symbols Nerd Font Mono", size: 11)
        }

        return .system(size: 11)
    }

    private var segmentFontWeight: Font.Weight {
        segment.isBold ? .semibold : .regular
    }

    private func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
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


