/// Typed snapshot of status bar data decoded from the BEAM.
///
/// Named fields prevent transposition bugs. Lives in the MingaProtocol
/// framework so both the app's `ProtocolDecoder` and the MingaUI preview
/// framework can construct and read it across the module boundary.

import Foundation

/// Typed snapshot of status bar data from the BEAM. Named fields prevent transposition bugs.
public struct StatusBarUpdate: Sendable {
    public struct IndentInfo: Sendable, Equatable {
        public let kind: UInt8
        public let size: UInt8

        public init(kind: UInt8, size: UInt8) {
            self.kind = kind
            self.size = size
        }
    }

    public struct SelectionInfo: Sendable, Equatable {
        public let mode: UInt8
        public let size: UInt32

        public init(mode: UInt8, size: UInt32) {
            self.mode = mode
            self.size = size
        }
    }

    public struct WorkspaceInfo: Sendable, Equatable {
        public let id: UInt16
        public let kind: UInt8
        public let status: UInt8
        public let flags: UInt16
        public let draftCount: UInt16
        public let conflictCount: UInt16
        public let backgroundCount: UInt16
        public let attentionCount: UInt16
        public let label: String
        public let icon: String

        public init(id: UInt16, kind: UInt8, status: UInt8, flags: UInt16, draftCount: UInt16, conflictCount: UInt16, backgroundCount: UInt16, attentionCount: UInt16, label: String, icon: String) {
            self.id = id
            self.kind = kind
            self.status = status
            self.flags = flags
            self.draftCount = draftCount
            self.conflictCount = conflictCount
            self.backgroundCount = backgroundCount
            self.attentionCount = attentionCount
            self.label = label
            self.icon = icon
        }
    }

    public let contentKind: UInt8
    public let mode: UInt8
    public let cursorLine: UInt32
    public let cursorCol: UInt32
    public let lineCount: UInt32
    public let flags: UInt8
    public let safeMode: Bool
    public let lspStatus: UInt8
    public let gitBranch: String
    public let message: String
    public let filetype: String
    public let errorCount: UInt16
    public let warningCount: UInt16
    public let modelName: String
    public let messageCount: UInt32
    public let sessionStatus: UInt8
    public let infoCount: UInt16
    public let hintCount: UInt16
    public let macroRecording: UInt8
    public let parserStatus: UInt8
    public let agentStatus: UInt8
    public let activeToolName: String
    public let gitAdded: UInt16
    public let gitModified: UInt16
    public let gitDeleted: UInt16
    public let icon: String
    public let iconColorR: UInt8
    public let iconColorG: UInt8
    public let iconColorB: UInt8
    public let filename: String
    public let diagnosticHint: String
    public let backgroundSubagentCount: UInt16
    public let backgroundSubagentLabel: String
    public let indent: IndentInfo
    public let modelineSegmentsPresent: Bool
    public let modelineLeftSegments: [Wire.StatusBarSegment]
    public let modelineRightSegments: [Wire.StatusBarSegment]
    public let selection: SelectionInfo
    public let workspace: WorkspaceInfo?

    public init(
        contentKind: UInt8,
        mode: UInt8,
        cursorLine: UInt32,
        cursorCol: UInt32,
        lineCount: UInt32,
        flags: UInt8,
        safeMode: Bool = false,
        lspStatus: UInt8,
        gitBranch: String,
        message: String,
        filetype: String,
        errorCount: UInt16,
        warningCount: UInt16,
        modelName: String,
        messageCount: UInt32,
        sessionStatus: UInt8,
        infoCount: UInt16,
        hintCount: UInt16,
        macroRecording: UInt8,
        parserStatus: UInt8,
        agentStatus: UInt8,
        activeToolName: String = "",
        gitAdded: UInt16,
        gitModified: UInt16,
        gitDeleted: UInt16,
        icon: String,
        iconColorR: UInt8,
        iconColorG: UInt8,
        iconColorB: UInt8,
        filename: String,
        diagnosticHint: String,
        backgroundSubagentCount: UInt16,
        backgroundSubagentLabel: String,
        indent: IndentInfo = .init(kind: 0, size: 2),
        modelineSegmentsPresent: Bool = false,
        modelineLeftSegments: [Wire.StatusBarSegment] = [],
        modelineRightSegments: [Wire.StatusBarSegment] = [],
        selection: SelectionInfo = .init(mode: 0, size: 0),
        workspace: WorkspaceInfo? = nil
    ) {
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
        self.workspace = workspace
    }
}
