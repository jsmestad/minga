import Foundation
import Observation

/// A source-owned list surface that supports frontend-local preview navigation.
public enum LocalPresentationSurface: Hashable, Sendable {
    case completion
    case picker
    case fileTree
}

/// The opaque source identity of one locally previewed item.
public struct LocalPresentationIdentity: Equatable, Sendable {
    /// The source generation that owns the item.
    public let generation: UInt32
    /// The source-owned item identifier within `generation`.
    public let itemID: String

    /// Creates an identity from the generation and item ID supplied by the BEAM.
    public init(generation: UInt32, itemID: String) {
        self.generation = generation
        self.itemID = itemID
    }
}

/// Frontend-local selection previews shared by semantic list surfaces.
///
/// The source owns identity. A preview survives only while its generation and
/// item ID remain present in the next authoritative model.
@MainActor
@Observable
public final class LocalPresentationStore {
    /// Creates an empty local presentation store.
    public init() {}

    private var previews: [LocalPresentationSurface: LocalPresentationIdentity] = [:]

    /// Returns the current local preview identity for a surface.
    public func preview(for surface: LocalPresentationSurface) -> LocalPresentationIdentity? {
        previews[surface]
    }

    /// Installs a local preview, or discards it when the identity is invalid.
    public func setPreview(_ identity: LocalPresentationIdentity, for surface: LocalPresentationSurface) {
        guard identity.generation != 0, !identity.itemID.isEmpty else {
            previews[surface] = nil
            return
        }
        previews[surface] = identity
    }

    /// Reconciles a preview with the latest authoritative source model.
    ///
    /// A same-generation preview survives document-only and reordered frames when its item remains present.
    /// Generation changes, retained-item misses, committed selection catches, and hidden surfaces discard it.
    @discardableResult
    public func reconcile(surface: LocalPresentationSurface, generation: UInt32, committedItemID: String, retainedItemIDs: Set<String>, visible: Bool = true) -> String {
        guard visible, generation != 0 else {
            previews[surface] = nil
            return committedItemID
        }
        guard let preview = previews[surface],
              preview.generation == generation,
              preview.itemID != committedItemID,
              retainedItemIDs.contains(preview.itemID) else {
            previews[surface] = nil
            return committedItemID
        }
        return preview.itemID
    }

    /// Discards the local preview for one surface.
    public func discard(_ surface: LocalPresentationSurface) {
        previews[surface] = nil
    }
}
