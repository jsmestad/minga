import Foundation

/// Provenance for a checked-in optimized-harness calibration.
public struct RenderPerformanceProvenance: Codable, Equatable, Sendable {
    /// Date when the calibration was recorded.
    public let measuredAt: String
    /// Hardware and operating-system description for the calibration host.
    public let environment: String
    /// Optimized compiler and toolchain description.
    public let toolchain: String
    /// Human-reviewed reason for the baseline update.
    public let rationale: String

    /// Creates provenance for one checked-in optimized-harness calibration.
    public init(measuredAt: String, environment: String, toolchain: String, rationale: String) {
        self.measuredAt = measuredAt
        self.environment = environment
        self.toolchain = toolchain
        self.rationale = rationale
    }
}

/// Versioned p95 references for the optimized native harness.
///
/// Policy ceilings intentionally do not belong to this schema. A baseline update
/// can recalibrate relative references, but cannot relax production policy.
public struct RenderPerformanceBaseline: Codable, Equatable, Sendable {
    /// Baseline schema version.
    public let version: Int
    /// Fixed benchmark fixture identity.
    public let fixtureVersion: String
    /// Clock used to collect the reference percentiles.
    public let measurementClock: String
    /// Reference p95 for decode plus semantic apply.
    public let decodeApplyP95Ms: Double
    /// Reference p95 for visible-range command preparation.
    public let commandPreparationP95Ms: Double
    /// Reference p95 for the combined native preparation path.
    public let combinedP95Ms: Double
    /// Calibration provenance reviewed with the baseline diff.
    public let provenance: RenderPerformanceProvenance

    /// Creates one versioned set of measured p95 references.
    public init(version: Int, fixtureVersion: String, measurementClock: String = "thread_cpu",
                decodeApplyP95Ms: Double, commandPreparationP95Ms: Double,
                combinedP95Ms: Double, provenance: RenderPerformanceProvenance) {
        self.version = version
        self.fixtureVersion = fixtureVersion
        self.measurementClock = measurementClock
        self.decodeApplyP95Ms = decodeApplyP95Ms
        self.commandPreparationP95Ms = commandPreparationP95Ms
        self.combinedP95Ms = combinedP95Ms
        self.provenance = provenance
    }
}

/// Percentile measurements emitted by one optimized native harness batch or aggregate.
public struct RenderPerformanceMeasurement: Codable, Equatable, Sendable {
    /// Median decode plus semantic-apply duration.
    public let decodeApplyP50Ms: Double
    /// P95 decode plus semantic-apply duration.
    public let decodeApplyP95Ms: Double
    /// Median visible-range command-preparation duration.
    public let commandPreparationP50Ms: Double
    /// P95 visible-range command-preparation duration.
    public let commandPreparationP95Ms: Double
    /// Median combined native-preparation duration.
    public let combinedP50Ms: Double
    /// P95 combined native-preparation duration.
    public let combinedP95Ms: Double

    /// Creates the stage and combined percentile measurements for one run.
    public init(decodeApplyP50Ms: Double, decodeApplyP95Ms: Double,
                commandPreparationP50Ms: Double, commandPreparationP95Ms: Double,
                combinedP50Ms: Double, combinedP95Ms: Double) {
        self.decodeApplyP50Ms = decodeApplyP50Ms
        self.decodeApplyP95Ms = decodeApplyP95Ms
        self.commandPreparationP50Ms = commandPreparationP50Ms
        self.commandPreparationP95Ms = commandPreparationP95Ms
        self.combinedP50Ms = combinedP50Ms
        self.combinedP95Ms = combinedP95Ms
    }
}

/// Validation failures while aggregating independent optimized-harness batches.
public enum RenderPerformanceAggregationError: Error, Equatable, Sendable {
    /// The harness must provide exactly the configured odd batch count.
    case invalidBatchCount(expected: Int, actual: Int)
    /// Every percentile in every source batch must be finite and greater than zero.
    case invalidBatchMeasurement(index: Int)
}

/// Side of a paired render-performance comparison containing invalid input.
public enum RenderPerformanceComparisonSide: String, Equatable, Sendable {
    /// The merge-base measurement is invalid.
    case base
    /// The candidate measurement is invalid.
    case head
}

/// Validation failures while comparing same-runner measurement pairs.
public enum RenderPerformanceComparisonError: Error, Equatable, Sendable {
    /// Base and HEAD must contain the same number of measurements.
    case unequalPairCounts(base: Int, head: Int)
    /// A comparison requires an odd number of at least three adjacent pairs.
    case invalidPairCount(actual: Int)
    /// Every percentile in every source measurement must be finite and greater than zero.
    case invalidMeasurement(side: RenderPerformanceComparisonSide, index: Int)
}

/// Aggregate values reported for one same-runner paired comparison.
public struct RenderPerformancePairedComparison: Codable, Equatable, Sendable {
    /// Number of adjacent base/HEAD pairs included in the decision.
    public let pairCount: Int
    /// Median of each pair's `HEAD combinedP50 / BASE combinedP50` ratio.
    public let medianCombinedP50Ratio: Double
    /// Metric-by-metric median of the base measurements.
    public let medianBaseMeasurement: RenderPerformanceMeasurement
    /// Metric-by-metric median of the HEAD measurements.
    public let medianHeadMeasurement: RenderPerformanceMeasurement

    /// Creates the report for a validated same-runner paired comparison.
    public init(pairCount: Int, medianCombinedP50Ratio: Double,
                medianBaseMeasurement: RenderPerformanceMeasurement,
                medianHeadMeasurement: RenderPerformanceMeasurement) {
        self.pairCount = pairCount
        self.medianCombinedP50Ratio = medianCombinedP50Ratio
        self.medianBaseMeasurement = medianBaseMeasurement
        self.medianHeadMeasurement = medianHeadMeasurement
    }
}

/// Fail-closed production policy for optimized native rendering measurements.
public enum RenderPerformanceGate {
    /// Baseline schema version accepted by the gate.
    public static let supportedBaselineVersion = 3
    /// Fixture identity accepted by the gate.
    public static let supportedFixtureVersion = "resident-ordinary-edit-v2"
    /// Measurement clock accepted by the gate.
    public static let supportedMeasurementClock = "thread_cpu"
    /// Absolute p95 ceiling for each measured stage.
    public static let stageAbsoluteBudgetMs = 4.0
    /// Absolute p95 ceiling for the combined native preparation path.
    public static let combinedAbsoluteBudgetMs = 8.0
    /// Largest allowed ratio between a measurement and its checked-in reference.
    public static let maximumRegressionRatio = 1.10
    /// Minimum absolute allowance for sub-millisecond measurement variance.
    public static let minimumRegressionAllowanceMs = 0.05
    /// Number of independent batches required for the authoritative median aggregate.
    public static let requiredBatchCount = 5

    /// Aggregates independent batch percentiles by taking each metric's median.
    public static func aggregate(
        measurements: [RenderPerformanceMeasurement]
    ) throws -> RenderPerformanceMeasurement {
        guard measurements.count == requiredBatchCount else {
            throw RenderPerformanceAggregationError.invalidBatchCount(
                expected: requiredBatchCount,
                actual: measurements.count
            )
        }

        for (index, measurement) in measurements.enumerated() {
            let values = [
                measurement.decodeApplyP50Ms,
                measurement.decodeApplyP95Ms,
                measurement.commandPreparationP50Ms,
                measurement.commandPreparationP95Ms,
                measurement.combinedP50Ms,
                measurement.combinedP95Ms
            ]
            guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw RenderPerformanceAggregationError.invalidBatchMeasurement(index: index)
            }
        }

        return RenderPerformanceMeasurement(
            decodeApplyP50Ms: median(measurements.map(\.decodeApplyP50Ms)),
            decodeApplyP95Ms: median(measurements.map(\.decodeApplyP95Ms)),
            commandPreparationP50Ms: median(measurements.map(\.commandPreparationP50Ms)),
            commandPreparationP95Ms: median(measurements.map(\.commandPreparationP95Ms)),
            combinedP50Ms: median(measurements.map(\.combinedP50Ms)),
            combinedP95Ms: median(measurements.map(\.combinedP95Ms))
        )
    }

    /// Returns hard-ceiling failures for one measurement without consulting a static baseline.
    public static func absoluteFailures(measurement: RenderPerformanceMeasurement) -> [String] {
        var failures = measurementValidationFailures(measurement, prefix: "measurement")
        guard failures.isEmpty else { return failures }

        checkAbsolute("decode_apply", measurement.decodeApplyP95Ms, stageAbsoluteBudgetMs, &failures)
        checkAbsolute(
            "command_preparation",
            measurement.commandPreparationP95Ms,
            stageAbsoluteBudgetMs,
            &failures
        )
        checkAbsolute("combined", measurement.combinedP95Ms, combinedAbsoluteBudgetMs, &failures)
        return failures
    }

    /// Compares adjacent same-runner base/HEAD measurements after validating pair symmetry.
    public static func pairedComparison(
        baseMeasurements: [RenderPerformanceMeasurement],
        headMeasurements: [RenderPerformanceMeasurement]
    ) throws -> RenderPerformancePairedComparison {
        guard baseMeasurements.count == headMeasurements.count else {
            throw RenderPerformanceComparisonError.unequalPairCounts(
                base: baseMeasurements.count,
                head: headMeasurements.count
            )
        }
        guard baseMeasurements.count >= 3, baseMeasurements.count % 2 == 1 else {
            throw RenderPerformanceComparisonError.invalidPairCount(actual: baseMeasurements.count)
        }
        try validateComparisonMeasurements(baseMeasurements, side: .base)
        try validateComparisonMeasurements(headMeasurements, side: .head)

        let pairedRatios = zip(baseMeasurements, headMeasurements).map { base, head in
            head.combinedP50Ms / base.combinedP50Ms
        }
        return RenderPerformancePairedComparison(
            pairCount: baseMeasurements.count,
            medianCombinedP50Ratio: median(pairedRatios),
            medianBaseMeasurement: medianMeasurement(baseMeasurements),
            medianHeadMeasurement: medianMeasurement(headMeasurements)
        )
    }

    /// Returns relative combined-p50 and absolute HEAD failures for paired measurements.
    public static func pairedFailures(
        baseMeasurements: [RenderPerformanceMeasurement],
        headMeasurements: [RenderPerformanceMeasurement]
    ) -> [String] {
        let comparison: RenderPerformancePairedComparison
        do {
            comparison = try pairedComparison(
                baseMeasurements: baseMeasurements,
                headMeasurements: headMeasurements
            )
        } catch {
            return ["invalid paired comparison: \(error)"]
        }

        var failures = absoluteFailures(measurement: comparison.medianHeadMeasurement)
        if comparison.medianCombinedP50Ratio > maximumRegressionRatio {
            failures.append(
                "combined p50 paired median ratio \(format(comparison.medianCombinedP50Ratio))x exceeds \(format(maximumRegressionRatio))x"
            )
        }
        return failures
    }

    /// Returns every policy or baseline validation failure for one measurement.
    public static func failures(measurement: RenderPerformanceMeasurement,
                                baseline: RenderPerformanceBaseline) -> [String] {
        var failures = validationFailures(measurement: measurement, baseline: baseline)
        guard failures.isEmpty else { return failures }

        check("decode_apply", measurement.decodeApplyP95Ms, baseline.decodeApplyP95Ms,
              stageAbsoluteBudgetMs, &failures)
        check("command_preparation", measurement.commandPreparationP95Ms,
              baseline.commandPreparationP95Ms, stageAbsoluteBudgetMs, &failures)
        check("combined", measurement.combinedP95Ms, baseline.combinedP95Ms,
              combinedAbsoluteBudgetMs, &failures)
        return failures
    }

    private static func validationFailures(measurement: RenderPerformanceMeasurement,
                                           baseline: RenderPerformanceBaseline) -> [String] {
        var failures: [String] = []
        if baseline.version != supportedBaselineVersion {
            failures.append("unsupported baseline version \(baseline.version); expected \(supportedBaselineVersion)")
        }
        if baseline.fixtureVersion != supportedFixtureVersion {
            failures.append("unsupported fixture \(baseline.fixtureVersion); expected \(supportedFixtureVersion)")
        }
        if baseline.measurementClock != supportedMeasurementClock {
            failures.append("unsupported measurement clock \(baseline.measurementClock); expected \(supportedMeasurementClock)")
        }

        validate("baseline decode_apply p95", baseline.decodeApplyP95Ms, &failures)
        validate("baseline command_preparation p95", baseline.commandPreparationP95Ms, &failures)
        validate("baseline combined p95", baseline.combinedP95Ms, &failures)
        failures.append(contentsOf: measurementValidationFailures(measurement, prefix: "measurement"))
        return failures
    }

    private static func measurementValidationFailures(
        _ measurement: RenderPerformanceMeasurement,
        prefix: String
    ) -> [String] {
        var failures: [String] = []
        validate("\(prefix) decode_apply p50", measurement.decodeApplyP50Ms, &failures)
        validate("\(prefix) decode_apply p95", measurement.decodeApplyP95Ms, &failures)
        validate("\(prefix) command_preparation p50", measurement.commandPreparationP50Ms, &failures)
        validate("\(prefix) command_preparation p95", measurement.commandPreparationP95Ms, &failures)
        validate("\(prefix) combined p50", measurement.combinedP50Ms, &failures)
        validate("\(prefix) combined p95", measurement.combinedP95Ms, &failures)
        return failures
    }

    private static func validateComparisonMeasurements(
        _ measurements: [RenderPerformanceMeasurement],
        side: RenderPerformanceComparisonSide
    ) throws {
        for (index, measurement) in measurements.enumerated()
            where !measurementValidationFailures(measurement, prefix: side.rawValue).isEmpty {
            throw RenderPerformanceComparisonError.invalidMeasurement(side: side, index: index)
        }
    }

    private static func validate(_ name: String, _ value: Double, _ failures: inout [String]) {
        if !value.isFinite || value <= 0 {
            failures.append("\(name) must be finite and greater than zero")
        }
    }

    private static func check(_ stage: String, _ measured: Double, _ baseline: Double,
                              _ absolute: Double, _ failures: inout [String]) {
        checkAbsolute(stage, measured, absolute, &failures)
        let ratioLimit = baseline * maximumRegressionRatio
        let noiseLimit = baseline + minimumRegressionAllowanceMs
        let relative = max(ratioLimit, noiseLimit)
        if measured > relative {
            failures.append("\(stage) p95 \(format(measured))ms exceeds relative limit \(format(relative))ms (\(format(maximumRegressionRatio))x baseline or +\(format(minimumRegressionAllowanceMs))ms noise allowance)")
        }
    }

    private static func checkAbsolute(
        _ stage: String,
        _ measured: Double,
        _ absolute: Double,
        _ failures: inout [String]
    ) {
        if measured > absolute {
            failures.append("\(stage) p95 \(format(measured))ms exceeds absolute \(format(absolute))ms")
        }
    }

    private static func medianMeasurement(
        _ measurements: [RenderPerformanceMeasurement]
    ) -> RenderPerformanceMeasurement {
        RenderPerformanceMeasurement(
            decodeApplyP50Ms: median(measurements.map(\.decodeApplyP50Ms)),
            decodeApplyP95Ms: median(measurements.map(\.decodeApplyP95Ms)),
            commandPreparationP50Ms: median(measurements.map(\.commandPreparationP50Ms)),
            commandPreparationP95Ms: median(measurements.map(\.commandPreparationP95Ms)),
            combinedP50Ms: median(measurements.map(\.combinedP50Ms)),
            combinedP95Ms: median(measurements.map(\.combinedP95Ms))
        )
    }

    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// End-to-end Release measurement for one native editor rendering batch.
public struct NativeRenderPerformanceMeasurement: Codable, Equatable, Sendable {
    /// Median transaction-freeze plus publication duration.
    public let freezePublicationP50Ms: Double
    /// P95 transaction-freeze plus publication duration.
    public let freezePublicationP95Ms: Double
    /// Median CPU time spent preparing and encoding a warm native draw.
    public let drawCPUP50Ms: Double
    /// P95 CPU time spent preparing and encoding a warm native draw.
    public let drawCPUP95Ms: Double
    /// P99 CPU time spent preparing and encoding a warm native draw.
    public let drawCPUP99Ms: Double
    /// Median GPU time across render and drawable-copy command buffers.
    public let gpuP50Ms: Double
    /// P95 GPU time across render and drawable-copy command buffers.
    public let gpuP95Ms: Double
    /// Median wall time from committed snapshot handoff through completion of the drawable-copy command.
    public let completionWallP50Ms: Double
    /// P95 wall time from committed snapshot handoff through completion of the drawable-copy command.
    public let completionWallP95Ms: Double
    /// Largest number of bytes allocated by native draw resources in any measured warm frame.
    public let maximumAllocatedBytesPerFrame: Int
    /// Native buffer or texture allocation calls observed after warm-up.
    public let allocationCountAfterWarmup: Int
    /// Frames submitted to the measured native path.
    public let attemptedFrameCount: Int
    /// Frames that completed the drawable-copy command and requested presentation.
    public let copyCompletedFrameCount: Int
    /// Frames failed or discarded before drawable-copy completion.
    public let failedOrDiscardedFrameCount: Int
    /// Largest number of native presentation generations simultaneously in flight.
    public let maximumInFlightGenerations: Int

    /// Creates one complete native render measurement.
    public init(
        freezePublicationP50Ms: Double,
        freezePublicationP95Ms: Double,
        drawCPUP50Ms: Double,
        drawCPUP95Ms: Double,
        drawCPUP99Ms: Double,
        gpuP50Ms: Double,
        gpuP95Ms: Double,
        completionWallP50Ms: Double,
        completionWallP95Ms: Double,
        maximumAllocatedBytesPerFrame: Int,
        allocationCountAfterWarmup: Int,
        attemptedFrameCount: Int,
        copyCompletedFrameCount: Int,
        failedOrDiscardedFrameCount: Int,
        maximumInFlightGenerations: Int
    ) {
        self.freezePublicationP50Ms = freezePublicationP50Ms
        self.freezePublicationP95Ms = freezePublicationP95Ms
        self.drawCPUP50Ms = drawCPUP50Ms
        self.drawCPUP95Ms = drawCPUP95Ms
        self.drawCPUP99Ms = drawCPUP99Ms
        self.gpuP50Ms = gpuP50Ms
        self.gpuP95Ms = gpuP95Ms
        self.completionWallP50Ms = completionWallP50Ms
        self.completionWallP95Ms = completionWallP95Ms
        self.maximumAllocatedBytesPerFrame = maximumAllocatedBytesPerFrame
        self.allocationCountAfterWarmup = allocationCountAfterWarmup
        self.attemptedFrameCount = attemptedFrameCount
        self.copyCompletedFrameCount = copyCompletedFrameCount
        self.failedOrDiscardedFrameCount = failedOrDiscardedFrameCount
        self.maximumInFlightGenerations = maximumInFlightGenerations
    }
}

/// Fail-closed budgets for the complete native editor presentation path.
public enum NativeRenderPerformanceGate {
    /// Ordinary snapshot freeze and publication p95 budget.
    public static let freezePublicationP95BudgetMs = 1.0
    /// Warm cursor and local-scroll draw CPU p95 budget.
    public static let drawCPUP95BudgetMs = 2.5
    /// Warm cursor and local-scroll draw CPU p99 budget.
    public static let drawCPUP99BudgetMs = 4.0
    /// GPU render plus drawable-copy active-time p95 budget for a 120 Hz refresh interval.
    public static let gpuP95BudgetMs = 8.33
    /// End-to-end handoff through drawable-copy completion p95 budget for a 120 Hz refresh interval.
    public static let completionWallP95BudgetMs = 8.33
    /// Largest supported number of native presentation generations in flight.
    public static let maximumInFlightGenerations = 3
    /// Largest permitted paired median regression for end-to-end presentation p50.
    public static let maximumPairedRegressionRatio = 1.10

    /// Returns every absolute native-render budget violation.
    public static func absoluteFailures(_ measurement: NativeRenderPerformanceMeasurement) -> [String] {
        var failures = validationFailures(measurement)
        guard failures.isEmpty else { return failures }

        check("freeze_publication p95", measurement.freezePublicationP95Ms,
              freezePublicationP95BudgetMs, &failures)
        check("draw_cpu p95", measurement.drawCPUP95Ms, drawCPUP95BudgetMs, &failures)
        check("draw_cpu p99", measurement.drawCPUP99Ms, drawCPUP99BudgetMs, &failures)
        check("gpu_active_time p95", measurement.gpuP95Ms, gpuP95BudgetMs, &failures)
        check("handoff_to_copy_completion p95", measurement.completionWallP95Ms,
              completionWallP95BudgetMs, &failures)
        if measurement.maximumAllocatedBytesPerFrame != 0 {
            failures.append("warm frames allocated up to \(measurement.maximumAllocatedBytesPerFrame) bytes")
        }
        if measurement.allocationCountAfterWarmup != 0 {
            failures.append("warm frames performed \(measurement.allocationCountAfterWarmup) native allocations")
        }
        if measurement.failedOrDiscardedFrameCount != 0 {
            failures.append("native rendering failed or discarded \(measurement.failedOrDiscardedFrameCount) frames")
        }
        if measurement.maximumInFlightGenerations > maximumInFlightGenerations {
            failures.append("native presentation retained \(measurement.maximumInFlightGenerations) generations; limit is \(maximumInFlightGenerations)")
        }
        return failures
    }

    /// Returns absolute HEAD failures plus the paired end-to-end p50 regression failure.
    public static func pairedFailures(
        base: NativeRenderPerformanceMeasurement,
        head: NativeRenderPerformanceMeasurement
    ) -> [String] {
        pairedFailures(
            baseMeasurements: [base, base, base],
            headMeasurements: [head, head, head]
        )
    }

    /// Returns failures for an odd set of at least three adjacent same-runner base/HEAD pairs.
    public static func pairedFailures(
        baseMeasurements: [NativeRenderPerformanceMeasurement],
        headMeasurements: [NativeRenderPerformanceMeasurement]
    ) -> [String] {
        guard baseMeasurements.count == headMeasurements.count else {
            return ["native paired measurements have unequal counts"]
        }
        guard baseMeasurements.count >= 3, baseMeasurements.count.isMultiple(of: 2) == false else {
            return ["native paired comparison requires an odd count of at least three"]
        }
        for measurement in baseMeasurements where !validationFailures(measurement).isEmpty {
            return ["invalid native base measurement"]
        }
        for measurement in headMeasurements where !validationFailures(measurement).isEmpty {
            return ["invalid native HEAD measurement"]
        }

        var failures = absoluteFailures(aggregate(headMeasurements))
        let ratios = zip(baseMeasurements, headMeasurements).map { base, head in
            head.completionWallP50Ms / base.completionWallP50Ms
        }
        let ratio = median(ratios)
        if ratio > maximumPairedRegressionRatio {
            failures.append(
                "native handoff-to-copy-completion p50 paired median ratio \(format(ratio))x exceeds \(format(maximumPairedRegressionRatio))x"
            )
        }
        return failures
    }

    private static func validationFailures(_ measurement: NativeRenderPerformanceMeasurement) -> [String] {
        var failures: [String] = []
        let durations = [
            ("freeze_publication p50", measurement.freezePublicationP50Ms),
            ("freeze_publication p95", measurement.freezePublicationP95Ms),
            ("draw_cpu p50", measurement.drawCPUP50Ms),
            ("draw_cpu p95", measurement.drawCPUP95Ms),
            ("draw_cpu p99", measurement.drawCPUP99Ms),
            ("gpu p50", measurement.gpuP50Ms),
            ("gpu_active_time p95", measurement.gpuP95Ms),
            ("handoff_to_copy_completion p50", measurement.completionWallP50Ms),
            ("handoff_to_copy_completion p95", measurement.completionWallP95Ms)
        ]
        for (name, value) in durations where !value.isFinite || value <= 0 {
            failures.append("\(name) must be finite and greater than zero")
        }
        if measurement.maximumAllocatedBytesPerFrame < 0 || measurement.allocationCountAfterWarmup < 0
            || measurement.attemptedFrameCount <= 0 || measurement.copyCompletedFrameCount <= 0
            || measurement.failedOrDiscardedFrameCount < 0 || measurement.maximumInFlightGenerations <= 0
            || measurement.copyCompletedFrameCount + measurement.failedOrDiscardedFrameCount != measurement.attemptedFrameCount {
            failures.append("native render counters are invalid or incomplete")
        }
        return failures
    }

    private static func aggregate(
        _ measurements: [NativeRenderPerformanceMeasurement]
    ) -> NativeRenderPerformanceMeasurement {
        NativeRenderPerformanceMeasurement(
            freezePublicationP50Ms: median(measurements.map(\.freezePublicationP50Ms)),
            freezePublicationP95Ms: median(measurements.map(\.freezePublicationP95Ms)),
            drawCPUP50Ms: median(measurements.map(\.drawCPUP50Ms)),
            drawCPUP95Ms: median(measurements.map(\.drawCPUP95Ms)),
            drawCPUP99Ms: median(measurements.map(\.drawCPUP99Ms)),
            gpuP50Ms: median(measurements.map(\.gpuP50Ms)),
            gpuP95Ms: median(measurements.map(\.gpuP95Ms)),
            completionWallP50Ms: median(measurements.map(\.completionWallP50Ms)),
            completionWallP95Ms: median(measurements.map(\.completionWallP95Ms)),
            maximumAllocatedBytesPerFrame: measurements.map(\.maximumAllocatedBytesPerFrame).max() ?? 0,
            allocationCountAfterWarmup: measurements.map(\.allocationCountAfterWarmup).max() ?? 0,
            attemptedFrameCount: Int(median(measurements.map { Double($0.attemptedFrameCount) })),
            copyCompletedFrameCount: Int(median(measurements.map { Double($0.copyCompletedFrameCount) })),
            failedOrDiscardedFrameCount: measurements.map(\.failedOrDiscardedFrameCount).max() ?? 0,
            maximumInFlightGenerations: measurements.map(\.maximumInFlightGenerations).max() ?? 0
        )
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private static func check(
        _ name: String,
        _ measured: Double,
        _ limit: Double,
        _ failures: inout [String]
    ) {
        if measured > limit {
            failures.append("\(name) \(format(measured))ms exceeds \(format(limit))ms")
        }
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
