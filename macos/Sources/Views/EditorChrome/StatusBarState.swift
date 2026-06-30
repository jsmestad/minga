import SwiftUI
import MingaProtocol

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
    var safeMode: Bool = false
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
    var activeToolName: String = ""
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
    var modelineSegmentsPresent: Bool = false
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
        if self.safeMode != data.safeMode { self.safeMode = data.safeMode }
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
        if self.activeToolName != data.activeToolName { self.activeToolName = data.activeToolName }
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
        let hasModelineSegments = data.modelineSegmentsPresent || !data.modelineLeftSegments.isEmpty || !data.modelineRightSegments.isEmpty
        if self.modelineSegmentsPresent != hasModelineSegments { self.modelineSegmentsPresent = hasModelineSegments }
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
    var isSafeMode: Bool { safeMode }

    /// The macro register character (a-z), or nil if not recording.
    var macroRegister: Character? {
        guard macroRecording > 0, macroRecording <= 26 else { return nil }
        return Character(UnicodeScalar(96 + macroRecording))
    }

    /// Titleized filetype for display (e.g., "elixir" -> "Elixir", "c_sharp" -> "C Sharp").
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
