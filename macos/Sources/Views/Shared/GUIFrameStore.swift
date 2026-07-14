import Observation
import SwiftUI

/// Consumer regions invalidated by one atomic GUI publication.
public struct GUIFrameImpact: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shell = GUIFrameImpact(rawValue: 1 << 0)
    public static let editor = GUIFrameImpact(rawValue: 1 << 1)
    public static let editorOverlay = GUIFrameImpact(rawValue: 1 << 2)
    public static let windowOverlay = GUIFrameImpact(rawValue: 1 << 3)
    public static let all: GUIFrameImpact = [.shell, .editor, .editorOverlay, .windowOverlay]
}

/// Identity of the latest transaction committed by the BEAM.
public struct GUICommittedFrame: Equatable, Sendable {
    public let generation: UInt32
    public let frameSeq: UInt32

    public init(generation: UInt32, frameSeq: UInt32) {
        self.generation = generation
        self.frameSeq = frameSeq
    }
}

/// Immutable version visible to one consumer domain.
public struct GUIFrameVersion: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case committed
        case local
    }

    public let revision: UInt64
    public let lastCommitted: GUICommittedFrame?
    public let source: Source

    public init(revision: UInt64, lastCommitted: GUICommittedFrame?, source: Source) {
        self.revision = revision
        self.lastCommitted = lastCommitted
        self.source = source
    }
}

private struct GUIFrameVersionEnvironmentKey: EnvironmentKey {
    static let defaultValue = GUIFrameVersion(revision: 0, lastCommitted: nil, source: .local)
}

extension EnvironmentValues {
    /// Focused publication version for the nearest shell, editor, or overlay host.
    public var guiFrameVersion: GUIFrameVersion {
        get { self[GUIFrameVersionEnvironmentKey.self] }
        set { self[GUIFrameVersionEnvironmentKey.self] = newValue }
    }
}

/// One atomically installed version bundle for all consumer domains.
public struct GUIFrameVersions: Equatable, Sendable {
    public let shell: GUIFrameVersion
    public let editor: GUIFrameVersion
    public let editorOverlay: GUIFrameVersion
    public let windowOverlay: GUIFrameVersion

    public init(
        shell: GUIFrameVersion,
        editor: GUIFrameVersion,
        editorOverlay: GUIFrameVersion,
        windowOverlay: GUIFrameVersion
    ) {
        self.shell = shell
        self.editor = editor
        self.editorOverlay = editorOverlay
        self.windowOverlay = windowOverlay
    }
}

/// Observable invalidation channel for exactly one consumer domain.
@MainActor
@Observable
public final class GUIFrameChannel {
    public private(set) var value: GUIFrameVersion

    fileprivate init(value: GUIFrameVersion) {
        self.value = value
    }

    fileprivate func install(_ value: GUIFrameVersion) {
        self.value = value
    }
}

/// Atomically publishes backing-state mutations through focused invalidation channels.
@MainActor
public final class GUIFrameStore {
    /// Deterministic publication phases exposed to unit tests without making application code rely on callbacks.
    enum PublicationEvent: Equatable {
        case mutated
        case installed
        case channel(GUIFrameImpact)
    }

    @ObservationIgnored public private(set) var installed: GUIFrameVersions
    public let shell: GUIFrameChannel
    public let editor: GUIFrameChannel
    public let editorOverlay: GUIFrameChannel
    public let windowOverlay: GUIFrameChannel

    @ObservationIgnored var onPublicationEvent: ((PublicationEvent) -> Void)?
    @ObservationIgnored private var isPublishing = false

    public init() {
        let initial = GUIFrameVersion(revision: 0, lastCommitted: nil, source: .local)
        let versions = GUIFrameVersions(
            shell: initial,
            editor: initial,
            editorOverlay: initial,
            windowOverlay: initial
        )
        installed = versions
        shell = GUIFrameChannel(value: versions.shell)
        editor = GUIFrameChannel(value: versions.editor)
        editorOverlay = GUIFrameChannel(value: versions.editorOverlay)
        windowOverlay = GUIFrameChannel(value: versions.windowOverlay)
    }

    /// Publishes one validated committed transaction.
    public func publishCommitted(
        generation: UInt32,
        frameSeq: UInt32,
        impact: GUIFrameImpact,
        mutation: () -> Void
    ) {
        publish(
            committed: GUICommittedFrame(generation: generation, frameSeq: frameSeq),
            source: .committed,
            impact: impact
        ) {
            mutation()
            return true
        }
    }

    /// Publishes one synchronous client-local or recovery mutation without replacing the latest committed frame.
    public func publishLocal(impact: GUIFrameImpact, mutation: () -> Void) {
        publish(committed: nil, source: .local, impact: impact) {
            mutation()
            return true
        }
    }

    /// Publishes a local mutation only when the mutation reports a visible change.
    @discardableResult
    public func publishLocalIfChanged(
        impact: GUIFrameImpact,
        mutation: () -> Bool
    ) -> Bool {
        publish(committed: nil, source: .local, impact: impact, mutation: mutation)
    }

    @discardableResult
    private func publish(
        committed: GUICommittedFrame?,
        source: GUIFrameVersion.Source,
        impact: GUIFrameImpact,
        mutation: () -> Bool
    ) -> Bool {
        precondition(!isPublishing, "GUI frame publication cannot recurse")
        isPublishing = true
        defer { isPublishing = false }

        guard mutation() else { return false }
        onPublicationEvent?(.mutated)

        let prior = installed
        // Focused commits can leave channel identities divergent from the complete installed bundle.
        // A local publication stays correlated with what each affected consumer currently displays.
        let published = GUIFrameVersions(
            shell: shell.value,
            editor: editor.value,
            editorOverlay: editorOverlay.value,
            windowOverlay: windowOverlay.value
        )
        let next = GUIFrameVersions(
            shell: version(after: prior.shell, published: published.shell, committed: committed, source: source, affected: impact.contains(.shell)),
            editor: version(after: prior.editor, published: published.editor, committed: committed, source: source, affected: impact.contains(.editor)),
            editorOverlay: version(after: prior.editorOverlay, published: published.editorOverlay, committed: committed, source: source, affected: impact.contains(.editorOverlay)),
            windowOverlay: version(after: prior.windowOverlay, published: published.windowOverlay, committed: committed, source: source, affected: impact.contains(.windowOverlay))
        )
        installed = next
        onPublicationEvent?(.installed)

        // This order is part of the publication contract.
        if impact.contains(.shell) {
            shell.install(next.shell)
            onPublicationEvent?(.channel(.shell))
        }
        if impact.contains(.editor) {
            editor.install(next.editor)
            onPublicationEvent?(.channel(.editor))
        }
        if impact.contains(.editorOverlay) {
            editorOverlay.install(next.editorOverlay)
            onPublicationEvent?(.channel(.editorOverlay))
        }
        if impact.contains(.windowOverlay) {
            windowOverlay.install(next.windowOverlay)
            onPublicationEvent?(.channel(.windowOverlay))
        }
        return true
    }

    private func version(
        after prior: GUIFrameVersion,
        published: GUIFrameVersion,
        committed: GUICommittedFrame?,
        source: GUIFrameVersion.Source,
        affected: Bool
    ) -> GUIFrameVersion {
        if source == .local {
            guard affected else { return prior }
            return GUIFrameVersion(
                revision: prior.revision &+ 1,
                lastCommitted: published.lastCommitted,
                source: source
            )
        }
        return GUIFrameVersion(
            revision: affected ? prior.revision &+ 1 : prior.revision,
            lastCommitted: committed,
            source: source
        )
    }
}
