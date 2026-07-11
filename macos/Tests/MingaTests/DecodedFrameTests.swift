import Foundation
import Testing

@Suite("Transactional frame decoding")
struct DecodedFrameTests {
    @Test("later truncation publishes no partial commands")
    func atomicFailure() {
        var packet = Data([OP_SET_WINDOW_BG, 1, 2, 3, OP_SET_TITLE, 0, 4])
        packet.append(contentsOf: [0x61, 0x62])
        var published: [RenderCommand] = []

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommands(from: packet) { published.append($0) }
        }
        #expect(published.isEmpty)
    }

    @Test("nested string lengths cannot consume the following command")
    func nestedLengthIsSectionBounded() {
        var packet = Data([OP_GUI_STATUS_BAR, 1, 0x03, 0, 10])
        packet.append(Data(repeating: 0, count: 8))
        packet.append(contentsOf: [0, 4]) // hint length exceeds this section
        packet.append(contentsOf: [OP_SET_WINDOW_BG, 1, 2, 3])
        var published: [RenderCommand] = []

        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommands(from: packet) { published.append($0) }
        }
        #expect(published.isEmpty)
    }

    @Test("unknown size-framed commands fail closed")
    func unknownSizedCommand() {
        let packet = Data([0xB7, 0, 2, 0xAA, 0xBB])
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeFrame(from: packet)
        }
    }

    @Test("metrics expose zero tail copies and one frame allocation")
    func metrics() throws {
        let packet = Data([OP_SET_WINDOW_BG, 1, 2, 3, OP_COMMIT_FRAME, 0, 0, 0, 1, 0, 0, 0, 2])
        let frame = try decodeFrame(from: packet, collectOwnedMetrics: true)

        #expect(frame.commands.count == 2)
        #expect(frame.metrics.packetBytes == packet.count)
        #expect(frame.metrics.bytesCopied == 0)
        #expect(frame.metrics.allocations == 1)
        #expect(frame.metrics.actorHopCount == 0)
        #expect(frame.recordingActorHop().metrics.actorHopCount == 1)
        #expect(frame.metrics.decodeDuration >= .zero)
    }

    @Test("production decode skips deep owned-value accounting")
    func productionMetricsStayLightweight() throws {
        let packet = makeRenderingPacket(size: 64 * 1024)
        let frame = try decodeFrame(from: packet)

        #expect(frame.metrics.bytesCopied == -1)
        #expect(frame.metrics.allocations == -1)
    }

    @Test("release scaling seam covers 64 KiB through 64 MiB")
    func releaseScalingSeam() throws {
        let sizes = [64 * 1024, 1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024]
        var baselineNanoseconds = 0.0

        for packetSize in sizes {
            let packet = makeRenderingPacket(size: packetSize)
            let frame = try decodeFrame(from: packet, collectOwnedMetrics: true)
            let elapsed = nanoseconds(frame.metrics.decodeDuration)
            if baselineNanoseconds == 0 { baselineNanoseconds = max(elapsed, 1_000) }
            let linearBudget = max(1_000_000, baselineNanoseconds * Double(packetSize / sizes[0]) * 4)

            #expect(frame.metrics.packetBytes == packetSize)
            #expect(frame.metrics.bytesCopied == packetSize - frame.commands.count * 3)
            #expect(frame.metrics.allocations == frame.commands.count + 1)
            #expect(elapsed <= linearBudget)
        }
    }

    private func nanoseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000_000_000 + Double(components.attoseconds) / 1_000_000_000
    }

    private func makeRenderingPacket(size: Int) -> Data {
        var packet = Data(capacity: size)
        var remaining = size
        while remaining > 65_538 {
            let commandSize = remaining - 65_538 == 1 ? 65_537 : 65_538
            let textSize = commandSize - 3
            packet.append(OP_SET_TITLE)
            packet.append(UInt8((textSize >> 8) & 0xFF))
            packet.append(UInt8(textSize & 0xFF))
            packet.append(Data(repeating: 0x61, count: textSize))
            remaining -= commandSize
        }
        if remaining == 2 {
            packet.append(contentsOf: [OP_SET_CURSOR_SHAPE, CURSOR_BLOCK])
        } else if remaining >= 3 {
            let textSize = remaining - 3
            packet.append(OP_SET_TITLE)
            packet.append(UInt8((textSize >> 8) & 0xFF))
            packet.append(UInt8(textSize & 0xFF))
            packet.append(Data(repeating: 0x61, count: textSize))
        }
        return packet
    }
}

private final class DecodeThreadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var decodedOnMain = true
    private var hops = 0

    func record(decodedOnMain: Bool, hops: Int) {
        lock.lock()
        self.decodedOnMain = decodedOnMain
        self.hops = hops
        lock.unlock()
    }

    func snapshot() -> (decodedOnMain: Bool, hops: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (decodedOnMain, hops)
    }
}

@Suite("ProtocolReader decode isolation")
struct ProtocolReaderDecodeIsolationTests {
    @Test("binary decoding executes off main before the actor handoff")
    func offMainDecode() throws {
        let payload = Data([OP_SET_WINDOW_BG, 1, 2, 3])
        var stream = Data([0, 0, 0, UInt8(payload.count)])
        stream.append(payload)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minga-decoder-isolation-\(UUID().uuidString).bin")
        try stream.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = DecodeThreadCapture()
        let delivered = DispatchSemaphore(value: 0)
        let disconnected = DispatchSemaphore(value: 0)
        let handle = try FileHandle(forReadingFrom: url)
        let reader = ProtocolReader(
            input: handle,
            decoder: { data in
                let onMain = Thread.isMainThread
                let frame = try decodeFrame(from: data)
                capture.record(decodedOnMain: onMain, hops: frame.metrics.actorHopCount)
                return frame
            },
            handler: { frame in
                capture.record(decodedOnMain: capture.snapshot().decodedOnMain, hops: frame.metrics.actorHopCount)
                delivered.signal()
            },
            onDecodeFailure: { _ in delivered.signal() },
            onDisconnect: { disconnected.signal() }
        )

        reader.start()
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(disconnected.wait(timeout: .now() + 2) == .success)
        try handle.close()

        let result = capture.snapshot()
        #expect(!result.decodedOnMain)
        #expect(result.hops == 0)
    }
}

@Suite("Ordered protocol event handoff")
struct ProtocolEventHandoffTests {
    @Test("multiple decoded packets reach one main-actor consumer in wire order")
    func preservesPacketOrder() async throws {
        let packets = [
            Data([OP_SET_WINDOW_BG, 1, 2, 3]),
            Data([OP_SET_TITLE, 0, 1, 0x78]),
            Data([OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 9])
        ]
        let frames = try packets.map { try decodeFrame(from: $0) }
        let handoff = ProtocolEventHandoff()

        let consumer = Task { @MainActor in
            var opcodes: [UInt8] = []
            var hops: [Int] = []
            for await event in handoff.events {
                guard case .frame(let frame) = event else { continue }
                opcodes.append(contentsOf: frame.commands.map(\.opcode))
                hops.append(frame.metrics.actorHopCount)
                if opcodes.count == packets.count { break }
            }
            return (opcodes, hops)
        }

        for frame in frames {
            handoff.deliver(frame)
        }

        let result = await consumer.value
        #expect(result.0 == [OP_SET_WINDOW_BG, OP_SET_TITLE, OP_COMMIT_FRAME])
        #expect(result.1 == [1, 1, 1])
    }
}
