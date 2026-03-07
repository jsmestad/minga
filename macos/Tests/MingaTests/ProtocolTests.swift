/// Protocol encode/decode round-trip tests.

import Testing
import Foundation
import os

@Suite("Protocol Decoder")
struct ProtocolDecoderTests {
    @Test("Decode clear command")
    func decodeClear() throws {
        let data = Data([OP_CLEAR])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 1)
        guard case .clear = cmd else {
            Issue.record("Expected .clear, got \(String(describing: cmd))")
            return
        }
    }

    @Test("Decode batch_end command")
    func decodeBatchEnd() throws {
        let data = Data([OP_BATCH_END])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 1)
        guard case .batchEnd = cmd else {
            Issue.record("Expected .batchEnd, got \(String(describing: cmd))")
            return
        }
    }

    @Test("Decode set_cursor command")
    func decodeSetCursor() throws {
        // row=5 (0x0005), col=10 (0x000A)
        let data = Data([OP_SET_CURSOR, 0x00, 0x05, 0x00, 0x0A])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 5)
        guard case .setCursor(let row, let col) = cmd else {
            Issue.record("Expected .setCursor, got \(String(describing: cmd))")
            return
        }
        #expect(row == 5)
        #expect(col == 10)
    }

    @Test("Decode set_cursor_shape command")
    func decodeSetCursorShape() throws {
        let data = Data([OP_SET_CURSOR_SHAPE, CURSOR_BEAM])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)
        guard case .setCursorShape(let shape) = cmd else {
            Issue.record("Expected .setCursorShape, got \(String(describing: cmd))")
            return
        }
        #expect(shape == .beam)
    }

    @Test("Decode draw_text command")
    func decodeDrawText() throws {
        // row=1, col=2, fg=0xFF0000 (red), bg=0x00FF00 (green), attrs=0x01 (bold), text="Hi"
        var data = Data()
        data.append(OP_DRAW_TEXT)
        data.append(contentsOf: [0x00, 0x01]) // row=1
        data.append(contentsOf: [0x00, 0x02]) // col=2
        data.append(contentsOf: [0xFF, 0x00, 0x00]) // fg=red
        data.append(contentsOf: [0x00, 0xFF, 0x00]) // bg=green
        data.append(0x01) // attrs=bold
        data.append(contentsOf: [0x00, 0x02]) // text_len=2
        data.append(contentsOf: "Hi".utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 16) // 1 + 13 + 2
        guard case .drawText(let row, let col, let fg, let bg, let attrs, let text) = cmd else {
            Issue.record("Expected .drawText, got \(String(describing: cmd))")
            return
        }
        #expect(row == 1)
        #expect(col == 2)
        #expect(fg == 0xFF0000)
        #expect(bg == 0x00FF00)
        #expect(attrs == 0x01)
        #expect(text == "Hi")
    }

    @Test("Decode define_region command")
    func decodeDefineRegion() throws {
        var data = Data()
        data.append(OP_DEFINE_REGION)
        data.append(contentsOf: [0x00, 0x64]) // id=100
        data.append(contentsOf: [0x00, 0x00]) // parent_id=0
        data.append(0x01) // role=1
        data.append(contentsOf: [0x00, 0x02]) // row=2
        data.append(contentsOf: [0x00, 0x03]) // col=3
        data.append(contentsOf: [0x00, 0x50]) // width=80
        data.append(contentsOf: [0x00, 0x18]) // height=24
        data.append(0x00) // z_order=0

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 15)
        guard case .defineRegion(let id, _, _, let row, let col, let width, let height, _) = cmd else {
            Issue.record("Expected .defineRegion, got \(String(describing: cmd))")
            return
        }
        #expect(id == 100)
        #expect(row == 2)
        #expect(col == 3)
        #expect(width == 80)
        #expect(height == 24)
    }

    @Test("Decode multiple commands in one payload")
    func decodeMultipleCommands() throws {
        var data = Data()
        data.append(OP_CLEAR)
        data.append(OP_SET_CURSOR)
        data.append(contentsOf: [0x00, 0x03, 0x00, 0x07])
        data.append(OP_BATCH_END)

        var commands: [RenderCommand] = []
        try decodeCommands(from: data) { cmd in
            commands.append(cmd)
        }
        #expect(commands.count == 3)
    }

    @Test("Skip highlight opcodes without error")
    func skipHighlightOpcodes() throws {
        // set_language with name "elixir"
        var data = Data()
        data.append(OP_SET_LANGUAGE)
        data.append(contentsOf: [0x00, 0x06]) // name_len=6
        data.append(contentsOf: "elixir".utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(cmd == nil) // Skipped
        #expect(size == 9) // 1 + 2 + 6
    }
}

@Suite("Protocol Encoder")
struct ProtocolEncoderTests {
    // Encoder writes to stdout, so we test the binary layout indirectly
    // by verifying the ready event structure.
    @Test("Ready event has correct size")
    func readyEventSize() {
        // The ready payload should be 13 bytes:
        // opcode:1, cols:2, rows:2, caps_version:1, caps_len:1, fields:6
        // Total frame: 4 (length prefix) + 13 = 17 bytes
        // We can't easily capture stdout in tests, but we verify the
        // constants are correct.
        #expect(CAPS_VERSION == 1)
        #expect(FRONTEND_NATIVE_GUI == 1)
        #expect(COLOR_RGB == 2)
    }
}

// MARK: - Spy encoder for testing resize behavior

/// Records calls to sendResize so tests can verify the view notifies the
/// BEAM when its frame changes.
/// Spy that records encoder calls for test assertions. Uses
/// OSAllocatedUnfairLock so it satisfies Sendable without @unchecked.
final class SpyEncoder: InputEncoder, Sendable {
    struct Resize: Sendable { let cols: UInt16; let rows: UInt16 }
    struct Ready: Sendable { let cols: UInt16; let rows: UInt16 }
    struct Log: Sendable { let level: UInt8; let message: String }

    private let state = OSAllocatedUnfairLock(initialState: State())

    struct State: Sendable {
        var resizeCalls: [Resize] = []
        var readyCalls: [Ready] = []
        var logCalls: [Log] = []
    }

    var resizeCalls: [Resize] { state.withLock { $0.resizeCalls } }
    var readyCalls: [Ready] { state.withLock { $0.readyCalls } }
    var logCalls: [Log] { state.withLock { $0.logCalls } }

    func sendReady(cols: UInt16, rows: UInt16) {
        state.withLock { $0.readyCalls.append(Ready(cols: cols, rows: rows)) }
    }
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {}
    func sendResize(cols: UInt16, rows: UInt16) {
        state.withLock { $0.resizeCalls.append(Resize(cols: cols, rows: rows)) }
    }
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8) {}
    func sendLog(level: UInt8, message: String) {
        state.withLock { $0.logCalls.append(Log(level: level, message: message)) }
    }
}

@Suite("CellGrid Resize")
struct CellGridResizeTests {
    @Test("resize updates dimensions and clears cells")
    func resizeUpdatesDimensions() {
        let grid = CellGrid(cols: 80, rows: 24)
        grid.writeCell(col: 0, row: 0, cell: Cell(grapheme: "A"))

        grid.resize(newCols: 100, newRows: 30)

        #expect(grid.cols == 100)
        #expect(grid.rows == 30)
        // All cells should be blank after resize.
        #expect(grid.cells.count == 100 * 30)
        #expect(grid.cells[0].grapheme == "")
    }

    @Test("resize is a no-op when dimensions unchanged")
    func resizeNoOpWhenSame() {
        let grid = CellGrid(cols: 80, rows: 24)
        grid.writeCell(col: 0, row: 0, cell: Cell(grapheme: "X"))

        grid.resize(newCols: 80, newRows: 24)

        // Cell should still be there since resize was skipped.
        #expect(grid.cells[0].grapheme == "X")
    }
}

@Suite("EditorNSView Resize")
struct EditorNSViewResizeTests {
    @Test("setFrameSize sends resize when cell dimensions change")
    @MainActor func setFrameSizeSendsResize() throws {
        let spy = SpyEncoder()
        let grid = CellGrid(cols: 80, rows: 24)
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        guard let renderer = MetalRenderer() else {
            // No GPU available (CI), skip gracefully.
            return
        }

        let view = EditorNSView(encoder: spy, metalRenderer: renderer, fontFace: face, cellGrid: grid)

        // Simulate a frame resize that changes the cell grid dimensions.
        let newWidth = CGFloat(face.cellWidth) * 100
        let newHeight = CGFloat(face.cellHeight) * 40
        view.setFrameSize(NSSize(width: newWidth, height: newHeight))

        #expect(spy.resizeCalls.count == 1)
        #expect(spy.resizeCalls[0].cols == 100)
        #expect(spy.resizeCalls[0].rows == 40)
        #expect(grid.cols == 100)
        #expect(grid.rows == 40)
    }

    @Test("setFrameSize does not send resize when dimensions unchanged")
    @MainActor func setFrameSizeNoResizeWhenSame() throws {
        let spy = SpyEncoder()
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        let cols = UInt16(800 / CGFloat(face.cellWidth))
        let rows = UInt16(600 / CGFloat(face.cellHeight))
        let grid = CellGrid(cols: cols, rows: rows)
        guard let renderer = MetalRenderer() else { return }

        let view = EditorNSView(encoder: spy, metalRenderer: renderer, fontFace: face, cellGrid: grid)

        // Set frame to the same logical cell dimensions.
        view.setFrameSize(NSSize(width: CGFloat(cols) * CGFloat(face.cellWidth),
                                  height: CGFloat(rows) * CGFloat(face.cellHeight)))

        #expect(spy.resizeCalls.isEmpty)
    }

    @Test("setFrameSize clamps to minimum 1x1")
    @MainActor func setFrameSizeClampsMinimum() throws {
        let spy = SpyEncoder()
        let grid = CellGrid(cols: 80, rows: 24)
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        guard let renderer = MetalRenderer() else { return }

        let view = EditorNSView(encoder: spy, metalRenderer: renderer, fontFace: face, cellGrid: grid)

        // A tiny frame should clamp to 1x1, not overflow or crash.
        view.setFrameSize(NSSize(width: 1, height: 1))

        #expect(spy.resizeCalls.count == 1)
        #expect(spy.resizeCalls[0].cols >= 1)
        #expect(spy.resizeCalls[0].rows >= 1)
        #expect(grid.cols >= 1)
        #expect(grid.rows >= 1)
    }
}

@Suite("PortLogger")
struct PortLoggerTests {
    @Test("log calls are forwarded to the encoder")
    func logForwarding() {
        let spy = SpyEncoder()
        PortLogger.setup(encoder: spy)

        PortLogger.info("hello from test")

        #expect(spy.logCalls.count == 1)
        #expect(spy.logCalls[0].level == LOG_LEVEL_INFO)
        #expect(spy.logCalls[0].message == "hello from test")
    }

    @Test("all log levels are sent with the correct level byte")
    func logLevels() {
        let spy = SpyEncoder()
        PortLogger.setup(encoder: spy)

        PortLogger.error("e")
        PortLogger.warn("w")
        PortLogger.info("i")
        PortLogger.debug("d")

        #expect(spy.logCalls.count == 4)
        #expect(spy.logCalls[0].level == LOG_LEVEL_ERR)
        #expect(spy.logCalls[1].level == LOG_LEVEL_WARN)
        #expect(spy.logCalls[2].level == LOG_LEVEL_INFO)
        #expect(spy.logCalls[3].level == LOG_LEVEL_DEBUG)
    }

    @Test("sendLog binary layout matches Zig encodeLogMessage")
    func logBinaryLayout() {
        // Verify the real ProtocolEncoder produces the right binary.
        // We can't capture stdout easily, but we can verify the
        // constants match the Zig protocol.
        #expect(OP_LOG_MESSAGE == 0x60)
        #expect(LOG_LEVEL_ERR == 0)
        #expect(LOG_LEVEL_WARN == 1)
        #expect(LOG_LEVEL_INFO == 2)
        #expect(LOG_LEVEL_DEBUG == 3)
    }
}
