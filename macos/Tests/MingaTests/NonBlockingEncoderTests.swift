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

private final class ProtocolReaderCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var payloadSizes: [Int] = []

    func append(_ data: Data) {
        lock.lock()
        payloadSizes.append(data.count)
        lock.unlock()
    }

    func snapshot() -> [Int] {
        lock.lock()
        let sizes = payloadSizes
        lock.unlock()
        return sizes
    }
}

private func framedPayload(_ payload: Data) -> Data {
    var frame = Data(count: 4)
    let length = payload.count
    frame[0] = UInt8((length >> 24) & 0xFF)
    frame[1] = UInt8((length >> 16) & 0xFF)
    frame[2] = UInt8((length >> 8) & 0xFF)
    frame[3] = UInt8(length & 0xFF)
    frame.append(payload)
    return frame
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
        // Key press frames are 10 bytes: opcode + codepoint(4) + modifiers(1) +
        // correlation sequence(4) (ticket #2215).
        #expect(frames?.allSatisfy { $0.count == 10 && $0.first == OP_KEY_PRESS } == true)
    }
}

@Suite("ProtocolReader")
struct ProtocolReaderTests {
    @Test("rejects an oversized packet before reading or decoding its payload")
    func rejectsOversizedPacketBeforeDecode() throws {
        let stream = Data([0, 0, 0, 9])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minga-protocol-reader-limit-\(UUID().uuidString).bin")
        try stream.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = ProtocolReaderCapture()
        let disconnected = DispatchSemaphore(value: 0)
        let handle = try FileHandle(forReadingFrom: url)
        let reader = ProtocolReader(
            input: handle,
            maxPayloadLength: 8,
            decoder: { data in
                capture.append(data)
                return DecodedFrame(
                    commands: [],
                    metrics: FrameDecodeMetrics(
                        packetBytes: data.count,
                        bytesCopied: 0,
                        allocations: 0,
                        decodeDuration: .zero,
                        actorHopCount: 0
                    )
                )
            },
            handler: { _ in },
            onDecodeFailure: { _ in disconnected.signal() },
            onDisconnect: { disconnected.signal() }
        )

        reader.start()
        #expect(disconnected.wait(timeout: .now() + 2) == .success)
        try handle.close()
        #expect(capture.snapshot().isEmpty)
    }

    @Test("accepts large render payloads and preserves packet alignment")
    func acceptsLargeRenderPayloads() throws {
        let largePayload = Data(repeating: 0xAB, count: 1_100_000)
        let smallPayload = Data([0x01, 0x02, 0x03])
        var stream = Data()
        stream.append(framedPayload(largePayload))
        stream.append(framedPayload(smallPayload))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minga-protocol-reader-\(UUID().uuidString).bin")
        try stream.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = ProtocolReaderCapture()
        let disconnected = DispatchSemaphore(value: 0)
        let handle = try FileHandle(forReadingFrom: url)
        let reader = ProtocolReader(
            input: handle,
            maxPayloadLength: 2_000_000,
            decoder: { data in
                DecodedFrame(
                    commands: [],
                    metrics: FrameDecodeMetrics(
                        packetBytes: data.count,
                        bytesCopied: 0,
                        allocations: 0,
                        decodeDuration: .zero,
                        actorHopCount: 0
                    )
                )
            },
            handler: { frame in
                capture.append(Data(count: frame.metrics.packetBytes))
            },
            onDecodeFailure: { _ in
                disconnected.signal()
            },
            onDisconnect: {
                disconnected.signal()
            }
        )

        reader.start()
        #expect(disconnected.wait(timeout: .now() + 2) == .success)
        try handle.close()

        #expect(capture.snapshot() == [largePayload.count, smallPayload.count])
    }
}
