import Foundation
import MingaProtocol
import Testing

@Suite("Render performance comparator")
struct RenderPerformanceGateTests {
    private let provenance = RenderPerformanceProvenance(
        measuredAt: "2026-07-11", environment: "test", toolchain: "swiftc -O", rationale: "test"
    )

    private var baseline: RenderPerformanceBaseline {
        RenderPerformanceBaseline(
            version: 3,
            fixtureVersion: "resident-ordinary-edit-v2",
            decodeApplyP95Ms: 1.0,
            commandPreparationP95Ms: 1.0,
            combinedP95Ms: 2.0,
            provenance: provenance
        )
    }

    @Test("exact relative boundary passes and the next representable value fails")
    func relativeBoundary() {
        #expect(failures(stage: 1.10, combined: 2.20).isEmpty)
        #expect(failures(stage: 1.10.nextUp, combined: 2.20).contains { $0.contains("1.10x baseline") })
    }

    @Test("sub-millisecond references include a fixed host-noise allowance")
    func subMillisecondNoiseAllowance() {
        let tinyBaseline = RenderPerformanceBaseline(
            version: 3, fixtureVersion: "resident-ordinary-edit-v2", decodeApplyP95Ms: 0.03,
            commandPreparationP95Ms: 0.35, combinedP95Ms: 0.39, provenance: provenance)
        let boundary = 0.08
        let pass = RenderPerformanceMeasurement(
            decodeApplyP50Ms: 0.01, decodeApplyP95Ms: boundary,
            commandPreparationP50Ms: 0.13, commandPreparationP95Ms: 0.35,
            combinedP50Ms: 0.15, combinedP95Ms: 0.39)
        #expect(RenderPerformanceGate.failures(measurement: pass, baseline: tinyBaseline).isEmpty)

        let fail = RenderPerformanceMeasurement(
            decodeApplyP50Ms: 0.01, decodeApplyP95Ms: boundary.nextUp,
            commandPreparationP50Ms: 0.13, commandPreparationP95Ms: 0.35,
            combinedP50Ms: 0.15, combinedP95Ms: 0.39)
        #expect(RenderPerformanceGate.failures(measurement: fail, baseline: tinyBaseline)
            .contains { $0.contains("noise allowance") })
    }

    @Test("common-mode three-times host slowdown passes paired comparison")
    func commonModeHostSlowdownPasses() {
        let base = [0.30, 0.60, 0.90].map { pairedMeasurement(combinedP50: $0) }
        let head = [0.30, 0.60, 0.90].map { pairedMeasurement(combinedP50: $0) }

        #expect(RenderPerformanceGate.pairedFailures(
            baseMeasurements: base,
            headMeasurements: head
        ).isEmpty)
    }

    @Test("HEAD combined-p50 regression above 1.10x fails")
    func pairedCombinedP50RegressionFails() {
        let base = Array(repeating: pairedMeasurement(combinedP50: 1.0), count: 3)
        let head = Array(repeating: pairedMeasurement(combinedP50: 1.11), count: 3)
        let failures = RenderPerformanceGate.pairedFailures(
            baseMeasurements: base,
            headMeasurements: head
        )

        #expect(failures.contains { $0.contains("combined p50 paired median ratio") })
    }

    @Test("one noisy pair does not fail a three-pair median")
    func oneNoisyPairPasses() {
        let base = Array(repeating: pairedMeasurement(combinedP50: 1.0), count: 3)
        let head = [2.0, 1.0, 1.0].map { pairedMeasurement(combinedP50: $0) }

        #expect(RenderPerformanceGate.pairedFailures(
            baseMeasurements: base,
            headMeasurements: head
        ).isEmpty)
    }

    @Test("five-pair confirmation decides over all pair ratios")
    func fivePairConfirmationMedianPasses() {
        let base = Array(repeating: pairedMeasurement(combinedP50: 1.0), count: 5)
        let ratios = [1.15, 1.15, 1.0, 1.0, 1.0]
        let head = ratios.map { pairedMeasurement(combinedP50: $0) }
        let initialFailures = RenderPerformanceGate.pairedFailures(
            baseMeasurements: Array(base.prefix(3)),
            headMeasurements: Array(head.prefix(3))
        )

        #expect(initialFailures.contains { $0.contains("combined p50 paired median ratio") })
        #expect(RenderPerformanceGate.pairedFailures(
            baseMeasurements: base,
            headMeasurements: head
        ).isEmpty)
    }

    @Test("hard p95 ceilings fail despite equal paired ratios")
    func hardCeilingsStillFailPairedComparison() {
        let base = Array(repeating: pairedMeasurement(combinedP50: 1.0), count: 3)
        let head = Array(
            repeating: pairedMeasurement(combinedP50: 1.0, stageP95: 4.01, combinedP95: 8.01),
            count: 3
        )
        let failures = RenderPerformanceGate.pairedFailures(
            baseMeasurements: base,
            headMeasurements: head
        )

        #expect(failures.contains { $0.contains("absolute 4.00ms") })
        #expect(failures.contains { $0.contains("absolute 8.00ms") })
        #expect(failures.contains { $0.contains("paired median ratio") } == false)
    }

    @Test("invalid and unequal pair sets fail closed")
    func invalidPairSetsFailClosed() {
        let valid = pairedMeasurement(combinedP50: 1.0)

        #expect(RenderPerformanceGate.pairedFailures(
            baseMeasurements: [valid, valid, valid],
            headMeasurements: [valid, valid, valid, valid, valid]
        ).isEmpty == false)
        #expect(RenderPerformanceGate.pairedFailures(
            baseMeasurements: [valid, valid],
            headMeasurements: [valid, valid]
        ).isEmpty == false)

        for invalidValue in [Double.nan, 0, -1] {
            let invalid = pairedMeasurement(combinedP50: invalidValue)
            #expect(RenderPerformanceGate.pairedFailures(
                baseMeasurements: [valid, valid, valid],
                headMeasurements: [valid, invalid, valid]
            ).isEmpty == false)
        }
    }

    @Test("two noisy batches do not fail the median aggregate")
    func minorityNoisyBatchesPass() throws {
        let good = batch(decode: 1.0, command: 1.0, combined: 2.0)
        let noisy = batch(decode: 2.0, command: 2.0, combined: 4.0)
        let aggregate = try RenderPerformanceGate.aggregate(
            measurements: [good, noisy, good, noisy, good]
        )

        #expect(RenderPerformanceGate.failures(measurement: aggregate, baseline: baseline).isEmpty)
    }

    @Test("three regressed batches fail the median aggregate")
    func majorityRegressedBatchesFail() throws {
        let good = batch(decode: 1.0, command: 1.0, combined: 2.0)
        let regressed = batch(decode: 2.0, command: 2.0, combined: 4.0)
        let aggregate = try RenderPerformanceGate.aggregate(
            measurements: [regressed, good, regressed, good, regressed]
        )
        let failures = RenderPerformanceGate.failures(measurement: aggregate, baseline: baseline)

        #expect(failures.contains { $0.contains("decode_apply") })
        #expect(failures.contains { $0.contains("command_preparation") })
        #expect(failures.contains { $0.contains("combined") })
    }

    @Test("each aggregate metric uses its own batch median")
    func metricsAggregateIndependently() throws {
        let aggregate = try RenderPerformanceGate.aggregate(measurements: [
            batch(decode: 1, command: 50, combined: 200),
            batch(decode: 5, command: 10, combined: 500),
            batch(decode: 3, command: 40, combined: 100),
            batch(decode: 2, command: 20, combined: 400),
            batch(decode: 4, command: 30, combined: 300)
        ])

        #expect(aggregate.decodeApplyP95Ms == 3)
        #expect(aggregate.commandPreparationP95Ms == 30)
        #expect(aggregate.combinedP95Ms == 300)
    }

    @Test("invalid aggregate input fails closed")
    func invalidAggregateInput() {
        #expect(
            throws: RenderPerformanceAggregationError.invalidBatchCount(expected: 5, actual: 0)
        ) {
            try RenderPerformanceGate.aggregate(measurements: [])
        }

        let invalid = batch(decode: 1, command: 1, combined: 2, decodeP50: .nan)
        #expect(throws: RenderPerformanceAggregationError.invalidBatchMeasurement(index: 3)) {
            try RenderPerformanceGate.aggregate(measurements: [
                batch(decode: 1, command: 1, combined: 2),
                batch(decode: 1, command: 1, combined: 2),
                batch(decode: 1, command: 1, combined: 2),
                invalid,
                batch(decode: 1, command: 1, combined: 2)
            ])
        }
    }

    @Test("exact absolute boundaries pass and the next representable values fail")
    func absoluteBoundaries() {
        let absoluteBaseline = RenderPerformanceBaseline(
            version: 3, fixtureVersion: "resident-ordinary-edit-v2", decodeApplyP95Ms: 4.0,
            commandPreparationP95Ms: 4.0, combinedP95Ms: 8.0, provenance: provenance)

        let pass = measurement(stage: 4.0, combined: 8.0)
        #expect(RenderPerformanceGate.failures(measurement: pass, baseline: absoluteBaseline).isEmpty)

        let stageFail = measurement(stage: 4.0.nextUp, combined: 8.0)
        #expect(RenderPerformanceGate.failures(measurement: stageFail, baseline: absoluteBaseline)
            .contains { $0.contains("absolute 4.00ms") })

        let combinedFail = measurement(stage: 4.0, combined: 8.0.nextUp)
        #expect(RenderPerformanceGate.failures(measurement: combinedFail, baseline: absoluteBaseline)
            .contains { $0.contains("absolute 8.00ms") })
    }

    @Test("baseline JSON cannot redefine hard-coded policy ceilings")
    func baselineCannotRedefinePolicy() throws {
        let json = """
        {
          "version": 3,
          "fixtureVersion": "resident-ordinary-edit-v2",
          "measurementClock": "thread_cpu",
          "decodeApplyP95Ms": 4.0,
          "commandPreparationP95Ms": 4.0,
          "combinedP95Ms": 8.0,
          "stageAbsoluteBudgetMs": 999.0,
          "combinedAbsoluteBudgetMs": 999.0,
          "maximumRegressionRatio": 999.0,
          "provenance": {
            "measuredAt": "2026-07-11",
            "environment": "test",
            "toolchain": "swiftc -O",
            "rationale": "test"
          }
        }
        """
        let decoded = try JSONDecoder().decode(RenderPerformanceBaseline.self, from: Data(json.utf8))
        let failures = RenderPerformanceGate.failures(
            measurement: measurement(stage: 4.01, combined: 8.01), baseline: decoded)
        #expect(failures.contains { $0.contains("absolute 4.00ms") })
        #expect(failures.contains { $0.contains("absolute 8.00ms") })
    }

    @Test("unsupported baseline identities fail closed")
    func unsupportedBaselineIdentity() {
        let unsupported = RenderPerformanceBaseline(
            version: 4, fixtureVersion: "other-fixture", measurementClock: "wall",
            decodeApplyP95Ms: 1, commandPreparationP95Ms: 1, combinedP95Ms: 2,
            provenance: provenance)
        let failures = RenderPerformanceGate.failures(
            measurement: measurement(stage: 1, combined: 2), baseline: unsupported)
        #expect(failures.contains { $0.contains("unsupported baseline version") })
        #expect(failures.contains { $0.contains("unsupported fixture") })
        #expect(failures.contains { $0.contains("unsupported measurement clock") })
    }

    @Test("non-finite, zero, and negative references fail closed", arguments: [
        Double.nan, Double.infinity, -Double.infinity, 0.0, -0.01
    ])
    func invalidReference(value: Double) {
        let invalid = RenderPerformanceBaseline(
            version: 3, fixtureVersion: "resident-ordinary-edit-v2", decodeApplyP95Ms: value,
            commandPreparationP95Ms: 1, combinedP95Ms: 2, provenance: provenance)
        #expect(RenderPerformanceGate.failures(
            measurement: measurement(stage: 1, combined: 2), baseline: invalid
        ).contains { $0.contains("baseline decode_apply p95 must be finite and greater than zero") })
    }

    @Test("non-finite, zero, and negative measurements fail closed", arguments: [
        Double.nan, Double.infinity, -Double.infinity, 0.0, -0.01
    ])
    func invalidMeasurement(value: Double) {
        let invalid = RenderPerformanceMeasurement(
            decodeApplyP50Ms: 1, decodeApplyP95Ms: 1,
            commandPreparationP50Ms: 1, commandPreparationP95Ms: value,
            combinedP50Ms: 2, combinedP95Ms: 2)
        #expect(RenderPerformanceGate.failures(measurement: invalid, baseline: baseline)
            .contains { $0.contains("measurement command_preparation p95 must be finite and greater than zero") })
    }

    private func batch(
        decode: Double,
        command: Double,
        combined: Double,
        decodeP50: Double? = nil
    ) -> RenderPerformanceMeasurement {
        RenderPerformanceMeasurement(
            decodeApplyP50Ms: decodeP50 ?? decode / 2,
            decodeApplyP95Ms: decode,
            commandPreparationP50Ms: command / 2,
            commandPreparationP95Ms: command,
            combinedP50Ms: combined / 2,
            combinedP95Ms: combined
        )
    }

    private func pairedMeasurement(
        combinedP50: Double,
        stageP95: Double = 1.0,
        combinedP95: Double = 2.0
    ) -> RenderPerformanceMeasurement {
        RenderPerformanceMeasurement(
            decodeApplyP50Ms: 0.25,
            decodeApplyP95Ms: stageP95,
            commandPreparationP50Ms: 0.25,
            commandPreparationP95Ms: stageP95,
            combinedP50Ms: combinedP50,
            combinedP95Ms: combinedP95
        )
    }

    private func failures(stage: Double, combined: Double) -> [String] {
        RenderPerformanceGate.failures(measurement: measurement(stage: stage, combined: combined), baseline: baseline)
    }

    private func measurement(stage: Double, combined: Double) -> RenderPerformanceMeasurement {
        RenderPerformanceMeasurement(
            decodeApplyP50Ms: stage, decodeApplyP95Ms: stage,
            commandPreparationP50Ms: min(stage, 1), commandPreparationP95Ms: min(stage, 1),
            combinedP50Ms: combined, combinedP95Ms: combined
        )
    }
}
