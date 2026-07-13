import Foundation

/// Immutable limits applied at the four resource-accounting phases of a frame.
public struct FrameResourcePolicy: Sendable, Equatable {
    /// Maximum packet bytes admitted before payload allocation.
    public struct WireLimits: Sendable, Equatable {
        public let payloadBytes: Int
        /// Creates a wire-byte ceiling.
        public init(payloadBytes: Int) { self.payloadBytes = payloadBytes }
    }
    /// Limits for one decoder pass.
    public struct DecodeLimits: Sendable, Equatable {
        public let weight: FrameResourceWeight
        /// Creates a decoder weight ceiling.
        public init(weight: FrameResourceWeight) { self.weight = weight }
    }
    /// Limits for phase-local semantic staging.
    public struct StagingLimits: Sendable, Equatable {
        public let weight: FrameResourceWeight
        /// Creates a staging weight ceiling.
        public init(weight: FrameResourceWeight) { self.weight = weight }
    }
    /// Exact limits retained by one published window.
    public struct ResidentLimits: Sendable, Equatable {
        public let weightPerWindow: FrameResourceWeight
        /// Creates a per-window resident weight ceiling.
        public init(weightPerWindow: FrameResourceWeight) { self.weightPerWindow = weightPerWindow }
    }
    /// Renderer-owned native allocation ceilings. These are presentation-health
    /// limits only and are never consulted by semantic frame publication.
    public struct NativeRendererLimits: Sendable, Equatable {
        public let rasterBytes: Int
        public let atlasBytes: Int
        public let aggregateDrawBufferBytes: Int
        public let renderTargetBytes: Int
        public let textureWidth: Int
        public let textureHeight: Int

        /// Creates deterministic native allocation ceilings for one renderer instance.
        public init(rasterBytes: Int, atlasBytes: Int, aggregateDrawBufferBytes: Int,
                    renderTargetBytes: Int = 256 * 1_048_576,
                    textureWidth: Int, textureHeight: Int) {
            self.rasterBytes = rasterBytes
            self.atlasBytes = atlasBytes
            self.aggregateDrawBufferBytes = aggregateDrawBufferBytes
            self.renderTargetBytes = renderTargetBytes
            self.textureWidth = textureWidth
            self.textureHeight = textureHeight
        }

        public static let `default` = NativeRendererLimits(
            rasterBytes: 64 * 1_048_576, atlasBytes: 256 * 1_048_576,
            aggregateDrawBufferBytes: 64 * 1_048_576,
            renderTargetBytes: 256 * 1_048_576,
            textureWidth: 16_384, textureHeight: 16_384
        )
    }

    public let wire: WireLimits
    public let decode: DecodeLimits
    public let staging: StagingLimits
    public let resident: ResidentLimits
    public let nativeRenderer: NativeRendererLimits

    /// Creates immutable phase slices at the composition root.
    public init(
        wire: WireLimits, decode: DecodeLimits,
        staging: StagingLimits, resident: ResidentLimits,
        nativeRenderer: NativeRendererLimits = .default
    ) {
        self.wire = wire
        self.decode = decode
        self.staging = staging
        self.resident = resident
        self.nativeRenderer = nativeRenderer
    }

    /// Production policy. Decode, staging, and per-window residence retain
    /// headroom above the 65,536-row corpus for ordinary structural edits.
    public static let `default` = FrameResourcePolicy(
        wire: WireLimits(payloadBytes: 64 * 1_048_576),
        decode: DecodeLimits(weight: .init(
            commands: 131_072, ownedUTF8Bytes: 64 * 1_048_576, arrayEntries: 4_194_304,
            rows: 131_072, spans: 2_097_152, overlays: 1_048_576,
            spliceEntries: 131_072, locatorEntries: 131_072
        )),
        staging: StagingLimits(weight: .init(
            commands: 131_072, ownedUTF8Bytes: 64 * 1_048_576, arrayEntries: 8_388_608,
            rows: 1_048_576, spans: 4_194_304, overlays: 2_097_152,
            spliceEntries: 131_072, locatorEntries: 1_048_576
        )),
        resident: ResidentLimits(weightPerWindow: .init(
            commands: .max, ownedUTF8Bytes: 256 * 1_048_576, arrayEntries: .max,
            rows: 131_072, spans: 4_194_304, overlays: 2_097_152,
            spliceEntries: .max, locatorEntries: 131_072
        ))
    )
}

/// Exact, checked resource dimensions shared by decode, staging, and residency.
public struct FrameResourceWeight: Sendable, Equatable {
    public var commands: Int
    public var ownedUTF8Bytes: Int
    public var arrayEntries: Int
    public var rows: Int
    public var spans: Int
    public var overlays: Int
    public var spliceEntries: Int
    public var locatorEntries: Int

    /// Creates an exact multidimensional weight.
    public init(
        commands: Int = 0, ownedUTF8Bytes: Int = 0, arrayEntries: Int = 0,
        rows: Int = 0, spans: Int = 0, overlays: Int = 0,
        spliceEntries: Int = 0, locatorEntries: Int = 0
    ) {
        self.commands = commands
        self.ownedUTF8Bytes = ownedUTF8Bytes
        self.arrayEntries = arrayEntries
        self.rows = rows
        self.spans = spans
        self.overlays = overlays
        self.spliceEntries = spliceEntries
        self.locatorEntries = locatorEntries
    }

    /// Returns the checked component-wise sum.
    public func adding(_ other: Self) throws -> Self {
        Self(
            commands: try Self.add(commands, other.commands, .commands),
            ownedUTF8Bytes: try Self.add(ownedUTF8Bytes, other.ownedUTF8Bytes, .ownedUTF8Bytes),
            arrayEntries: try Self.add(arrayEntries, other.arrayEntries, .arrayEntries),
            rows: try Self.add(rows, other.rows, .rows),
            spans: try Self.add(spans, other.spans, .spans),
            overlays: try Self.add(overlays, other.overlays, .overlays),
            spliceEntries: try Self.add(spliceEntries, other.spliceEntries, .spliceEntries),
            locatorEntries: try Self.add(locatorEntries, other.locatorEntries, .locatorEntries)
        )
    }

    /// Returns a component-wise sum after an earlier checked aggregate admitted it.
    func addingPrevalidated(_ other: Self) -> Self {
        do {
            return try adding(other)
        } catch {
            preconditionFailure("prevalidated frame resource weight overflowed")
        }
    }

    /// Returns the checked component-wise difference.
    public func subtracting(_ other: Self) throws -> Self {
        guard commands >= other.commands, ownedUTF8Bytes >= other.ownedUTF8Bytes,
              arrayEntries >= other.arrayEntries, rows >= other.rows,
              spans >= other.spans, overlays >= other.overlays,
              spliceEntries >= other.spliceEntries, locatorEntries >= other.locatorEntries else {
            throw FrameResourceError.arithmeticOverflow
        }
        return Self(commands: commands - other.commands,
                    ownedUTF8Bytes: ownedUTF8Bytes - other.ownedUTF8Bytes,
                    arrayEntries: arrayEntries - other.arrayEntries,
                    rows: rows - other.rows, spans: spans - other.spans,
                    overlays: overlays - other.overlays,
                    spliceEntries: spliceEntries - other.spliceEntries,
                    locatorEntries: locatorEntries - other.locatorEntries)
    }

    /// Returns the first deterministic dimension above `limit`.
    public func firstExceeded(limit: Self) -> FrameResourceDimension? {
        for dimension in FrameResourceDimension.allCases where value(dimension) > limit.value(dimension) {
            return dimension
        }
        return nil
    }

    /// Returns one dimension's value.
    public func value(_ dimension: FrameResourceDimension) -> Int {
        switch dimension {
        case .commands: commands
        case .ownedUTF8Bytes: ownedUTF8Bytes
        case .arrayEntries: arrayEntries
        case .rows: rows
        case .spans: spans
        case .overlays: overlays
        case .spliceEntries: spliceEntries
        case .locatorEntries: locatorEntries
        }
    }

    /// Measures owned strings, data, and collection entries in an already-materialized value.
    public static func measuringOwnedPayload(_ value: Any) throws -> Self {
        if let string = value as? String {
            return Self(ownedUTF8Bytes: string.utf8.count)
        }
        if let data = value as? Data {
            return Self(ownedUTF8Bytes: data.count)
        }

        let mirror = Mirror(reflecting: value)
        let collectionEntries: Int
        switch mirror.displayStyle {
        case .collection, .dictionary, .set:
            collectionEntries = mirror.children.count
        default:
            collectionEntries = 0
        }

        var weight = Self(arrayEntries: collectionEntries)
        for child in mirror.children {
            weight = try weight.adding(try measuringOwnedPayload(child.value))
        }
        return weight
    }

    private static func add(_ lhs: Int, _ rhs: Int, _ dimension: FrameResourceDimension) throws -> Int {
        guard rhs >= 0 else { throw FrameResourceError.arithmeticOverflow }
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw FrameResourceError.arithmeticOverflow }
        return result
    }
}

/// Independently bounded payload-amplification axes.
public enum FrameResourceDimension: String, Sendable, CaseIterable {
    case commands, ownedUTF8Bytes, arrayEntries, rows, spans, overlays, spliceEntries, locatorEntries
}

/// Typed policy and arithmetic failures.
public enum FrameResourceError: Error, Sendable, Equatable {
    case wirePayloadLimitExceeded(requested: Int, limit: Int)
    case limitExceeded(dimension: FrameResourceDimension, used: Int, requested: Int, limit: Int)
    case arithmeticOverflow
}

/// Phase-local mutable accounting. It never crosses actor isolation.
public final class FrameResourceUsageBuilder: @unchecked Sendable {
    public typealias ReservationProbe = @Sendable (FrameResourceDimension, Int) -> Void

    public private(set) var weight = FrameResourceWeight()
    public let limit: FrameResourceWeight
    private let reservationProbe: ReservationProbe?

    /// Creates one phase-local builder and optional metadata-only test probe.
    public init(limit: FrameResourceWeight, reservationProbe: ReservationProbe? = nil) {
        self.limit = limit
        self.reservationProbe = reservationProbe
    }

    /// Atomically reserves one dimension before the caller allocates.
    public func reserve(_ dimension: FrameResourceDimension, _ amount: Int) throws {
        guard amount >= 0 else { throw FrameResourceError.arithmeticOverflow }
        let used = weight.value(dimension)
        let (requested, overflow) = used.addingReportingOverflow(amount)
        guard !overflow else { throw FrameResourceError.arithmeticOverflow }
        let maximum = limit.value(dimension)
        guard requested <= maximum else {
            throw FrameResourceError.limitExceeded(dimension: dimension, used: used, requested: requested, limit: maximum)
        }
        // Test instrumentation observes successful admission before the caller's
        // payload-proportional allocation. It receives metadata only.
        reservationProbe?(dimension, requested)
        switch dimension {
        case .commands: weight.commands = requested
        case .ownedUTF8Bytes: weight.ownedUTF8Bytes = requested
        case .arrayEntries: weight.arrayEntries = requested
        case .rows: weight.rows = requested
        case .spans: weight.spans = requested
        case .overlays: weight.overlays = requested
        case .spliceEntries: weight.spliceEntries = requested
        case .locatorEntries: weight.locatorEntries = requested
        }
    }

    /// Captures usage before speculative legacy decoding.
    public func checkpoint() -> FrameResourceWeight { weight }

    /// Restores a child-local speculative checkpoint.
    public func restore(_ checkpoint: FrameResourceWeight) { weight = checkpoint }
}

/// Task-local bridge used by decoder helpers without a second parser.
public enum FrameDecodeAccounting {
    @TaskLocal static var current: FrameResourceUsageBuilder?
    @TaskLocal static var currentResidentLimit: FrameResourceWeight?

    /// Resident policy active for the complete decode transaction.
    public static var residentLimit: FrameResourceWeight {
        currentResidentLimit ?? FrameResourcePolicy.default.resident.weightPerWindow
    }

    /// Installs one decoder-owned usage builder and resident limit for a complete pass.
    public static func withUsage<T>(
        _ usage: FrameResourceUsageBuilder,
        residentLimit: FrameResourceWeight,
        operation: () throws -> T
    ) rethrows -> T {
        try $current.withValue(usage) {
            try $currentResidentLimit.withValue(residentLimit, operation: operation)
        }
    }

    /// Reserves through the current decoder builder when present.
    public static func reserve(_ dimension: FrameResourceDimension, _ amount: Int) throws {
        try current?.reserve(dimension, amount)
    }

    /// Rolls accounting back when a speculative legacy branch fails. Successful
    /// branches retain their reservations and are still decoded only once.
    public static func withCheckpoint<T>(_ body: () throws -> T) throws -> T {
        guard let current else { return try body() }
        let checkpoint = current.checkpoint()
        do {
            return try body()
        } catch {
            current.restore(checkpoint)
            throw error
        }
    }
}
