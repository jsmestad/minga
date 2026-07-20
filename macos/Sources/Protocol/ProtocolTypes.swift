/// Data types decoded from the BEAM's binary protocol.
///
/// All types live inside the `Wire` namespace to distinguish them from
/// SwiftUI view model types that share the same domain names. Protocol
/// types represent the raw wire format; view model types in `*State.swift`
/// files add `Identifiable`, computed properties, and Swift-native types.
///
/// Example: `Wire.TabEntry` is the decoded struct from the binary protocol.
/// `TabEntry` in `TabBarState.swift` is the SwiftUI view model.
///
/// These value types live in the MingaProtocol framework (Metal-free,
/// Foundation-only) so the app and the MingaUI preview framework can share
/// them across a module boundary. Every type is `public` and every struct
/// constructed outside this module carries an explicit `public init`.

import Foundation

/// Config setting value encoded in GUI config actions and state pushes.
public enum SettingValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case atom(String)
    case float(Double)
}

/// Semantic severity for one editor notification.
public enum NotificationLevel: Sendable, Equatable {
    case info
    case warning
    case error
    case success
    case progress
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .info
        case 1: self = .warning
        case 2: self = .error
        case 3: self = .success
        case 4: self = .progress
        default: self = .unknown(rawValue)
        }
    }

    public var name: String {
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
public enum Wire {

    // MARK: - Sidebars

    /// Semantic sidebar metadata decoded from the BEAM sidebar host payload.
    public struct SidebarMetadata: Sendable, Equatable, Identifiable {
        public let id: String
        public let displayName: String
        public let semanticKind: String
        public let icon: String
        public let order: UInt16
        public let visible: Bool
        public let focused: Bool
        public let preferredWidth: UInt16
        public let badgeCount: UInt16?

        public init(id: String, displayName: String, semanticKind: String, icon: String, order: UInt16, visible: Bool, focused: Bool, preferredWidth: UInt16, badgeCount: UInt16?) {
            self.id = id
            self.displayName = displayName
            self.semanticKind = semanticKind
            self.icon = icon
            self.order = order
            self.visible = visible
            self.focused = focused
            self.preferredWidth = preferredWidth
            self.badgeCount = badgeCount
        }
    }

    // MARK: - Notifications

    /// A BEAM-owned editor notification decoded from gui_notifications.
    public struct EditorNotification: Sendable {
        public let id: String
        public let level: NotificationLevel
        public let flags: UInt8
        public let createdAt: UInt64
        public let updatedAt: UInt64
        public let autoDismissMs: UInt32?
        public let title: String
        public let body: String
        public let source: String
        public let actions: [NotificationAction]

        public var dismissable: Bool { flags & 0x01 != 0 }

        public init(id: String, level: NotificationLevel, flags: UInt8, createdAt: UInt64, updatedAt: UInt64, autoDismissMs: UInt32?, title: String, body: String, source: String, actions: [NotificationAction]) {
            self.id = id
            self.level = level
            self.flags = flags
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.autoDismissMs = autoDismissMs
            self.title = title
            self.body = body
            self.source = source
            self.actions = actions
        }
    }

    /// An inline action decoded from a notification card.
    public struct NotificationAction: Sendable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    // MARK: - Settings

    /// Complete or incremental settings state from the BEAM.
    public struct ConfigState: Sendable {
        public let options: [String: SettingValue]
        public let themePreviews: [ThemePreview]
        public let keybindings: [KeybindingEntry]

        public init(options: [String: SettingValue], themePreviews: [ThemePreview], keybindings: [KeybindingEntry]) {
            self.options = options
            self.themePreviews = themePreviews
            self.keybindings = keybindings
        }
    }

    /// A compact built-in theme preview for the settings panel.
    public struct ThemePreview: Sendable, Identifiable {
        public let name: String
        public let atom: String
        public let editorBg: UInt32
        public let editorFg: UInt32
        public let accent: UInt32

        public var id: String { atom }

        public init(name: String, atom: String, editorBg: UInt32, editorFg: UInt32, accent: UInt32) {
            self.name = name
            self.atom = atom
            self.editorBg = editorBg
            self.editorFg = editorFg
            self.accent = accent
        }
    }

    /// A read-only keybinding row for the settings panel.
    public struct KeybindingEntry: Sendable, Identifiable {
        public let mode: String
        public let key: String
        public let command: String
        public let description: String

        public var id: String { "\(mode):\(key):\(command):\(description)" }

        public init(mode: String, key: String, command: String, description: String) {
            self.mode = mode
            self.key = key
            self.command = command
            self.description = description
        }
    }

    // MARK: - Tab bar

    /// A single tab entry decoded from the gui_tab_bar protocol message.
    ///
    /// Flag bits 4-6 are kind-scoped: agent tabs carry the agent status
    /// there; file tabs use bit 4 as the ephemeral (not-on-disk) marker.
    public struct TabEntry: Sendable {
        public let id: UInt32
        public let groupId: UInt16
        public let isActive: Bool
        public let isDirty: Bool
        public let isAgent: Bool
        public let hasAttention: Bool
        public let agentStatus: UInt8
        public let isPinned: Bool
        public let isEphemeral: Bool
        public let tintColorRGB: UInt32
        public let icon: String
        public let label: String

        public init(id: UInt32, groupId: UInt16, isActive: Bool, isDirty: Bool, isAgent: Bool, hasAttention: Bool, agentStatus: UInt8, isPinned: Bool, isEphemeral: Bool = false, tintColorRGB: UInt32, icon: String, label: String) {
            self.id = id
            self.groupId = groupId
            self.isActive = isActive
            self.isDirty = isDirty
            self.isAgent = isAgent
            self.hasAttention = hasAttention
            self.agentStatus = agentStatus
            self.isPinned = isPinned
            self.isEphemeral = isEphemeral
            self.tintColorRGB = tintColorRGB
            self.icon = icon
            self.label = label
        }
    }

    // MARK: - Launchpad empty state

    /// A single launchpad row decoded from the gui_empty_state protocol message (0xA5).
    ///
    /// `kind`: 0=resume, 1=recent_file, 2=action, 3=hint. The BEAM sends semantic
    /// data only; the frontend owns all layout. `jumpKey` (single instant key),
    /// `chord` (space-separated keystroke tokens), and a `detail` beginning with
    /// ":" select one of three input-visual treatments.
    public struct EmptyStateItem: Sendable, Identifiable {
        public let kind: UInt8
        public let id: String
        public let label: String
        public let detail: String
        public let jumpKey: String
        public let chord: String
        public let icon: String
        public let iconColorRGB: UInt32

        public init(kind: UInt8, id: String, label: String, detail: String, jumpKey: String, chord: String, icon: String, iconColorRGB: UInt32) {
            self.kind = kind
            self.id = id
            self.label = label
            self.detail = detail
            self.jumpKey = jumpKey
            self.chord = chord
            self.icon = icon
            self.iconColorRGB = iconColorRGB
        }
    }

    /// A launchpad section decoded from gui_empty_state (0xA5).
    ///
    /// `sectionId`: 0=session, 1=recent, 2=start, 3=footer.
    public struct EmptyStateSection: Sendable, Identifiable {
        public let sectionId: UInt8
        public let title: String
        public let items: [EmptyStateItem]

        public var id: UInt8 { sectionId }

        public init(sectionId: UInt8, title: String, items: [EmptyStateItem]) {
            self.sectionId = sectionId
            self.title = title
            self.items = items
        }
    }

    /// A workspace entry decoded from the canonical gui_workspaces protocol message.
    public struct WorkspaceEntry: Sendable {
        public let id: UInt16
        public let kind: UInt8
        public let status: UInt8
        public let flags: UInt16
        public let colorR: UInt8
        public let colorG: UInt8
        public let colorB: UInt8
        public let tabCount: UInt16
        public let draftCount: UInt16
        public let conflictCount: UInt16
        public let runningBackgroundCount: UInt16
        public let label: String
        public let icon: String

        public var agentStatus: UInt8 { status }

        public init(id: UInt16, kind: UInt8, status: UInt8, flags: UInt16, colorR: UInt8, colorG: UInt8, colorB: UInt8, tabCount: UInt16, draftCount: UInt16, conflictCount: UInt16, runningBackgroundCount: UInt16, label: String, icon: String) {
            self.id = id
            self.kind = kind
            self.status = status
            self.flags = flags
            self.colorR = colorR
            self.colorG = colorG
            self.colorB = colorB
            self.tabCount = tabCount
            self.draftCount = draftCount
            self.conflictCount = conflictCount
            self.runningBackgroundCount = runningBackgroundCount
            self.label = label
            self.icon = icon
        }
    }

    /// A visible file tab decoded from the canonical gui_workspaces protocol message.
    public struct WorkspaceTabEntry: Sendable {
        public let id: UInt32
        public let workspaceId: UInt16
        public let kind: UInt8
        public let flags: UInt16
        public let pathHash: UInt32
        public let tintColorRGB: UInt32
        public let icon: String
        public let label: String
        public let path: String

        public init(id: UInt32, workspaceId: UInt16, kind: UInt8, flags: UInt16, pathHash: UInt32, tintColorRGB: UInt32, icon: String, label: String, path: String) {
            self.id = id
            self.workspaceId = workspaceId
            self.kind = kind
            self.flags = flags
            self.pathHash = pathHash
            self.tintColorRGB = tintColorRGB
            self.icon = icon
            self.label = label
            self.path = path
        }
    }

    // MARK: - BEAM Observatory

    /// A single process node decoded from the BEAM Observatory protocol message.
    public struct ObservatoryNode: Sendable {
        public let pid: String
        public let parentPid: String
        public let name: String
        public let processClass: UInt8
        public let depth: UInt8
        public let memory: UInt32
        public let messageQueueLen: UInt16
        public let reductions: UInt32
        public let sparkline: [Float]

        public init(pid: String, parentPid: String, name: String, processClass: UInt8, depth: UInt8, memory: UInt32, messageQueueLen: UInt16, reductions: UInt32, sparkline: [Float]) {
            self.pid = pid
            self.parentPid = parentPid
            self.name = name
            self.processClass = processClass
            self.depth = depth
            self.memory = memory
            self.messageQueueLen = messageQueueLen
            self.reductions = reductions
            self.sparkline = sparkline
        }
    }

    // MARK: - File tree

    /// A single file tree entry decoded from the semantic gui_file_tree protocol message.
    public struct FileTreeEntry: Sendable {
        public let pathHash: UInt32
        public let id: String
        public let path: String
        public let isDir: Bool
        public let isExpanded: Bool
        public let isSelected: Bool
        public let isFocused: Bool
        public let isActive: Bool
        public let isDirty: Bool
        public let isEditing: Bool
        public let isLastChild: Bool
        public let depth: UInt8
        public let gitStatus: UInt8
        public let diagnosticErrorCount: UInt16
        public let diagnosticWarningCount: UInt16
        public let diagnosticInfoCount: UInt16
        public let diagnosticHintCount: UInt16
        public let guides: [Bool]
        public let icon: String
        /// Per-row icon color (R, G, B), resolved from the active theme's icon palette.
        public let iconColorR: UInt8
        public let iconColorG: UInt8
        public let iconColorB: UInt8
        public let name: String
        public let relPath: String
        /// 0=new_file, 1=new_folder, 2=rename, 255=none.
        public let editingType: UInt8
        /// Pre-filled text for the editing field.
        public let editingText: String
        /// Extension-contributed familiarity/heat bucket 0...4, or 255 for none.
        public let heatLevel: UInt8

        public init(pathHash: UInt32, id: String, path: String, isDir: Bool, isExpanded: Bool, isSelected: Bool, isFocused: Bool, isActive: Bool, isDirty: Bool, isEditing: Bool, isLastChild: Bool, depth: UInt8, gitStatus: UInt8, diagnosticErrorCount: UInt16, diagnosticWarningCount: UInt16, diagnosticInfoCount: UInt16, diagnosticHintCount: UInt16, guides: [Bool], icon: String, iconColorR: UInt8, iconColorG: UInt8, iconColorB: UInt8, name: String, relPath: String, editingType: UInt8, editingText: String, heatLevel: UInt8 = 255) {
            self.pathHash = pathHash
            self.id = id
            self.path = path
            self.isDir = isDir
            self.isExpanded = isExpanded
            self.isSelected = isSelected
            self.isFocused = isFocused
            self.isActive = isActive
            self.isDirty = isDirty
            self.isEditing = isEditing
            self.isLastChild = isLastChild
            self.depth = depth
            self.gitStatus = gitStatus
            self.diagnosticErrorCount = diagnosticErrorCount
            self.diagnosticWarningCount = diagnosticWarningCount
            self.diagnosticInfoCount = diagnosticInfoCount
            self.diagnosticHintCount = diagnosticHintCount
            self.guides = guides
            self.icon = icon
            self.iconColorR = iconColorR
            self.iconColorG = iconColorG
            self.iconColorB = iconColorB
            self.name = name
            self.relPath = relPath
            self.editingType = editingType
            self.editingText = editingText
            self.heatLevel = heatLevel
        }
    }

    // MARK: - Completion

    /// A completion item from gui_completion.
    public struct CompletionItem: Sendable {
        public let kind: UInt8
        public let label: String
        public let detail: String

        public init(kind: UInt8, label: String, detail: String) {
            self.kind = kind
            self.label = label
            self.detail = detail
        }
    }

    // MARK: - Which key

    /// A which-key binding from gui_which_key.
    public struct WhichKeyBinding: Sendable {
        public let kind: UInt8  // 0 = command, 1 = group
        public let key: String
        public let description: String
        public let icon: String

        public init(kind: UInt8, key: String, description: String, icon: String) {
            self.kind = kind
            self.key = key
            self.description = description
            self.icon = icon
        }
    }

    // MARK: - Status bar

    /// A configured modeline segment from the gui_status_bar modeline segment section.
    public struct StatusBarSegment: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: String
        public let text: String
        public let fgColor: UInt32
        public let bgColor: UInt32
        public let attrs: UInt8
        public let command: String

        public init(id: Int, kind: String = "custom", text: String, fgColor: UInt32, bgColor: UInt32, attrs: UInt8, command: String) {
            self.id = id
            self.kind = kind
            self.text = text
            self.fgColor = fgColor
            self.bgColor = bgColor
            self.attrs = attrs
            self.command = command
        }

        public var isBold: Bool { attrs & 0x01 != 0 }
        public var isUnderline: Bool { attrs & 0x02 != 0 }
        public var isItalic: Bool { attrs & 0x04 != 0 }
    }

    // MARK: - Picker

    /// A picker item from gui_picker (v2 extended format).
    public struct PickerItem: Sendable {
        public let iconColor: UInt32  // 24-bit RGB
        public let flags: UInt8       // bit 0: two_line, bit 1: marked
        public let label: String
        public let description: String
        public let annotation: String
        public let matchPositions: [UInt16]  // 0-based character indices of matched chars in label

        public var isTwoLine: Bool { flags & 0x01 != 0 }
        public var isMarked: Bool { flags & 0x02 != 0 }

        public init(iconColor: UInt32, flags: UInt8, label: String, description: String, annotation: String, matchPositions: [UInt16]) {
            self.iconColor = iconColor
            self.flags = flags
            self.label = label
            self.description = description
            self.annotation = annotation
            self.matchPositions = matchPositions
        }
    }

    /// An action menu for the picker (C-o menu).
    public struct PickerActionMenu: Sendable {
        public let selectedIndex: UInt8
        public let actions: [String]

        public init(selectedIndex: UInt8, actions: [String]) {
            self.selectedIndex = selectedIndex
            self.actions = actions
        }
    }

    /// Async loading status for picker sources.
    public enum PickerLoadStatus: Sendable, Equatable {
        case ready
        case loading
        case error(String)
    }

    /// A styled text segment for picker preview content.
    public struct PickerPreviewSegment: Sendable {
        public let fgColor: UInt32   // 24-bit RGB
        public let bold: Bool
        public let text: String

        public init(fgColor: UInt32, bold: Bool, text: String) {
            self.fgColor = fgColor
            self.bold = bold
            self.text = text
        }
    }

    /// A line of preview content (array of styled segments).
    public typealias PickerPreviewLine = [PickerPreviewSegment]

    // MARK: - Minibuffer

    public struct MinibufferCandidate: Sendable {
        public let matchScore: UInt8
        public let label: String
        public let description: String
        public let annotation: String
        public let matchPositions: [UInt16]

        public init(matchScore: UInt8, label: String, description: String, annotation: String, matchPositions: [UInt16]) {
            self.matchScore = matchScore
            self.label = label
            self.description = description
            self.annotation = annotation
            self.matchPositions = matchPositions
        }
    }

    // MARK: - Hover popup

    /// Markdown style for a hover text segment.
    public enum HoverStyle: UInt8, Sendable {
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
    public enum HoverLineType: UInt8, Sendable {
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
    public struct HoverSegment: Sendable {
        public let style: HoverStyle
        public let fgColor: UInt32?
        public let flags: UInt8
        public let text: String

        public init(style: HoverStyle, fgColor: UInt32?, flags: UInt8, text: String) {
            self.style = style
            self.fgColor = fgColor
            self.flags = flags
            self.text = text
        }
    }

    /// A line of hover content with its block type and styled segments.
    public struct HoverLine: Sendable {
        public let lineType: HoverLineType
        public let segments: [HoverSegment]

        public init(lineType: HoverLineType, segments: [HoverSegment]) {
            self.lineType = lineType
            self.segments = segments
        }
    }

    // MARK: - Signature help

    /// A parameter in a function signature.
    public struct SignatureParameter: Sendable {
        public let label: String
        public let documentation: String

        public init(label: String, documentation: String) {
            self.label = label
            self.documentation = documentation
        }
    }

    /// A function signature with its parameters.
    public struct Signature: Sendable {
        public let label: String
        public let documentation: String
        public let parameters: [SignatureParameter]

        public init(label: String, documentation: String, parameters: [SignatureParameter]) {
            self.label = label
            self.documentation = documentation
            self.parameters = parameters
        }
    }

    // MARK: - Split separators

    /// A vertical split separator line.
    public struct VerticalSeparator: Sendable {
        public let col: UInt16
        public let startRow: UInt16
        public let endRow: UInt16

        public init(col: UInt16, startRow: UInt16, endRow: UInt16) {
            self.col = col
            self.startRow = startRow
            self.endRow = endRow
        }
    }

    /// A horizontal split separator with a centered filename.
    public struct HorizontalSeparator: Sendable {
        public let row: UInt16
        public let col: UInt16
        public let width: UInt16
        public let filename: String

        public init(row: UInt16, col: UInt16, width: UInt16, filename: String) {
            self.row = row
            self.col = col
            self.width = width
            self.filename = filename
        }
    }

    // MARK: - Git status

    /// Raw decoded entry from gui_git_status protocol message.
    public struct GitStatusEntry: Sendable {
        public let pathHash: UInt32
        public let section: UInt8
        public let status: UInt8
        public let path: String

        public init(pathHash: UInt32, section: UInt8, status: UInt8, path: String) {
            self.pathHash = pathHash
            self.section = section
            self.status = status
            self.path = path
        }
    }


    // MARK: - Gutter

    /// Line number display style from the BEAM.
    public enum LineNumberStyle: UInt8, Sendable {
        case hybrid = 0
        case absolute = 1
        case relative = 2
        case none = 3
    }

    /// Display type for a gutter row.
    public enum GutterDisplayType: UInt8, Sendable {
        case normal = 0
        case foldStart = 1
        case foldContinuation = 2
        case wrapContinuation = 3
        case foldOpen = 4
        case blank = 5
    }

    /// Sign type for the gutter sign column.
    public enum GutterSignType: UInt8, Sendable {
        case none = 0
        case gitAdded = 1
        case gitModified = 2
        case gitDeleted = 3
        case diagError = 4
        case diagWarning = 5
        case diagInfo = 6
        case diagHint = 7
        case annotation = 8
        case gitRemoved = 9
        case diagAdvisory = 10
    }

    /// A single gutter entry for one visible line.
    public struct GutterEntry: Sendable {
        public let bufLine: UInt32
        public let displayType: GutterDisplayType
        public let signType: GutterSignType
        /// Annotation icon foreground color (24-bit RGB). Only valid when signType == .annotation.
        public let signFg: UInt32
        /// Inclusive end line for the fold range when this row is foldable.
        public let foldEndLine: UInt32?
        /// Annotation icon text. Only valid when signType == .annotation.
        public let signText: String

        public init(bufLine: UInt32, displayType: GutterDisplayType, signType: GutterSignType,
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
    public struct WindowGutter: Sendable {
        /// Window ID matching the gui_window_content (0x80) windowId.
        public let windowId: UInt16
        /// Screen row where this window's content area begins.
        public let contentRow: UInt16
        /// Screen column where this window's content area begins.
        public let contentCol: UInt16
        /// Height of this window's content area in rows.
        public let contentHeight: UInt16
        /// Whether this is the active (focused) window.
        public let isActive: Bool
        /// Width of this window's content area in columns.
        public let contentWidth: UInt16

        public let cursorLine: UInt32
        public let lineNumberStyle: LineNumberStyle
        public let lineNumberWidth: UInt8
        public let signColWidth: UInt8
        public var entries: [GutterEntry]

        public init(windowId: UInt16, contentRow: UInt16, contentCol: UInt16, contentHeight: UInt16, isActive: Bool, contentWidth: UInt16, cursorLine: UInt32, lineNumberStyle: LineNumberStyle, lineNumberWidth: UInt8, signColWidth: UInt8, entries: [GutterEntry]) {
            self.windowId = windowId
            self.contentRow = contentRow
            self.contentCol = contentCol
            self.contentHeight = contentHeight
            self.isActive = isActive
            self.contentWidth = contentWidth
            self.cursorLine = cursorLine
            self.lineNumberStyle = lineNumberStyle
            self.lineNumberWidth = lineNumberWidth
            self.signColWidth = signColWidth
            self.entries = entries
        }
    }

    // MARK: - Bottom panel

    /// A tab definition from gui_bottom_panel.
    public struct BottomPanelTab: Sendable {
        public let tabType: UInt8
        public let name: String

        public init(tabType: UInt8, name: String) {
            self.tabType = tabType
            self.name = name
        }
    }

    /// A structured log entry from the Messages tab content.
    public struct MessageEntry: Sendable {
        public let streamInstance: UInt32
        public let id: UInt32
        public let level: UInt8
        public let subsystem: UInt8
        public let timestampSecs: UInt32
        public let filePath: String
        public let text: String

        public init(streamInstance: UInt32, id: UInt32, level: UInt8, subsystem: UInt8, timestampSecs: UInt32, filePath: String, text: String) {
            self.streamInstance = streamInstance
            self.id = id
            self.level = level
            self.subsystem = subsystem
            self.timestampSecs = timestampSecs
            self.filePath = filePath
            self.text = text
        }
    }

    // MARK: - Prompt completion

    /// Inline completion popup for the agent prompt (mention or slash command).
    public struct PromptCompletion: Sendable {
        /// 0 = mention (@file), 1 = slash (/command).
        public let type: UInt8
        public let selected: UInt8
        public let anchorLine: UInt16
        public let anchorCol: UInt16
        public let candidates: [(name: String, description: String)]

        public init(type: UInt8, selected: UInt8, anchorLine: UInt16, anchorCol: UInt16, candidates: [(name: String, description: String)]) {
            self.type = type
            self.selected = selected
            self.anchorLine = anchorLine
            self.anchorCol = anchorCol
            self.candidates = candidates
        }
    }

    // MARK: - Agent chat

    /// A styled text run for GUI rendering. Carries pre-computed colors from the BEAM.
    public struct StyledTextRun: Sendable {
        public let text: String
        public let fgR: UInt8
        public let fgG: UInt8
        public let fgB: UInt8
        public let bgR: UInt8
        public let bgG: UInt8
        public let bgB: UInt8
        public let bold: Bool
        public let italic: Bool
        public let underline: Bool
        public let code: Bool
        public let linkURL: String?

        public init(text: String, fgR: UInt8, fgG: UInt8, fgB: UInt8, bgR: UInt8, bgG: UInt8, bgB: UInt8, bold: Bool, italic: Bool, underline: Bool, code: Bool = false, linkURL: String? = nil) {
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
            self.code = code
            self.linkURL = linkURL
        }
    }

    /// A help group from gui_agent_chat, containing a category title and keybindings.
    public struct HelpGroup: Sendable {
        public let title: String
        public let bindings: [(key: String, description: String)]

        public init(title: String, bindings: [(key: String, description: String)]) {
            self.title = title
            self.bindings = bindings
        }
    }

    /// Semantic markdown block kind from gui_agent_chat assistant_markdown messages.
    public enum AgentMarkdownBlockKind: UInt8, Sendable {
        case paragraph = 0x01
        case heading = 0x02
        case listItem = 0x03
        case blockquote = 0x04
        case rule = 0x05
        case spacer = 0x06
        case codeBlock = 0x07
    }

    /// BEAM-authored semantic markdown block. Frontends render this structure directly and never infer block semantics from styled-run flags.
    public struct AgentMarkdownBlock: Sendable, Identifiable {
        public let id: UInt32
        public let kind: AgentMarkdownBlockKind
        public let flags: UInt8
        public let lines: [[StyledTextRun]]
        public let level: UInt8
        public let indent: UInt8
        public let ordered: Bool
        public let ordinal: UInt32
        public let height: UInt8
        public let language: String
        public let label: String
        public let targetPath: String
        public let capabilityFlags: UInt8

        public var isComplete: Bool { flags & 0x01 != 0 }

        public init(id: UInt32, kind: AgentMarkdownBlockKind, flags: UInt8, lines: [[StyledTextRun]], level: UInt8, indent: UInt8, ordered: Bool, ordinal: UInt32, height: UInt8, language: String, label: String, targetPath: String, capabilityFlags: UInt8) {
            self.id = id
            self.kind = kind
            self.flags = flags
            self.lines = lines
            self.level = level
            self.indent = indent
            self.ordered = ordered
            self.ordinal = ordinal
            self.height = height
            self.language = language
            self.label = label
            self.targetPath = targetPath
            self.capabilityFlags = capabilityFlags
        }
    }

    /// A chat message from gui_agent_transcript, with a stable BEAM-assigned ID.
    public struct ChatMessage: Sendable {
        /// Stable uint32 ID assigned by the BEAM. Persists across streaming updates.
        public let beamId: UInt32
        public let content: ChatMessageContent

        public init(beamId: UInt32, content: ChatMessageContent) {
            self.beamId = beamId
            self.content = content
        }
    }

    /// The payload of a chat message (type-specific data).
    public enum ChatMessageContent: Sendable {
        case user(text: String)
        case assistant(text: String)
        /// Assistant message with pre-styled text runs from tree-sitter.
        case styledAssistant(lines: [[StyledTextRun]])
        /// Assistant message with BEAM-authored semantic markdown blocks.
        case assistantMarkdown(blocks: [AgentMarkdownBlock])
        case thinking(text: String, collapsed: Bool)
        case toolCall(name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, result: String, previewKind: UInt8, previewLines: [String])
        /// Tool call with pre-styled result runs from tree-sitter.
        case styledToolCall(name: String, summary: String, status: UInt8, isError: Bool, collapsed: Bool, autoApprovedScope: UInt8, durationMs: UInt32, resultLines: [[StyledTextRun]], previewKind: UInt8, previewLines: [String])
        case approvalToolCall(name: String, summary: String, toolCallId: String, previewKind: UInt8, previewLines: [String])
        case system(text: String, isError: Bool)
        case usage(input: UInt32, output: UInt32, cacheRead: UInt32, cacheWrite: UInt32, costMicros: UInt32)
    }

    // MARK: - Edit timeline

    public struct AgentProgress: Sendable, Equatable {
        public let activeAction: String
        public let toolCount: UInt16
        public let fileCount: UInt16
        public let reviewHint: String

        public init(activeAction: String, toolCount: UInt16, fileCount: UInt16, reviewHint: String) {
            self.activeAction = activeAction
            self.toolCount = toolCount
            self.fileCount = fileCount
            self.reviewHint = reviewHint
        }
    }

    public struct AgentTodo: Sendable, Identifiable, Equatable {
        public let status: UInt8
        public let description: String

        public var id: String { "\(status):\(description)" }

        public init(status: UInt8, description: String) {
            self.status = status
            self.description = description
        }
    }

    public struct TimelineEntry: Sendable, Identifiable {
        public let index: UInt8
        public let toolName: String
        public let timestampDelta: UInt32

        public var id: Int { Int(index) }

        public init(index: UInt8, toolName: String, timestampDelta: UInt32) {
            self.index = index
            self.toolName = toolName
            self.timestampDelta = timestampDelta
        }
    }

    public struct TimelineFile: Sendable, Identifiable, Equatable {
        public let path: String
        public let entryCount: UInt8
        public let linesAdded: UInt32
        public let linesRemoved: UInt32
        public let reviewStatus: UInt8

        public var id: String { path }

        public init(path: String, entryCount: UInt8, linesAdded: UInt32, linesRemoved: UInt32, reviewStatus: UInt8) {
            self.path = path
            self.entryCount = entryCount
            self.linesAdded = linesAdded
            self.linesRemoved = linesRemoved
            self.reviewStatus = reviewStatus
        }
    }

    // MARK: - Extension overlays

    /// An overlay entry from an extension, decoded from gui_extension_overlay (0x9C).
    public struct ExtensionOverlayEntry: Sendable, Identifiable, Equatable {
        public let extensionName: String
        public let overlayID: String
        public let windowID: UInt16
        public let row: UInt16
        public let col: UInt16
        public let shape: UInt8
        public let colorR: UInt8
        public let colorG: UInt8
        public let colorB: UInt8
        public let opacity: UInt8
        public let content: String

        public var id: String { "\(extensionName):\(overlayID)" }

        public init(extensionName: String, overlayID: String, windowID: UInt16, row: UInt16, col: UInt16, shape: UInt8, colorR: UInt8, colorG: UInt8, colorB: UInt8, opacity: UInt8, content: String) {
            self.extensionName = extensionName
            self.overlayID = overlayID
            self.windowID = windowID
            self.row = row
            self.col = col
            self.shape = shape
            self.colorR = colorR
            self.colorG = colorG
            self.colorB = colorB
            self.opacity = opacity
            self.content = content
        }
    }

    // MARK: - Extension panels

    /// A content block in an extension panel.
    public enum PanelContentBlock: Sendable {
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
    public struct PanelTreeNode: Sendable {
        public let label: String
        public let expanded: Bool
        public let children: [PanelTreeNode]

        public init(label: String, expanded: Bool, children: [PanelTreeNode]) {
            self.label = label
            self.expanded = expanded
            self.children = children
        }
    }

    /// A panel registered by an extension.
    public struct ExtensionPanelEntry: Sendable, Identifiable {
        public let extensionName: String
        public let panelID: String
        public let title: String
        public let position: UInt8
        public let sizeType: UInt8
        public let sizeValue: UInt8
        public let visible: Bool
        public let blocks: [PanelContentBlock]

        public var id: String { "\(extensionName):\(panelID)" }

        public init(extensionName: String, panelID: String, title: String, position: UInt8, sizeType: UInt8, sizeValue: UInt8, visible: Bool, blocks: [PanelContentBlock]) {
            self.extensionName = extensionName
            self.panelID = panelID
            self.title = title
            self.position = position
            self.sizeType = sizeType
            self.sizeValue = sizeValue
            self.visible = visible
            self.blocks = blocks
        }
    }
}

/// Cursor shape matching the protocol constants.
public enum CursorShape: UInt8, Sendable {
    case block = 0x00
    case beam = 0x01
    case underline = 0x02
}

/// Indent guide data from the BEAM (opcode 0x91).
public struct IndentGuideData: Sendable {
    public let windowId: UInt16
    public let tabWidth: UInt8
    /// Character column of the active guide. 0xFFFF = no active guide.
    public let activeGuideCol: UInt16
    /// Character columns where guides appear (content-relative, not screen-relative).
    public let guideCols: [UInt16]
    /// Per visible line indent level. Empty if the sender omitted per-line data (legacy); renderer falls back to full-height guides.
    public let lineIndentLevels: [UInt8]

    public init(windowId: UInt16, tabWidth: UInt8, activeGuideCol: UInt16, guideCols: [UInt16], lineIndentLevels: [UInt8]) {
        self.windowId = windowId
        self.tabWidth = tabWidth
        self.activeGuideCol = activeGuideCol
        self.guideCols = guideCols
        self.lineIndentLevels = lineIndentLevels
    }
}
