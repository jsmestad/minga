import Foundation
import Metal
import MingaProtocol
import QuartzCore
import os

/// Metal does not expose a per-device 2D edge property. macOS 15's documented
/// feature tables guarantee and cap 2D textures at 16,384 for every supported
/// Mac GPU family; keep that device-API ceiling separate from configured policy.
func nativeDeviceTextureDimensionLimit(_ device: MTLDevice) -> Int {
    _ = device.registryID
    return 16_384
}

/// Native allocation dimension used by policy failures and presentation telemetry.
public enum NativeRenderResourceDimension: String, Sendable, Equatable {
    case textureWidth = "texture_width"
    case textureHeight = "texture_height"
    case rasterBytes = "raster_bytes"
    case atlasBytes = "atlas_bytes"
    case atlasSlots = "atlas_slots"
    case lineInstances = "line_instances"
    case quadInstances = "quad_instances"
    case drawBufferBytes = "draw_buffer_bytes"
    case texture
    case buffer
    case lineBuffer = "line_buffer"
    case quadBuffer0 = "quad_buffer_0"
    case quadBuffer1 = "quad_buffer_1"
    case quadBuffer2 = "quad_buffer_2"
    case rasterContext = "raster_context"
    case commandBuffer = "command_buffer"
    case encoder
    case renderTarget = "render_target"
    case presentationCommandBuffer = "presentation_command_buffer"
    case presentationEncoder = "presentation_encoder"
    case presentationCopy = "presentation_copy"
    case drawable
    case submission
    case completion
    case arithmetic
}

/// Metadata-only presentation failure. It deliberately contains no editor payload.
public struct NativePresentationFailure: Error, Sendable, Equatable {
    /// Renderer phase that discarded the candidate visual frame.
    public enum Phase: String, Sendable { case demand, raster, atlas, buffers, command, drawable, submission, completion }
    /// Stable failure category that contains no editor payload.
    public enum Reason: String, Sendable { case limit, overflow, allocation, unavailable, context, submission, completion, mismatch, injected }

    public let phase: Phase
    public let dimension: NativeRenderResourceDimension
    public let requested: Int?
    public let limit: Int?
    public let frameSequence: UInt32
    public let reason: Reason

    /// Creates a metadata-only failure for one discarded visual candidate.
    public init(phase: Phase, dimension: NativeRenderResourceDimension,
                requested: Int? = nil, limit: Int? = nil,
                frameSequence: UInt32 = 0, reason: Reason) {
        self.phase = phase
        self.dimension = dimension
        self.requested = requested
        self.limit = limit
        self.frameSequence = frameSequence
        self.reason = reason
    }
}

/// Exact checked demand derived from already-bounded visible preparation and
/// native ABI strides. No guessed slot or instance constants are accepted.
public struct NativeRenderDemand: Sendable, Equatable {
    public let textureWidth: Int
    public let textureHeight: Int
    public let rasterBytes: Int
    public let atlasSlots: Int
    public let atlasBytes: Int
    public let lineInstances: Int
    public let lineBufferBytes: Int
    public let quadInstances: Int
    public let quadBufferBytes: Int
    public let aggregateDrawBufferBytes: Int

    /// Computes exact native demand and rejects any checked policy or device boundary violation.
    public static func checked(
        textureWidth: Int, slotHeight: Int, atlasSlots: Int,
        lineInstances: Int, lineStride: Int,
        quadInstances: Int, quadStride: Int, quadBufferCount: Int,
        policy: FrameResourcePolicy.NativeRendererLimits,
        deviceTextureWidth: Int, deviceTextureHeight: Int,
        deviceMaxBufferLength: Int,
        frameSequence: UInt32 = 0
    ) throws -> Self {
        let values = [textureWidth, slotHeight, atlasSlots, lineInstances, lineStride,
                      quadInstances, quadStride, quadBufferCount]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw failure(.arithmetic, frameSequence, .overflow)
        }
        let widthLimit = min(policy.textureWidth, deviceTextureWidth)
        let heightLimit = min(policy.textureHeight, deviceTextureHeight)
        guard textureWidth <= widthLimit else {
            throw failure(.textureWidth, frameSequence, .limit, textureWidth, widthLimit)
        }
        let textureHeight = try multiply(atlasSlots, slotHeight, frameSequence)
        guard textureHeight <= heightLimit else {
            throw failure(.textureHeight, frameSequence, .limit, textureHeight, heightLimit)
        }
        let bytesPerRow = try multiply(textureWidth, 4, frameSequence)
        let rasterBytes = try multiply(bytesPerRow, slotHeight, frameSequence)
        guard rasterBytes <= policy.rasterBytes else {
            throw failure(.rasterBytes, frameSequence, .limit, rasterBytes, policy.rasterBytes)
        }
        let atlasBytes = try multiply(rasterBytes, atlasSlots, frameSequence)
        guard atlasBytes <= policy.atlasBytes else {
            throw failure(.atlasBytes, frameSequence, .limit, atlasBytes, policy.atlasBytes)
        }
        let lineBufferBytes = try multiply(lineInstances, lineStride, frameSequence)
        let oneQuadBufferBytes = try multiply(quadInstances, quadStride, frameSequence)
        let quadBufferBytes = try multiply(oneQuadBufferBytes, quadBufferCount, frameSequence)
        let aggregate = try add(lineBufferBytes, quadBufferBytes, frameSequence)
        guard lineBufferBytes <= deviceMaxBufferLength else {
            throw failure(.lineBuffer, frameSequence, .limit,
                          lineBufferBytes, deviceMaxBufferLength)
        }
        guard oneQuadBufferBytes <= deviceMaxBufferLength else {
            throw failure(.quadBuffer0, frameSequence, .limit,
                          oneQuadBufferBytes, deviceMaxBufferLength)
        }
        guard aggregate <= policy.aggregateDrawBufferBytes else {
            throw failure(.drawBufferBytes, frameSequence, .limit,
                          aggregate, policy.aggregateDrawBufferBytes)
        }
        return Self(textureWidth: textureWidth, textureHeight: textureHeight,
                    rasterBytes: rasterBytes, atlasSlots: atlasSlots, atlasBytes: atlasBytes,
                    lineInstances: lineInstances, lineBufferBytes: lineBufferBytes,
                    quadInstances: quadInstances, quadBufferBytes: quadBufferBytes,
                    aggregateDrawBufferBytes: aggregate)
    }

    /// Maximum complete slots under both the atlas byte ceiling and texture-height ceiling.
    public static func maximumAtlasSlots(textureWidth: Int, slotHeight: Int,
                                         policy: FrameResourcePolicy.NativeRendererLimits,
                                         deviceTextureHeight: Int,
                                         frameSequence: UInt32 = 0) throws -> Int {
        guard textureWidth > 0, slotHeight > 0 else { return 0 }
        let slotBytes = try multiply(try multiply(textureWidth, 4, frameSequence), slotHeight, frameSequence)
        return min(policy.atlasBytes / slotBytes,
                   min(policy.textureHeight, deviceTextureHeight) / slotHeight)
    }

    private static func multiply(_ lhs: Int, _ rhs: Int, _ seq: UInt32) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw failure(.arithmetic, seq, .overflow) }
        return value
    }

    private static func add(_ lhs: Int, _ rhs: Int, _ seq: UInt32) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw failure(.arithmetic, seq, .overflow) }
        return value
    }

    private static func failure(_ dimension: NativeRenderResourceDimension, _ seq: UInt32,
                                _ reason: NativePresentationFailure.Reason,
                                _ requested: Int? = nil, _ limit: Int? = nil) -> NativePresentationFailure {
        NativePresentationFailure(phase: .demand, dimension: dimension,
                                  requested: requested, limit: limit,
                                  frameSequence: seq, reason: reason)
    }
}

/// Exact byte demand for the complete line/quad candidate set.
struct NativeRenderTargetDemand: Sendable, Equatable {
    let width: Int
    let height: Int
    let byteCount: Int

    static func checked(width: Int, height: Int,
                        policy: FrameResourcePolicy.NativeRendererLimits,
                        deviceTextureDimension: Int,
                        frameSequence: UInt32) throws -> Self {
        guard width > 0, height > 0 else {
            throw NativePresentationFailure(
                phase: .drawable, dimension: .renderTarget,
                frameSequence: frameSequence, reason: .unavailable
            )
        }
        let widthLimit = min(policy.textureWidth, deviceTextureDimension)
        let heightLimit = min(policy.textureHeight, deviceTextureDimension)
        guard width <= widthLimit else {
            throw NativePresentationFailure(
                phase: .drawable, dimension: .textureWidth,
                requested: width, limit: widthLimit,
                frameSequence: frameSequence, reason: .limit
            )
        }
        guard height <= heightLimit else {
            throw NativePresentationFailure(
                phase: .drawable, dimension: .textureHeight,
                requested: height, limit: heightLimit,
                frameSequence: frameSequence, reason: .limit
            )
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw NativePresentationFailure(
                phase: .drawable, dimension: .arithmetic,
                frameSequence: frameSequence, reason: .overflow
            )
        }
        guard byteCount <= policy.renderTargetBytes else {
            throw NativePresentationFailure(
                phase: .drawable, dimension: .renderTarget,
                requested: byteCount, limit: policy.renderTargetBytes,
                frameSequence: frameSequence, reason: .limit
            )
        }
        return Self(width: width, height: height, byteCount: byteCount)
    }
}

struct NativeDrawBufferDemand: Sendable, Equatable {
    let lineBytes: Int
    let quadBytesPerBuffer: Int
    let aggregateBytes: Int

    static func checked(lineCount: Int, lineStride: Int,
                        quadPassCounts: [Int], quadStride: Int,
                        quadBufferCount: Int, alignment: Int,
                        limit: Int, deviceLimit: Int,
                        frameSequence: UInt32) throws -> Self {
        guard [lineCount, lineStride, quadStride, quadBufferCount, alignment]
            .allSatisfy({ $0 >= 0 }), quadPassCounts.allSatisfy({ $0 >= 0 }) else {
            throw NativePresentationFailure(phase: .buffers, dimension: .arithmetic,
                                            frameSequence: frameSequence, reason: .overflow)
        }
        func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            guard !overflow else {
                throw NativePresentationFailure(phase: .buffers, dimension: .arithmetic,
                                                frameSequence: frameSequence, reason: .overflow)
            }
            return value
        }
        func add(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else {
                throw NativePresentationFailure(phase: .buffers, dimension: .arithmetic,
                                                frameSequence: frameSequence, reason: .overflow)
            }
            return value
        }
        let lineBytes = try multiply(lineCount, lineStride)
        var quadBytes = 0
        for count in quadPassCounts where count > 0 {
            if alignment > 0 {
                let padding = (alignment - quadBytes % alignment) % alignment
                quadBytes = try add(quadBytes, padding)
            }
            quadBytes = try add(quadBytes, try multiply(count, quadStride))
        }
        let allQuadBytes = try multiply(quadBytes, quadBufferCount)
        let aggregate = try add(lineBytes, allQuadBytes)
        guard lineBytes <= deviceLimit else {
            throw NativePresentationFailure(
                phase: .buffers, dimension: .lineBuffer,
                requested: lineBytes, limit: deviceLimit,
                frameSequence: frameSequence, reason: .limit
            )
        }
        guard quadBytes <= deviceLimit else {
            throw NativePresentationFailure(
                phase: .buffers, dimension: .quadBuffer0,
                requested: quadBytes, limit: deviceLimit,
                frameSequence: frameSequence, reason: .limit
            )
        }
        guard aggregate <= limit else {
            throw NativePresentationFailure(
                phase: .buffers, dimension: .drawBufferBytes,
                requested: aggregate, limit: limit,
                frameSequence: frameSequence, reason: .limit
            )
        }
        return Self(lineBytes: lineBytes, quadBytesPerBuffer: quadBytes,
                    aggregateBytes: aggregate)
    }
}

/// Narrow renderer-owned allocation and scheduling seams. Production closures
/// call Metal directly; tests can fail one phase without mocking the Metal API.
@MainActor
struct NativeRenderFactories {
    var makeLibrary: (MTLDevice) -> MTLLibrary?
    var makeTexture: (MTLDevice, MTLTextureDescriptor) -> MTLTexture?
    var makeBuffer: (MTLDevice, Int, MTLResourceOptions) -> MTLBuffer?
    var makeRasterizer: () -> BitmapRasterizer
    var makeCommandBuffer: (MTLCommandQueue) -> MTLCommandBuffer?
    var makeEncoder: (MTLCommandBuffer, MTLRenderPassDescriptor) -> MTLRenderCommandEncoder?
    var makeBlitEncoder: (MTLCommandBuffer) -> MTLBlitCommandEncoder?
    /// Injectable gates for deterministic render and presentation-copy submission failures.
    var preSubmit: (MTLCommandBuffer) throws -> Void
    var prePresentationSubmit: (MTLCommandBuffer) throws -> Void
    /// Delivers only metadata from Metal's sendable completion callback back to the main actor.
    var observeCompletion: (
        MTLCommandBuffer,
        @escaping @MainActor @Sendable (_ succeeded: Bool, _ status: Int) -> Void
    ) -> Void
    /// Called only after the command that copied into the drawable completed successfully.
    var present: (CAMetalDrawable) throws -> Void
    var reportFailure: (NativePresentationFailure) -> Void

    static let production = Self(
        makeLibrary: { device in
            if let library = try? device.makeDefaultLibrary(bundle: Bundle.main) {
                return library
            }
            let executableURL = Bundle.main.executableURL!
            return try? device.makeLibrary(
                URL: executableURL.deletingLastPathComponent().appendingPathComponent("default.metallib")
            )
        },
        makeTexture: { device, descriptor in device.makeTexture(descriptor: descriptor) },
        makeBuffer: { device, length, options in device.makeBuffer(length: length, options: options) },
        makeRasterizer: { BitmapRasterizer() },
        makeCommandBuffer: { queue in queue.makeCommandBuffer() },
        makeEncoder: { commandBuffer, descriptor in
            commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        },
        makeBlitEncoder: { $0.makeBlitCommandEncoder() },
        preSubmit: { _ in },
        prePresentationSubmit: { _ in },
        observeCompletion: { commandBuffer, completion in
            commandBuffer.addCompletedHandler { @Sendable completed in
                let succeeded = completed.status == .completed
                let status = Int(completed.status.rawValue)
                Task { @MainActor in completion(succeeded, status) }
            }
        },
        present: { $0.present() },
        reportFailure: { failure in
            os_log(.error, log: OSLog(subsystem: "com.minga.editor", category: "NativePresentation"),
                   "Native presentation failed phase=%{public}@ dimension=%{public}@ reason=%{public}@ seq=%{public}u",
                   failure.phase.rawValue, failure.dimension.rawValue,
                   failure.reason.rawValue, failure.frameSequence)
        }
    )
}

/// Orders asynchronous resource promotion. A completion from an older frame
/// may never replace a generation that already completed later.
struct NativePresentationGeneration: Sendable, Equatable {
    struct Reservation: Sendable, Equatable {
        let generation: UInt64
        let slot: Int
    }

    private(set) var next: UInt64 = 0
    private(set) var completed: UInt64 = 0
    private var inFlightSlots: [UInt64: Int] = [:]

    var inFlightCount: Int { inFlightSlots.count }

    mutating func issue(slotCount: Int) -> Reservation? {
        guard slotCount > 0 else { return nil }
        guard let slot = (0..<slotCount).first(where: { !inFlightSlots.values.contains($0) }) else { return nil }
        next &+= 1
        inFlightSlots[next] = slot
        return Reservation(generation: next, slot: slot)
    }

    mutating func complete(_ generation: UInt64) -> Bool {
        guard inFlightSlots.removeValue(forKey: generation) != nil,
              generation > completed else { return false }
        completed = generation
        return true
    }

    mutating func retire(_ generation: UInt64) {
        inFlightSlots.removeValue(forKey: generation)
    }
}
