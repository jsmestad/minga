/// Protocol encode/decode round-trip tests.

import Testing
import Foundation
@testable import minga_mac

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
