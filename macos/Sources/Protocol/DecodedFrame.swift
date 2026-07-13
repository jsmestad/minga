/// Immutable values and deterministic metrics produced by one packet decode.

import Foundation
import MingaProtocol

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
/// Correlation recovered from a valid leading begin-frame command.
struct FrameEnvelope: Sendable, Equatable {
    let generation: UInt32
    let frameSeq: UInt32
    let baseFrameSeq: UInt32
}

/// A fully decoded failure. The optional envelope allows a resource rejection
/// to use the same correlated terminal status as a staged-frame rejection.
struct DecodedFrameFailure: Error, Sendable {
    let error: ProtocolDecodeError
    let envelope: FrameEnvelope?
}

enum DecodedFrameEvent: Sendable {
    case frame(DecodedFrame)
    case failure(DecodedFrameFailure)
}

struct DecodedFrame: Sendable {
    let commands: [DecodedCommand]
    let envelope: FrameEnvelope?
    let resourceWeight: FrameResourceWeight
    let metrics: FrameDecodeMetrics

    init(
        commands: [DecodedCommand], envelope: FrameEnvelope? = nil,
        resourceWeight: FrameResourceWeight = .init(), metrics: FrameDecodeMetrics
    ) {
        self.commands = commands
        self.envelope = envelope
        self.resourceWeight = resourceWeight
        self.metrics = metrics
    }

    func recordingActorHop() -> DecodedFrame {
        DecodedFrame(
            commands: commands,
            envelope: envelope,
            resourceWeight: resourceWeight,
            metrics: metrics.recordingActorHop()
        )
    }
}
