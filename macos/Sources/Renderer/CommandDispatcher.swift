/// Routes decoded protocol commands to the LineBuffer and triggers rendering.
///
/// Handles region tracking (define/clear/destroy/set_active) with coordinate
/// offset and clipping, matching the Zig renderer.zig logic.

import Foundation
import AppKit

/// Tracks a defined region for coordinate offset/clipping.
struct Region {
    let id: UInt16
    let parentId: UInt16
    let role: UInt8
    let row: UInt16
    let col: UInt16
    let width: UInt16
    let height: UInt16
    let zOrder: UInt8
}

/// Dispatches render commands to a LineBuffer and notifies when a frame is complete.
@MainActor
final class CommandDispatcher {
    /// Line-based styled run buffer for CoreText rendering.
    let lineBuffer: LineBuffer

    private var regions: [UInt16: Region] = [:]
    private var activeRegion: Region?

    /// Font manager for per-span font family support.
    var fontManager: FontManager?

    /// Called after each `batch_end` command. The renderer hooks into
    /// this to trigger a GPU frame.
    var onFrameReady: (() -> Void)?

    /// Called when the window title should change.
    var onTitleChanged: ((String) -> Void)?

    /// Called when the BEAM sends a window background color (RGB).
    var onWindowBgChanged: ((NSColor) -> Void)?

    /// Called when the BEAM sends a font configuration change.
    /// Parameters: family, size, ligatures, weight byte.
    var onFontChanged: ((String, UInt16, Bool, UInt8) -> Void)?

    /// Called when the editor mode changes (for accessibility announcements).
    /// Parameter: mode name string (e.g., "NORMAL", "INSERT", "VISUAL").
    var onModeChanged: ((String) -> Void)?

    /// Tracks the last mode to detect changes.
    private var lastMode: UInt8 = 0

    /// All GUI chrome sub-states. Injected at init from AppDelegate.
    /// Non-optional: forgetting to wire this is a compile-time error.
    let guiState: GUIState

    init(cols: UInt16, rows: UInt16, guiState: GUIState) {
        self.lineBuffer = LineBuffer(cols: cols, rows: rows)
        self.guiState = guiState
    }

    /// Process a single render command.
    func dispatch(_ command: RenderCommand) {
        switch command {
        case .clear:
            lineBuffer.clear()

        case .drawText(let row, let col, let fg, let bg, let attrs, let text):
            drawText(row: row, col: col, fg: fg, bg: bg, attrs: attrs, text: text)

        case .drawStyledText(let row, let col, let fg, let bg, let attrs16, let ulColor, _, let fontWeight, let fontId, let text):
            let attrs8 = UInt8(attrs16 & 0xFF)
            let ulStyle = UInt8((attrs16 >> UL_STYLE_SHIFT) & UL_STYLE_MASK)
            drawText(row: row, col: col, fg: fg, bg: bg, attrs: attrs8, text: text,
                     underlineColor: ulColor, underlineStyle: ulStyle, fontWeight: fontWeight,
                     fontId: fontId)

        case .setCursor(let row, let col):
            var absRow = row
            var absCol = col
            if let region = activeRegion {
                absRow &+= region.row
                absCol &+= region.col
            }
            lineBuffer.showCursor(col: absCol, row: absRow)

        case .setCursorShape(let shape):
            switch shape {
            case .block: lineBuffer.cursorShape = .block
            case .beam: lineBuffer.cursorShape = .beam
            case .underline: lineBuffer.cursorShape = .underline
            }

        case .batchEnd:
            onFrameReady?()

        case .setTitle(let title):
            onTitleChanged?(title)

        case .setWindowBg(let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            lineBuffer.defaultBg = rgb
            let color = NSColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
            PortLogger.info("Window bg received: r=\(r) g=\(g) b=\(b)")
            onWindowBgChanged?(color)

        case .defineRegion(let id, let parentId, let role, let row, let col, let width, let height, let zOrder):
            let region = Region(id: id, parentId: parentId, role: role, row: row, col: col, width: width, height: height, zOrder: zOrder)
            regions[id] = region

        case .clearRegion(let id):
            if let region = regions[id] {
                lineBuffer.clearRect(col: region.col, row: region.row, width: region.width, height: region.height)
            }

        case .destroyRegion(let id):
            if let region = regions[id] {
                lineBuffer.clearRect(col: region.col, row: region.row, width: region.width, height: region.height)
            }
            regions.removeValue(forKey: id)
            if activeRegion?.id == id {
                activeRegion = nil
            }

        case .setActiveRegion(let id):
            if id == 0 {
                activeRegion = nil
            } else {
                activeRegion = regions[id]
            }

        case .setFont(let family, let size, let ligatures, let weight):
            onFontChanged?(family, size, ligatures, weight)

        case .setFontFallback(let families):
            fontManager?.primary.setFallbackFonts(families)

        case .registerFont(let id, let family):
            fontManager?.registerFont(id: id, name: family)

        case .guiTheme(let slots):
            guiState.themeColors.applySlots(slots)

        case .guiTabBar(let activeIndex, let tabs):
            guiState.tabBarState.update(activeIndex: activeIndex, entries: tabs)

        case .guiFileTree(let selectedIndex, let treeWidth, let entries):
            if entries.isEmpty {
                guiState.fileTreeState.hide()
            } else {
                guiState.fileTreeState.update(selectedIndex: selectedIndex, treeWidth: treeWidth, rawEntries: entries)
            }

        case .guiCompletion(let visible, let anchorRow, let anchorCol, let selectedIndex, let items):
            if visible {
                guiState.completionState.update(visible: true, anchorRow: anchorRow, anchorCol: anchorCol, selectedIndex: selectedIndex, rawItems: items)
            } else {
                guiState.completionState.hide()
            }

        case .guiWhichKey(let visible, let prefix, let page, let pageCount, let bindings):
            if visible {
                guiState.whichKeyState.update(visible: true, prefix: prefix, page: page, pageCount: pageCount, rawBindings: bindings)
            } else {
                guiState.whichKeyState.hide()
            }

        case .guiBreadcrumb(let segments):
            guiState.breadcrumbState.update(segments: segments)

        case .guiStatusBar(let contentKind, let mode, let cursorLine, let cursorCol, let lineCount, let flags, let lspStatus, let gitBranch, let message, let filetype, let errorCount, let warningCount, let modelName, let messageCount, let sessionStatus):
            guiState.statusBarState.update(contentKind: contentKind, mode: mode, cursorLine: cursorLine, cursorCol: cursorCol, lineCount: lineCount, flags: flags, lspStatus: lspStatus, gitBranch: gitBranch, message: message, filetype: filetype, errorCount: errorCount, warningCount: warningCount, modelName: modelName, messageCount: messageCount, sessionStatus: sessionStatus)
            if mode != lastMode {
                lastMode = mode
                onModeChanged?(guiState.statusBarState.modeName)
            }

        case .guiPicker(let visible, let selectedIndex, let title, let query, let items):
            if visible {
                guiState.pickerState.update(visible: true, selectedIndex: selectedIndex, title: title, query: query, rawItems: items)
            } else {
                guiState.pickerState.hide()
            }

        case .guiAgentChat(let visible, let status, let model, let prompt, let pendingToolName, let pendingToolSummary, let messages):
            if visible {
                guiState.agentChatState.update(visible: true, status: status, model: model, prompt: prompt, pendingToolName: pendingToolName, pendingToolSummary: pendingToolSummary, rawMessages: messages)
            } else {
                guiState.agentChatState.hide()
            }

        case .guiGutterSeparator(let col, let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            lineBuffer.gutterCol = col
            lineBuffer.gutterSeparatorColor = rgb
        }
    }

    // MARK: - Private

    /// Append a styled text run to the LineBuffer.
    ///
    /// CoreText handles all shaping, ligatures, and glyph layout natively,
    /// so there's no per-character decomposition. The full text run is
    /// preserved as-is for CoreText to process.
    private func drawText(row: UInt16, col: UInt16, fg: UInt32, bg: UInt32, attrs: UInt8, text: String,
                          underlineColor: UInt32 = 0, underlineStyle: UInt8 = 0, fontWeight: UInt8 = 2,
                          fontId: UInt8 = 0) {
        var absRow = row
        var absCol = col

        if let region = activeRegion {
            absRow &+= region.row
            absCol &+= region.col
            if absRow >= region.row &+ region.height { return }
        }

        lineBuffer.appendRun(
            row: absRow, col: absCol, text: text,
            fg: fg, bg: bg, attrs: attrs,
            underlineColor: underlineColor, underlineStyle: underlineStyle,
            fontWeight: fontWeight, fontId: fontId
        )
    }
}
