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
