/// Encodes input events from the GUI to the BEAM via stdout.
///
/// All events are length-prefixed with a 4-byte big-endian header
/// (`{:packet, 4}` framing). The encoder writes directly to stdout
/// with a lock to prevent interleaved writes from multiple threads.

import Foundation

/// Protocol for sending input events to the BEAM. The real implementation
/// writes to stdout; tests can use a spy conformance to verify calls.
protocol InputEncoder: AnyObject, Sendable {
    func sendReady(cols: UInt16, rows: UInt16)
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8)
    func sendResize(cols: UInt16, rows: UInt16)
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8)
    func sendLog(level: UInt8, message: String)
}

/// Thread-safe encoder that writes `{:packet, 4}` framed events to stdout.
final class ProtocolEncoder: InputEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private let stdout = FileHandle.standardOutput

    /// Send the ready event with initial dimensions and capabilities.
    func sendReady(cols: UInt16, rows: UInt16) {
        var buf = Data(count: 13)
        buf[0] = OP_READY
        writeU16(&buf, 1, cols)
        writeU16(&buf, 3, rows)
        buf[5] = CAPS_VERSION
        buf[6] = 6 // 6 capability fields
        buf[7] = FRONTEND_NATIVE_GUI
        buf[8] = COLOR_RGB
        buf[9] = UNICODE_15
        buf[10] = IMAGE_NATIVE
        buf[11] = FLOAT_NATIVE
        buf[12] = TEXT_PROPORTIONAL
        writeFrame(buf)
    }

    /// Send a key press event.
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {
        var buf = Data(count: 6)
        buf[0] = OP_KEY_PRESS
        writeU32(&buf, 1, codepoint)
        buf[5] = modifiers
        writeFrame(buf)
    }

    /// Send a resize event (dimensions in cells).
    func sendResize(cols: UInt16, rows: UInt16) {
        var buf = Data(count: 5)
        buf[0] = OP_RESIZE
        writeU16(&buf, 1, cols)
        writeU16(&buf, 3, rows)
        writeFrame(buf)
    }

    /// Send a mouse event.
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8) {
        var buf = Data(count: 8)
        buf[0] = OP_MOUSE_EVENT
        writeI16(&buf, 1, row)
        writeI16(&buf, 3, col)
        buf[5] = button
        buf[6] = modifiers
        buf[7] = eventType
        writeFrame(buf)
    }

    /// Send a log message to the BEAM for display in *Messages*.
    /// Layout: opcode(1) + level(1) + msg_len(2, big-endian) + msg(msg_len).
    func sendLog(level: UInt8, message: String) {
        let utf8 = Array(message.utf8)
        let msgLen = min(utf8.count, Int(UInt16.max))
        var buf = Data(count: 4 + msgLen)
        buf[0] = OP_LOG_MESSAGE
        buf[1] = level
        writeU16(&buf, 2, UInt16(msgLen))
        if msgLen > 0 {
            buf.replaceSubrange(4..<(4 + msgLen), with: utf8[0..<msgLen])
        }
        writeFrame(buf)
    }

    // MARK: - Private

    /// Write a length-prefixed frame to stdout.
    private func writeFrame(_ payload: Data) {
        var frame = Data(count: 4 + payload.count)
        let len = UInt32(payload.count)
        frame[0] = UInt8((len >> 24) & 0xFF)
        frame[1] = UInt8((len >> 16) & 0xFF)
        frame[2] = UInt8((len >> 8) & 0xFF)
        frame[3] = UInt8(len & 0xFF)
        frame.replaceSubrange(4..<(4 + payload.count), with: payload)

        lock.lock()
        defer { lock.unlock() }
        stdout.write(frame)
    }

    private func writeU16(_ buf: inout Data, _ offset: Int, _ value: UInt16) {
        buf[offset] = UInt8((value >> 8) & 0xFF)
        buf[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeU32(_ buf: inout Data, _ offset: Int, _ value: UInt32) {
        buf[offset] = UInt8((value >> 24) & 0xFF)
        buf[offset + 1] = UInt8((value >> 16) & 0xFF)
        buf[offset + 2] = UInt8((value >> 8) & 0xFF)
        buf[offset + 3] = UInt8(value & 0xFF)
    }

    private func writeI16(_ buf: inout Data, _ offset: Int, _ value: Int16) {
        writeU16(&buf, offset, UInt16(bitPattern: value))
    }
}
