import AppKit
import Observation
import os
import SwiftUI

/// Release telemetry for commit-to-first-affected-native-presentation.
@MainActor
public final class GUIFramePresentationMetrics {
    public enum Outcome: String, CaseIterable, Sendable {
        case submitted
        case presented
        case nativeDraw = "native_draw"
        case superseded
        case hidden
        case unavailable
        case failed
    }

    public struct Sample: Equatable, Sendable {
        public let frame: GUICommittedFrame
        public let domain: GUIFrameImpact
        public let outcome: Outcome
    }

    private struct Pending {
        let frame: GUICommittedFrame
        let started: ContinuousClock.Instant
        var submitted: Bool
    }

    private let log = OSLog(subsystem: "com.minga.editor", category: "GUIFramePresentation")
    private var pending: [GUIFrameImpact: Pending] = [:]
    #if DEBUG
    private var samples: [Sample] = []
    #endif

    public init() {}

    /// Starts one ticket per affected domain after semantic publication completes.
    public func beginCommitted(frame: GUICommittedFrame, impact: GUIFrameImpact) {
        for domain in Self.domains where impact.contains(domain) {
            if let prior = pending.removeValue(forKey: domain) {
                record(frame: prior.frame, domain: domain, outcome: .superseded)
            }
            pending[domain] = Pending(frame: frame, started: .now, submitted: false)
        }
    }

    /// Returns the committed editor frame currently waiting for Metal submission.
    public func pendingEditorFrameSeq() -> UInt32? {
        pending[.editor]?.frame.frameSeq
    }

    /// Resolves a native SwiftUI/AppKit consumer only from its NSView draw callback.
    public func recordNativeDraw(domain: GUIFrameImpact, version: GUIFrameVersion) {
        guard domain != .editor,
              let committed = version.lastCommitted,
              let ticket = pending[domain], ticket.frame == committed else { return }
        pending.removeValue(forKey: domain)
        record(frame: committed, domain: domain, outcome: .nativeDraw, started: ticket.started)
    }

    /// Records native submission only after `MTLCommandBuffer.commit()` returned.
    /// The ticket stays pending until drawable presentation succeeds or is discarded.
    public func recordMetalSubmission(frameSeq: UInt32) {
        guard var ticket = pending[.editor], ticket.frame.frameSeq == frameSeq,
              !ticket.submitted else { return }
        ticket.submitted = true
        pending[.editor] = ticket
        record(frame: ticket.frame, domain: .editor, outcome: .submitted, started: ticket.started)
    }

    /// Resolves the resident editor after its drawable was presented successfully.
    public func recordMetalPresented(frameSeq: UInt32) {
        guard let ticket = pending[.editor], ticket.frame.frameSeq == frameSeq else { return }
        pending.removeValue(forKey: .editor)
        record(frame: ticket.frame, domain: .editor, outcome: .presented, started: ticket.started)
    }

    /// Resolves a ticket that cannot reach its domain's native presentation path.
    public func discard(domain: GUIFrameImpact, outcome: Outcome, frame: GUICommittedFrame? = nil) {
        guard outcome == .superseded || outcome == .hidden || outcome == .unavailable || outcome == .failed,
              let ticket = pending[domain], frame == nil || ticket.frame == frame else { return }
        resolveDiscard(domain: domain, ticket: ticket, outcome: outcome)
    }

    /// Resolves an editor ticket from renderer code that carries the committed frame sequence.
    public func discard(domain: GUIFrameImpact, outcome: Outcome, frameSeq: UInt32) {
        guard let ticket = pending[domain], ticket.frame.frameSeq == frameSeq else { return }
        resolveDiscard(domain: domain, ticket: ticket, outcome: outcome)
    }

    #if DEBUG
    /// Deterministic test snapshot. Production telemetry is emitted only as signposts.
    public func snapshot() -> [Sample] { samples }
    #endif

    private func resolveDiscard(domain: GUIFrameImpact, ticket: Pending, outcome: Outcome) {
        pending.removeValue(forKey: domain)
        record(frame: ticket.frame, domain: domain, outcome: outcome, started: ticket.started)
    }

    private func record(
        frame: GUICommittedFrame,
        domain: GUIFrameImpact,
        outcome: Outcome,
        started: ContinuousClock.Instant? = nil
    ) {
        #if DEBUG
        samples.append(Sample(frame: frame, domain: domain, outcome: outcome))
        #else
        let elapsed = started.map { $0.duration(to: .now) } ?? .zero
        let micros = elapsed.components.seconds * 1_000_000
            + elapsed.components.attoseconds / 1_000_000_000_000
        os_signpost(
            .event, log: log, name: "GUIFramePresentation",
            "generation=%{public}u frame=%{public}u domain=%{public}u outcome=%{public}s micros=%{public}lld",
            frame.generation, frame.frameSeq, domain.rawValue, outcome.rawValue, micros
        )
        #endif
    }

    private static let domains: [GUIFrameImpact] = [
        .shell, .editor, .editorOverlay, .windowOverlay
    ]
}

/// Stable NSView bridge that treats only AppKit drawing as native presentation.
private struct GUIFrameNativeDrawProbe: NSViewRepresentable {
    let domain: GUIFrameImpact
    let version: GUIFrameVersion
    let metrics: GUIFramePresentationMetrics

    func makeNSView(context: Context) -> GUIFrameDrawNSView {
        GUIFrameDrawNSView(domain: domain, version: version, metrics: metrics)
    }

    func updateNSView(_ nsView: GUIFrameDrawNSView, context: Context) {
        nsView.update(domain: domain, version: version, metrics: metrics)
    }
}

@MainActor
private final class GUIFrameDrawNSView: NSView {
    private var domain: GUIFrameImpact
    private var version: GUIFrameVersion
    private weak var metrics: GUIFramePresentationMetrics?
    private var availabilityCheck: Task<Void, Never>?

    init(domain: GUIFrameImpact, version: GUIFrameVersion, metrics: GUIFramePresentationMetrics) {
        self.domain = domain
        self.version = version
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(domain: GUIFrameImpact, version: GUIFrameVersion, metrics: GUIFramePresentationMetrics) {
        self.domain = domain
        self.version = version
        self.metrics = metrics
        schedulePresentation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedulePresentation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        availabilityCheck?.cancel()
        metrics?.discard(domain: domain, outcome: .hidden, frame: version.lastCommitted)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        availabilityCheck?.cancel()
        metrics?.recordNativeDraw(domain: domain, version: version)
    }

    private func schedulePresentation() {
        availabilityCheck?.cancel()
        if isHiddenOrHasHiddenAncestor {
            metrics?.discard(domain: domain, outcome: .hidden, frame: version.lastCommitted)
            return
        }
        if window != nil {
            needsDisplay = true
            return
        }

        let expectedFrame = version.lastCommitted
        availabilityCheck = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.version.lastCommitted == expectedFrame else { return }
            if self.isHiddenOrHasHiddenAncestor {
                self.metrics?.discard(domain: self.domain, outcome: .hidden, frame: expectedFrame)
            } else if self.window == nil {
                self.metrics?.discard(domain: self.domain, outcome: .unavailable, frame: expectedFrame)
            } else {
                self.needsDisplay = true
            }
        }
    }
}

extension View {
    /// Installs a zero-sized stable native draw probe for one focused host.
    func frameNativeDrawProbe(
        domain: GUIFrameImpact,
        version: GUIFrameVersion,
        metrics: GUIFramePresentationMetrics
    ) -> some View {
        background {
            GUIFrameNativeDrawProbe(domain: domain, version: version, metrics: metrics)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }
}
