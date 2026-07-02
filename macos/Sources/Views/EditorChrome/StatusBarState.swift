import SwiftUI
import MingaProtocol

@MainActor
@Observable
public final class StatusBarState {
    public init(contentKind: UInt8 = 0, mode: UInt8 = 0, cursorLine: UInt32 = 1, cursorCol: UInt32 = 1, lineCount: UInt32 = 1, flags: UInt8 = 0, safeMode: Bool = false, lspStatus: UInt8 = 0, gitBranch: String = "", message: String = "", filetype: String = "", errorCount: UInt16 = 0, warningCount: UInt16 = 0, modelName: String = "", messageCount: UInt32 = 0, sessionStatus: UInt8 = 0, infoCount: UInt16 = 0, hintCount: UInt16 = 0, macroRecording: UInt8 = 0, parserStatus: UInt8 = 0, agentStatus: UInt8 = 0, activeToolName: String = "", gitAdded: UInt16 = 0, gitModified: UInt16 = 0, gitDeleted: UInt16 = 0, icon: String = "", iconColorR: UInt8 = 0, iconColorG: UInt8 = 0, iconColorB: UInt8 = 0, filename: String = "", diagnosticHint: String = "", backgroundSubagentCount: UInt16 = 0, backgroundSubagentLabel: String = "", indent: StatusBarUpdate.IndentInfo = .init(kind: 0, size: 2), modelineSegmentsPresent: Bool = false, modelineLeftSegments: [Wire.StatusBarSegment] = [], modelineRightSegments: [Wire.StatusBarSegment] = [], selection: StatusBarUpdate.SelectionInfo = .init(mode: 0, size: 0), pendingKeys: String = "") {
        self.contentKind = contentKind
        self.mode = mode
        self.cursorLine = cursorLine
        self.cursorCol = cursorCol
        self.lineCount = lineCount
        self.flags = flags
        self.safeMode = safeMode
        self.lspStatus = lspStatus
        self.gitBranch = gitBranch
        self.message = message
        self.filetype = filetype
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.modelName = modelName
        self.messageCount = messageCount
        self.sessionStatus = sessionStatus
        self.infoCount = infoCount
        self.hintCount = hintCount
        self.macroRecording = macroRecording
        self.parserStatus = parserStatus
        self.agentStatus = agentStatus
        self.activeToolName = activeToolName
        self.gitAdded = gitAdded
        self.gitModified = gitModified
        self.gitDeleted = gitDeleted
        self.icon = icon
        self.iconColorR = iconColorR
        self.iconColorG = iconColorG
        self.iconColorB = iconColorB
        self.filename = filename
        self.diagnosticHint = diagnosticHint
        self.backgroundSubagentCount = backgroundSubagentCount
        self.backgroundSubagentLabel = backgroundSubagentLabel
        self.indent = indent
        self.modelineSegmentsPresent = modelineSegmentsPresent
        self.modelineLeftSegments = modelineLeftSegments
        self.modelineRightSegments = modelineRightSegments
        self.selection = selection
        self.pendingKeys = pendingKeys
    }
    /// 0 = buffer window, 1 = agent chat window.
    public var contentKind: UInt8 = 0
    public var mode: UInt8 = 0
    public var cursorLine: UInt32 = 1
    public var cursorCol: UInt32 = 1
    public var lineCount: UInt32 = 1
    public var flags: UInt8 = 0
    public var safeMode: Bool = false
    public var lspStatus: UInt8 = 0
    public var gitBranch: String = ""
    public var message: String = ""
    public var filetype: String = ""
    public var errorCount: UInt16 = 0
    public var warningCount: UInt16 = 0
    // Agent-only fields
    public var modelName: String = ""
    public var messageCount: UInt32 = 0
    public var sessionStatus: UInt8 = 0
    // Extended fields (TUI modeline parity)
    public var infoCount: UInt16 = 0
    public var hintCount: UInt16 = 0
    public var macroRecording: UInt8 = 0
    public var parserStatus: UInt8 = 0
    public var agentStatus: UInt8 = 0
    public var activeToolName: String = ""
    public var gitAdded: UInt16 = 0
    public var gitModified: UInt16 = 0
    public var gitDeleted: UInt16 = 0
    public var icon: String = ""
    public var iconColorR: UInt8 = 0
    public var iconColorG: UInt8 = 0
    public var iconColorB: UInt8 = 0
    public var filename: String = ""
    public var diagnosticHint: String = ""
    public var backgroundSubagentCount: UInt16 = 0
    public var backgroundSubagentLabel: String = ""
    public var indent: StatusBarUpdate.IndentInfo = .init(kind: 0, size: 2)
    public var modelineSegmentsPresent: Bool = false
    public var modelineLeftSegments: [Wire.StatusBarSegment] = []
    public var modelineRightSegments: [Wire.StatusBarSegment] = []
    public var selection: StatusBarUpdate.SelectionInfo = .init(mode: 0, size: 0)
    /// vim showcmd: pending key sequence echoed instantly. Empty when nothing is pending.
    public var pendingKeys: String = ""

    /// Updates status bar properties, guarding each assignment with an
    /// equality check to prevent redundant `@Observable` notifications.
    /// During j/k scroll, only cursorLine changes; the other ~25 fields
    /// stay the same. Without guards, every write fires a notification
    /// that invalidates the SwiftUI sub-view reading that property.
    public func update(from data: StatusBarUpdate) {
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
        if self.pendingKeys != data.pendingKeys { self.pendingKeys = data.pendingKeys }
    }

    public var modeName: String {
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

    public var hasGit: Bool { flags & 0x02 != 0 }
    public var hasLsp: Bool { flags & 0x01 != 0 }
    public var isDirty: Bool { flags & 0x04 != 0 }
    public var isInsertMode: Bool { mode == 1 }
    public var isAgentWindow: Bool { contentKind == 1 }
    public var isRecordingMacro: Bool { macroRecording > 0 }
    public var hasGitDiffStats: Bool { gitAdded > 0 || gitModified > 0 || gitDeleted > 0 }
    public var hasRunningBackgroundSubagents: Bool { backgroundSubagentCount > 0 }
    public var isSafeMode: Bool { safeMode }

    /// The macro register character (a-z), or nil if not recording.
    public var macroRegister: Character? {
        guard macroRecording > 0, macroRecording <= 26 else { return nil }
        return Character(UnicodeScalar(96 + macroRecording))
    }

    /// Titleized filetype for display (e.g., "elixir" -> "Elixir", "c_sharp" -> "C Sharp").
    public var filetypeDisplay: String {
        filetype
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Icon color as a SwiftUI Color from the 24-bit RGB components.
    public var iconColor: Color {
        Color(
            red: Double(iconColorR) / 255.0,
            green: Double(iconColorG) / 255.0,
            blue: Double(iconColorB) / 255.0
        )
    }

    public var sessionStatusName: String {
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
