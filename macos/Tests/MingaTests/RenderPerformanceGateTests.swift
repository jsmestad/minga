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
            version: 1,
            fixtureVersion: "resident-ordinary-edit-v2",
            decodeApplyP95Ms: 1.0,
            commandPreparationP95Ms: 1.0,
            combinedP95Ms: 2.0,
            provenance: provenance
        )
    }

    @Test("exact relative boundary passes and the next representable value fails")
    func relativeBoundary() {
        #expect(failures(stage: 1.20, combined: 2.40).isEmpty)
        #expect(failures(stage: 1.20.nextUp, combined: 2.40).contains { $0.contains("1.20x baseline") })
    }

    @Test("sub-millisecond references include a fixed host-noise allowance")
    func subMillisecondNoiseAllowance() {
        let tinyBaseline = RenderPerformanceBaseline(
            version: 1, fixtureVersion: "resident-ordinary-edit-v2", decodeApplyP95Ms: 0.03,
            commandPreparationP95Ms: 0.35, combinedP95Ms: 0.39, provenance: provenance)
        let boundary = 0.03 + RenderPerformanceGate.minimumRegressionAllowanceMs
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

    @Test("exact absolute boundaries pass and the next representable values fail")
    func absoluteBoundaries() {
        let absoluteBaseline = RenderPerformanceBaseline(
            version: 1, fixtureVersion: "resident-ordinary-edit-v2", decodeApplyP95Ms: 4.0,
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
          "version": 1,
          "fixtureVersion": "resident-ordinary-edit-v2",
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

    @Test("unsupported baseline versions and fixtures fail closed")
    func unsupportedBaselineIdentity() {
        let unsupported = RenderPerformanceBaseline(
            version: 2, fixtureVersion: "other-fixture", decodeApplyP95Ms: 1,
            commandPreparationP95Ms: 1, combinedP95Ms: 2, provenance: provenance)
        let failures = RenderPerformanceGate.failures(
            measurement: measurement(stage: 1, combined: 2), baseline: unsupported)
        #expect(failures.contains { $0.contains("unsupported baseline version") })
        #expect(failures.contains { $0.contains("unsupported fixture") })
    }

    @Test("non-finite, zero, and negative references fail closed", arguments: [
        Double.nan, Double.infinity, -Double.infinity, 0.0, -0.01
    ])
    func invalidReference(value: Double) {
        let invalid = RenderPerformanceBaseline(
            version: 1, fixtureVersion: "resident-ordinary-edit-v2", decodeApplyP95Ms: value,
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
