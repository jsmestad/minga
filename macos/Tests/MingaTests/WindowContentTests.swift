/// Tests for the gui_window_content (0x80) protocol decoder.
///
/// Verifies that the Swift decoder correctly parses binaries produced
/// by the BEAM's GUIWindowContent encoder. Tests build binary payloads
/// matching the wire format spec, decode them, and assert field values.

import Testing
import Foundation

// MARK: - Binary builder helpers

/// Builds a gui_window_content binary payload for testing.
struct WindowContentBuilder {
    var windowId: UInt16 = 1
    var flags: UInt8 = 1  // full_refresh
    var cursorRow: UInt16 = 0
    var cursorCol: UInt16 = 0
    var cursorShape: UInt8 = 0  // block
    var rows: [RowBuilder] = []
    var selectionType: UInt8 = 0
    var selectionCoords: (UInt16, UInt16, UInt16, UInt16)?
    var searchMatches: [(row: UInt16, startCol: UInt16, endCol: UInt16, isCurrent: UInt8)] = []
    var diagnosticRanges: [(startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16, severity: UInt8)] = []
    var documentHighlights: [(startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16, kind: UInt8)] = []

    struct RowBuilder {
        var rowType: UInt8 = 0  // normal
        var bufLine: UInt32 = 0
        var contentHash: UInt32 = 12345
        var text: String = ""
        var spans: [SpanBuilder] = []
    }

    struct SpanBuilder {
        var startCol: UInt16 = 0
        var endCol: UInt16 = 0
        var fgR: UInt8 = 0; var fgG: UInt8 = 0; var fgB: UInt8 = 0
        var bgR: UInt8 = 0; var bgG: UInt8 = 0; var bgB: UInt8 = 0
        var attrs: UInt8 = 0
        var fontWeight: UInt8 = 0
        var fontId: UInt8 = 0
    }

    func build() -> Data {
        var data = Data()
        data.append(OP_GUI_WINDOW_CONTENT)
        appendU16(&data, windowId)
        data.append(flags)
        appendU16(&data, cursorRow)
        appendU16(&data, cursorCol)
        data.append(cursorShape)
        appendU16(&data, UInt16(rows.count))

        for row in rows {
            data.append(row.rowType)
            appendU32(&data, row.bufLine)
            appendU32(&data, row.contentHash)
            let textBytes = Array(row.text.utf8)
            appendU32(&data, UInt32(textBytes.count))
            data.append(contentsOf: textBytes)
            appendU16(&data, UInt16(row.spans.count))
            for span in row.spans {
                appendU16(&data, span.startCol)
                appendU16(&data, span.endCol)
                data.append(contentsOf: [span.fgR, span.fgG, span.fgB])
                data.append(contentsOf: [span.bgR, span.bgG, span.bgB])
                data.append(span.attrs)
                data.append(span.fontWeight)
                data.append(span.fontId)
            }
        }

        data.append(selectionType)
        if selectionType != 0, let coords = selectionCoords {
            appendU16(&data, coords.0)
            appendU16(&data, coords.1)
            appendU16(&data, coords.2)
            appendU16(&data, coords.3)
        }

        appendU16(&data, UInt16(searchMatches.count))
        for m in searchMatches {
            appendU16(&data, m.row)
            appendU16(&data, m.startCol)
            appendU16(&data, m.endCol)
            data.append(m.isCurrent)
        }

        appendU16(&data, UInt16(diagnosticRanges.count))
        for d in diagnosticRanges {
            appendU16(&data, d.startRow)
            appendU16(&data, d.startCol)
            appendU16(&data, d.endRow)
            appendU16(&data, d.endCol)
            data.append(d.severity)
        }

        appendU16(&data, UInt16(documentHighlights.count))
        for h in documentHighlights {
            appendU16(&data, h.startRow)
            appendU16(&data, h.startCol)
            appendU16(&data, h.endRow)
            appendU16(&data, h.endCol)
            data.append(h.kind)
        }

        return data
    }

    private func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

// MARK: - Tests

@Suite("GUI Window Content Decoder")
struct WindowContentDecoderTests {

    @Test("Decode empty window (0 rows, no selection, no matches, no diagnostics)")
    func decodeEmptyWindow() throws {
        let builder = WindowContentBuilder(windowId: 42, cursorRow: 0, cursorCol: 0)
        let data = builder.build()
        let (cmd, size) = try decodeCommand(data: data, offset: 0)

        #expect(size == data.count)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent, got \(String(describing: cmd))")
            return
        }

        #expect(content.windowId == 42)
        #expect(content.fullRefresh == true)
        #expect(content.cursorRow == 0)
        #expect(content.cursorCol == 0)
        #expect(content.cursorShape == .block)
        #expect(content.rows.isEmpty)
        #expect(content.selection == nil)
        #expect(content.searchMatches.isEmpty)
        #expect(content.diagnosticUnderlines.isEmpty)
        #expect(content.documentHighlights.isEmpty)
    }

    @Test("Decode header fields: window_id, cursor, shape, full_refresh")
    func decodeHeaderFields() throws {
        var builder = WindowContentBuilder()
        builder.windowId = 7
        builder.flags = 0  // full_refresh = false
        builder.cursorRow = 15
        builder.cursorCol = 42
        builder.cursorShape = 1  // beam

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.windowId == 7)
        #expect(content.fullRefresh == false)
        #expect(content.cursorRow == 15)
        #expect(content.cursorCol == 42)
        #expect(content.cursorShape == .beam)
    }

    @Test("Decode rows with text and buf_line")
    func decodeRows() throws {
        var builder = WindowContentBuilder()
        builder.rows = [
            .init(rowType: 0, bufLine: 0, text: "hello"),
            .init(rowType: 0, bufLine: 1, text: "world"),
        ]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.rows.count == 2)
        #expect(content.rows[0].text == "hello")
        #expect(content.rows[0].bufLine == 0)
        #expect(content.rows[1].text == "world")
        #expect(content.rows[1].bufLine == 1)
    }

    @Test("Decode all row types")
    func decodeRowTypes() throws {
        var builder = WindowContentBuilder()
        builder.rows = [
            .init(rowType: 0, text: "normal"),
            .init(rowType: 1, text: "fold"),
            .init(rowType: 2, text: "virtual"),
            .init(rowType: 3, text: "block"),
            .init(rowType: 4, text: "wrap"),
        ]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.rows[0].rowType == .normal)
        #expect(content.rows[1].rowType == .foldStart)
        #expect(content.rows[2].rowType == .virtualLine)
        #expect(content.rows[3].rowType == .block)
        #expect(content.rows[4].rowType == .wrapContinuation)
    }

    @Test("Decode multi-byte UTF-8 text")
    func decodeUTF8() throws {
        var builder = WindowContentBuilder()
        builder.rows = [.init(text: "🥨日本語héllo")]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.rows[0].text == "🥨日本語héllo")
    }

    @Test("Decode content_hash")
    func decodeContentHash() throws {
        var builder = WindowContentBuilder()
        builder.rows = [.init(contentHash: 0xDEADBEEF, text: "x")]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.rows[0].contentHash == 0xDEADBEEF)
    }

    @Test("Decode spans with colors and attributes")
    func decodeSpans() throws {
        var builder = WindowContentBuilder()
        let span = WindowContentBuilder.SpanBuilder(
            startCol: 3, endCol: 17,
            fgR: 0xFF, fgG: 0x6C, fgB: 0x6B,
            bgR: 0x28, bgG: 0x2C, bgB: 0x34,
            attrs: 0x03,  // bold + italic
            fontWeight: 5, fontId: 2
        )
        builder.rows = [.init(text: "hello world", spans: [span])]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        let s = content.rows[0].spans[0]
        #expect(s.startCol == 3)
        #expect(s.endCol == 17)
        #expect(s.fg == 0xFF6C6B)
        #expect(s.bg == 0x282C34)
        #expect(s.isBold == true)
        #expect(s.isItalic == true)
        #expect(s.isUnderline == false)
        #expect(s.fontWeight == 5)
        #expect(s.fontId == 2)
    }

    @Test("Decode char selection")
    func decodeCharSelection() throws {
        var builder = WindowContentBuilder()
        builder.selectionType = 1  // char
        builder.selectionCoords = (2, 5, 7, 15)

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.selection != nil)
        #expect(content.selection?.type == .char)
        #expect(content.selection?.startRow == 2)
        #expect(content.selection?.startCol == 5)
        #expect(content.selection?.endRow == 7)
        #expect(content.selection?.endCol == 15)
    }

    @Test("Decode nil selection")
    func decodeNilSelection() throws {
        let builder = WindowContentBuilder()  // selectionType defaults to 0

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.selection == nil)
    }

    @Test("Decode search matches with is_current flag")
    func decodeSearchMatches() throws {
        var builder = WindowContentBuilder()
        builder.searchMatches = [
            (row: 5, startCol: 10, endCol: 15, isCurrent: 0),
            (row: 8, startCol: 0, endCol: 3, isCurrent: 1),
        ]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.searchMatches.count == 2)
        #expect(content.searchMatches[0].row == 5)
        #expect(content.searchMatches[0].startCol == 10)
        #expect(content.searchMatches[0].isCurrent == false)
        #expect(content.searchMatches[1].row == 8)
        #expect(content.searchMatches[1].isCurrent == true)
    }

    @Test("Decode diagnostic ranges with all severity levels")
    func decodeDiagnosticRanges() throws {
        var builder = WindowContentBuilder()
        builder.diagnosticRanges = [
            (startRow: 1, startCol: 0, endRow: 1, endCol: 10, severity: 0),  // error
            (startRow: 3, startCol: 5, endRow: 3, endCol: 20, severity: 1),  // warning
            (startRow: 5, startCol: 0, endRow: 5, endCol: 5, severity: 2),   // info
            (startRow: 7, startCol: 0, endRow: 7, endCol: 3, severity: 3),   // hint
        ]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.diagnosticUnderlines.count == 4)
        #expect(content.diagnosticUnderlines[0].severity == .error)
        #expect(content.diagnosticUnderlines[1].severity == .warning)
        #expect(content.diagnosticUnderlines[2].severity == .info)
        #expect(content.diagnosticUnderlines[3].severity == .hint)
        #expect(content.diagnosticUnderlines[0].startRow == 1)
        #expect(content.diagnosticUnderlines[1].startCol == 5)
    }

    @Test("Decode document highlights with all kind values")
    func decodeDocumentHighlights() throws {
        var builder = WindowContentBuilder()
        builder.documentHighlights = [
            (startRow: 2, startCol: 4, endRow: 2, endCol: 12, kind: 1),  // text
            (startRow: 5, startCol: 0, endRow: 5, endCol: 8, kind: 2),   // read
            (startRow: 8, startCol: 10, endRow: 8, endCol: 18, kind: 3), // write
        ]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.documentHighlights.count == 3)
        #expect(content.documentHighlights[0].kind == .text)
        #expect(content.documentHighlights[0].startRow == 2)
        #expect(content.documentHighlights[0].startCol == 4)
        #expect(content.documentHighlights[0].endCol == 12)
        #expect(content.documentHighlights[1].kind == .read)
        #expect(content.documentHighlights[1].startRow == 5)
        #expect(content.documentHighlights[2].kind == .write)
        #expect(content.documentHighlights[2].startCol == 10)
        #expect(content.documentHighlights[2].endCol == 18)
    }

    @Test("Decode consumes entire binary (no leftover bytes)")
    func decodeConsumesAllBytes() throws {
        var builder = WindowContentBuilder()
        builder.rows = [.init(text: "hello", spans: [
            .init(startCol: 0, endCol: 5, fgR: 0xFF, fgG: 0, fgB: 0)
        ])]
        builder.selectionType = 1
        builder.selectionCoords = (0, 0, 0, 5)
        builder.searchMatches = [(row: 0, startCol: 0, endCol: 5, isCurrent: 1)]
        builder.diagnosticRanges = [(startRow: 0, startCol: 0, endRow: 0, endCol: 5, severity: 0)]

        let data = builder.build()
        let (_, size) = try decodeCommand(data: data, offset: 0)

        #expect(size == data.count, "Decoder should consume all \(data.count) bytes, consumed \(size)")
    }

    @Test("Complete window with all sections decodes correctly")
    func decodeCompleteWindow() throws {
        var builder = WindowContentBuilder(windowId: 7, cursorRow: 1, cursorCol: 3, cursorShape: 1)
        builder.rows = [
            .init(rowType: 0, bufLine: 0, text: "def foo do", spans: [
                .init(startCol: 0, endCol: 3, fgR: 0x51, fgG: 0xAF, fgB: 0xEF, attrs: 0x01),
                .init(startCol: 4, endCol: 7, fgR: 0xEC, fgG: 0xBE, fgB: 0x7B),
            ]),
            .init(rowType: 1, bufLine: 1, text: "  :ok ··· 3 lines"),
        ]
        builder.selectionType = 1
        builder.selectionCoords = (0, 0, 0, 10)
        builder.searchMatches = [(row: 0, startCol: 4, endCol: 7, isCurrent: 0)]
        builder.diagnosticRanges = [(startRow: 0, startCol: 0, endRow: 0, endCol: 3, severity: 1)]
        builder.documentHighlights = [(startRow: 0, startCol: 4, endRow: 0, endCol: 7, kind: 2)]

        let data = builder.build()
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)

        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.windowId == 7)
        #expect(content.cursorShape == .beam)
        #expect(content.rows.count == 2)
        #expect(content.rows[0].text == "def foo do")
        #expect(content.rows[0].spans.count == 2)
        #expect(content.rows[0].spans[0].fg == 0x51AFEF)
        #expect(content.rows[0].spans[0].isBold == true)
        #expect(content.rows[1].rowType == .foldStart)
        #expect(content.selection?.type == .char)
        #expect(content.searchMatches.count == 1)
        #expect(content.diagnosticUnderlines.count == 1)
        #expect(content.diagnosticUnderlines[0].severity == .warning)
        #expect(content.documentHighlights.count == 1)
        #expect(content.documentHighlights[0].kind == .read)
    }
}
