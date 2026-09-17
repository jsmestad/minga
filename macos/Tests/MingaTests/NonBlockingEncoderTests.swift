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

private final class ControlledWriter: @unchecked Sendable {
    enum Result {
        case write(Int)
        case wouldBlock
        case fatal(Int32)
        case writeAll
    }

    private let lock = NSLock()
    private var results: [Result] = []
    private var defaultResult: Result = .wouldBlock
    private var written = Data()

    func replaceResults(_ results: [Result], default defaultResult: Result = .wouldBlock) {
        lock.lock()
        self.results = results
        self.defaultResult = defaultResult
        lock.unlock()
    }

    func allowAllWrites() {
        replaceResults([], default: .writeAll)
    }

    func write(pointer: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let result = results.isEmpty ? defaultResult : results.removeFirst()
        switch result {
        case .write(let requestedCount):
            let actualCount = min(requestedCount, count)
            written.append(Data(bytes: pointer, count: actualCount))
            return actualCount
        case .wouldBlock:
            errno = EAGAIN
            return -1
        case .fatal(let errorCode):
            errno = errorCode
            return -1
        case .writeAll:
            written.append(Data(bytes: pointer, count: count))
            return count
        }
    }

    func writtenData() -> Data {
        lock.lock()
        let snapshot = written
        lock.unlock()
        return snapshot
    }
}

@MainActor
private final class TransportFailureCapture {
    private(set) var failures: [OutboundTransportFailureReport] = []

    func append(_ failure: OutboundTransportFailureReport) {
        MainActor.assertIsolated()
        failures.append(failure)
    }
}

@MainActor
private func awaitFailureCount(_ count: Int, capture: TransportFailureCapture) async {
    for _ in 0..<1_000 where capture.failures.count < count {
        await Task.yield()
    }
}

private func makeControlledEncoder(
    writer: ControlledWriter,
    maxBufferSize: Int = 1_024 * 1_024,
    maximumPayloadSize: Int = 1_024 * 1_024,
    nonBlockingSetupOperation: @escaping ProtocolEncoder.NonBlockingSetupOperation = { _ in nil },
    onTransportFailure: @escaping @MainActor @Sendable (OutboundTransportFailureReport) -> Void = { _ in },
    onInputRejection: @escaping @MainActor @Sendable (OutboundInputRejection) -> Void = { _ in }
) -> ProtocolEncoder {
    let pipe = Pipe()
    return try! ProtocolEncoder(
        output: pipe.fileHandleForWriting,
        maxBufferSize: maxBufferSize,
        maximumPayloadSize: maximumPayloadSize,
        retryDelay: nil,
        nonBlockingSetupOperation: nonBlockingSetupOperation,
        writeOperation: { _, pointer, count in
            writer.write(pointer: pointer, count: count)
        },
        onTransportFailure: onTransportFailure,
        onInputRejection: onInputRejection
    )
}

@Suite("Encoder: Non-blocking Buffer")
struct NonBlockingEncoderTests {
    @Test("writes are buffered and delivered asynchronously")
    func writesDeliveredAsynchronously() {
        let pipe = Pipe()
        let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)

        encoder.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0))
        encoder.send(.keyPress(codepoint: 0x62, modifiers: 0, sequence: 0))
        encoder.send(.resize(cols: 120, rows: 40))

        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()

        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        let frames = parseFrames(raw)
        #expect(frames?.count == 3)
        #expect(frames?[0].first == OP_KEY_PRESS)
        #expect(frames?[1].first == OP_KEY_PRESS)
        #expect(frames?[2].first == OP_RESIZE)
    }

    @Test("authoritative keys paste and GUI actions survive saturation in FIFO order")
    func authoritativeEventsSurviveSaturation() throws {
        let writer = ControlledWriter()
        let encoder = makeControlledEncoder(writer: writer)

        encoder.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 1))
        encoder.send(.paste("paste"))
        encoder.send(.selectTab(id: 42))
        encoder.send(.frameApplied(generation: 3, frameSequence: 7))
        encoder.send(.frameRejected(
            generation: 3,
            frameSequence: 8,
            lastAppliedFrameSequence: 7,
            reason: GeneratedProtocol.FrameRejectionReason.resourcePolicy.rawValue,
            disposition: GeneratedProtocol.FrameRejectionDisposition.terminalFrontendFailure.rawValue
        ))
        encoder.send(.keyPress(codepoint: 0x62, modifiers: 0, sequence: 2))
        #expect(encoder.waitForPendingWritesForTesting())
        #expect(writer.writtenData().isEmpty)

        writer.allowAllWrites()
        #expect(encoder.waitForPendingWritesForTesting())

        let frames = try #require(parseFrames(writer.writtenData()))
        #expect(
            frames.map(\.first) == [
                OP_KEY_PRESS,
                OP_PASTE_EVENT,
                OP_GUI_ACTION,
                OP_FRAME_APPLIED,
                OP_FRAME_REJECTED,
                OP_KEY_PRESS
            ]
        )
        #expect(frames[0][4] == 0x61)
        #expect(String(data: frames[1].subdata(in: 3..<frames[1].count), encoding: .utf8) == "paste")
        #expect(frames[2][1] == GUI_ACTION_SELECT_TAB)
        #expect(frames[5][4] == 0x62)
    }

    @Test("partial writes retain the head frame and resume from its explicit offset")
    func partialWritesRetainHeadOffset() throws {
        let writer = ControlledWriter()
        let encoder = makeControlledEncoder(writer: writer)
        encoder.send(.paste("authoritative paste"))
        encoder.send(.keyPress(codepoint: 0x6B, modifiers: 0, sequence: 0))
        encoder.send(.selectTab(id: 9))
        #expect(encoder.waitForPendingWritesForTesting())

        writer.replaceResults([.write(7), .wouldBlock])
        #expect(encoder.waitForPendingWritesForTesting())
        #expect(encoder.headWriteOffsetForTesting == 7)

        writer.allowAllWrites()
        #expect(encoder.waitForPendingWritesForTesting())

        let frames = try #require(parseFrames(writer.writtenData()))
        #expect(frames.map(\.first) == [OP_PASTE_EVENT, OP_KEY_PRESS, OP_GUI_ACTION])
        #expect(String(data: frames[0].subdata(in: 3..<frames[0].count), encoding: .utf8) == "authoritative paste")
        #expect(frames[2][1] == GUI_ACTION_SELECT_TAB)
    }

    @Test("resize coalescing cannot cross an authoritative barrier")
    func resizeCoalescingRespectsBarrier() throws {
        let writer = ControlledWriter()
        let encoder = makeControlledEncoder(writer: writer)

        encoder.send(.resize(cols: 80, rows: 24))
        encoder.send(.resize(cols: 90, rows: 30))
        encoder.send(.keyPress(codepoint: 0x78, modifiers: 0, sequence: 0))
        encoder.send(.resize(cols: 100, rows: 40))
        encoder.send(.resize(cols: 110, rows: 50))
        #expect(encoder.waitForPendingWritesForTesting())

        writer.allowAllWrites()
        #expect(encoder.waitForPendingWritesForTesting())

        let frames = try #require(parseFrames(writer.writtenData()))
        #expect(frames.map(\.first) == [OP_RESIZE, OP_KEY_PRESS, OP_RESIZE])
        #expect(frames[0][1...2] == Data([0, 90]))
        #expect(frames[2][1...2] == Data([0, 110]))
    }

    @Test("a partially written resize head is never coalesced")
    func partialResizeHeadIsNotCoalesced() throws {
        let writer = ControlledWriter()
        writer.replaceResults([.write(2), .wouldBlock])
        let encoder = makeControlledEncoder(writer: writer)

        encoder.send(.resize(cols: 80, rows: 24))
        #expect(encoder.waitForPendingWritesForTesting())
        #expect(encoder.headWriteOffsetForTesting == 2)
        encoder.send(.resize(cols: 100, rows: 40))

        writer.allowAllWrites()
        #expect(encoder.waitForPendingWritesForTesting())
        let frames = try #require(parseFrames(writer.writtenData()))
        #expect(frames.count == 2)
        #expect(frames[0][1...2] == Data([0, 80]))
        #expect(frames[1][1...2] == Data([0, 100]))
    }

    @Test("the maximum legal paste frame fits at exact capacity")
    func maximumLegalPasteFitsCapacity() throws {
        let writer = ControlledWriter()
        let maximumPastePayloadSize = 3 + Int(UInt16.max)
        let maximumPasteFrameSize = 4 + maximumPastePayloadSize
        let encoder = makeControlledEncoder(
            writer: writer,
            maxBufferSize: maximumPasteFrameSize,
            maximumPayloadSize: maximumPastePayloadSize
        )

        let text = String(repeating: "x", count: Int(UInt16.max) - 2) + "é"
        encoder.send(.paste(text))
        #expect(encoder.waitForPendingWritesForTesting())
        #expect(encoder.bufferedByteCount == maximumPasteFrameSize)
        writer.allowAllWrites()
        #expect(encoder.waitForPendingWritesForTesting())
        let frames = try #require(parseFrames(writer.writtenData()))
        #expect(frames.count == 1)
        let frame = try #require(frames.first)
        #expect(frame.prefix(3) == Data([OP_PASTE_EVENT, 0xFF, 0xFF]))
        #expect(String(data: frame.dropFirst(3), encoding: .utf8) == text)
    }

    @Test("oversized paste rejects all bytes without disconnecting", .timeLimit(.minutes(1)))
    @MainActor
    func oversizedPasteDoesNotTruncateOrDisconnect() async throws {
        let writer = ControlledWriter()
        let failures = TransportFailureCapture()
        let rejections = AsyncStream.makeStream(of: OutboundInputRejection.self, bufferingPolicy: .bufferingNewest(1))
        defer { rejections.continuation.finish() }
        let encoder = makeControlledEncoder(
            writer: writer,
            onTransportFailure: { failures.append($0) },
            onInputRejection: {
                MainActor.assertIsolated()
                rejections.continuation.yield($0)
            }
        )
        var iterator = rejections.stream.makeAsyncIterator()

        for text in [String(repeating: "x", count: 65_536), String(repeating: "x", count: 65_534) + "é"] {
            encoder.send(.paste(text))
            let rejection = await iterator.next()
            #expect(rejection == .pasteTooLarge(limitBytes: 65_535, attemptedBytes: 65_536))
            #expect(encoder.waitForPendingWritesForTesting())
            #expect(encoder.bufferedByteCount == 0)
            #expect(writer.writtenData().isEmpty)
        }

        encoder.send(.paste("é\n"))
        #expect(encoder.waitForPendingWritesForTesting())
        let acceptedFrame = encoder.bufferedDataForTesting()
        #expect(acceptedFrame.isEmpty == false)
        encoder.send(.paste(String(repeating: "x", count: 65_536)))
        let rejection = await iterator.next()
        #expect(rejection == .pasteTooLarge(limitBytes: 65_535, attemptedBytes: 65_536))
        #expect(encoder.bufferedDataForTesting() == acceptedFrame)
        encoder.send(.paste("ok"))
        writer.allowAllWrites()
        #expect(encoder.waitForPendingWritesForTesting())
        let frames = try #require(parseFrames(writer.writtenData()))
        #expect(frames == [
            Data([OP_PASTE_EVENT, 0, 3, 0xC3, 0xA9, 0x0A]),
            Data([OP_PASTE_EVENT, 0, 2, 0x6F, 0x6B])
        ])
        #expect(failures.failures.isEmpty)
    }

    @Test("production capacity admits the maximum legal protocol frame")
    func productionCapacityAdmitsMaximumFrame() {
        let writer = ControlledWriter()
        let maximumPayloadSize = Int(RESOURCE_MAX_FRAME_BYTES)
        let maximumFrameSize = maximumPayloadSize + 4
        let encoder = makeControlledEncoder(
            writer: writer,
            maxBufferSize: maximumFrameSize,
            maximumPayloadSize: maximumPayloadSize
        )

        encoder.writePayloadForTesting(Data(repeating: 0xA5, count: maximumPayloadSize))
        #expect(encoder.waitForPendingWritesForTesting())
        #expect(encoder.bufferedByteCount == maximumFrameSize)
    }

    @Test("lifecycle request and decision preserve synchronous admission under saturation")
    func lifecycleAdmissionRemainsSynchronous() throws {
        let writer = ControlledWriter()
        let encoder = makeControlledEncoder(
            writer: writer,
            maxBufferSize: 19,
            maximumPayloadSize: 15
        )

        #expect(encoder.send(.applicationQuitRequest(requestID: 42)).wasAccepted)
        #expect(encoder.send(.applicationQuitDecision(requestID: 42, decision: 1)).wasAccepted)
        #expect(encoder.bufferedByteCount == 19)

        writer.allowAllWrites()
        #expect(encoder.waitForPendingWritesForTesting())
        let frames = try #require(parseFrames(writer.writtenData()))
        #expect(frames.map(\.first) == [OP_APPLICATION_QUIT_REQUEST, OP_APPLICATION_QUIT_DECISION])
    }

    @Test("capacity exhaustion reports exactly one terminal failure")
    @MainActor
    func capacityExhaustionFailsOnce() async {
        let writer = ControlledWriter()
        let capture = TransportFailureCapture()
        let encoder = makeControlledEncoder(
            writer: writer,
            maxBufferSize: 14,
            maximumPayloadSize: 10,
            onTransportFailure: { failure in capture.append(failure) }
        )

        encoder.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0))
        encoder.send(.keyPress(codepoint: 0x62, modifiers: 0, sequence: 0))
        encoder.send(.paste("ignored after terminal failure"))
        await awaitFailureCount(1, capture: capture)

        #expect(capture.failures == [OutboundTransportFailureReport(
            failure: .capacityExhausted(limit: 14, attemptedFrameBytes: 14),
            undeliveredDurableFrameCount: 1,
            undeliveredDurableByteCount: 14
        )])
        #expect(encoder.bufferedByteCount == 0)
    }

    @Test("fatal writes report exactly one terminal failure")
    @MainActor
    func fatalWriteFailsOnce() async {
        let writer = ControlledWriter()
        writer.replaceResults([.write(5), .fatal(EPIPE)], default: .fatal(EPIPE))
        let capture = TransportFailureCapture()
        let encoder = makeControlledEncoder(
            writer: writer,
            onTransportFailure: { failure in capture.append(failure) }
        )

        encoder.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0))
        #expect(encoder.waitForPendingWritesForTesting())
        encoder.send(.keyPress(codepoint: 0x62, modifiers: 0, sequence: 0))
        #expect(encoder.waitForPendingWritesForTesting())
        await awaitFailureCount(1, capture: capture)

        #expect(capture.failures == [OutboundTransportFailureReport(
            failure: .writeFailed(errorCode: EPIPE),
            undeliveredDurableFrameCount: 1,
            undeliveredDurableByteCount: 9
        )])
    }

    @Test("unexpected disconnect reports accepted durable frames exactly once")
    @MainActor
    func unexpectedDisconnectReportsStrandedFramesOnce() async {
        let writer = ControlledWriter()
        let capture = TransportFailureCapture()
        let encoder = makeControlledEncoder(
            writer: writer,
            onTransportFailure: { failure in capture.append(failure) }
        )

        encoder.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0))
        encoder.send(.paste("accepted"))
        #expect(encoder.waitForPendingWritesForTesting())
        let strandedBytes = encoder.bufferedByteCount
        encoder.disconnect(reason: .unexpectedPeerClosure)
        encoder.disconnect(reason: .unexpectedPeerClosure)
        #expect(encoder.waitForPendingWritesForTesting())
        await awaitFailureCount(1, capture: capture)

        #expect(capture.failures == [OutboundTransportFailureReport(
            failure: .peerDisconnected,
            undeliveredDurableFrameCount: 2,
            undeliveredDurableByteCount: strandedBytes
        )])
    }

    @Test("failure report omits accepted-input loss when no durable frame is stranded")
    func zeroDurableFrameFailureMessage() {
        let report = OutboundTransportFailureReport(
            failure: .peerDisconnected,
            undeliveredDurableFrameCount: 0,
            undeliveredDurableByteCount: 0
        )

        #expect(report.userFacingMessage == OutboundTransportFailure.peerDisconnected.userFacingMessage)
        #expect(report.userFacingMessage.contains("Undelivered accepted input") == false)
    }

    @Test("failure report summarizes stranded accepted durable frames")
    func nonzeroDurableFrameFailureMessage() {
        let report = OutboundTransportFailureReport(
            failure: .peerDisconnected,
            undeliveredDurableFrameCount: 2,
            undeliveredDurableByteCount: 28
        )

        #expect(report.userFacingMessage.contains("Undelivered accepted input: 2 durable frames, 28 bytes."))
    }

    @Test("nonblocking setup failure rejects input and reports once")
    func nonBlockingSetupFailureIsTerminal() {
        let writer = ControlledWriter()
        writer.allowAllWrites()
        let pipe = Pipe()

        #expect(throws: OutboundTransportInitializationError.nonBlockingSetupFailed(errorCode: EPERM)) {
            try ProtocolEncoder(
                output: pipe.fileHandleForWriting,
                nonBlockingSetupOperation: { _ in EPERM },
                writeOperation: { _, pointer, count in
                    writer.write(pointer: pointer, count: count)
                }
            )
        }
        #expect(writer.writtenData().isEmpty)
    }

    @Test("saturated transport admission does not wait for pipe writability")
    @MainActor
    func saturationDoesNotBlockMainActor() {
        let pipe = Pipe()
        let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)
        fillPipeUntilWouldBlock(pipe.fileHandleForWriting.fileDescriptor)
        let start = ContinuousClock.now

        encoder.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0))

        #expect(start.duration(to: .now) < .milliseconds(100))
        pipe.fileHandleForWriting.closeFile()
        pipe.fileHandleForReading.closeFile()
    }

    @Test("expected teardown discards buffered writes without reporting failure")
    func expectedTeardownDiscardsBufferedWrites() {
        let pipe = Pipe()
        let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)

        encoder.disconnect(reason: .expectedTeardown)
        encoder.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0))
        encoder.send(.paste("dropped"))

        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()

        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(raw.isEmpty)
    }

    @Test("concurrent writes from multiple tasks keep frame boundaries")
    func concurrentWritesKeepFrameBoundaries() async {
        let pipe = Pipe()
        let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)

        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<8 {
                group.addTask {
                    for offset in 0..<25 {
                        encoder.send(.keyPress(codepoint: UInt32(0x61 + ((taskIndex + offset) % 26)), modifiers: 0, sequence: 0))
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
