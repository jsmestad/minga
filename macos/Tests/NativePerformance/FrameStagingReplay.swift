import Darwin
import Foundation
import MingaProtocol
import MingaUI
import os

/// One replayed workload's main-thread dispatch cost per committed frame (#3652).
///
/// The replay feeds packets captured from a real Editor (`bench/frame_staging_capture.exs`) through the production `CommandDispatcher`. Packets are decoded before timing, as the protocol reader does off the main thread, so each sample covers only the main-thread work: staging, freeze, publish, and the post-commit callbacks. The `FrameStage`, `FrameFreeze`, and `FramePublish` signposts split that work when Instruments records the run.
struct FrameStagingReplayMeasurement: Codable {
    let workload: String
    let measuredPackets: Int
    let measuredFrames: Int
    let measuredPacketBytes: Int
    let commandsPerFrameP50: Int
    let commandsPerFrameMax: Int
    let dispatchCPUP50Ms: Double
    let dispatchCPUP95Ms: Double
    let dispatchWallP50Ms: Double
    let dispatchWallP95Ms: Double
    let dispatchCPUSamplesMs: [Double]
    let sampleFrameSeqs: [UInt32]
    let sampleFullTranscriptReplace: [Bool]
    let signpostsEnabled: Bool
    let revision: String
}

private struct FrameStagingManifest: Decodable {
    let workload: String
    let measureFromPacket: Int

    enum CodingKeys: String, CodingKey {
        case workload
        case measureFromPacket = "measure_from_packet"
    }
}

private func readCapturedPackets(_ url: URL) throws -> [Data] {
    let bytes = try Data(contentsOf: url)
    var packets: [Data] = []
    var offset = bytes.startIndex
    while offset < bytes.endIndex {
        precondition(bytes.endIndex - offset >= 4, "truncated packet length in \(url.path)")
        var length = 0
        for index in 0..<4 { length = (length << 8) | Int(bytes[offset + index]) }
        let start = offset + 4
        precondition(bytes.endIndex - start >= length, "truncated packet payload in \(url.path)")
        packets.append(bytes.subdata(in: start..<(start + length)))
        offset = start + length
    }
    return packets
}

private func replayPercentile(_ samples: [Double], _ ratio: Double) -> Double {
    let sorted = samples.sorted()
    let index = min(max(Int((Double(sorted.count) * ratio).rounded(.up)) - 1, 0), sorted.count - 1)
    return sorted[index]
}

private func replayPercentile(_ samples: [Int], _ ratio: Double) -> Int {
    let sorted = samples.sorted()
    let index = min(max(Int((Double(sorted.count) * ratio).rounded(.up)) - 1, 0), sorted.count - 1)
    return sorted[index]
}

private struct PacketShape {
    var commits = 0
    var lastFrameSeq: UInt32 = 0
    var fullTranscriptReplace = false
}

private func packetShape(_ frame: DecodedFrame) -> PacketShape {
    var shape = PacketShape()
    for decoded in frame.commands {
        switch decoded.command {
        case .commitFrame(let frameSeq, _):
            shape.commits += 1
            shape.lastFrameSeq = frameSeq
        case .guiAgentTranscript(let mode, _, _, _, _, _):
            if mode == 0 { shape.fullTranscriptReplace = true }
        default:
            break
        }
    }
    return shape
}

/// Replays one capture and writes its measurement. Fails if any captured frame is rejected, because a rejected frame would measure recovery instead of the workload.
@MainActor
func runFrameStagingReplay(capturePath: String, manifestPath: String, outputURL: URL) throws {
    let manifest = try JSONDecoder().decode(
        FrameStagingManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
    )
    let packets = try readCapturedPackets(URL(fileURLWithPath: capturePath))
    precondition(manifest.measureFromPacket < packets.count, "capture has no measured packets")
    var frames: [DecodedFrame] = []
    frames.reserveCapacity(packets.count)
    for packet in packets { frames.append(try decodeFrame(from: packet)) }

    if ProcessInfo.processInfo.environment["MINGA_FRAME_STAGING_DESCRIBE"] == "1" {
        describeMeasuredCommands(frames.dropFirst(manifest.measureFromPacket))
        return
    }

    let guiState = GUIState()
    let dispatcher = CommandDispatcher(
        cols: 220, rows: 60, guiState: guiState, applicationEffectSink: { _ in }
    )
    var rejections: [FrameTransactionResult] = []
    dispatcher.onTransactionResult = { result in
        if case .applied = result { return }
        rejections.append(result)
    }

    var cpuSamples: [Double] = []
    var wallSamples: [Double] = []
    var commandsPerFrame: [Int] = []
    var frameSeqs: [UInt32] = []
    var fullReplace: [Bool] = []
    var measuredFrames = 0
    var measuredBytes = 0
    for (index, frame) in frames.enumerated() {
        let wallStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        dispatcher.dispatch(frame)
        let cpuEnd = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard index >= manifest.measureFromPacket else { continue }
        let shape = packetShape(frame)
        measuredBytes += packets[index].count
        guard shape.commits > 0 else { continue }
        measuredFrames += shape.commits
        frameSeqs.append(shape.lastFrameSeq)
        fullReplace.append(shape.fullTranscriptReplace)
        cpuSamples.append(Double(cpuEnd - cpuStart) / 1_000_000)
        wallSamples.append(Double(wallEnd - wallStart) / 1_000_000)
        commandsPerFrame.append(frame.commands.count)
    }
    precondition(rejections.isEmpty, "replay rejected frames: \(rejections.prefix(3))")

    precondition(!cpuSamples.isEmpty, "capture has no measured committed frames")

    let measurement = FrameStagingReplayMeasurement(
        workload: manifest.workload,
        measuredPackets: frames.count - manifest.measureFromPacket,
        measuredFrames: measuredFrames,
        measuredPacketBytes: measuredBytes,
        commandsPerFrameP50: replayPercentile(commandsPerFrame, 0.50),
        commandsPerFrameMax: commandsPerFrame.max() ?? 0,
        dispatchCPUP50Ms: replayPercentile(cpuSamples, 0.50),
        dispatchCPUP95Ms: replayPercentile(cpuSamples, 0.95),
        dispatchWallP50Ms: replayPercentile(wallSamples, 0.50),
        dispatchWallP95Ms: replayPercentile(wallSamples, 0.95),
        dispatchCPUSamplesMs: cpuSamples,
        sampleFrameSeqs: frameSeqs,
        sampleFullTranscriptReplace: fullReplace,
        // The frame signposts use `renderLog`; reading it directly keeps this file buildable against a base revision without them.
        signpostsEnabled: OSSignposter(logHandle: renderLog).isEnabled,
        revision: ProcessInfo.processInfo.environment["MINGA_BENCHMARK_REVISION"] ?? "unknown"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(measurement).write(to: outputURL, options: .atomic)
    let summary = String(
        format: "workload=%@ frames=%d commands_p50=%d dispatch_cpu_p50_ms=%.4f dispatch_cpu_p95_ms=%.4f signposts=%@\n",
        measurement.workload, measurement.measuredFrames, measurement.commandsPerFrameP50,
        measurement.dispatchCPUP50Ms, measurement.dispatchCPUP95Ms,
        measurement.signpostsEnabled ? "enabled" : "disabled"
    )
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// Prints measured command composition to standard error so a capture can be checked against the workload it claims to represent.
private func describeMeasuredCommands(_ frames: ArraySlice<DecodedFrame>) {
    var counts: [UInt8: Int] = [:]
    var ownedBytes: [UInt8: Int] = [:]
    var transcriptModes: [UInt8: Int] = [:]
    var transcriptMessages = 0
    for frame in frames {
        for decoded in frame.commands {
            counts[decoded.opcode, default: 0] += 1
            ownedBytes[decoded.opcode, default: 0] += decoded.resourceWeight.ownedUTF8Bytes
            if case .guiAgentTranscript(let mode, let epoch, let truncated, let trimFront, let baseCount, let messages) = decoded.command {
                transcriptModes[mode, default: 0] += 1
                transcriptMessages += messages.count
                if transcriptModes.values.reduce(0, +) <= 12 {
                    let first = messages.first?.beamId ?? 0
                    let last = messages.last?.beamId ?? 0
                    let detail = "transcript mode=\(mode) epoch=\(epoch) truncated=\(truncated) trim=\(trimFront) base=\(baseCount) count=\(messages.count) ids=\(first)...\(last)\n"
                    FileHandle.standardError.write(Data(detail.utf8))
                }
            }
        }
    }
    var lines = "opcode count owned_utf8_bytes\n"
    for opcode in counts.keys.sorted() {
        lines += String(format: "0x%02X %d %d\n", opcode, counts[opcode] ?? 0, ownedBytes[opcode] ?? 0)
    }
    lines += "transcript_modes=\(transcriptModes) transcript_messages=\(transcriptMessages)\n"
    FileHandle.standardError.write(Data(lines.utf8))
}
