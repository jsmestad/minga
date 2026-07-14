import AppKit
import Observation
import os
import SwiftUI

/// Release telemetry for commit-to-first-affected-native-presentation.
@MainActor
@Observable
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

    @ObservationIgnored private let log = OSLog(subsystem: "com.minga.editor", category: "GUIFramePresentation")
    private var pending: [GUIFrameImpact: Pending] = [:]
    #if DEBUG
    @ObservationIgnored private var samples: [Sample] = []
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
    public func pendingEditorFrame() -> GUICommittedFrame? {
        pending[.editor]?.frame
    }

    /// Returns the committed identity currently awaiting presentation in one domain.
    func pendingFrame(domain: GUIFrameImpact) -> GUICommittedFrame? {
        pending[domain]?.frame
    }

    /// Resolves a native SwiftUI/AppKit consumer only from the frame captured when its draw was scheduled.
    func recordNativeDraw(domain: GUIFrameImpact, expectedFrame: GUICommittedFrame?) {
        guard domain != .editor,
              let expectedFrame,
              let ticket = pending[domain], ticket.frame == expectedFrame else { return }
        pending.removeValue(forKey: domain)
        record(frame: expectedFrame, domain: domain, outcome: .nativeDraw, started: ticket.started)
    }

    /// Resolves a native probe's unavailable path only when its captured frame is still pending.
    func discardNativeDraw(
        domain: GUIFrameImpact,
        outcome: Outcome,
        expectedFrame: GUICommittedFrame?
    ) {
        guard let expectedFrame else { return }
        discard(domain: domain, outcome: outcome, frame: expectedFrame)
    }

    /// Records native submission only after `MTLCommandBuffer.commit()` returned.
    /// The ticket stays pending until drawable presentation succeeds or is discarded.
    public func recordMetalSubmission(presentationFrame: GUICommittedFrame) {
        guard var ticket = pending[.editor], ticket.frame == presentationFrame,
              !ticket.submitted else { return }
        ticket.submitted = true
        pending[.editor] = ticket
        record(frame: ticket.frame, domain: .editor, outcome: .submitted, started: ticket.started)
    }

    /// Resolves the resident editor after its drawable was presented successfully.
    public func recordMetalPresented(presentationFrame: GUICommittedFrame) {
        guard let ticket = pending[.editor], ticket.frame == presentationFrame else { return }
        pending.removeValue(forKey: .editor)
        record(frame: ticket.frame, domain: .editor, outcome: .presented, started: ticket.started)
    }

    /// Resolves a ticket that cannot reach its domain's native presentation path.
    public func discard(domain: GUIFrameImpact, outcome: Outcome, frame: GUICommittedFrame? = nil) {
        guard outcome == .superseded || outcome == .hidden || outcome == .unavailable || outcome == .failed,
              let ticket = pending[domain], frame == nil || ticket.frame == frame else { return }
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
    let expectedFrame: GUICommittedFrame?
    let metrics: GUIFramePresentationMetrics

    func makeNSView(context: Context) -> GUIFrameDrawNSView {
        GUIFrameDrawNSView(domain: domain, expectedFrame: expectedFrame, metrics: metrics)
    }

    func updateNSView(_ nsView: GUIFrameDrawNSView, context: Context) {
        nsView.update(domain: domain, expectedFrame: expectedFrame, metrics: metrics)
    }
}

@MainActor
private final class GUIFrameDrawNSView: NSView {
    private var domain: GUIFrameImpact
    private var expectedFrame: GUICommittedFrame?
    private weak var metrics: GUIFramePresentationMetrics?
    private var availabilityCheck: Task<Void, Never>?

    init(
        domain: GUIFrameImpact,
        expectedFrame: GUICommittedFrame?,
        metrics: GUIFramePresentationMetrics
    ) {
        self.domain = domain
        self.expectedFrame = expectedFrame
        self.metrics = metrics
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(
        domain: GUIFrameImpact,
        expectedFrame: GUICommittedFrame?,
        metrics: GUIFramePresentationMetrics
    ) {
        self.domain = domain
        self.expectedFrame = expectedFrame
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
        metrics?.discardNativeDraw(domain: domain, outcome: .hidden, expectedFrame: expectedFrame)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        availabilityCheck?.cancel()
        metrics?.recordNativeDraw(domain: domain, expectedFrame: expectedFrame)
    }

    private func schedulePresentation() {
        availabilityCheck?.cancel()
        if isHiddenOrHasHiddenAncestor {
            metrics?.discardNativeDraw(domain: domain, outcome: .hidden, expectedFrame: expectedFrame)
            return
        }
        if window != nil {
            needsDisplay = true
            return
        }

        let scheduledFrame = expectedFrame
        availabilityCheck = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.expectedFrame == scheduledFrame else { return }
            if self.isHiddenOrHasHiddenAncestor {
                self.metrics?.discardNativeDraw(
                    domain: self.domain,
                    outcome: .hidden,
                    expectedFrame: scheduledFrame
                )
            } else if self.window == nil {
                self.metrics?.discardNativeDraw(
                    domain: self.domain,
                    outcome: .unavailable,
                    expectedFrame: scheduledFrame
                )
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
        metrics: GUIFramePresentationMetrics
    ) -> some View {
        background {
            GUIFrameNativeDrawProbe(
                domain: domain,
                expectedFrame: metrics.pendingFrame(domain: domain),
                metrics: metrics
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
    }
}
