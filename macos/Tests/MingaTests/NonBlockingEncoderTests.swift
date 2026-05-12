/// Tests for ProtocolEncoder's asynchronous, non-blocking write buffer.

import Darwin
import Foundation
import Testing

private func fillPipeUntilWouldBlock(_ fd: Int32) {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let written = chunk.withUnsafeMutableBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
        if written >= 0 { continue }
        if errno == EINTR { continue }
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)
        return
    }
}

private func parseFrames(_ raw: Data) -> [Data]? {
    var frames: [Data] = []
    var offset = 0

    while offset < raw.count {
        guard raw.count - offset >= 4 else { return nil }
        let length = Int(raw[offset]) << 24 | Int(raw[offset + 1]) << 16 | Int(raw[offset + 2]) << 8 | Int(raw[offset + 3])
        let frameStart = offset + 4
        let frameEnd = frameStart + length
        guard length > 0, frameEnd <= raw.count else { return nil }
        frames.append(raw.subdata(in: frameStart..<frameEnd))
        offset = frameEnd
    }

    return frames
}

@Suite("Encoder: Non-blocking Buffer")
struct NonBlockingEncoderTests {
    @Test("writes are buffered and delivered asynchronously")
    func writesDeliveredAsynchronously() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        encoder.sendKeyPress(codepoint: 0x61, modifiers: 0)
        encoder.sendKeyPress(codepoint: 0x62, modifiers: 0)
        encoder.sendResize(cols: 120, rows: 40)

        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()

        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        let frames = parseFrames(raw)
        #expect(frames?.count == 3)
        #expect(frames?[0].first == OP_KEY_PRESS)
        #expect(frames?[1].first == OP_KEY_PRESS)
        #expect(frames?[2].first == OP_RESIZE)
    }

    @Test("single frame larger than threshold is preserved when writable")
    func singleLargeFrameIsPreservedWhenWritable() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting, maxBufferSize: 16)

        encoder.sendPasteEvent(text: String(repeating: "x", count: 128))

        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()

        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        let frames = parseFrames(raw)
        #expect(encoder.droppedMessageCount == 0)
        #expect(frames?.count == 1)
        #expect(frames?.first?.first == OP_PASTE_EVENT)
    }

    @Test("buffer overflow drops complete oldest messages")
    func bufferOverflowDropsCompleteMessages() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting, maxBufferSize: 16)
        fillPipeUntilWouldBlock(pipe.fileHandleForWriting.fileDescriptor)

        encoder.sendPasteEvent(text: String(repeating: "x", count: 128))
        encoder.sendKeyPress(codepoint: 0x63, modifiers: 0)

        #expect(encoder.waitForPendingWritesForTesting())

        let frames = parseFrames(encoder.bufferedDataForTesting())
        #expect(encoder.droppedMessageCount > 0)
        #expect(frames?.count == 1)
        #expect(frames?.first?.first == OP_KEY_PRESS)

        pipe.fileHandleForWriting.closeFile()
        pipe.fileHandleForReading.closeFile()
    }

    @Test("disconnect discards buffered writes")
    func disconnectDiscardsBufferedWrites() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        encoder.disconnect()
        encoder.sendKeyPress(codepoint: 0x61, modifiers: 0)
        encoder.sendPasteEvent(text: "dropped")

        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()

        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(raw.isEmpty)
    }

    @Test("concurrent writes from multiple tasks keep frame boundaries")
    func concurrentWritesKeepFrameBoundaries() async {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<8 {
                group.addTask {
                    for offset in 0..<25 {
                        encoder.sendKeyPress(codepoint: UInt32(0x61 + ((taskIndex + offset) % 26)), modifiers: 0)
                    }
                }
            }
        }

        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()

        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        let frames = parseFrames(raw)
        #expect(frames?.count == 200)
        #expect(frames?.allSatisfy { $0.count == 6 && $0.first == OP_KEY_PRESS } == true)
    }
}
