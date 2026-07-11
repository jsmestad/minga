/// Immutable values and deterministic metrics produced by one packet decode.

import Foundation

struct DecodedCommand: Sendable {
    let command: RenderCommand
    let opcode: UInt8
}

struct DecoderOwnedMetrics {
    private(set) var bytesCopied = 0
    private(set) var allocations = 0

    /// Records owned values that the decoder publishes beyond the packet lifetime.
    /// Packet views and scalar enum payloads do not allocate owned byte storage.
    mutating func record(_ value: Any) {
        if let string = value as? String {
            bytesCopied += string.utf8.count
            allocations += 1
            return
        }
        if let data = value as? Data {
            bytesCopied += data.count
            if !data.isEmpty { allocations += 1 }
            return
        }

        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .collection, .dictionary, .set:
            if !mirror.children.isEmpty { allocations += 1 }
        default:
            break
        }
        for child in mirror.children {
            record(child.value)
        }
    }

    mutating func recordFrameCommandStorage(count: Int) {
        if count > 0 { allocations += 1 }
    }
}

struct FrameDecodeMetrics: Sendable, Equatable {
    let packetBytes: Int
    /// Owned-byte count, or `-1` when deep Release-harness accounting is disabled.
    let bytesCopied: Int
    /// Owned-allocation count, or `-1` when deep Release-harness accounting is disabled.
    let allocations: Int
    let decodeDuration: Duration
    let actorHopCount: Int

    func recordingActorHop() -> FrameDecodeMetrics {
        FrameDecodeMetrics(
            packetBytes: packetBytes,
            bytesCopied: bytesCopied,
            allocations: allocations,
            decodeDuration: decodeDuration,
            actorHopCount: actorHopCount + 1
        )
    }
}

/// A fully validated packet. No command is observable until this value exists.
/// The main-actor dispatcher consumes the whole value and compiles its commands
/// directly into a `PreparedFrameTransactionBuilder`; it never stores packet views
/// or publishes commands individually.
struct DecodedFrame: Sendable {
    let commands: [DecodedCommand]
    let metrics: FrameDecodeMetrics

    func recordingActorHop() -> DecodedFrame {
        DecodedFrame(commands: commands, metrics: metrics.recordingActorHop())
    }
}
