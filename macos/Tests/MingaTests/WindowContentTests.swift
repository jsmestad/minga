/// Tests for the gui_window_content (0x80) protocol decoder.
///
/// Verifies that the Swift decoder correctly parses binaries produced
/// by the BEAM's GUIWindowContent encoder. Tests build binary payloads
/// matching the wire format spec, decode them, and assert field values.

import Testing
import Foundation
import MingaProtocol

// MARK: - Binary builder helpers

/// Builds a gui_window_content binary payload for testing.
struct WindowContentBuilder {
    var windowId: UInt16 = 1
    var flags: UInt8 = 0x03  // bit 0 = full_refresh, bit 1 = cursor_visible
    var cursorRow: UInt16 = 0
    var cursorCol: UInt16 = 0
    var cursorShape: UInt8 = 0  // block
    var scrollLeft: UInt16 = 0
    var contentEpoch: UInt32?
    var rows: [RowBuilder] = []
    var selectionType: UInt8 = 0
    var selectionCoords: (UInt16, UInt16, UInt16, UInt16)?
    var searchMatches: [(row: UInt16, startCol: UInt16, endCol: UInt16, isCurrent: UInt8)] = []
    var diagnosticRanges: [(startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16, severity: UInt8)] = []
    var documentHighlights: [(startRow: UInt16, startCol: UInt16, endRow: UInt16, endCol: UInt16, kind: UInt8)] = []
    var paneGeometryPayload: Data?
    var cursorline: (row: UInt16, r: UInt8, g: UInt8, b: UInt8)?
    var scrollPresentationPayload: Data?

    struct RowBuilder {
        var rowType: UInt8 = 0  // normal
        var rowId: UInt64
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
        // Sectioned format: opcode(1) + section_count(1) + sections...
        var headerPayload = Data()
        appendU16(&headerPayload, windowId)
        headerPayload.append(flags)
        appendU16(&headerPayload, cursorRow)
        appendU16(&headerPayload, cursorCol)
        headerPayload.append(cursorShape)
        appendU16(&headerPayload, scrollLeft)
        if let contentEpoch {
            appendU32(&headerPayload, contentEpoch)
        }

        var rowsPayload = Data()
        appendU32(&rowsPayload, UInt32(rows.count))
        for row in rows {
            rowsPayload.append(row.rowType)
            appendU64(&rowsPayload, row.rowId)
            appendU32(&rowsPayload, row.bufLine)
            appendU32(&rowsPayload, row.contentHash)
            let textBytes = Array(row.text.utf8)
            appendU32(&rowsPayload, UInt32(textBytes.count))
            rowsPayload.append(contentsOf: textBytes)
            appendU16(&rowsPayload, UInt16(row.spans.count))
            for span in row.spans {
                appendU16(&rowsPayload, span.startCol)
                appendU16(&rowsPayload, span.endCol)
                rowsPayload.append(contentsOf: [span.fgR, span.fgG, span.fgB])
                rowsPayload.append(contentsOf: [span.bgR, span.bgG, span.bgB])
                rowsPayload.append(span.attrs)
                rowsPayload.append(span.fontWeight)
                rowsPayload.append(span.fontId)
            }
        }

        var selPayload = Data()
        selPayload.append(selectionType)
        if selectionType != 0, let coords = selectionCoords {
            appendU16(&selPayload, coords.0)
            appendU16(&selPayload, coords.1)
            appendU16(&selPayload, coords.2)
            appendU16(&selPayload, coords.3)
        }

        var matchPayload = Data()
        appendU16(&matchPayload, UInt16(searchMatches.count))
        for m in searchMatches {
            appendU16(&matchPayload, m.row)
            appendU16(&matchPayload, m.startCol)
            appendU16(&matchPayload, m.endCol)
            matchPayload.append(m.isCurrent)
        }

        var diagPayload = Data()
        appendU16(&diagPayload, UInt16(diagnosticRanges.count))
        for d in diagnosticRanges {
            appendU16(&diagPayload, d.startRow)
            appendU16(&diagPayload, d.startCol)
            appendU16(&diagPayload, d.endRow)
            appendU16(&diagPayload, d.endCol)
            diagPayload.append(d.severity)
        }

        var highlightPayload = Data()
        appendU16(&highlightPayload, UInt16(documentHighlights.count))
        for h in documentHighlights {
            appendU16(&highlightPayload, h.startRow)
            appendU16(&highlightPayload, h.startCol)
            appendU16(&highlightPayload, h.endRow)
            appendU16(&highlightPayload, h.endCol)
            highlightPayload.append(h.kind)
        }

        // Build sections
        var sections: [Data] = [
            buildSection(0x01, headerPayload),
            buildSection(0x02, rowsPayload),
            buildSection(0x03, selPayload),
            buildSection(0x04, matchPayload),
            buildSection(0x05, diagPayload),
            buildSection(0x06, highlightPayload),
            buildSection(0x07, Data()) // empty annotations
        ]
        if let paneGeometryPayload {
            sections.append(buildSection(0x08, paneGeometryPayload))
        }
        if let cursorline {
            var payload = Data()
            appendU16(&payload, cursorline.row)
            payload.append(contentsOf: [cursorline.r, cursorline.g, cursorline.b])
            sections.append(buildSection(0x09, payload))
        }
        if let scrollPresentationPayload {
            sections.append(buildSection(0x0A, scrollPresentationPayload))
        }

        var data = Data()
        var payload = Data()
        payload.append(UInt8(sections.count))
        for section in sections {
            payload.append(contentsOf: section)
        }

        data.append(OP_GUI_WINDOW_CONTENT)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func sampleScrollPresentationPayload(windowId: UInt16 = 7) -> Data {
        var data = Data()
        appendU16(&data, windowId)
        data.append(0x01)
        appendU32(&data, 5)
        appendU16(&data, 2)
        appendU16(&data, 1)
        appendU32(&data, 5)
        appendU32(&data, 15)
        appendU32(&data, 4)
        appendU32(&data, 18)
        appendU32(&data, 42)
        appendU32(&data, 99)
        appendU32(&data, 3) // scroll_seq (#2661)
        return data
    }

    static func samplePaneGeometryPayload(windowId: UInt16 = 7) -> Data {
        var data = Data()
        appendU16(&data, windowId)
        appendRect(&data, row: 1, col: 2, width: 40, height: 12)
        appendRect(&data, row: 2, col: 3, width: 38, height: 10)
        appendRect(&data, row: 2, col: 8, width: 33, height: 10)
        appendRect(&data, row: 2, col: 3, width: 5, height: 10)
        appendRect(&data, row: 2, col: 8, width: 33, height: 10)
        appendU32(&data, 5)
        appendU16(&data, 2)
        appendU16(&data, 10)
        appendU16(&data, 33)
        appendU32(&data, 200)
        appendU16(&data, 0)
        appendU32(&data, 20)
        appendU16(&data, 2)
        appendU16(&data, 3)
        data.append(2)
        data.append(1)
        appendRect(&data, row: 2, col: 8, width: 33, height: 10)
        appendU16(&data, windowId)
        data.append(3)
        appendRect(&data, row: 2, col: 7, width: 1, height: 10)
        appendU16(&data, windowId)
        return data
    }

    private static func appendRect(_ data: inout Data, row: UInt16, col: UInt16, width: UInt16, height: UInt16) {
        appendU16(&data, row)
        appendU16(&data, col)
        appendU16(&data, width)
        appendU16(&data, height)
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func buildSection(_ id: UInt8, _ payload: Data) -> Data {
        var section = Data()
        section.append(id)
        appendU32(&section, UInt32(payload.count))
        section.append(payload)
        return section
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

    private func appendU64(_ data: inout Data, _ value: UInt64) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

// MARK: - Tests

private func resourceTestGeometry(hitRegionCount: Int) -> GUIPaneGeometry {
    GUIPaneGeometry(
        windowId: 7,
        totalRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
        contentRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
        textRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
        gutterRect: GUICellRect(row: 0, col: 0, width: 0, height: 24),
        clipRect: GUICellRect(row: 0, col: 0, width: 80, height: 24),
        viewport: GUIViewportSummary(
            top: 0, left: 0, rows: 24, cols: 80, totalLines: 24,
            visualRowOffset: 0, totalVisualRows: 24
        ),
        gutterMetrics: GUIGutterMetrics(lineNumberWidth: 0, signColWidth: 0),
        hitRegions: (0..<hitRegionCount).map { index in
            GUIHitRegion(
                kind: .text,
                rect: GUICellRect(row: UInt16(index), col: 0, width: 1, height: 1),
                windowId: 7
            )
        }
    )
}

@Suite("GUI Window Content Decoder")
struct WindowContentDecoderTests {

    private func buildRowsDelta(opcode: UInt8, includeHeader: Bool = true, includeRows: Bool = true, scrollPresentationPayload: Data? = nil) -> Data {
        var sections: [Data] = []

        if includeHeader {
            var header = Data()
            deltaAppendU16(&header, 7)
            deltaAppendU32(&header, 42)
            header.append(1)
            deltaAppendU16(&header, 1)
            deltaAppendU16(&header, 3)
            header.append(1)
            deltaAppendU16(&header, 2)
            sections.append(deltaSection(0x01, header))
        }

        if includeRows {
            var rows = Data()
            deltaAppendU32(&rows, 2)
            rows.append(0)
            deltaAppendU64(&rows, 1)
            deltaAppendU32(&rows, 11)
            rows.append(1)
            rows.append(0)
            deltaAppendU64(&rows, 2)
            deltaAppendU32(&rows, 1)
            deltaAppendU32(&rows, 22)
            let text = Data("new".utf8)
            deltaAppendU32(&rows, UInt32(text.count))
            rows.append(text)
            deltaAppendU16(&rows, 0)
            sections.append(deltaSection(0x02, rows))
        }

        if let scrollPresentationPayload {
            sections.append(deltaSection(0x0A, scrollPresentationPayload))
        }

        var data = Data()
        data.append(opcode)
        data.append(UInt8(sections.count))
        for section in sections {
            data.append(section)
        }
        return data
    }

    private func buildRowSplicesDelta(_ payload: Data, includeLegacyRows: Bool = false) -> Data {
        var header = Data()
        deltaAppendU16(&header, 7)
        deltaAppendU32(&header, 42)
        header.append(1)
        deltaAppendU16(&header, 1)
        deltaAppendU16(&header, 3)
        header.append(1)
        deltaAppendU16(&header, 2)
        var sections = [deltaSection(0x01, header)]
        if includeLegacyRows {
            var rows = Data()
            deltaAppendU32(&rows, 0)
            sections.append(deltaSection(0x02, rows))
        }
        sections.append(deltaSection(0x0B, payload))
        var data = Data([OP_GUI_WINDOW_ROWS_DELTA, UInt8(sections.count)])
        for section in sections { data.append(section) }
        return data
    }

    private func deltaSection(_ id: UInt8, _ payload: Data) -> Data {
        var section = Data()
        section.append(id)
        deltaAppendU32(&section, UInt32(payload.count))
        section.append(payload)
        return section
    }

    private func deltaAppendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private func deltaAppendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func deltaAppendU64(_ data: inout Data, _ value: UInt64) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

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
        #expect(content.cursorVisible == true)
        #expect(content.cursorRow == 0)
        #expect(content.cursorCol == 0)
        #expect(content.cursorShape == .block)
        #expect(content.rows.isEmpty)
        #expect(content.selection == nil)
        #expect(content.searchMatches.isEmpty)
        #expect(content.diagnosticUnderlines.isEmpty)
        #expect(content.documentHighlights.isEmpty)
    }

    @Test("Decode header fields: window_id, cursor, shape, full_refresh, scrollLeft")
    func decodeHeaderFields() throws {
        var builder = WindowContentBuilder()
        builder.windowId = 7
        builder.flags = 0  // full_refresh = false, cursor_visible = false
        builder.cursorRow = 15
        builder.cursorCol = 42
        builder.cursorShape = 1  // beam
        builder.scrollLeft = 25

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.windowId == 7)
        #expect(content.fullRefresh == false)
        #expect(content.cursorVisible == false)
        #expect(content.cursorRow == 15)
        #expect(content.cursorCol == 42)
        #expect(content.cursorShape == .beam)
        #expect(content.scrollLeft == 25)
    }

    @Test("Decode overlay delta without cursorline")
    func decodeOverlayDeltaWithoutCursorline() throws {
        var data = Data([OP_GUI_WINDOW_OVERLAY_DELTA])
        data.append(contentsOf: [0x00, 0x09]) // window_id
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x2A]) // content_epoch
        data.append(0x01) // cursor_visible
        data.append(contentsOf: [0x00, 0x03]) // cursor_row
        data.append(contentsOf: [0x00, 0x07]) // cursor_col
        data.append(0x01) // beam
        data.append(OP_COMMIT_FRAME) // next opcode proves consumed size stays aligned

        let (cmd, size) = try decodeCommand(data: data, offset: 0)

        #expect(size == 13)
        #expect(data[size] == OP_COMMIT_FRAME)
        guard case .guiWindowOverlayDelta(let delta) = cmd else {
            Issue.record("Expected .guiWindowOverlayDelta"); return
        }

        #expect(delta.windowId == 9)
        #expect(delta.contentEpoch == 42)
        #expect(delta.cursorVisible == true)
        #expect(delta.cursorRow == 3)
        #expect(delta.cursorCol == 7)
        #expect(delta.cursorShape == .beam)
        #expect(delta.cursorline == nil)
    }

    @Test("Decode overlay delta with cursor and cursorline")
    func decodeOverlayDelta() throws {
        var data = Data([OP_GUI_WINDOW_OVERLAY_DELTA])
        data.append(contentsOf: [0x00, 0x09]) // window_id
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x2A]) // content_epoch
        data.append(0x03) // cursor_visible + cursorline
        data.append(contentsOf: [0x00, 0x03]) // cursor_row
        data.append(contentsOf: [0x00, 0x07]) // cursor_col
        data.append(0x01) // beam
        data.append(contentsOf: [0x00, 0x02]) // cursorline row
        data.append(contentsOf: [0x11, 0x22, 0x33]) // cursorline bg

        let (cmd, size) = try decodeCommand(data: data, offset: 0)

        #expect(size == data.count)
        guard case .guiWindowOverlayDelta(let delta) = cmd else {
            Issue.record("Expected .guiWindowOverlayDelta"); return
        }

        #expect(delta.windowId == 9)
        #expect(delta.contentEpoch == 42)
        #expect(delta.cursorVisible == true)
        #expect(delta.cursorRow == 3)
        #expect(delta.cursorCol == 7)
        #expect(delta.cursorShape == .beam)
        #expect(delta.cursorline == GUICursorline(row: 2, bg: 0x112233))
    }

    @Test("Decode cursor_visible flag from flags byte bit 1")
    func decodeCursorVisible() throws {
        // flags = 0x03: full_refresh (bit 0) + cursor_visible (bit 1)
        var builder = WindowContentBuilder()
        builder.flags = 0x03
        let (cmd1, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content1) = cmd1 else {
            Issue.record("Expected .guiWindowContent"); return
        }
        #expect(content1.fullRefresh == true)
        #expect(content1.cursorVisible == true)

        // flags = 0x01: full_refresh only, cursor hidden
        builder.flags = 0x01
        let (cmd2, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content2) = cmd2 else {
            Issue.record("Expected .guiWindowContent"); return
        }
        #expect(content2.fullRefresh == true)
        #expect(content2.cursorVisible == false)

        // flags = 0x02: cursor visible only, no full refresh
        builder.flags = 0x02
        let (cmd3, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content3) = cmd3 else {
            Issue.record("Expected .guiWindowContent"); return
        }
        #expect(content3.fullRefresh == false)
        #expect(content3.cursorVisible == true)
    }

    @Test("Decode content epoch and pane geometry")
    func decodeContentEpochAndPaneGeometry() throws {
        var builder = WindowContentBuilder(windowId: 7)
        builder.contentEpoch = 42
        builder.paneGeometryPayload = WindowContentBuilder.samplePaneGeometryPayload(windowId: 7)

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.contentEpoch == 42)
        guard let geometry = content.paneGeometry else {
            Issue.record("Expected pane geometry"); return
        }

        #expect(geometry.windowId == 7)
        #expect(geometry.totalRect == GUICellRect(row: 1, col: 2, width: 40, height: 12))
        #expect(geometry.textRect == GUICellRect(row: 2, col: 8, width: 33, height: 10))
        #expect(geometry.viewport.top == 5)
        #expect(geometry.viewport.totalLines == 200)
        #expect(geometry.gutterMetrics.lineNumberWidth == 2)
        #expect(geometry.gutterMetrics.signColWidth == 3)
        #expect(geometry.hitRegions.map(\.kind) == [.text, .foldControl])
        #expect(content.exactResourceWeight().arrayEntries == 2)
    }

    @Test("Cached window weight includes annotation bytes and pane hit regions")
    func cachedExactWindowWeight() throws {
        let row = GUIVisualRow(
            rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1,
            text: "row", spans: []
        )
        let geometry = resourceTestGeometry(hitRegionCount: 2)
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [row], selection: nil, searchMatches: [],
            diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [GUILineAnnotation(
                row: 0, kind: .inlineText, fg: 0, bg: 0, text: "😀"
            )],
            paneGeometry: geometry
        )

        let expected = FrameResourceWeight(
            ownedUTF8Bytes: 7, arrayEntries: 3, rows: 1,
            overlays: 1, locatorEntries: 1
        )
        #expect(content.resourceWeight == expected)
        #expect(content.exactResourceWeight() == expected)
        #expect(content.exactResourceWeight() == content.resourceWeight)
        #expect(content.reportingOperationCounters(.init()).exactResourceWeight() == expected)
    }

    @Test("Full content rejects complete weight before row-store construction")
    func fullContentRejectsBeforeStoreConstruction() {
        let duplicate = GUIVisualRow(
            rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1,
            text: "x", spans: []
        )
        let limit = FrameResourceWeight(
            commands: .max, ownedUTF8Bytes: .max, arrayEntries: 0,
            rows: 2, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: 2
        )

        #expect(throws: FrameResourceError.self) {
            _ = try GUIWindowContent(
                windowId: 7, fullRefresh: true,
                cursorRow: 0, cursorCol: 0, cursorShape: .block,
                rows: [duplicate, duplicate], selection: nil, searchMatches: [],
                diagnosticUnderlines: [], documentHighlights: [],
                paneGeometry: resourceTestGeometry(hitRegionCount: 1),
                residentLimit: limit
            )
        }
    }

    @Test("Rows delta rejects complete resulting weight without changing prior content")
    func rowsDeltaCompleteWeightRollback() throws {
        let row = GUIVisualRow(
            rowType: .normal, rowId: 1, bufLine: 0, contentHash: 1,
            text: "ok", spans: []
        )
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: [row], selection: nil, searchMatches: [],
            diagnosticUnderlines: [], documentHighlights: []
        )
        let priorWeight = content.exactResourceWeight()
        let limit = FrameResourceWeight(
            commands: .max, ownedUTF8Bytes: 2, arrayEntries: .max,
            rows: 1, spans: .max, overlays: .max,
            spliceEntries: .max, locatorEntries: 1
        )
        let delta = GUIWindowRowsDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            rows: [.reference(rowId: 1, contentHash: 1)],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [GUILineAnnotation(
                row: 0, kind: .inlineText, fg: 0, bg: 0, text: "overflow"
            )],
            paneGeometry: nil, cursorline: nil
        )

        if case .failure(.resourcePolicy) = content.applyingRowsDeltaChecked(
            delta, residentLimit: limit
        ) {} else {
            Issue.record("Expected complete resulting window weight rejection")
        }
        #expect(content.rows == [row])
        #expect(content.exactResourceWeight() == priorWeight)
    }

    @Test("Decode scroll presentation metadata")
    func decodeScrollPresentation() throws {
        var builder = WindowContentBuilder(windowId: 7)
        builder.contentEpoch = 42
        builder.scrollPresentationPayload = WindowContentBuilder.sampleScrollPresentationPayload(windowId: 7)

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        guard let presentation = content.scrollPresentation else {
            Issue.record("Expected scroll presentation"); return
        }

        #expect(presentation.windowId == 7)
        #expect(presentation.resetRequired == true)
        #expect(presentation.anchorTop == 5)
        #expect(presentation.anchorLeft == 2)
        #expect(presentation.anchorVisualRowOffset == 1)
        #expect(presentation.visibleStartLine == 5)
        #expect(presentation.visibleEndLine == 15)
        #expect(presentation.overscanStartLine == 4)
        #expect(presentation.overscanEndLine == 18)
        #expect(presentation.contentEpoch == 42)
        #expect(presentation.layoutGeneration == 99)
        #expect(presentation.scrollSeq == 3)
    }

    @Test("Reject scroll presentation identity mismatch")
    func rejectScrollPresentationIdentityMismatch() throws {
        var builder = WindowContentBuilder(windowId: 7)
        builder.contentEpoch = 42
        builder.scrollPresentationPayload = WindowContentBuilder.sampleScrollPresentationPayload(windowId: 8)

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: builder.build(), offset: 0)
        }
    }

    @Test("Decode pane-local cursorline")
    func decodePaneLocalCursorline() throws {
        var builder = WindowContentBuilder(windowId: 7)
        builder.cursorline = (row: 3, r: 0x11, g: 0x22, b: 0x33)

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.cursorline == GUICursorline(row: 3, bg: 0x112233))
    }

    @Test("Decode rows with row_id, text, and buf_line")
    func decodeRows() throws {
        var builder = WindowContentBuilder()
        builder.rows = [
            .init(rowType: 0, rowId: 0x1000_0000_0000_0001, bufLine: 0, text: "hello"),
            .init(rowType: 0, rowId: 0x1000_0001_0000_0000, bufLine: 1, text: "world"),
        ]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.rows.count == 2)
        #expect(content.rows[0].text == "hello")
        #expect(content.rows[0].rowId == 0x1000_0000_0000_0001)
        #expect(content.rows[0].bufLine == 0)
        #expect(content.rows[1].text == "world")
        #expect(content.rows[1].rowId == 0x1000_0001_0000_0000)
        #expect(content.rows[1].bufLine == 1)
    }

    @Test("Decode all row types")
    func decodeRowTypes() throws {
        var builder = WindowContentBuilder()
        builder.rows = [
            .init(rowType: 0, rowId: 1, text: "normal"),
            .init(rowType: 1, rowId: 2, text: "fold"),
            .init(rowType: 2, rowId: 3, text: "virtual"),
            .init(rowType: 3, rowId: 4, text: "block"),
            .init(rowType: 4, rowId: 5, text: "wrap"),
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
        builder.rows = [.init(rowId: 1, text: "🥨日本語héllo")]

        let (cmd, _) = try decodeCommand(data: builder.build(), offset: 0)
        guard case .guiWindowContent(let content) = cmd else {
            Issue.record("Expected .guiWindowContent"); return
        }

        #expect(content.rows[0].text == "🥨日本語héllo")
    }

    @Test("Decode content_hash")
    func decodeContentHash() throws {
        var builder = WindowContentBuilder()
        builder.rows = [.init(rowId: 1, contentHash: 0xDEADBEEF, text: "x")]

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
        builder.rows = [.init(rowId: 1, text: "hello world", spans: [span])]

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
        builder.rows = [.init(rowId: 1, text: "hello", spans: [
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

    @Test("Decode viewport delta with retained ref and full row entries")
    func decodeViewportDelta() throws {
        let data = buildRowsDelta(opcode: OP_GUI_WINDOW_VIEWPORT_DELTA)
        let (cmd, size) = try decodeCommand(data: data, offset: 0)

        #expect(size == data.count)
        guard case .guiWindowViewportDelta(let delta) = cmd else {
            Issue.record("Expected .guiWindowViewportDelta"); return
        }

        #expect(delta.windowId == 7)
        #expect(delta.contentEpoch == 42)
        #expect(delta.cursorVisible == true)
        #expect(delta.cursorRow == 1)
        #expect(delta.cursorCol == 3)
        #expect(delta.cursorShape == .beam)
        #expect(delta.scrollLeft == 2)
        #expect(delta.rows.count == 2)

        guard case .reference(let rowId, let contentHash) = delta.rows[0] else {
            Issue.record("Expected retained row ref"); return
        }
        #expect(rowId == 1)
        #expect(contentHash == 11)

        guard case .full(let row) = delta.rows[1] else {
            Issue.record("Expected full row"); return
        }
        #expect(row.rowId == 2)
        #expect(row.contentHash == 22)
        #expect(row.text == "new")
    }

    @Test("Decode rows delta with retained ref and full row entries")
    func decodeRowsDelta() throws {
        let data = buildRowsDelta(opcode: OP_GUI_WINDOW_ROWS_DELTA)
        let (cmd, size) = try decodeCommand(data: data, offset: 0)

        #expect(size == data.count)
        guard case .guiWindowRowsDelta(let delta) = cmd else {
            Issue.record("Expected .guiWindowRowsDelta"); return
        }

        #expect(delta.windowId == 7)
        #expect(delta.contentEpoch == 42)
        #expect(delta.rows.count == 2)
    }

    @Test("Decode protocol-v11 row splices and reject ambiguous legacy rows")
    func decodeRowSplices() throws {
        var payload = Data()
        deltaAppendU32(&payload, 3)
        deltaAppendU32(&payload, 3)
        deltaAppendU32(&payload, 1)
        deltaAppendU32(&payload, 1)
        deltaAppendU32(&payload, 1)
        deltaAppendU32(&payload, 1)
        payload.append(0)
        deltaAppendU64(&payload, 2)
        deltaAppendU32(&payload, 22)

        let (command, _) = try decodeCommand(data: buildRowSplicesDelta(payload), offset: 0)
        guard case .guiWindowRowsDelta(let delta) = command,
              let splice = delta.rowSplices?.first else {
            Issue.record("Expected v11 row splice"); return
        }
        #expect(delta.baseRowCount == 3)
        #expect(delta.resultRowCount == 3)
        #expect(splice.startIndex == 1)
        #expect(splice.deleteCount == 1)
        #expect(splice.insertEntries.count == 1)

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: buildRowSplicesDelta(payload, includeLegacyRows: true), offset: 0)
        }
    }

    @Test("Row splice decoder rejects overlap, range, and result arithmetic")
    func rejectMalformedRowSplices() {
        var overlap = Data()
        deltaAppendU32(&overlap, 4); deltaAppendU32(&overlap, 2); deltaAppendU32(&overlap, 2)
        deltaAppendU32(&overlap, 1); deltaAppendU32(&overlap, 2); deltaAppendU32(&overlap, 0)
        deltaAppendU32(&overlap, 2); deltaAppendU32(&overlap, 2); deltaAppendU32(&overlap, 0)
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: buildRowSplicesDelta(overlap), offset: 0)
        }

        var badResult = Data()
        deltaAppendU32(&badResult, 1); deltaAppendU32(&badResult, 9); deltaAppendU32(&badResult, 1)
        deltaAppendU32(&badResult, 0); deltaAppendU32(&badResult, 1); deltaAppendU32(&badResult, 0)
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: buildRowSplicesDelta(badResult), offset: 0)
        }
    }

    @Test("Decode rows delta with scroll presentation metadata")
    func decodeRowsDeltaScrollPresentation() throws {
        let data = buildRowsDelta(opcode: OP_GUI_WINDOW_ROWS_DELTA, scrollPresentationPayload: WindowContentBuilder.sampleScrollPresentationPayload(windowId: 7))
        let (cmd, size) = try decodeCommand(data: data, offset: 0)

        #expect(size == data.count)
        guard case .guiWindowRowsDelta(let delta) = cmd else {
            Issue.record("Expected .guiWindowRowsDelta"); return
        }

        guard let presentation = delta.scrollPresentation else {
            Issue.record("Expected scroll presentation on rows delta"); return
        }

        #expect(presentation.windowId == 7)
        #expect(presentation.contentEpoch == 42)
        #expect(presentation.layoutGeneration == 99)
        #expect(presentation.scrollSeq == 3)
    }

    @Test("Rows delta rejects mismatched scroll presentation identity")
    func rowsDeltaRejectsMismatchedScrollPresentationIdentity() throws {
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: buildRowsDelta(opcode: OP_GUI_WINDOW_ROWS_DELTA, scrollPresentationPayload: WindowContentBuilder.sampleScrollPresentationPayload(windowId: 8)), offset: 0)
        }
    }

    @Test("Rows delta decoder rejects missing required sections")
    func decodeRowsDeltaMissingRequiredSections() throws {
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: buildRowsDelta(opcode: OP_GUI_WINDOW_ROWS_DELTA, includeHeader: false), offset: 0)
        }

        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: buildRowsDelta(opcode: OP_GUI_WINDOW_ROWS_DELTA, includeRows: false), offset: 0)
        }
    }

    @Test("Rows delta clears stale scroll presentation when payload is absent")
    func rowsDeltaClearsStaleScrollPresentation() throws {
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        let replacement = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1, contentHash: 22, text: "new", spans: [])
        let baseline = GUIScrollPresentation(windowId: 7, resetRequired: true, anchorTop: 10, anchorLeft: 2, anchorVisualRowOffset: 0, visibleStartLine: 10, visibleEndLine: 20, overscanStartLine: 9, overscanEndLine: 21, contentEpoch: 42, layoutGeneration: 11)

        let content = try GUIWindowContent(windowId: 7, fullRefresh: true, contentEpoch: 42, cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: [retained], selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [], scrollPresentation: baseline)
        let delta = GUIWindowRowsDelta(windowId: 7, contentEpoch: 42, cursorVisible: true, cursorRow: 1, cursorCol: 2, cursorShape: .beam, scrollLeft: 3, rows: [.reference(rowId: 1, contentHash: 11), .full(replacement)], selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [], lineAnnotations: [], paneGeometry: nil, cursorline: nil)

        guard let updated = content.applyingRowsDelta(delta) else {
            Issue.record("Expected rows delta to apply")
            return
        }
        #expect(updated.rows.map { $0.text } == ["old", "new"])
        #expect(updated.scrollPresentation == nil)
    }

    @Test("Rows delta replaces scroll presentation when identity matches")
    func rowsDeltaReplacesMatchingScrollPresentation() throws {
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        let replacement = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1, contentHash: 22, text: "new", spans: [])
        let baseline = GUIScrollPresentation(windowId: 7, resetRequired: true, anchorTop: 10, anchorLeft: 2, anchorVisualRowOffset: 0, visibleStartLine: 10, visibleEndLine: 20, overscanStartLine: 9, overscanEndLine: 21, contentEpoch: 42, layoutGeneration: 11)
        let next = GUIScrollPresentation(windowId: 7, resetRequired: false, anchorTop: 12, anchorLeft: 3, anchorVisualRowOffset: 1, visibleStartLine: 12, visibleEndLine: 22, overscanStartLine: 11, overscanEndLine: 23, contentEpoch: 42, layoutGeneration: 12)

        let content = try GUIWindowContent(windowId: 7, fullRefresh: true, contentEpoch: 42, cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: [retained], selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [], scrollPresentation: baseline)
        let delta = GUIWindowRowsDelta(windowId: 7, contentEpoch: 42, cursorVisible: true, cursorRow: 1, cursorCol: 2, cursorShape: .beam, scrollLeft: 3, rows: [.reference(rowId: 1, contentHash: 11), .full(replacement)], selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [], lineAnnotations: [], paneGeometry: nil, cursorline: nil, scrollPresentation: next)

        guard let updated = content.applyingRowsDelta(delta) else {
            Issue.record("Expected rows delta to apply")
            return
        }
        #expect(updated.rows.map { $0.text } == ["old", "new"])
        #expect(updated.scrollPresentation == next)
    }

    @Test("Rows delta resolves retained refs and full replacement rows")
    func rowsDeltaAppliesRefsAndFullRows() throws {
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])
        let replacement = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1, contentHash: 22, text: "new", spans: [])

        let content = try GUIWindowContent(
            windowId: 7,
            fullRefresh: true,
            contentEpoch: 42,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            rows: [retained],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: []
        )

        let delta = GUIWindowRowsDelta(
            windowId: 7,
            contentEpoch: 42,
            cursorVisible: true,
            cursorRow: 1,
            cursorCol: 2,
            cursorShape: .beam,
            scrollLeft: 3,
            rows: [.reference(rowId: 1, contentHash: 11), .full(replacement)],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [],
            paneGeometry: nil,
            cursorline: nil
        )

        guard let updated = content.applyingRowsDelta(delta) else {
            Issue.record("Expected rows delta to apply")
            return
        }
        #expect(updated.rows.map { $0.text } == ["old", "new"])
        #expect(updated.cursorShape == CursorShape.beam)
        #expect(updated.cursorRow == 1)
        #expect(updated.scrollLeft == 3)
    }

    @Test("Rows delta fails when a retained ref is missing")
    func rowsDeltaMissingRefReturnsNil() throws {
        let retained = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "old", spans: [])

        let content = try GUIWindowContent(
            windowId: 7,
            fullRefresh: true,
            contentEpoch: 42,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            rows: [retained],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: []
        )

        let delta = GUIWindowRowsDelta(
            windowId: 7,
            contentEpoch: 42,
            cursorVisible: true,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            scrollLeft: 0,
            rows: [.reference(rowId: 999, contentHash: 11)],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: [],
            lineAnnotations: [],
            paneGeometry: nil,
            cursorline: nil
        )

        #expect(content.applyingRowsDelta(delta) == nil)
    }

    @Test("Rows delta supports front and middle deletion plus retained moves")
    func rowsDeltaStructuralChanges() throws {
        let a = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "A", spans: [])
        let b = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1, contentHash: 22, text: "B", spans: [])
        let c = GUIVisualRow(rowType: .normal, rowId: 3, bufLine: 2, contentHash: 33, text: "C", spans: [])
        let content = try GUIWindowContent(windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: [a, b, c], selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [])

        let front = GUIWindowRowsDelta(windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            rows: [.reference(rowId: 2, contentHash: 22), .reference(rowId: 3, contentHash: 33)],
            selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [], paneGeometry: nil, cursorline: nil)
        let frontResult = try content.applyingRowsDeltaChecked(front).get()
        #expect(frontResult.rows.map(\.rowId) == [2, 3])

        let middle = GUIWindowRowsDelta(windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            rows: [.reference(rowId: 1, contentHash: 11), .reference(rowId: 3, contentHash: 33)],
            selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [], paneGeometry: nil, cursorline: nil)
        #expect(try content.applyingRowsDeltaChecked(middle).get().rows.map(\.rowId) == [1, 3])

        let wrap = GUIVisualRow(rowType: .wrapContinuation, rowId: 4, bufLine: 1, contentHash: 44, text: "wrap", spans: [])
        let movable = try GUIWindowContent(windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: [b, wrap], selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [])
        let move = GUIWindowRowsDelta(windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            rows: [.reference(rowId: 4, contentHash: 44), .reference(rowId: 2, contentHash: 22)],
            selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [], paneGeometry: nil, cursorline: nil)
        #expect(try movable.applyingRowsDeltaChecked(move).get().rows.map(\.rowId) == [4, 2])
    }

    @Test("65,536 retained references validate without reset or chunk rewrite")
    func rowsDeltaLargeNoOpReferences() throws {
        let count = 65_536
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            rows.append(GUIVisualRow(
                rowType: .normal, rowId: UInt64(index + 1), bufLine: UInt32(index),
                contentHash: UInt32(index + 1), text: "row", spans: []
            ))
        }
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: rows, selection: nil, searchMatches: [],
            diagnosticUnderlines: [], documentHighlights: []
        )
        let references: [GUIWindowRowDeltaEntry] = rows.map {
            GUIWindowRowDeltaEntry.reference(rowId: $0.rowId, contentHash: $0.contentHash)
        }
        let delta = GUIWindowRowsDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            rows: references,
            selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
            lineAnnotations: [], paneGeometry: nil, cursorline: nil
        )

        let updated = try content.applyingRowsDeltaChecked(delta).get()
        #expect(updated.rowStore.count == count)
        #expect(updated.rowStoreOperationCounters.rowsVisited == count * 2)
        #expect(updated.rowStoreOperationCounters.idsResolved == count)
        #expect(updated.rowStoreOperationCounters.chunksTouched == 0)
        #expect(updated.rowStoreOperationCounters.fullResets == 0)
    }

    @Test("large changed middle rewrites only bounded chunks")
    func rowsDeltaLargeChangedMiddle() throws {
        let count = 65_536
        let middle = count / 2
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            rows.append(GUIVisualRow(
                rowType: .normal, rowId: UInt64(index + 1), bufLine: UInt32(index),
                contentHash: UInt32(index + 1), text: "row", spans: []
            ))
        }
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 0, cursorCol: 0, cursorShape: .block,
            rows: rows, selection: nil, searchMatches: [],
            diagnosticUnderlines: [], documentHighlights: []
        )
        let replacement = GUIVisualRow(
            rowType: .normal, rowId: UInt64(count + 1), bufLine: UInt32(middle),
            contentHash: UInt32(count + 1), text: "changed", spans: []
        )
        var entries = rows.map { GUIWindowRowDeltaEntry.reference(rowId: $0.rowId, contentHash: $0.contentHash) }
        entries[middle] = GUIWindowRowDeltaEntry.full(replacement)
        let delta = GUIWindowRowsDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            rows: entries, selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: nil, cursorline: nil
        )

        let updated = try content.applyingRowsDeltaChecked(delta).get()
        #expect(updated.rowStore.row(at: middle) == replacement)
        #expect(updated.rowStoreOperationCounters.idsResolved == count - 1)
        #expect(updated.rowStoreOperationCounters.chunksTouched <= 4)
        #expect(updated.rowStoreOperationCounters.fullResets == 0)
    }

    @Test("Rows delta rejects duplicate final IDs and late missing refs atomically")
    func rowsDeltaValidationRollback() throws {
        let a = GUIVisualRow(rowType: .normal, rowId: 1, bufLine: 0, contentHash: 11, text: "A", spans: [])
        let b = GUIVisualRow(rowType: .normal, rowId: 2, bufLine: 1, contentHash: 22, text: "B", spans: [])
        let content = try GUIWindowContent(windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: [a, b], selection: nil,
            searchMatches: [], diagnosticUnderlines: [], documentHighlights: [])
        let beforeRows = content.rows
        let beforeCounters = content.rowStore.counters

        func delta(_ rows: [GUIWindowRowDeltaEntry]) -> GUIWindowRowsDelta {
            GUIWindowRowsDelta(windowId: 7, contentEpoch: 42, cursorVisible: true,
                cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0, rows: rows,
                selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: [],
                lineAnnotations: [], paneGeometry: nil, cursorline: nil)
        }

        if case .failure(.duplicateRowID(1)) = content.applyingRowsDeltaChecked(delta([
            .reference(rowId: 1, contentHash: 11), .reference(rowId: 1, contentHash: 11)
        ])) {} else { Issue.record("Expected duplicate final row identity rejection") }
        if case .failure(.missingRowID(999)) = content.applyingRowsDeltaChecked(delta([
            .reference(rowId: 1, contentHash: 11), .reference(rowId: 999, contentHash: 99)
        ])) {} else { Issue.record("Expected late missing reference rejection") }
        #expect(content.rows == beforeRows)
        #expect(content.rowStore.counters == beforeCounters)
    }

    @Test("V11 row splices apply disjoint changes and keep one-row work document-size independent")
    func applyBoundedRowSplices() throws {
        let count = 65_536
        var rows: [GUIVisualRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let rowID = UInt64(index + 1)
            let bufferLine = UInt32(index)
            let contentHash = UInt32(index + 1)
            rows.append(GUIVisualRow(
                rowType: .normal, rowId: rowID, bufLine: bufferLine,
                contentHash: contentHash, text: "row", spans: []
            ))
        }
        let content = try GUIWindowContent(
            windowId: 7, fullRefresh: true, contentEpoch: 42,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, rows: rows,
            selection: nil, searchMatches: [], diagnosticUnderlines: [], documentHighlights: []
        )
        let middle = count / 2
        let front = GUIVisualRow(
            rowType: .normal, rowId: UInt64(count + 3), bufLine: 0,
            contentHash: 999_000, text: "front", spans: []
        )
        let replacement = GUIVisualRow(
            rowType: .normal, rowId: UInt64(count + 1), bufLine: UInt32(middle),
            contentHash: 999_001, text: "changed", spans: []
        )
        let tail = GUIVisualRow(
            rowType: .normal, rowId: UInt64(count + 2), bufLine: UInt32(count - 1),
            contentHash: 999_002, text: "tail", spans: []
        )
        let delta = GUIWindowRowsDelta(
            windowId: 7, contentEpoch: 42, cursorVisible: true,
            cursorRow: 0, cursorCol: 0, cursorShape: .block, scrollLeft: 0,
            baseRowCount: UInt32(count), resultRowCount: UInt32(count),
            rowSplices: [
                GUIWindowRowSplice(startIndex: 0, deleteCount: 1,
                                   insertEntries: [.full(front)]),
                GUIWindowRowSplice(startIndex: UInt32(middle), deleteCount: 1,
                                   insertEntries: [.full(replacement)]),
                GUIWindowRowSplice(startIndex: UInt32(count - 1), deleteCount: 1,
                                   insertEntries: [.full(tail)])
            ],
            selection: nil, searchMatches: [], diagnosticUnderlines: [],
            documentHighlights: [], lineAnnotations: [], paneGeometry: nil, cursorline: nil
        )

        let updated = try content.applyingRowsDeltaChecked(delta).get()
        #expect(updated.rowStore.row(at: 0) == front)
        #expect(updated.rowStore.row(at: middle) == replacement)
        #expect(updated.rowStore.row(at: count - 1) == tail)
        #expect(updated.rowStoreOperationCounters.splices == 3)
        #expect(updated.rowStoreOperationCounters.changedRowsValidated == 3)
        #expect(updated.rowStoreOperationCounters.idsResolved == 0)
        #expect(updated.rowStoreOperationCounters.rowsVisited < 3_000)
        #expect(updated.rowStoreOperationCounters.chunksTouched <= 12)
        #expect(updated.rowStoreOperationCounters.locatorNodesCopied < 40_000)
        #expect(updated.rowStoreOperationCounters.fullResets == 0)
    }

    @Test("Complete window with all sections decodes correctly")
    func decodeCompleteWindow() throws {
        var builder = WindowContentBuilder(windowId: 7, cursorRow: 1, cursorCol: 3, cursorShape: 1)
        builder.rows = [
            .init(rowType: 0, rowId: 1, bufLine: 0, text: "def foo do", spans: [
                .init(startCol: 0, endCol: 3, fgR: 0x51, fgG: 0xAF, fgB: 0xEF, attrs: 0x01),
                .init(startCol: 4, endCol: 7, fgR: 0xEC, fgG: 0xBE, fgB: 0x7B),
            ]),
            .init(rowType: 1, rowId: 2, bufLine: 1, text: "  :ok ··· 3 lines"),
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
