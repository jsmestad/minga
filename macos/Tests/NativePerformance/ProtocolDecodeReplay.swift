import Darwin
import Foundation
import MingaProtocol
import MingaUI
import Synchronization

/// Protocol decode time next to arrival-to-publish time for real captured frames (#3654).
///
/// The replay drives the production delivery path: `ProtocolReader` reads `{:packet, 4}` frames from a pipe on its own thread, decodes each payload with the production `decodeFrame`, and hands the frame to the main thread through `ProtocolEventHandoff`, where the production `CommandDispatcher` stages, freezes, and publishes it. Arrival is the moment the reader holds the complete payload, the same point as the `ProtocolPayloadReceived` signpost. Publish is the `.applied` transaction result, which the dispatcher reports right after `FramePublish` ends.
///
/// Keyframes arrive once per session, so the replay also repeats each workload's largest window-content and transcript-replace packet in fresh sessions to get a distribution for them.
struct ProtocolDecodeReplayMeasurement: Codable {
    let workload: String
    let revision: String
    let measureFromPacket: Int
    /// Mean cost of the instrumentation the replay adds per packet: four clock reads and one locked append, measured in a tight loop.
    let instrumentationOverheadNs: Double
    let packets: [ProtocolDecodeReplayPacket]
    let keyframeRepeats: [ProtocolDecodeReplayPacket]
}

/// One delivered packet. Times are wall-clock milliseconds.
struct ProtocolDecodeReplayPacket: Codable {
    let index: Int
    let bytes: Int
    let category: String
    let opcodes: String
    let transcriptMessages: Int
    let commits: Int
    /// `decodeFrame` call on the reader thread, measured around the call.
    let decodeCallMs: Double
    /// The decoder's own `FrameDecodeMetrics.decodeDuration`.
    let decodeMetricMs: Double
    /// Decode end to the start of main-thread dispatch: the reader-to-main handoff.
    let handoffMs: Double
    /// Dispatch start to the last `.applied` result of the packet; `-1` when the packet commits no frame.
    let dispatchToPublishMs: Double
    /// Arrival to the last `.applied` result of the packet; `-1` when the packet commits no frame.
    let arrivalToPublishMs: Double
}

/// Timestamps the reader thread writes. The single-slot handoff serializes packets, so entries stay in packet order.
private final class ReaderTimeline: Sendable {
    struct Entry {
        let arrival: UInt64
        let decodeEnd: UInt64
        let decodeMetricNs: Double
        let bytes: Int
    }

    let entries = Mutex<[Entry]>([])
    let disconnected = Mutex(false)
}

private func uptimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

private func milliseconds(_ nanoseconds: Double) -> Double {
    nanoseconds / 1_000_000
}

private func durationNanoseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000_000_000 + Double(components.attoseconds) / 1_000_000_000
}

private struct DeliveredShape {
    var category = "other"
    var opcodes = ""
    var transcriptMessages = 0
    var commits = 0
}

/// Names a packet by the most expensive kind of command it carries.
private func deliveredShape(_ frame: DecodedFrame) -> DeliveredShape {
    var shape = DeliveredShape()
    var seen = Set<UInt8>()
    var transcriptReplace = false
    var transcriptDelta = false
    for decoded in frame.commands {
        seen.insert(decoded.opcode)
        switch decoded.command {
        case .commitFrame:
            shape.commits += 1
        case .guiAgentTranscript(let mode, _, _, _, _, let messages):
            shape.transcriptMessages += messages.count
            if mode == 0 { transcriptReplace = true } else { transcriptDelta = true }
        default:
            break
        }
    }
    shape.opcodes = seen.sorted().map { String(format: "%02X", $0) }.joined(separator: " ")
    if transcriptReplace {
        shape.category = "agent_transcript_replace"
    } else if seen.contains(OP_GUI_WINDOW_CONTENT) {
        shape.category = "window_content"
    } else if transcriptDelta {
        shape.category = "agent_transcript_delta"
    } else if seen.contains(OP_GUI_WINDOW_ROWS_DELTA) {
        shape.category = "rows_delta"
    } else if seen.contains(OP_GUI_WINDOW_VIEWPORT_DELTA) {
        shape.category = "viewport_delta"
    } else if seen.contains(OP_GUI_WINDOW_OVERLAY_DELTA) {
        shape.category = "overlay_delta"
    }
    return shape
}

/// Main-thread side of one session: dispatch start, publish time, and packet shape per delivered packet.
@MainActor
private final class DispatchTimeline {
    var dispatchStarts: [UInt64] = []
    var lastPublish: [UInt64?] = []
    var shapes: [DeliveredShape] = []
    var rejections: [FrameTransactionResult] = []
}

private func framedPackets(_ packets: ArraySlice<Data>) -> Data {
    var stream = Data()
    stream.reserveCapacity(packets.reduce(0) { $0 + $1.count + 4 })
    for packet in packets {
        let length = UInt32(packet.count)
        stream.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        stream.append(packet)
    }
    return stream
}

/// Replays `packets` through the production reader, handoff, and dispatcher in a fresh session and returns one record per packet.
@MainActor
private func replaySession(_ packets: ArraySlice<Data>) -> [ProtocolDecodeReplayPacket] {
    let readerTimeline = ReaderTimeline()
    let dispatchTimeline = DispatchTimeline()
    let guiState = GUIState()
    let dispatcher = CommandDispatcher(
        cols: 220, rows: 60, guiState: guiState, applicationEffectSink: { _ in }
    )
    dispatcher.onTransactionResult = { result in
        if case .applied = result {
            dispatchTimeline.lastPublish[dispatchTimeline.lastPublish.count - 1] = uptimeNanoseconds()
            return
        }
        dispatchTimeline.rejections.append(result)
    }

    let handoff = ProtocolEventHandoff { event in
        guard case .frame(let frame) = event else {
            preconditionFailure("replay packet failed to decode")
        }
        dispatchTimeline.dispatchStarts.append(uptimeNanoseconds())
        dispatchTimeline.lastPublish.append(nil)
        dispatcher.dispatch(frame)
        dispatchTimeline.shapes.append(deliveredShape(frame))
    }

    let pipe = Pipe()
    let writeHandle = pipe.fileHandleForWriting
    let stream = framedPackets(packets)
    let writer = Thread {
        try? writeHandle.write(contentsOf: stream)
        try? writeHandle.close()
    }
    let reader = ProtocolReader(
        input: pipe.fileHandleForReading,
        decoder: { data in
            let arrival = uptimeNanoseconds()
            let frame = try decodeFrame(from: data)
            let decodeEnd = uptimeNanoseconds()
            let entry = ReaderTimeline.Entry(
                arrival: arrival, decodeEnd: decodeEnd,
                decodeMetricNs: durationNanoseconds(frame.metrics.decodeDuration), bytes: data.count
            )
            readerTimeline.entries.withLock { $0.append(entry) }
            return frame
        },
        handler: { frame in handoff.deliver(frame) },
        onDecodeFailure: { failure in handoff.deliver(failure) },
        onDisconnect: { readerTimeline.disconnected.withLock { $0 = true } },
        acquireAdmission: { handoff.acquireAdmission() },
        cancelAdmission: { handoff.cancel() }
    )
    writer.start()
    reader.start()
    while !readerTimeline.disconnected.withLock({ $0 }) {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    reader.stop()
    precondition(dispatchTimeline.rejections.isEmpty, "replay rejected frames: \(dispatchTimeline.rejections.prefix(3))")

    let entries = readerTimeline.entries.withLock { $0 }
    precondition(entries.count == packets.count && dispatchTimeline.shapes.count == packets.count, "replay delivered \(dispatchTimeline.shapes.count) of \(packets.count) packets")
    var records: [ProtocolDecodeReplayPacket] = []
    records.reserveCapacity(entries.count)
    for (offset, entry) in entries.enumerated() {
        let shape = dispatchTimeline.shapes[offset]
        let dispatchStart = dispatchTimeline.dispatchStarts[offset]
        var dispatchToPublish = -1.0
        var arrivalToPublish = -1.0
        if let publish = dispatchTimeline.lastPublish[offset] {
            dispatchToPublish = milliseconds(Double(publish - dispatchStart))
            arrivalToPublish = milliseconds(Double(publish - entry.arrival))
        }
        records.append(ProtocolDecodeReplayPacket(
            index: packets.startIndex + offset,
            bytes: entry.bytes,
            category: shape.category,
            opcodes: shape.opcodes,
            transcriptMessages: shape.transcriptMessages,
            commits: shape.commits,
            decodeCallMs: milliseconds(Double(entry.decodeEnd - entry.arrival)),
            decodeMetricMs: milliseconds(entry.decodeMetricNs),
            handoffMs: milliseconds(Double(dispatchStart - entry.decodeEnd)),
            dispatchToPublishMs: dispatchToPublish,
            arrivalToPublishMs: arrivalToPublish
        ))
    }
    return records
}

/// Mean cost of the per-packet instrumentation: four clock reads and one uncontended locked append.
private func instrumentationOverheadNanoseconds() -> Double {
    let iterations = 200_000
    let lock = Mutex<[UInt64]>([])
    lock.withLock { $0.reserveCapacity(iterations) }
    let start = uptimeNanoseconds()
    for _ in 0..<iterations {
        let first = uptimeNanoseconds()
        let second = uptimeNanoseconds()
        lock.withLock { $0.append(second &- first) }
        let third = uptimeNanoseconds()
        let fourth = uptimeNanoseconds()
        lock.withLock { $0[$0.count - 1] &+= fourth &- third }
    }
    return Double(uptimeNanoseconds() - start) / Double(iterations)
}

/// The largest packet of each keyframe category; these arrive once per session.
private func keyframeIndices(_ records: [ProtocolDecodeReplayPacket]) -> [Int] {
    var largest: [String: ProtocolDecodeReplayPacket] = [:]
    for record in records where record.category == "window_content" || record.category == "agent_transcript_replace" {
        if let current = largest[record.category], current.bytes >= record.bytes { continue }
        largest[record.category] = record
    }
    return largest.values.map(\.index).sorted()
}

/// Replays one capture once, then repeats its keyframes `keyframeRepeats` times, and writes the measurement.
@MainActor
func runProtocolDecodeReplay(capturePath: String, manifestPath: String, outputURL: URL, keyframeRepeats: Int) throws {
    let manifest = try JSONDecoder().decode(
        FrameStagingManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
    )
    let packets = try readCapturedPackets(URL(fileURLWithPath: capturePath))
    precondition(manifest.measureFromPacket < packets.count, "capture has no measured packets")

    let overhead = instrumentationOverheadNanoseconds()
    let records = replaySession(packets[...])
    var repeats: [ProtocolDecodeReplayPacket] = []
    for index in keyframeIndices(records) {
        for _ in 0..<keyframeRepeats {
            if let record = replaySession(packets[0...index]).last { repeats.append(record) }
        }
    }

    let measurement = ProtocolDecodeReplayMeasurement(
        workload: manifest.workload,
        revision: ProcessInfo.processInfo.environment["MINGA_BENCHMARK_REVISION"] ?? "unknown",
        measureFromPacket: manifest.measureFromPacket,
        instrumentationOverheadNs: overhead,
        packets: records,
        keyframeRepeats: repeats
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(measurement).write(to: outputURL, options: .atomic)
    let summary = "workload=\(manifest.workload) packets=\(records.count) keyframe_repeats=\(repeats.count) overhead_ns=\(String(format: "%.1f", overhead))\n"
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// Decodes one frame type's packets in a loop for `seconds`, without dispatch, so a sampling profiler can attribute decode time (#3654).
///
/// Delta categories use the measured packets; keyframe categories use the largest packet of that category in the capture.
func runProtocolDecodeLoop(capturePath: String, manifestPath: String, category: String, seconds: Int) throws {
    let manifest = try JSONDecoder().decode(
        FrameStagingManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
    )
    let packets = try readCapturedPackets(URL(fileURLWithPath: capturePath))
    let keyframe = category == "window_content" || category == "agent_transcript_replace"
    var chosen: [Data] = []
    for (index, packet) in packets.enumerated() where keyframe || index >= manifest.measureFromPacket {
        if deliveredShape(try decodeFrame(from: packet)).category == category { chosen.append(packet) }
    }
    if keyframe, let largest = chosen.max(by: { $0.count < $1.count }) { chosen = [largest] }
    precondition(!chosen.isEmpty, "capture has no \(category) packets")

    let deadline = uptimeNanoseconds() + UInt64(seconds) * 1_000_000_000
    var decoded = 0
    while uptimeNanoseconds() < deadline {
        for packet in chosen {
            _ = try decodeFrame(from: packet)
            decoded += 1
        }
    }
    FileHandle.standardOutput.write(Data("category=\(category) packets=\(chosen.count) decoded=\(decoded)\n".utf8))
}
