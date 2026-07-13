import Foundation
import MingaProtocol
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

    @Test("resource usage freezes into the decoded frame")
    func frozenResourceUsage() throws {
        let packet = Data([OP_SET_TITLE, 0, 3, 0x61, 0x62, 0x63])
        let frame = try decodeFrame(from: packet)

        #expect(frame.resourceWeight.commands == 1)
        #expect(frame.resourceWeight.ownedUTF8Bytes == 3)
        #expect(frame.resourceWeight.arrayEntries == 1)
    }

    @Test("array reservation rejects before payload-proportional allocation")
    func arrayPreallocationLimit() {
        let packet = Data([
            OP_GUI_THEME, 3,
            1, 1, 2, 3,
            2, 4, 5, 6,
            3, 7, 8, 9
        ])
        let defaults = FrameResourcePolicy.default
        let policy = FrameResourcePolicy(
            wire: defaults.wire,
            decode: .init(weight: .init(
                commands: 1, ownedUTF8Bytes: 64, arrayEntries: 2,
                rows: 0, spans: 0, overlays: 0, spliceEntries: 0, locatorEntries: 0
            )),
            staging: defaults.staging,
            resident: defaults.resident
        )

        do {
            _ = try decodeFrame(from: packet, policy: policy)
            Issue.record("expected array-entry resource rejection")
        } catch let error as ProtocolDecodeError {
            #expect(error.isResourceFailure)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("generated picker strings and both item arrays reserve before materialization")
    func generatedPickerReservations() throws {
        let items = Data([
            0, 1,
            0, 0, 0, 0,
            0, 1, 0x61,
            0, 1, 0x62,
            0, 1, 0x63,
            1, 0, 2
        ])
        var packet = Data([OP_GUI_PICKER, 1, 0x03, 0, UInt8(items.count)])
        packet.append(items)
        let defaults = FrameResourcePolicy.default
        let constrained = FrameResourcePolicy(
            wire: defaults.wire,
            decode: .init(weight: .init(
                commands: 1, ownedUTF8Bytes: 3, arrayEntries: 2,
                rows: 0, spans: 0, overlays: 0, spliceEntries: 0, locatorEntries: 0
            )),
            staging: defaults.staging,
            resident: defaults.resident
        )

        do {
            _ = try decodeFrame(from: packet, policy: constrained)
            Issue.record("expected mapped picker array reservation to exceed the limit")
        } catch let error as ProtocolDecodeError {
            #expect(error.isResourceFailure)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let frame = try decodeFrame(from: packet)
        #expect(frame.resourceWeight.ownedUTF8Bytes == 3)
        #expect(frame.resourceWeight.arrayEntries == 4)
    }

    @Test("reservation probe runs before array materialization")
    func reservationProbeOrder() throws {
        let packet = Data([
            OP_GUI_THEME, 2,
            1, 1, 2, 3,
            2, 4, 5, 6
        ])
        let capture = ReservationCapture()
        _ = try decodeFrame(from: packet, reservationProbe: { dimension, resulting in
            capture.record(dimension, resulting: resulting)
        })

        #expect(capture.snapshot().contains(.arrayEntries, resulting: 2))
    }

    @Test("resource arithmetic rejects overflow without trapping")
    func checkedWeightOverflow() {
        let nearMaximum = FrameResourceWeight(ownedUTF8Bytes: .max)
        #expect(throws: FrameResourceError.arithmeticOverflow) {
            _ = try nearMaximum.adding(FrameResourceWeight(ownedUTF8Bytes: 1))
        }
    }

    @Test("correlated resource failure retains the leading frame envelope")
    func correlatedFailureEnvelope() {
        var packet = Data([OP_BEGIN_FRAME, 0, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0, 9])
        packet.append(contentsOf: [OP_SET_TITLE, 0, 2, 0x61, 0x62])
        let defaults = FrameResourcePolicy.default
        let policy = FrameResourcePolicy(
            wire: defaults.wire,
            decode: .init(weight: .init(
                commands: 2, ownedUTF8Bytes: 1, arrayEntries: 0,
                rows: 0, spans: 0, overlays: 0, spliceEntries: 0, locatorEntries: 0
            )),
            staging: defaults.staging,
            resident: defaults.resident
        )

        do {
            _ = try decodeFrame(from: packet, policy: policy)
            Issue.record("expected correlated resource rejection")
        } catch let error as ProtocolDecodeError {
            #expect(error.isResourceFailure)
            #expect(error.frameEnvelope == FrameEnvelope(
                generation: 9, frameSeq: 7, baseFrameSeq: 3
            ))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("production decode skips deep owned-value accounting")
    func productionMetricsStayLightweight() throws {
        let packet = makeRenderingPacket(size: 64 * 1024)
        let frame = try decodeFrame(from: packet)

        #expect(frame.metrics.bytesCopied == -1)
        #expect(frame.metrics.allocations == -1)
    }

    @Test("deterministic copy scaling seam covers 64 KiB through 64 MiB")
    func releaseScalingSeam() throws {
        let sizes = [64 * 1024, 1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024]

        for packetSize in sizes {
            let packet = makeRenderingPacket(size: packetSize)
            let frame = try decodeFrame(from: packet, collectOwnedMetrics: true)

            #expect(frame.metrics.packetBytes == packetSize)
            #expect(frame.metrics.bytesCopied == packetSize - frame.commands.count * 3)
            #expect(frame.metrics.allocations == frame.commands.count + 1)
        }
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

private final class ReservationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(FrameResourceDimension, Int)] = []

    func record(_ dimension: FrameResourceDimension, resulting: Int) {
        lock.lock()
        values.append((dimension, resulting))
        lock.unlock()
    }

    func snapshot() -> ReservationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ReservationSnapshot(values: values)
    }
}

private struct ReservationSnapshot {
    let values: [(FrameResourceDimension, Int)]

    func contains(_ dimension: FrameResourceDimension, resulting: Int) -> Bool {
        values.contains { $0.0 == dimension && $0.1 == resulting }
    }
}

private final class DecodeThreadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var decodedOnMain = true
    private var hops = 0
    private var admitted = false
    private var decoderSawAdmission = false

    func recordAdmission() {
        lock.lock()
        admitted = true
        lock.unlock()
    }

    func record(decodedOnMain: Bool, hops: Int) {
        lock.lock()
        self.decodedOnMain = decodedOnMain
        self.hops = hops
        decoderSawAdmission = admitted
        lock.unlock()
    }

    func snapshot() -> (decodedOnMain: Bool, hops: Int, decoderSawAdmission: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (decodedOnMain, hops, decoderSawAdmission)
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
            onDisconnect: { disconnected.signal() },
            acquireAdmission: {
                capture.recordAdmission()
                return true
            }
        )

        reader.start()
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(disconnected.wait(timeout: .now() + 2) == .success)
        try handle.close()

        let result = capture.snapshot()
        #expect(!result.decodedOnMain)
        #expect(result.hops == 0)
        #expect(result.decoderSawAdmission)
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
                handoff.releaseAdmission()
                guard case .frame(let frame) = event else { continue }
                opcodes.append(contentsOf: frame.commands.map(\.opcode))
                hops.append(frame.metrics.actorHopCount)
                if opcodes.count == packets.count { break }
            }
            return (opcodes, hops)
        }

        for frame in frames {
            #expect(handoff.acquireAdmission())
            handoff.deliver(frame)
        }

        let result = await consumer.value
        handoff.cancel()
        #expect(result.0 == [OP_SET_WINDOW_BG, OP_SET_TITLE, OP_COMMIT_FRAME])
        #expect(result.1 == [1, 1, 1])
    }

    @Test("cancelled handoff cannot deliver stale events")
    func cancelledHandoffDropsStaleDelivery() async throws {
        let handoff = ProtocolEventHandoff()
        let frame = try decodeFrame(from: Data([OP_SET_WINDOW_BG, 1, 2, 3]))
        #expect(handoff.acquireAdmission())
        handoff.cancel()
        handoff.deliver(frame)

        var received = 0
        for await _ in handoff.events { received += 1 }
        #expect(received == 0)
    }

    @Test("cancellation wakes a producer blocked behind the capacity-one slot")
    func cancellationWakesAdmission() async {
        let handoff = ProtocolEventHandoff()
        #expect(handoff.acquireAdmission())

        let blocked = Task.detached { handoff.acquireAdmission() }
        handoff.cancel()

        #expect(await blocked.value == false)
        #expect(handoff.acquireAdmission() == false)
    }
}
