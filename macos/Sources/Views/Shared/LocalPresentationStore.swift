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
    /// The revision of the list the preview was made under, for a surface whose list can change inside one generation. A surface without one leaves it 0.
    public let revision: UInt32
    /// The source-owned item identifier within `generation`.
    public let itemID: String

    /// Creates an identity from the generation, list revision and item ID supplied by the BEAM.
    public init(generation: UInt32, revision: UInt32 = 0, itemID: String) {
        self.generation = generation
        self.revision = revision
        self.itemID = itemID
    }
}

/// Frontend-local selection previews shared by semantic list surfaces.
///
/// The source owns identity. A preview survives only while its generation and
/// item ID remain present in the next authoritative model.
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
    /// A preview survives a frame of the generation and list revision it was made under while its item remains present.
    /// Generation changes, list revision changes, retained-item misses, committed selection catches, and hidden surfaces discard it.
    /// The BEAM's selection is a position in the list, so under another list the previewed row is no longer the row the BEAM moved to.
    @discardableResult
    public func reconcile(surface: LocalPresentationSurface, generation: UInt32, revision: UInt32 = 0, committedItemID: String, retainedItemIDs: Set<String>, visible: Bool = true) -> String {
        guard visible, generation != 0 else {
            previews[surface] = nil
            return committedItemID
        }
        guard let preview = previews[surface],
              preview.generation == generation,
              preview.revision == revision,
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
