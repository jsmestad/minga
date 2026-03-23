/// Routes decoded protocol commands to FrameState and GUIState, triggering rendering.
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

/// Dispatches render commands to FrameState (metadata) and GUIState (chrome).
@MainActor
final class CommandDispatcher {
    /// Per-frame metadata for the Metal render pass.
    var frameState: FrameState

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

    /// Called once after the first `batch_end` is received from the BEAM.
    /// Used in bundle mode to flush pending file URLs after the BEAM is ready.
    var onFirstRender: (() -> Void)?

    /// Tracks the last mode to detect changes.
    private var lastMode: UInt8 = 0

    /// All GUI chrome sub-states. Injected at init from AppDelegate.
    /// Non-optional: forgetting to wire this is a compile-time error.
    let guiState: GUIState

    init(cols: UInt16, rows: UInt16, guiState: GUIState) {
        self.frameState = FrameState(cols: cols, rows: rows)
        self.guiState = guiState
    }

    /// Process a single render command.
    func dispatch(_ command: RenderCommand) {
        switch command {
        case .clear:
            frameState.beginFrame()
            guiState.beginFrame()

        case .drawText, .drawStyledText:
            // Legacy cell-grid text rendering. All content now flows through
            // gui_window_content (0x80) and dedicated GUI opcodes. Discard.
            break

        case .setCursor(let row, let col):
            var absRow = row
            var absCol = col
            if let region = activeRegion {
                absRow &+= region.row
                absCol &+= region.col
            }
            frameState.cursorCol = absCol
            frameState.cursorRow = absRow
            frameState.dirty = true

        case .setCursorShape(let shape):
            frameState.cursorShape = shape

        case .batchEnd:
            if let firstRender = onFirstRender {
                firstRender()
                onFirstRender = nil
            }
            onFrameReady?()

        case .setTitle(let title):
            onTitleChanged?(title)

        case .setWindowBg(let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            frameState.defaultBg = rgb
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

        case .clearRegion:
            // Cell-grid clearing no longer needed; semantic content is managed
            // by gui_window_content (0x80). Region tracking kept for cursor offset.
            break

        case .destroyRegion(let id):
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
            let tc = guiState.themeColors
            frameState.gutterColors = GutterThemeColors(
                fg: tc.gutterFgRGB,
                currentFg: tc.gutterCurrentFgRGB,
                errorFg: tc.gutterErrorFgRGB,
                warningFg: tc.gutterWarningFgRGB,
                infoFg: tc.gutterInfoFgRGB,
                hintFg: tc.gutterHintFgRGB,
                gitAddedFg: tc.gitAddedFgRGB,
                gitModifiedFg: tc.gitModifiedFgRGB,
                gitDeletedFg: tc.gitDeletedFgRGB
            )

        case .guiTabBar(let activeIndex, let tabs):
            guiState.tabBarState.update(activeIndex: activeIndex, entries: tabs)

        case .guiFileTree(let selectedIndex, let treeWidth, let rootPath, let entries):
            if entries.isEmpty {
                guiState.fileTreeState.hide()
            } else {
                guiState.fileTreeState.update(selectedIndex: selectedIndex, treeWidth: treeWidth, rootPath: rootPath, rawEntries: entries)
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

        case .guiStatusBar(let contentKind, let mode, let cursorLine, let cursorCol, let lineCount, let flags, let lspStatus, let gitBranch, let message, let filetype, let errorCount, let warningCount, let modelName, let messageCount, let sessionStatus, let infoCount, let hintCount, let macroRecording, let parserStatus, let agentStatus, let gitAdded, let gitModified, let gitDeleted, let icon, let iconColorR, let iconColorG, let iconColorB, let filename, let diagnosticHint):
            let update = StatusBarUpdate(
                contentKind: contentKind, mode: mode,
                cursorLine: cursorLine, cursorCol: cursorCol, lineCount: lineCount,
                flags: flags, lspStatus: lspStatus, gitBranch: gitBranch,
                message: message, filetype: filetype,
                errorCount: errorCount, warningCount: warningCount,
                modelName: modelName, messageCount: messageCount, sessionStatus: sessionStatus,
                infoCount: infoCount, hintCount: hintCount, macroRecording: macroRecording,
                parserStatus: parserStatus, agentStatus: agentStatus,
                gitAdded: gitAdded, gitModified: gitModified, gitDeleted: gitDeleted,
                icon: icon, iconColorR: iconColorR, iconColorG: iconColorG, iconColorB: iconColorB,
                filename: filename, diagnosticHint: diagnosticHint
            )
            guiState.statusBarState.update(from: update)
            if mode != lastMode {
                lastMode = mode
                onModeChanged?(guiState.statusBarState.modeName)
            }

        case .guiPicker(let visible, let selectedIndex, let filteredCount, let totalCount, let title, let query, let hasPreview, let items, let actionMenu):
            if visible {
                guiState.pickerState.update(visible: true, selectedIndex: selectedIndex, filteredCount: filteredCount, totalCount: totalCount, title: title, query: query, hasPreview: hasPreview, rawItems: items, actionMenu: actionMenu)
            } else {
                guiState.pickerState.hide()
            }

        case .guiPickerPreview(let visible, let lines):
            if visible {
                guiState.pickerState.updatePreview(lines: lines)
            } else {
                guiState.pickerState.clearPreview()
            }

        case .guiAgentChat(let visible, let status, let model, let prompt, let pendingToolName, let pendingToolSummary, let helpVisible, let helpGroups, let messages):
            if visible {
                let groups = helpGroups.map { g in
                    HelpGroup(title: g.title, bindings: g.bindings.map { ($0.key, $0.description) })
                }
                guiState.agentChatState.update(visible: true, status: status, model: model, prompt: prompt, pendingToolName: pendingToolName, pendingToolSummary: pendingToolSummary, helpVisible: helpVisible, helpGroups: groups, rawMessages: messages)
            } else {
                guiState.agentChatState.hide()
            }

        case .guiGutterSeparator(let col, let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            frameState.gutterCol = col
            frameState.gutterSeparatorColor = rgb
            frameState.dirty = true

        case .guiCursorline(let row, let r, let g, let b):
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            frameState.cursorlineRow = row
            frameState.cursorlineBg = rgb
            frameState.dirty = true

        case .guiGutter(let data):
            frameState.windowGutters[data.windowId] = data
            if data.isActive {
                frameState.gutterCol = UInt16(data.lineNumberWidth) + UInt16(data.signColWidth)
            }
            frameState.dirty = true

        case .guiWindowContent(let data):
            guiState.windowContents[data.windowId] = data
            // BEAM controls cursor visibility per window. When the minibuffer
            // or other overlay has focus, cursor_visible is false.
            frameState.cursorVisible = data.cursorVisible

        case .guiBottomPanel(let visible, let activeTabIndex, let heightPercent, let filterPreset, let tabs, let entries):
            if visible {
                let panelTabs = tabs.enumerated().map { (i, t) in
                    BottomPanelTab(id: i, tabType: t.tabType, name: t.name)
                }
                guiState.bottomPanelState.update(
                    visible: true,
                    activeTabIndex: Int(activeTabIndex),
                    heightPercent: Int(heightPercent),
                    filterPreset: filterPreset,
                    tabs: panelTabs
                )
                if !entries.isEmpty {
                    guiState.bottomPanelState.messagesState.appendEntries(entries)
                }
            } else {
                guiState.bottomPanelState.hide()
            }

        case .guiToolManager(let visible, let filter, let selectedIndex, let rawTools):
            if visible {
                let tools = rawTools.map { t in
                    ToolEntry(
                        id: t.name,
                        name: t.name,
                        label: t.label,
                        description: t.description,
                        category: ToolCategory(rawValue: t.category) ?? .lspServer,
                        status: ToolStatus(rawValue: t.status) ?? .notInstalled,
                        method: ToolMethod(rawValue: t.method) ?? .npm,
                        languages: t.languages,
                        version: t.version,
                        homepage: t.homepage,
                        provides: t.provides,
                        errorReason: t.errorReason
                    )
                }
                guiState.toolManagerState.update(
                    visible: true,
                    filter: ToolFilter(rawValue: filter) ?? .all,
                    selectedIndex: selectedIndex,
                    tools: tools
                )
            } else {
                guiState.toolManagerState.hide()
            }

        case .guiMinibuffer(let visible, let mode, let cursorPos, let prompt,
                             let input, let context, let selectedIndex,
                             let totalCandidates, let candidates):
            if visible {
                guiState.minibufferState.update(
                    visible: true, mode: mode, cursorPos: cursorPos,
                    prompt: prompt, input: input, context: context,
                    selectedIndex: selectedIndex, totalCandidates: totalCandidates,
                    rawCandidates: candidates
                )
            } else {
                guiState.minibufferState.hide()
            }

        case .guiHoverPopup(let visible, let anchorRow, let anchorCol,
                             let focused, let scrollOffset, let lines):
            if visible {
                guiState.hoverPopupState.update(
                    visible: true, anchorRow: anchorRow, anchorCol: anchorCol,
                    focused: focused, scrollOffset: scrollOffset, rawLines: lines
                )
            } else {
                guiState.hoverPopupState.hide()
            }

        case .guiSignatureHelp(let visible, let anchorRow, let anchorCol,
                                let activeSignature, let activeParameter, let signatures):
            if visible {
                guiState.signatureHelpState.update(
                    visible: true, anchorRow: anchorRow, anchorCol: anchorCol,
                    activeSignature: activeSignature, activeParameter: activeParameter,
                    rawSignatures: signatures
                )
            } else {
                guiState.signatureHelpState.hide()
            }

        case .guiSplitSeparators(let borderColor, let verticals, let horizontals):
            frameState.splitBorderColor = borderColor
            frameState.verticalSeparators = verticals
            frameState.horizontalSeparators = horizontals
            frameState.dirty = true

        case .guiFloatPopup(let visible, let width, let height, let title, let lines):
            if visible {
                guiState.floatPopupState.update(
                    visible: true, width: width, height: height,
                    title: title, lines: lines
                )
            } else {
                guiState.floatPopupState.hide()
            }

        case .guiGitStatus(let repoState, let ahead, let behind, let branchName, let rawEntries):
            // When git_status_panel is nil, the BEAM sends notARepo + empty
            // entries as the "panel closed" signal (same pattern as file tree
            // sending empty entries to trigger hide). Can't gate on
            // rawEntries.isEmpty alone: a clean working tree (normal repo,
            // 0 changed files) is a valid visible-panel state. The compound
            // check notARepo + empty is the specific sentinel the BEAM sends
            // when git_status_panel is nil. (#1047)
            let parsedRepoState = GitRepoState(rawValue: repoState) ?? .notARepo
            if parsedRepoState == .notARepo && rawEntries.isEmpty {
                guiState.gitStatusState.hide()
            } else {
                let entries = rawEntries.compactMap { raw -> GitStatusEntry? in
                    guard let section = GitStatusSection(rawValue: raw.section),
                          let status = GitFileStatus(rawValue: raw.status) else {
                        return nil
                    }
                    return GitStatusEntry(
                        id: (UInt32(raw.section) << 24) | (raw.pathHash & 0x00FFFFFF),
                        section: section,
                        status: status,
                        path: raw.path
                    )
                }
                guiState.gitStatusState.update(
                    repoState: parsedRepoState,
                    branchName: branchName,
                    ahead: ahead,
                    behind: behind,
                    entries: entries
                )
            }
        }
    }

}
