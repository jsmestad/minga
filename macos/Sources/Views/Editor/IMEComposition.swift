/// Pure IME composition state tracker.
///
/// Extracted from EditorNSView so the composition logic is unit-testable
/// without AppKit dependencies. Follows the ScrollAccumulator pattern.

import Foundation

/// Tracks the state of an active IME composition (marked text).
struct IMEComposition {
    /// The current composition text, or nil if no composition is active.
    private(set) var markedText: String?

    /// Selection range within the marked text.
    private(set) var selectedRange: NSRange = NSRange(location: NSNotFound, length: 0)

    /// Range in the "document" being replaced by this composition.
    private(set) var replacementRange: NSRange = NSRange(location: NSNotFound, length: 0)

    /// Whether a composition is currently active.
    var hasMarkedText: Bool { markedText != nil }

    /// The range of the marked text. Returns (NSNotFound, 0) when no composition.
    var markedRange: NSRange {
        guard let text = markedText else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: (text as NSString).length)
    }

    /// Update the composition with new marked text.
    ///
    /// Called by NSTextInputClient.setMarkedText. If text is empty,
    /// treats it as clearing the composition (some IMEs do this when
    /// the user deletes back through their composition).
    mutating func setMarked(text: String, selectedRange: NSRange, replacementRange: NSRange) {
        if text.isEmpty {
            clear()
            return
        }
        self.markedText = text
        self.selectedRange = selectedRange
        self.replacementRange = replacementRange
    }

    /// Clear the composition and return the text for commit.
    ///
    /// Returns the marked text if a composition was active, nil otherwise.
    /// After calling, hasMarkedText will be false.
    mutating func unmark() -> String? {
        let text = markedText
        clear()
        return text
    }

    /// Reset all state.
    mutating func clear() {
        markedText = nil
        selectedRange = NSRange(location: NSNotFound, length: 0)
        replacementRange = NSRange(location: NSNotFound, length: 0)
    }
}
