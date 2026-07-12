/// Observable state for honest native input latency milestones.
///
/// Semantic apply and Metal completion/presentation are displayed separately;
/// a frame acknowledgement can update apply statistics but never presentation.
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

    /// True when neither milestone has samples yet.
    public var isEmpty: Bool { stats.apply.count == 0 && stats.present.count == 0 }

    public var line: String {
        guard !isEmpty else { return "lat: (no apply/present samples)" }
        let apply = stageLine(label: "apply", stats: stats.apply)
        let present = stageLine(label: "present", stats: stats.present)
        let discarded = stats.discardCounts.values.reduce(0, +)
        return "\(apply)  \(present)  discarded=\(discarded)"
    }

    private func stageLine(label: String, stats: LatencyRecorder.StageStats) -> String {
        guard stats.count > 0 else { return "\(label) —" }
        return "\(label) p50 \(Self.formatMicros(stats.p50Micros)) p95 \(Self.formatMicros(stats.p95Micros)) n=\(stats.count)"
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
