import Foundation

/// Correlates optimistic native picker edits with authoritative BEAM echoes.
struct PickerQueryReconciler {
    static let maximumQueryBytes = Int(UInt16.max)

    struct Edit: Equatable {
        let generation: UInt32
        let sequence: UInt32
        let text: String
    }

    private(set) var generation: UInt32?
    private(set) var latestSentSequence: UInt32 = 0
    private var nextSequence: UInt32 = 0

    /// Returns authoritative text to apply, or nil while a newer local edit is still unacknowledged.
    mutating func reconcile(generation: UInt32, acknowledgedSequence: UInt32, authoritativeText: String) -> String? {
        guard self.generation == generation else {
            self.generation = generation
            latestSentSequence = acknowledgedSequence
            nextSequence = acknowledgedSequence
            return authoritativeText
        }

        nextSequence = max(nextSequence, acknowledgedSequence)
        guard acknowledgedSequence >= latestSentSequence else { return nil }
        latestSentSequence = acknowledgedSequence
        return authoritativeText
    }

    /// Records a complete native field value for the active picker generation.
    mutating func recordLocalEdit(_ text: String) -> Edit? {
        guard let generation else { return nil }
        guard nextSequence < UInt32.max else { return nil }
        nextSequence += 1
        latestSentSequence = nextSequence
        return Edit(generation: generation, sequence: nextSequence, text: text)
    }

    static func queryFitsWire(_ text: String) -> Bool {
        text.utf8.count <= maximumQueryBytes
    }

    /// Clamps an AppKit UTF-16 selection to the replacement text.
    static func clampSelection(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let selectionLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: selectionLength)
    }
}
