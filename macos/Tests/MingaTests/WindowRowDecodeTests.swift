/// Row text, error, and resource-accounting contracts of the window-content row decoder (#3906).
///
/// The row decoder reads text and spans straight from the packet bytes and resolves the decode accounting builder once per row section. These tests pin the observable behavior that must not change with that: decoded text for valid, BOM-led, and invalid UTF-8, the reservation trace the resource policy sees, and the decoder error for malformed rows.

import Foundation
import MingaProtocol
import MingaUI
import Testing

@Suite("Window content row decoding")
struct WindowRowDecodeTests {
    private typealias Row = WindowContentBuilder.RowBuilder
    private typealias Span = WindowContentBuilder.SpanBuilder

    @Test("valid UTF-8 row text decodes exactly, including multi-byte, empty, and embedded NUL")
    func validText() throws {
        let texts = ["", "a", "héllo", "日本語", "🥨👩‍👩‍👧", "e\u{301}", "a\u{0}b", "x\u{FEFF}y", "\u{10FFFF}"]
        let rows = texts.enumerated().map { index, text in
            Row(rowId: UInt64(index + 1), bufLine: UInt32(index), text: text)
        }

        let decoded = try decodeRows(rows)

        #expect(decoded.map(\.text) == texts)
        #expect(decoded.map(\.rowId) == rows.map(\.rowId))
    }

    @Test("a leading byte order mark is dropped once, as before; later ones stay in the text")
    func byteOrderMark() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let cases: [([UInt8], String)] = [
            (bom + [0x41], "A"),
            (bom, ""),
            (bom + bom + [0x41], "\u{FEFF}A"),
            ([0x41] + bom + [0x42], "A\u{FEFF}B"),
        ]
        let rows = cases.enumerated().map { index, testCase in
            Row(rowId: UInt64(index + 1), rawText: testCase.0)
        }

        let decoded = try decodeRows(rows)

        #expect(decoded.map(\.text) == cases.map(\.1))
    }

    @Test("invalid UTF-8 row text decodes as an empty row and keeps the following rows aligned")
    func invalidText() throws {
        let invalid: [[UInt8]] = [
            [0xFF],
            [0x41, 0xFF, 0x42],
            [0xE2, 0x82],
            [0xC0, 0xAF],
            [0xED, 0xA0, 0x80],
            [0xF4, 0x90, 0x80, 0x80],
            [0xEF, 0xBB],
            [0xEF, 0xBB, 0xBF, 0xFF],
            [0xFF, 0xFE, 0x41, 0x00],
        ]
        var rows: [Row] = []
        for (index, bytes) in invalid.enumerated() {
            let span = Span(startCol: 0, endCol: 1, fgR: UInt8(index), attrs: 0x01, fontWeight: 2, fontId: 3)
            rows.append(Row(rowId: UInt64(2 * index + 1), contentHash: UInt32(index), spans: [span], rawText: bytes))
            rows.append(Row(rowId: UInt64(2 * index + 2), text: "ok\(index)"))
        }

        let frame = try decodeFrame(from: WindowContentBuilder(rows: rows).build())
        let decoded = try windowRows(frame)

        for index in invalid.indices {
            let bad = decoded[2 * index]
            #expect(bad.text == "")
            #expect(bad.contentHash == UInt32(index))
            #expect(bad.spans == [GUIHighlightSpan(startCol: 0, endCol: 1, fg: UInt32(index) << 16, bg: 0, attrs: 0x01, fontWeight: 2, fontId: 3)])
            #expect(decoded[2 * index + 1].text == "ok\(index)")
        }
        // The wire bytes of invalid text are still reserved before decoding.
        let reservedText = rows.reduce(0) { $0 + ($1.rawText ?? Array($1.text.utf8)).count }
        #expect(frame.resourceWeight.ownedUTF8Bytes == reservedText)
    }

    @Test("row text up to the decode byte limit decodes; one byte more is a resource failure")
    func maximumLength() throws {
        let unit = "日本語ab🥨"
        let text = String(repeating: unit, count: 65_536)
        let byteCount = text.utf8.count
        let packet = WindowContentBuilder(rows: [Row(rowId: 1, text: text)]).build()

        let frame = try decodeFrame(from: packet, policy: policy(ownedUTF8Bytes: byteCount))
        #expect(try windowRows(frame).map(\.text) == [text])
        #expect(frame.resourceWeight.ownedUTF8Bytes == byteCount)

        do {
            _ = try decodeFrame(from: packet, policy: policy(ownedUTF8Bytes: byteCount - 1))
            Issue.record("expected the row text reservation to exceed the limit")
        } catch let error as ProtocolDecodeError {
            #expect(resourceError(error) == .limitExceeded(dimension: .ownedUTF8Bytes, used: 0, requested: byteCount, limit: byteCount - 1))
        }
    }

    @Test("window-content rows reserve resources in the same order and amounts as before")
    func contentReservationTrace() throws {
        let rows = [
            Row(rowId: 1, text: "héllo", spans: [Span(endCol: 2), Span(startCol: 2, endCol: 5)]),
            Row(rowId: 2, text: ""),
            Row(rowId: 3, spans: [Span(endCol: 1)], rawText: [0xFF, 0xFE]),
            Row(rowId: 4, text: "🥨", spans: [Span(endCol: 1), Span(endCol: 1), Span(endCol: 1)]),
        ]
        let capture = RowDecodeReservationTrace()
        let frame = try decodeFrame(from: WindowContentBuilder(rows: rows).build(), reservationProbe: { dimension, resulting in
            capture.record(dimension, resulting)
        })
        let trace = capture.entries

        var expected = RowDecodeExpectedTrace()
        expected.reserve(.commands, 1)
        expected.reserve(.rows, rows.count)
        expected.reserve(.locatorEntries, rows.count)
        expected.reserve(.arrayEntries, rows.count)
        for row in rows {
            expected.reserveRow(textBytes: (row.rawText ?? Array(row.text.utf8)).count, spanCount: row.spans.count)
            expected.reserve(.arrayEntries, 1)
        }

        #expect(Array(trace.prefix(expected.entries.count)) == expected.entries)
        #expect(frame.resourceWeight.rows == rows.count)
        #expect(frame.resourceWeight.spans == 6)
        #expect(frame.resourceWeight.locatorEntries == rows.count)
    }

    @Test("rows-delta full rows reserve resources in the same order and amounts as before")
    func deltaReservationTrace() throws {
        let fullRows = [
            Row(rowId: 2, bufLine: 1, contentHash: 22, text: "日本", spans: [Span(endCol: 2)]),
            Row(rowId: 3, bufLine: 2, contentHash: 33, rawText: [0xC0, 0xAF]),
        ]
        let capture = RowDecodeReservationTrace()
        let frame = try decodeFrame(from: rowsDeltaPacket(fullRows: fullRows), reservationProbe: { dimension, resulting in
            capture.record(dimension, resulting)
        })
        let trace = capture.entries

        var expected = RowDecodeExpectedTrace()
        expected.reserve(.commands, 1)
        expected.reserve(.locatorEntries, 1 + fullRows.count)
        expected.reserve(.arrayEntries, 1 + fullRows.count)
        expected.reserve(.arrayEntries, 1)
        for row in fullRows {
            expected.reserve(.rows, 1)
            expected.reserveRow(textBytes: (row.rawText ?? Array(row.text.utf8)).count, spanCount: row.spans.count)
            expected.reserve(.arrayEntries, 1)
        }

        #expect(Array(trace.prefix(expected.entries.count)) == expected.entries)
        guard case .guiWindowRowsDelta(let delta)? = frame.commands.first?.command else {
            Issue.record("expected a rows delta")
            return
        }
        let decodedFull = delta.rows.compactMap { entry -> GUIVisualRow? in
            if case .full(let row) = entry { return row }
            return nil
        }
        #expect(decodedFull.map(\.text) == ["日本", ""])
        #expect(decodedFull.map(\.contentHash) == [22, 33])
    }

    @Test("malformed rows keep their decoder errors")
    func malformedRows() throws {
        let valid = WindowContentBuilder(rows: [Row(rowId: 1, text: "abc", spans: [Span(endCol: 3)])]).build()
        // Byte offsets inside the rows section: section id(1) + length(4), row_count(4), then the row.
        let rowStart = try rowsSectionStart(valid) + 5 + 4

        var badType = valid
        badType[rowStart] = 0xEE
        var longText = valid
        longText[rowStart + 20] = 0x40
        var manySpans = valid
        manySpans[rowStart + 21 + 3 + 1] = 0x02

        for packet in [badType, longText, manySpans] {
            #expect(throws: ProtocolDecodeError.self) { _ = try decodeCommand(data: packet, offset: 0) }
            do {
                _ = try decodeCommand(data: packet, offset: 0)
            } catch let error as ProtocolDecodeError {
                #expect(String(describing: error) == "malformed")
            }
        }
    }

    // MARK: - Helpers

    private func decodeRows(_ rows: [Row]) throws -> [GUIVisualRow] {
        try windowRows(try decodeFrame(from: WindowContentBuilder(rows: rows).build()))
    }

    private func windowRows(_ frame: DecodedFrame) throws -> [GUIVisualRow] {
        guard case .guiWindowContent(let content)? = frame.commands.first?.command else {
            Issue.record("expected window content")
            return []
        }
        return content.rows
    }

    private func resourceError(_ error: ProtocolDecodeError) -> FrameResourceError? {
        switch error {
        case .resource(let cause): cause
        case .frameFailure(let cause, _), .commandFailed(_, _, _, let cause): resourceError(cause)
        default: nil
        }
    }

    private func policy(ownedUTF8Bytes: Int) -> FrameResourcePolicy {
        let defaults = FrameResourcePolicy.default
        var decode = defaults.decode.weight
        decode.ownedUTF8Bytes = ownedUTF8Bytes
        return FrameResourcePolicy(
            wire: defaults.wire, decode: .init(weight: decode),
            staging: defaults.staging, resident: defaults.resident
        )
    }

    /// Offset of the rows section (id 0x02) in a packet built by `WindowContentBuilder`.
    private func rowsSectionStart(_ packet: Data) throws -> Int {
        var pos = 1 + 4 + 1
        while pos < packet.count {
            let length = Int(packet[pos + 1]) << 24 | Int(packet[pos + 2]) << 16 | Int(packet[pos + 3]) << 8 | Int(packet[pos + 4])
            if packet[pos] == 0x02 { return pos }
            pos += 5 + length
        }
        throw ProtocolDecodeError.malformed
    }

    /// A rows delta with one reference row followed by `fullRows`.
    private func rowsDeltaPacket(fullRows: [Row]) -> Data {
        var header = Data()
        append(&header, UInt16(7), bytes: 2)
        append(&header, UInt32(42), bytes: 4)
        header.append(1)
        append(&header, UInt16(1), bytes: 2)
        append(&header, UInt16(3), bytes: 2)
        header.append(1)
        append(&header, UInt16(2), bytes: 2)

        let reference = Row(rowId: 1, contentHash: 11)
        var rows = Data()
        append(&rows, UInt32(1 + fullRows.count), bytes: 4)
        rows.append(0)
        append(&rows, reference.rowId, bytes: 8)
        append(&rows, UInt64(reference.contentHash), bytes: 4)
        for row in fullRows {
            rows.append(1)
            appendRow(&rows, row)
        }

        var packet = Data([OP_GUI_WINDOW_ROWS_DELTA, 2])
        for (id, payload) in [(UInt8(0x01), header), (UInt8(0x02), rows)] {
            packet.append(id)
            append(&packet, UInt64(payload.count), bytes: 4)
            packet.append(payload)
        }
        return packet
    }

    private func appendRow(_ data: inout Data, _ row: Row) {
        let text = row.rawText ?? Array(row.text.utf8)
        data.append(row.rowType)
        append(&data, row.rowId, bytes: 8)
        append(&data, UInt64(row.bufLine), bytes: 4)
        append(&data, UInt64(row.contentHash), bytes: 4)
        append(&data, UInt64(text.count), bytes: 4)
        data.append(contentsOf: text)
        append(&data, UInt64(row.spans.count), bytes: 2)
        for span in row.spans {
            append(&data, UInt64(span.startCol), bytes: 2)
            append(&data, UInt64(span.endCol), bytes: 2)
            data.append(contentsOf: [span.fgR, span.fgG, span.fgB, span.bgR, span.bgG, span.bgB])
            data.append(contentsOf: [span.attrs, span.fontWeight, span.fontId])
        }
    }

    private func append(_ data: inout Data, _ value: UInt16, bytes: Int) {
        append(&data, UInt64(value), bytes: bytes)
    }

    private func append(_ data: inout Data, _ value: UInt32, bytes: Int) {
        append(&data, UInt64(value), bytes: bytes)
    }

    private func append(_ data: inout Data, _ value: UInt64, bytes: Int) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}

/// One reservation the decode accounting admitted: the dimension and its resulting total.
private struct RowDecodeReservation: Equatable, CustomStringConvertible {
    let dimension: FrameResourceDimension
    let resulting: Int

    var description: String { "\(dimension.rawValue)=\(resulting)" }
}

/// Builds the expected reservation trace with running totals per dimension.
private struct RowDecodeExpectedTrace {
    private(set) var entries: [RowDecodeReservation] = []
    private var totals: [FrameResourceDimension: Int] = [:]

    mutating func reserve(_ dimension: FrameResourceDimension, _ amount: Int) {
        let resulting = totals[dimension, default: 0] + amount
        totals[dimension] = resulting
        entries.append(RowDecodeReservation(dimension: dimension, resulting: resulting))
    }

    /// The reservations of one row: its text bytes, its spans, the span array, and one entry per span.
    mutating func reserveRow(textBytes: Int, spanCount: Int) {
        reserve(.ownedUTF8Bytes, textBytes)
        reserve(.spans, spanCount)
        reserve(.arrayEntries, spanCount)
        for _ in 0..<spanCount {
            reserve(.arrayEntries, 1)
        }
    }
}

private final class RowDecodeReservationTrace: @unchecked Sendable {
    // @unchecked: every access holds `lock`.
    private let lock = NSLock()
    private var values: [RowDecodeReservation] = []

    func record(_ dimension: FrameResourceDimension, _ resulting: Int) {
        lock.lock()
        values.append(RowDecodeReservation(dimension: dimension, resulting: resulting))
        lock.unlock()
    }

    var entries: [RowDecodeReservation] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
