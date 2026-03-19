/// Routes decoded protocol commands to the CellGrid and triggers rendering.
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

/// Dispatches render commands to a CellGrid and notifies when a frame is complete.
@MainActor
final class CommandDispatcher {
    let grid: CellGrid
    private var regions: [UInt16: Region] = [:]
    private var activeRegion: Region?

    /// The current font face for ligature shaping. Set by the AppDelegate
    /// on init and updated when a set_font command arrives.
    var fontFace: FontFace?

    /// Font manager for per-span font family support. When set, glyph
    /// lookups route through the manager (which handles font_id routing).
    /// Set by the AppDelegate alongside fontFace.
    var fontManager: FontManager?

    /// Called after each `batch_end` command. The MetalRenderer hooks into
    /// this to trigger a GPU frame.
    var onFrameReady: (() -> Void)?

    /// Called when the window title should change.
    var onTitleChanged: ((String) -> Void)?

    /// Called when the BEAM sends a window background color (RGB).
    var onWindowBgChanged: ((NSColor) -> Void)?

    /// Called when the BEAM sends a font configuration change.
    /// Parameters: family, size, ligatures, weight byte.
    var onFontChanged: ((String, UInt16, Bool, UInt8) -> Void)?

    /// All GUI chrome sub-states. Injected at init from AppDelegate.
    /// Non-optional: forgetting to wire this is a compile-time error.
    let guiState: GUIState

    init(grid: CellGrid, guiState: GUIState) {
        self.grid = grid
        self.guiState = guiState
    }

    /// Process a single render command.
    func dispatch(_ command: RenderCommand) {
        switch command {
        case .clear:
            grid.clear()

        case .drawText(let row, let col, let fg, let bg, let attrs, let text):
            drawText(row: row, col: col, fg: fg, bg: bg, attrs: attrs, text: text)

        case .drawStyledText(let row, let col, let fg, let bg, let attrs16, let ulColor, _, let fontWeight, let fontId, let text):
            // Extended draw: 16-bit attrs with underline style, strikethrough, and underline color.
            // The low 8 bits of attrs16 match the regular attrs byte layout.
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
            grid.showCursor(col: absCol, row: absRow)

        case .setCursorShape(let shape):
            grid.cursorShape = shape

        case .batchEnd:
            onFrameReady?()

        case .setTitle(let title):
            onTitleChanged?(title)

        case .setWindowBg(let r, let g, let b):
            // Store as the grid's default bg so the Metal renderer uses it
            // for cells that don't specify an explicit background (bg=0).
            let rgb: UInt32 = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            grid.defaultBg = rgb
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
                grid.clearRect(col: region.col, row: region.row, width: region.width, height: region.height)
            }

        case .destroyRegion(let id):
            if let region = regions[id] {
                grid.clearRect(col: region.col, row: region.row, width: region.width, height: region.height)
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
            fontFace?.setFallbackFonts(families)

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

        case .guiStatusBar(let mode, let cursorLine, let cursorCol, let lineCount, let flags, let lspStatus, let gitBranch, let message, let filetype, let errorCount, let warningCount):
            guiState.statusBarState.update(mode: mode, cursorLine: cursorLine, cursorCol: cursorCol, lineCount: lineCount, flags: flags, lspStatus: lspStatus, gitBranch: gitBranch, message: message, filetype: filetype, errorCount: errorCount, warningCount: warningCount)

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
            grid.gutterCol = col
            grid.gutterSeparatorColor = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        }
    }

    // MARK: - Private

    // MARK: - Ligature lookup table (static, allocated once)

    /// Characters that can start a ligature sequence. Used to skip the
    /// ligature scan entirely for the vast majority of characters.
    private static let ligatureStarters: Set<Character> = {
        var s = Set<Character>()
        for (_, byFirst) in ligatureSequencesByLength {
            for (_, seqs) in byFirst {
                for str in seqs {
                    s.insert(str.first!)
                }
            }
        }
        return s
    }()

    /// Ligature sequences grouped by length (longest first for greedy match),
    /// then by first character for O(1) lookup.
    /// Structure: [(length, [firstChar: [fullSequence]])]
    private static let ligatureSequencesByLength: [(Int, [Character: [String]])] = {
        let all = [
            "www", "<=>", "==>", "-->", "<--", "<->", "===", "!==",
            "=>", "->", "<-", "!=", "<=", ">=", "::", "&&", "||",
            "++", "--", ">>", "<<", "..", "|>", "<|", "//", "/*",
            "*/", "~/", "~>", "<~"
        ]
        var byLen: [Int: [Character: [String]]] = [:]
        for seq in all {
            let len = seq.count
            let first = seq.first!
            byLen[len, default: [:]][first, default: []].append(seq)
        }
        // Sort longest first for greedy matching.
        return byLen.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }()

    private func drawText(row: UInt16, col: UInt16, fg: UInt32, bg: UInt32, attrs: UInt8, text: String,
                          underlineColor: UInt32 = 0, underlineStyle: UInt8 = 0, fontWeight: UInt8 = 2,
                          fontId: UInt8 = 0) {
        var absRow = row
        var absCol = col
        var maxCol = grid.cols

        if let region = activeRegion {
            absRow &+= region.row
            absCol &+= region.col
            if absRow >= region.row &+ region.height { return }
            maxCol = min(grid.cols, region.col &+ region.width)
        }

        // Fast path: no ligature shaping needed. Iterate characters directly
        // without converting to Array or scanning for sequences.
        let ligaturesActive = fontFace?.ligaturesEnabled ?? false
        guard ligaturesActive else {
            var currentCol = absCol
            for char in text {
                guard currentCol < maxCol else { break }
                let grapheme = String(char)
                let w = graphemeWidth(grapheme)
                grid.writeCell(col: currentCol, row: absRow, cell: Cell(
                    grapheme: grapheme, width: UInt8(w),
                    fg: fg, bg: bg, attrs: attrs, underlineColor: underlineColor, underlineStyle: underlineStyle,
                    fontWeight: fontWeight,
                    fontId: fontId
                ))
                currentCol &+= UInt16(w)
            }
            return
        }

        // Slow path: ligature shaping enabled. Need indexed access for
        // lookahead, so convert to Array once.
        let face = fontFace!
        let chars = Array(text)
        var i = 0
        var currentCol = absCol

        while i < chars.count {
            guard currentCol < maxCol else { break }

            var ligatureFound = false
            let ch = chars[i]

            // Only attempt ligature scan if this character can start one.
            if Self.ligatureStarters.contains(ch) {
                for (seqLen, byFirst) in Self.ligatureSequencesByLength {
                    guard i + seqLen <= chars.count else { continue }
                    guard let candidates = byFirst[ch] else { continue }
                    guard currentCol &+ UInt16(seqLen) <= maxCol else { continue }

                    let candidate = String(chars[i..<(i + seqLen)])
                    guard candidates.contains(candidate) else { continue }

                    if let lig = face.shapeLigature(candidate, style: attrs) {
                        grid.writeCell(col: currentCol, row: absRow, cell: Cell(
                            grapheme: candidate, width: UInt8(lig.cellCount),
                            fg: fg, bg: bg, attrs: attrs,
                            underlineColor: underlineColor, underlineStyle: underlineStyle,
                            fontWeight: fontWeight,
                            fontId: fontId,
                            ligatureText: candidate,
                            ligatureCellCount: UInt8(lig.cellCount),
                            isContinuation: false
                        ))
                        for offset in 1..<UInt16(lig.cellCount) {
                            grid.writeCell(col: currentCol &+ offset, row: absRow, cell: Cell(
                                grapheme: "", width: 1,
                                fg: fg, bg: bg, attrs: attrs,
                                underlineColor: underlineColor, underlineStyle: underlineStyle,
                                fontWeight: fontWeight,
                                fontId: fontId,
                                isContinuation: true
                            ))
                        }
                        currentCol &+= UInt16(lig.cellCount)
                        i += seqLen
                        ligatureFound = true
                        break
                    }
                }
            }

            if !ligatureFound {
                let grapheme = String(ch)
                let w = graphemeWidth(grapheme)
                grid.writeCell(col: currentCol, row: absRow, cell: Cell(
                    grapheme: grapheme, width: UInt8(w),
                    fg: fg, bg: bg, attrs: attrs, underlineColor: underlineColor, underlineStyle: underlineStyle,
                    fontWeight: fontWeight,
                    fontId: fontId
                ))
                currentCol &+= UInt16(w)
                i += 1
            }
        }
    }

    /// Estimate display width of a grapheme. Full-width CJK characters and
    /// emoji occupy 2 cells; most others occupy 1.
    private func graphemeWidth(_ grapheme: String) -> Int {
        guard let scalar = grapheme.unicodeScalars.first else { return 1 }
        let cp = scalar.value

        // CJK Unified Ideographs and related blocks
        if (cp >= 0x1100 && cp <= 0x115F) ||   // Hangul Jamo
           cp == 0x2329 || cp == 0x232A ||
           (cp >= 0x2E80 && cp <= 0x303E) ||    // CJK Radicals
           (cp >= 0x3040 && cp <= 0x33BF) ||    // Hiragana, Katakana, CJK
           (cp >= 0x3400 && cp <= 0x4DBF) ||    // CJK Extension A
           (cp >= 0x4E00 && cp <= 0xA4CF) ||    // CJK Unified Ideographs
           (cp >= 0xAC00 && cp <= 0xD7AF) ||    // Hangul Syllables
           (cp >= 0xF900 && cp <= 0xFAFF) ||    // CJK Compatibility Ideographs
           (cp >= 0xFE30 && cp <= 0xFE6F) ||    // CJK Compatibility Forms
           (cp >= 0xFF01 && cp <= 0xFF60) ||     // Fullwidth Forms
           (cp >= 0xFFE0 && cp <= 0xFFE6) ||
           (cp >= 0x1F000 && cp <= 0x1FFFF) ||  // Emoji, Mahjong, Domino
           (cp >= 0x20000 && cp <= 0x2FFFF) ||  // CJK Extension B+
           (cp >= 0x30000 && cp <= 0x3FFFF) {   // CJK Extension G+
            return 2
        }

        return 1
    }
}
