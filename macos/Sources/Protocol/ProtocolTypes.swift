/// Data types decoded from the BEAM's binary protocol.
///
/// All types live inside the `Wire` namespace to distinguish them from
/// SwiftUI view model types that share the same domain names. Protocol
/// types represent the raw wire format; view model types in `*State.swift`
/// files add `Identifiable`, computed properties, and Swift-native types.
///
/// Example: `Wire.TabEntry` is the decoded struct from the binary protocol.
/// `TabEntry` in `TabBarState.swift` is the SwiftUI view model.

import Foundation

/// Config setting value encoded in GUI config actions and state pushes.
enum SettingValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case atom(String)
    case float(Double)
}

/// Semantic severity for one editor notification.
enum NotificationLevel: Sendable, Equatable {
    case info
    case warning
    case error
    case success
    case progress
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .info
        case 1: self = .warning
        case 2: self = .error
        case 3: self = .success
        case 4: self = .progress
        default: self = .unknown(rawValue)
        }
    }

    var name: String {
        switch self {
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        case .success: return "success"
        case .progress: return "progress"
        case .unknown(let rawValue): return "unknown \(rawValue)"
        }
    }
}

/// Namespace for all binary protocol data types decoded from the BEAM.
enum Wire {

    // MARK: - Notifications

    /// A BEAM-owned editor notification decoded from gui_notifications.
    struct EditorNotification: Sendable {
        let id: String
        let level: NotificationLevel
        let flags: UInt8
        let createdAt: UInt64
        let updatedAt: UInt64
        let autoDismissMs: UInt32?
        let title: String
        let body: String
        let source: String
        let actions: [NotificationAction]

        var dismissable: Bool { flags & 0x01 != 0 }
    }

    /// An inline action decoded from a notification card.
    struct NotificationAction: Sendable {
        let id: String
        let label: String
    }

    // MARK: - Settings

    /// Complete or incremental settings state from the BEAM.
    struct ConfigState: Sendable {
        let options: [String: SettingValue]
        let themePreviews: [ThemePreview]
        let keybindings: [KeybindingEntry]
    }

    /// A compact built-in theme preview for the settings panel.
    struct ThemePreview: Sendable, Identifiable {
        let name: String
        let atom: String
        let editorBg: UInt32
        let editorFg: UInt32
        let accent: UInt32

        var id: String { atom }
    }

    /// A read-only keybinding row for the settings panel.
    struct KeybindingEntry: Sendable, Identifiable {
        let mode: String
        let key: String
        let command: String
        let description: String

        var id: String { "\(mode):\(key):\(command):\(description)" }
    }

    // MARK: - Tab bar

    /// A single tab entry decoded from the gui_tab_bar protocol message.
    struct TabEntry: Sendable {
        let id: UInt32
        let groupId: UInt16
        let isActive: Bool
        let isDirty: Bool
        let isAgent: Bool
        let hasAttention: Bool
        let agentStatus: UInt8
        let isPinned: Bool
        let tintColorRGB: UInt32
        let icon: String
        let label: String
    }

    /// A workspace entry decoded from the canonical gui_workspaces protocol message.
    struct WorkspaceEntry: Sendable {
        let id: UInt16
        let kind: UInt8
        let status: UInt8
        let flags: UInt16
        let colorR: UInt8
        let colorG: UInt8
        let colorB: UInt8
        let tabCount: UInt16
        let draftCount: UInt16
        let conflictCount: UInt16
        let runningBackgroundCount: UInt16
        let label: String
        let icon: String

        var agentStatus: UInt8 { status }
    }

    /// A visible file tab decoded from the canonical gui_workspaces protocol message.
    struct WorkspaceTabEntry: Sendable {
        let id: UInt32
        let workspaceId: UInt16
        let kind: UInt8
        let flags: UInt16
        let pathHash: UInt32
        let tintColorRGB: UInt32
        let icon: String
        let label: String
        let path: String
    }

    // MARK: - BEAM Observatory

    /// A single process node decoded from the BEAM Observatory protocol message.
    struct ObservatoryNode: Sendable {
        let pid: String
        let parentPid: String
        let name: String
        let processClass: UInt8
        let depth: UInt8
        let memory: UInt32
        let messageQueueLen: UInt16
        let reductions: UInt32
        let sparkline: [Float]
    }

    // MARK: - File tree

    /// A single file tree entry decoded from the semantic gui_file_tree protocol message.
    struct FileTreeEntry: Sendable {
        let pathHash: UInt32
        let id: String
        let path: String
        let isDir: Bool
        let isExpanded: Bool
        let isSelected: Bool
        let isFocused: Bool
        let isActive: Bool
        let isDirty: Bool
        let isEditing: Bool
        let isLastChild: Bool
        let depth: UInt8
        let gitStatus: UInt8
        let diagnosticErrorCount: UInt16
        let diagnosticWarningCount: UInt16
        let diagnosticInfoCount: UInt16
        let diagnosticHintCount: UInt16
        let guides: [Bool]
        let icon: String
        let name: String
        let relPath: String
        /// 0=new_file, 1=new_folder, 2=rename, 255=none.
        let editingType: UInt8
        /// Pre-filled text for the editing field.
        let editingText: String
    }

    // MARK: - Completion

    /// A completion item from gui_completion.
    struct CompletionItem: Sendable {
        let kind: UInt8
        let label: String
        let detail: String
    }

    // MARK: - Which key

    /// A which-key binding from gui_which_key.
    struct WhichKeyBinding: Sendable {
        let kind: UInt8  // 0 = command, 1 = group
        let key: String
        let description: String
        let icon: String
    }

    // MARK: - Status bar

    /// A configured modeline segment from the gui_status_bar modeline segment section.
    struct StatusBarSegment: Sendable, Equatable, Identifiable {
        let id: Int
        let kind: String
        let text: String
        let fgColor: UInt32
        let bgColor: UInt32
        let attrs: UInt8
        let command: String

        init(id: Int, kind: String = "custom", text: String, fgColor: UInt32, bgColor: UInt32, attrs: UInt8, command: String) {
            self.id = id
            self.kind = kind
            self.text = text
            self.fgColor = fgColor
            self.bgColor = bgColor
            self.attrs = attrs
            self.command = command
        }

        var isBold: Bool { attrs & 0x01 != 0 }
        var isUnderline: Bool { attrs & 0x02 != 0 }
        var isItalic: Bool { attrs & 0x04 != 0 }
    }

    // MARK: - Picker

    /// A picker item from gui_picker (v2 extended format).
    struct PickerItem: Sendable {
        let iconColor: UInt32  // 24-bit RGB
        let flags: UInt8       // bit 0: two_line, bit 1: marked
        let label: String
        let description: String
        let annotation: String
        let matchPositions: [UInt16]  // 0-based character indices of matched chars in label

        var isTwoLine: Bool { flags & 0x01 != 0 }
        var isMarked: Bool { flags & 0x02 != 0 }
    }

    /// An action menu for the picker (C-o menu).
    struct PickerActionMenu: Sendable {
        let selectedIndex: UInt8
        let actions: [String]
    }

    /// Async loading status for picker sources.
    enum PickerLoadStatus: Sendable, Equatable {
        case ready
        case loading
        case error(String)
    }

    /// A styled text segment for picker preview content.
    struct PickerPreviewSegment: Sendable {
        let fgColor: UInt32   // 24-bit RGB
        let bold: Bool
        let text: String
    }

    /// A line of preview content (array of styled segments).
    typealias PickerPreviewLine = [PickerPreviewSegment]

    // MARK: - Minibuffer

    struct MinibufferCandidate: Sendable {
        let matchScore: UInt8
        let label: String
        let description: String
        let annotation: String
        let matchPositions: [UInt16]
    }

    // MARK: - Hover popup

    /// Markdown style for a hover text segment.
    enum HoverStyle: UInt8, Sendable {
        case plain = 0
        case bold = 1
        case italic = 2
        case boldItalic = 3
        case code = 4
        case codeBlock = 5
        case codeContent = 6
        case header1 = 7
        case header2 = 8
        case header3 = 9
        case blockquote = 10
        case listBullet = 11
        case rule = 12
        case syntaxHighlighted = 13
    }

    /// Line type for hover content (block context).
    enum HoverLineType: UInt8, Sendable {
        case text = 0
        case code = 1
        case codeHeader = 2
        case header = 3
        case blockquote = 4
        case listItem = 5
        case rule = 6
        case empty = 7
    }

    /// A styled text segment within a hover line.
    struct HoverSegment: Sendable {
        let style: HoverStyle
        let fgColor: UInt32?
        let flags: UInt8
        let text: String
    }

    /// A line of hover content with its block type and styled segments.
    struct HoverLine: Sendable {
        let lineType: HoverLineType
        let segments: [HoverSegment]
    }

    // MARK: - Signature help

    /// A parameter in a function signature.
    struct SignatureParameter: Sendable {
        let label: String
        let documentation: String
    }

    /// A function signature with its parameters.
    struct Signature: Sendable {
        let label: String
        let documentation: String
        let parameters: [SignatureParameter]
    }

    // MARK: - Split separators

    /// A vertical split separator line.
    struct VerticalSeparator: Sendable {
        let col: UInt16
        let startRow: UInt16
        let endRow: UInt16
    }

    /// A horizontal split separator with a centered filename.
    struct HorizontalSeparator: Sendable {
        let row: UInt16
        let col: UInt16
        let width: UInt16
        let filename: String
    }

    // MARK: - Git status

    /// Raw decoded entry from gui_git_status protocol message.
    struct GitStatusEntry: Sendable {
        let pathHash: UInt32
        let section: UInt8
        let status: UInt8
        let path: String
    }

    // MARK: - Tool manager

    struct ToolEntry: Sendable {
        let name: String
        let label: String
        let description: String
        let category: UInt8
        let status: UInt8
        let method: UInt8
        let languages: [String]
        let version: String
        let homepage: String
        let provides: [String]
        let errorReason: String
    }

    // MARK: - Gutter

    /// Line number display style from the BEAM.
    enum LineNumberStyle: UInt8, Sendable {
        case hybrid = 0
        case absolute = 1
        case relative = 2
        case none = 3
    }

    /// Display type for a gutter row.
    enum GutterDisplayType: UInt8, Sendable {
        case normal = 0
        case foldStart = 1
        case foldContinuation = 2
        case wrapContinuation = 3
        case foldOpen = 4
    }

    /// Sign type for the gutter sign column.
    enum GutterSignType: UInt8, Sendable {
        case none = 0
        case gitAdded = 1
        case gitModified = 2
        case gitDeleted = 3
        case diagError = 4
        case diagWarning = 5
        case diagInfo = 6
        case diagHint = 7
        case annotation = 8
    }

    /// A single gutter entry for one visible line.
    struct GutterEntry: Sendable {
        let bufLine: UInt32
        let displayType: GutterDisplayType
        let signType: GutterSignType
        /// Annotation icon foreground color (24-bit RGB). Only valid when signType == .annotation.
        let signFg: UInt32
        /// Inclusive end line for the fold range when this row is foldable.
        let foldEndLine: UInt32?
        /// Annotation icon text. Only valid when signType == .annotation.
        let signText: String

        init(bufLine: UInt32, displayType: GutterDisplayType, signType: GutterSignType,
             foldEndLine: UInt32? = nil, signFg: UInt32 = 0, signText: String = "") {
            self.bufLine = bufLine
            self.displayType = displayType
            self.signType = signType
            self.foldEndLine = foldEndLine
            self.signFg = signFg
            self.signText = signText
        }
    }

    /// Gutter data for one window, including its screen position.
    /// One message per window arrives each frame.
    struct WindowGutter: Sendable {
        /// Window ID matching the gui_window_content (0x80) windowId.
        let windowId: UInt16
        /// Screen row where this window's content area begins.
        let contentRow: UInt16
        /// Screen column where this window's content area begins.
        let contentCol: UInt16
        /// Height of this window's content area in rows.
        let contentHeight: UInt16
        /// Whether this is the active (focused) window.
        let isActive: Bool
        /// Width of this window's content area in columns.
        let contentWidth: UInt16

        let cursorLine: UInt32
        let lineNumberStyle: LineNumberStyle
        let lineNumberWidth: UInt8
        let signColWidth: UInt8
        var entries: [GutterEntry]
    }

    // MARK: - Bottom panel

    /// A tab definition from gui_bottom_panel.
    struct BottomPanelTab: Sendable {
        let tabType: UInt8
        let name: String
    }

    /// A structured log entry from the Messages tab content.
    struct MessageEntry: Sendable {
        let id: UInt32
        let level: UInt8
        let subsystem: UInt8
        let timestampSecs: UInt32
        let filePath: String
        let text: String
    }

    // MARK: - Prompt completion

    /// Inline completion popup for the agent prompt (mention or slash command).
    struct PromptCompletion: Sendable {
        /// 0 = mention (@file), 1 = slash (/command).
        let type: UInt8
        let selected: UInt8
        let anchorLine: UInt16
        let anchorCol: UInt16
        let candidates: [(name: String, description: String)]
    }

    // MARK: - Agent chat

    /// A styled text run for GUI rendering. Carries pre-computed colors from the BEAM.
    struct StyledTextRun: Sendable {
        let text: String
        let fgR: UInt8
        let fgG: UInt8
        let fgB: UInt8
        let bgR: UInt8
        let bgG: UInt8
        let bgB: UInt8
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let linkURL: String?

        init(text: String, fgR: UInt8, fgG: UInt8, fgB: UInt8, bgR: UInt8, bgG: UInt8, bgB: UInt8, bold: Bool, italic: Bool, underline: Bool, linkURL: String? = nil) {
            self.text = text
            self.fgR = fgR
            self.fgG = fgG
            self.fgB = fgB
            self.bgR = bgR
            self.bgG = bgG
            self.bgB = bgB
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.linkURL = linkURL
        }
    }

    /// A help group from gui_agent_chat, containing a category title and keybindings.
    struct HelpGroup: Sendable {
        let title: String
        let bindings: [(key: String, description: String)]
    }

    /// A chat message from gui_agent_chat, with a stable BEAM-assigned ID.
    struct ChatMessage: Sendable {
        /// Stable uint32 ID assigned by the BEAM. Persists across streaming updates.
        let beamId: UInt32
        let content: ChatMessageContent
    }

    /// The payload of a chat message (type-specific data).
    enum ChatMessageContent: Sendable {
        case user(text: String)
        case assistant(text: String)
        /// Assistant message with pre-styled text runs from tree-sitter.
        case styledAssistant(lines: [[StyledTextRun]])
        case thinking(text: String, collapsed: Bool)
        case toolCall(name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, result: String)
        /// Tool call with pre-styled result runs from tree-sitter.
        case styledToolCall(name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, resultLines: [[StyledTextRun]])
        case approvalToolCall(name: String, summary: String, toolCallId: String, previewKind: UInt8, previewLines: [String])
        case system(text: String, isError: Bool)
        case usage(input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)
    }

    // MARK: - Edit timeline

    struct TimelineEntry: Sendable, Identifiable {
        let index: UInt8
        let toolName: String
        let timestampDelta: UInt32

        var id: Int { Int(index) }
    }

    // MARK: - Extension panels

    /// A content block in an extension panel.
    enum PanelContentBlock: Sendable {
        case text(String)
        case styledText(runs: [(text: String, r: UInt8, g: UInt8, b: UInt8, bold: Bool, italic: Bool)])
        case table(columns: [String], rows: [[String]], selected: UInt16)
        case keyValue(pairs: [(key: String, value: String)])
        case separator
        case progress(label: String, percent: Float)
        case tree(nodes: [PanelTreeNode])
        case unknown
    }

    /// A tree node in an extension panel.
    struct PanelTreeNode: Sendable {
        let label: String
        let expanded: Bool
        let children: [PanelTreeNode]
    }

    /// A panel registered by an extension.
    struct ExtensionPanelEntry: Sendable, Identifiable {
        let extensionName: String
        let panelID: String
        let title: String
        let position: UInt8
        let sizeType: UInt8
        let sizeValue: UInt8
        let visible: Bool
        let blocks: [PanelContentBlock]

        var id: String { "\(extensionName):\(panelID)" }
    }
}

/// Cursor shape matching the protocol constants.
enum CursorShape: UInt8, Sendable {
    case block = 0x00
    case beam = 0x01
    case underline = 0x02
}

/// Indent guide data from the BEAM (opcode 0x91).
struct IndentGuideData: Sendable {
    let windowId: UInt16
    let tabWidth: UInt8
    /// Character column of the active guide. 0xFFFF = no active guide.
    let activeGuideCol: UInt16
    /// Character columns where guides appear (content-relative, not screen-relative).
    let guideCols: [UInt16]
    /// Per visible line indent level. Empty if the sender omitted per-line data (legacy); renderer falls back to full-height guides.
    let lineIndentLevels: [UInt8]
}
