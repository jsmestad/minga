/// Observable state for the on-screen keystroke-to-present latency HUD (ticket
/// #2215).
///
/// The macOS GUI's `LatencyRecorder` (owned by `CommandDispatcher`) records
/// keystroke-to-present samples: the input path stamps a correlation sequence
/// into each key packet, and `commit_frame` resolves the sample when the frame is
/// presented. This state object is the client-local, ephemeral display layer for
/// those numbers, mirroring the Go TUI's HUD: it shows live p50/p99/max and the
/// sample count, refreshed on a coarse timer so reading the recorder never
/// happens inside the measured critical sections.
///
/// `visible` is enabled at boot when `MINGA_LATENCY_HUD=1` and toggled at runtime
/// from the View menu (cmd-ctrl-l). This is a frontend-local debug surface in the
/// same class as the Go HUD; it does not consume any editor keybinding the BEAM
/// owns.

import SwiftUI
import MingaProtocol

@MainActor
@Observable
public final class LatencyHUDState {
    /// Whether the overlay is currently shown.
    public var visible: Bool

    /// The latest percentile snapshot rendered by the HUD.
    public var stats: LatencyRecorder.Stats = LatencyRecorder.Stats()

    /// Snapshot source, injected once the dispatcher exists. The closure copies
    /// the live sample window and computes percentiles outside the stamp/resolve
    /// critical sections, so calling it on the refresh timer does not perturb the
    /// numbers being measured.
    private var snapshotProvider: (@MainActor () -> LatencyRecorder.Stats)?

    /// Drives the periodic refresh. Cancelled when the HUD is hidden or the state
    /// is deallocated.
    private var refreshTask: Task<Void, Never>?

    /// Refresh cadence. Coarse on purpose: the HUD reports keystroke-to-present
    /// latency, so it must not redraw per frame or per keystroke and distort the
    /// very numbers it shows.
    private let refreshInterval: Duration

    /// - Parameters:
    ///   - environment: process environment, read once for the boot default.
    ///   - refreshInterval: how often to pull a fresh snapshot while visible.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        refreshInterval: Duration = .milliseconds(500)
    ) {
        self.visible = LatencyHUDState.envEnabled(environment)
        self.refreshInterval = refreshInterval
    }

    /// Reports whether `MINGA_LATENCY_HUD` requests the overlay on at startup.
    /// Any non-empty value other than `0`/`false`/`no` enables it, matching the
    /// Go TUI's `latencyHUDEnvEnabled`.
    nonisolated static func envEnabled(_ environment: [String: String]) -> Bool {
        switch environment["MINGA_LATENCY_HUD"] {
        case nil, "", "0", "false", "no":
            return false
        default:
            return true
        }
    }

    /// Wires the recorder snapshot source and starts refreshing if the HUD booted
    /// visible. Called once from `AppDelegate` after the dispatcher is created.
    public func connect(snapshotProvider: @escaping @MainActor () -> LatencyRecorder.Stats) {
        self.snapshotProvider = snapshotProvider
        if visible {
            refresh()
            startRefreshing()
        }
    }

    /// Flips the overlay and starts or stops the refresh loop to match. Returns
    /// the new visibility so callers can update menu state.
    @discardableResult
    public func toggle() -> Bool {
        visible.toggle()
        if visible {
            refresh()
            startRefreshing()
        } else {
            stopRefreshing()
        }
        return visible
    }

    /// Pulls one fresh snapshot from the recorder, if connected.
    public func refresh() {
        guard let snapshotProvider else { return }
        stats = snapshotProvider()
    }

    /// One-line model used by the HUD view and exercised by unit tests.
    public var model: LatencyHUDModel { LatencyHUDModel(stats: stats) }

    private func startRefreshing() {
        guard refreshTask == nil else { return }
        let interval = refreshInterval
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.visible else { return }
                self.refresh()
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }
    // No deinit-based cancellation: the refresh loop captures `self` weakly and
    // exits on the next tick once the state deallocates, matching the project's
    // Task.sleep timer pattern (see BlinkingCursor / AGENTS.md concurrency notes).
}

/// Pure formatting model for the latency HUD. Kept `Sendable` and free of
/// `@MainActor` so it can be unit-tested directly, mirroring the Go TUI's
/// `Stats.HUD()`/`fmtDur` helpers.
public struct LatencyHUDModel: Sendable, Equatable {
    public init(stats: LatencyRecorder.Stats) {
        self.stats = stats
    }
    public let stats: LatencyRecorder.Stats

    /// True when there are no resolved samples yet.
    public var isEmpty: Bool { stats.count == 0 }

    /// p50 formatted as a duration string (e.g. `812µs`, `1.20ms`).
    public var p50: String { LatencyHUDModel.formatMicros(stats.p50Micros) }
    /// p99 formatted as a duration string.
    public var p99: String { LatencyHUDModel.formatMicros(stats.p99Micros) }
    /// max formatted as a duration string.
    public var max: String { LatencyHUDModel.formatMicros(stats.maxMicros) }
    /// Resolved sample count backing the percentiles.
    public var sampleCount: Int { stats.count }

    /// One-line badge text, matching the Go HUD layout. Shows a placeholder until
    /// the first sample resolves.
    public var line: String {
        guard !isEmpty else { return "lat: (no samples)" }
        return "lat p50 \(p50)  p99 \(p99)  max \(max)  n=\(sampleCount)"
    }

    /// Formats a microsecond value as `µs` below 1ms and `ms` at or above, with
    /// two decimals, matching the Go TUI's `fmtDur`.
    public static func formatMicros(_ micros: Double) -> String {
        if micros >= 1000.0 {
            return String(format: "%.2fms", micros / 1000.0)
        }
        return String(format: "%dµs", Int(micros.rounded()))
    }
}
