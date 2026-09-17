import SwiftUI
import MingaProtocol

@MainActor
@Observable
public final class StatusBarState {
    public init(contentKind: EditorContentKind = .buffer, mode: EditorMode = .normal, cursorLine: UInt32 = 1, cursorCol: UInt32 = 1, lineCount: UInt32 = 1, flags: StatusBarFlags = [], lspStatus: UInt8 = 0, gitBranch: String = "", message: String = "", filetype: String = "", errorCount: UInt16 = 0, warningCount: UInt16 = 0, modelName: String = "", messageCount: UInt32 = 0, sessionStatus: AgentStatus = .idle, infoCount: UInt16 = 0, hintCount: UInt16 = 0, macroRecording: UInt8 = 0, parserStatus: UInt8 = 0, agentStatus: AgentStatus = .idle, activeToolName: String = "", gitAdded: UInt16 = 0, gitModified: UInt16 = 0, gitDeleted: UInt16 = 0, icon: String = "", iconColorR: UInt8 = 0, iconColorG: UInt8 = 0, iconColorB: UInt8 = 0, filename: String = "", diagnosticHint: String = "", backgroundSubagentCount: UInt16 = 0, backgroundSubagentLabel: String = "", indent: StatusBarUpdate.IndentInfo = .init(kind: 0, size: 2), modelineSegmentsPresent: Bool = false, modelineLeftSegments: [Wire.StatusBarSegment] = [], modelineRightSegments: [Wire.StatusBarSegment] = [], selection: StatusBarUpdate.SelectionInfo = .init(mode: 0, size: 0), pendingKeys: String = "") {
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
    public var contentKind: EditorContentKind = .buffer
    public var mode: EditorMode = .normal
    public var cursorLine: UInt32 = 1
    public var cursorCol: UInt32 = 1
    public var lineCount: UInt32 = 1
    public var flags: StatusBarFlags = []
    public var lspStatus: UInt8 = 0
    public var gitBranch: String = ""
    public var message: String = ""
    public var filetype: String = ""
    public var errorCount: UInt16 = 0
    public var warningCount: UInt16 = 0
    // Agent-only fields
    public var modelName: String = ""
    public var messageCount: UInt32 = 0
    public var sessionStatus: AgentStatus = .idle
    // Extended fields (TUI modeline parity)
    public var infoCount: UInt16 = 0
    public var hintCount: UInt16 = 0
    public var macroRecording: UInt8 = 0
    public var parserStatus: UInt8 = 0
    public var agentStatus: AgentStatus = .idle
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

    /// Clears status and mode authority when the BEAM connection is replaced.
    public func resetProtocolConnection() {
        contentKind = .buffer
        mode = .normal
        cursorLine = 1
        cursorCol = 1
        lineCount = 1
        flags = []
        lspStatus = 0
        gitBranch = ""
        message = ""
        filetype = ""
        errorCount = 0
        warningCount = 0
        modelName = ""
        messageCount = 0
        sessionStatus = .idle
        infoCount = 0
        hintCount = 0
        macroRecording = 0
        parserStatus = 0
        agentStatus = .idle
        activeToolName = ""
        gitAdded = 0
        gitModified = 0
        gitDeleted = 0
        icon = ""
        iconColorR = 0
        iconColorG = 0
        iconColorB = 0
        filename = ""
        diagnosticHint = ""
        backgroundSubagentCount = 0
        backgroundSubagentLabel = ""
        indent = .init(kind: 0, size: 2)
        modelineSegmentsPresent = false
        modelineLeftSegments = []
        modelineRightSegments = []
        selection = .init(mode: 0, size: 0)
        pendingKeys = ""
    }

    public var modeName: String {
        switch mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .command: return "COMMAND"
        case .operatorPending: return "O-PENDING"
        case .search: return "SEARCH"
        case .replace: return "REPLACE"
        case .unknown: return "NORMAL"
        }
    }

    public var hasGit: Bool { flags.contains(.hasGit) }
    public var hasLsp: Bool { flags.contains(.hasLSP) }
    public var isDirty: Bool { flags.contains(.dirty) }
    public var isInsertMode: Bool { mode == .insert }
    public var isAgentWindow: Bool { contentKind == .agent }
    public var isRecordingMacro: Bool { macroRecording > 0 }
    public var hasGitDiffStats: Bool { gitAdded > 0 || gitModified > 0 || gitDeleted > 0 }
    public var hasRunningBackgroundSubagents: Bool { backgroundSubagentCount > 0 }
    public var isSafeMode: Bool { flags.contains(.safeMode) }

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
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .executingTool: return "executing"
        case .error: return "error"
        case .planning: return "plan"
        case .unknown: return "unknown"
        }
    }
}
