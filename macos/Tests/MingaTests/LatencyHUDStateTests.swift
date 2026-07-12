import MingaProtocol
@testable import MingaUI
import Foundation
import Testing

@testable import Minga

/// Verifies the latency HUD's formatting model, env-driven boot visibility, and
/// runtime toggle (ticket #2215). The formatting model mirrors the Go TUI HUD.
@Suite("Latency HUD")
struct LatencyHUDStateTests {

    // MARK: - Formatting model

    @Test("empty stats render the no-samples placeholder")
    func emptyPlaceholder() {
        let model = LatencyHUDModel(stats: LatencyRecorder.Stats())
        #expect(model.isEmpty)
        #expect(model.line == "lat: (no apply/present samples)")
    }

    @Test("sub-millisecond values format as microseconds")
    func microsecondFormatting() {
        #expect(LatencyHUDModel.formatMicros(0) == "0µs")
        #expect(LatencyHUDModel.formatMicros(812) == "812µs")
        #expect(LatencyHUDModel.formatMicros(999.4) == "999µs")
        // Rounds to nearest microsecond below the millisecond boundary.
        #expect(LatencyHUDModel.formatMicros(750.6) == "751µs")
    }

    @Test("values at or above 1ms format as milliseconds with two decimals")
    func millisecondFormatting() {
        #expect(LatencyHUDModel.formatMicros(1000) == "1.00ms")
        #expect(LatencyHUDModel.formatMicros(1234.5) == "1.23ms")
        #expect(LatencyHUDModel.formatMicros(20000) == "20.00ms")
    }

    @Test("populated stats render the full badge line")
    func populatedLine() {
        let stats = LatencyRecorder.Stats(
            apply: .init(count: 128, p50Micros: 812, p95Micros: 1_200),
            present: .init(count: 120, p50Micros: 2_450, p95Micros: 5_100),
            submittedCount: 120,
            discardCounts: [.superseded: 8]
        )
        let model = LatencyHUDModel(stats: stats)
        #expect(!model.isEmpty)
        #expect(model.line == "apply p50 812µs p95 1.20ms n=128  present p50 2.45ms p95 5.10ms n=120  discarded=8")
    }

    // MARK: - Boot visibility (MINGA_LATENCY_HUD)

    @Test("env enables the HUD only for truthy values")
    func envEnabled() {
        #expect(LatencyHUDState.envEnabled([:]) == false)
        #expect(LatencyHUDState.envEnabled(["MINGA_LATENCY_HUD": ""]) == false)
        #expect(LatencyHUDState.envEnabled(["MINGA_LATENCY_HUD": "0"]) == false)
        #expect(LatencyHUDState.envEnabled(["MINGA_LATENCY_HUD": "false"]) == false)
        #expect(LatencyHUDState.envEnabled(["MINGA_LATENCY_HUD": "no"]) == false)
        #expect(LatencyHUDState.envEnabled(["MINGA_LATENCY_HUD": "1"]) == true)
        #expect(LatencyHUDState.envEnabled(["MINGA_LATENCY_HUD": "true"]) == true)
        #expect(LatencyHUDState.envEnabled(["MINGA_LATENCY_HUD": "on"]) == true)
    }

    @MainActor
    @Test("HUD boots hidden by default and visible when env requests it")
    func bootVisibility() {
        let hidden = LatencyHUDState(environment: [:])
        #expect(hidden.visible == false)

        let shown = LatencyHUDState(environment: ["MINGA_LATENCY_HUD": "1"])
        #expect(shown.visible == true)
    }

    // MARK: - Runtime toggle and snapshot wiring

    @MainActor
    @Test("toggle flips visibility")
    func toggleFlips() {
        let state = LatencyHUDState(environment: [:])
        #expect(state.visible == false)
        #expect(state.toggle() == true)
        #expect(state.visible == true)
        #expect(state.toggle() == false)
        #expect(state.visible == false)
    }

    @MainActor
    @Test("connect pulls an immediate snapshot when booted visible")
    func connectRefreshesWhenVisible() {
        let recorder = LatencyRecorder()
        let seq = recorder.stamp()
        recorder.markApplied(seq: seq)
        recorder.markSubmitted(seq: seq)
        recorder.markPresented(seq: seq)

        let state = LatencyHUDState(
            environment: ["MINGA_LATENCY_HUD": "1"],
            refreshInterval: .seconds(60)
        )
        #expect(state.stats.present.count == 0)
        state.connect { recorder.snapshot() }
        #expect(state.stats.present.count == 1)
    }

    @MainActor
    @Test("refresh re-reads the recorder snapshot on demand")
    func refreshReadsSnapshot() {
        let recorder = LatencyRecorder()
        let state = LatencyHUDState(environment: [:], refreshInterval: .seconds(60))
        state.connect { recorder.snapshot() }
        #expect(state.model.isEmpty)

        let seq = recorder.stamp()
        recorder.markApplied(seq: seq)
        recorder.markSubmitted(seq: seq)
        recorder.markPresented(seq: seq)
        state.refresh()
        #expect(state.stats.present.count == 1)
        #expect(!state.model.isEmpty)
    }
}
