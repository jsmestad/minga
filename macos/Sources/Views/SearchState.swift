/// Observable search toolbar state driven by BEAM gui_search_state messages (0x9E).
///
/// Holds all state needed to render the native SwiftUI find/replace toolbar:
/// visibility, match count, current match index, and search option flags.
/// Updated by CommandDispatcher when a guiSearchState command arrives.

import SwiftUI

enum SearchFlags {
    static let replaceMode: UInt8 = 0x01
    static let caseSensitive: UInt8 = 0x02
    static let wholeWord: UInt8 = 0x04
    static let regex: UInt8 = 0x08
}

@MainActor
@Observable
final class SearchState {
    /// Whether the search toolbar is visible.
    var visible: Bool = false

    /// Total number of matches for the current query.
    var matchCount: UInt16 = 0

    /// 1-based index of the currently highlighted match (0 when no matches).
    var currentIndex: UInt16 = 0

    /// Whether replace mode is active (shows the replace row).
    var replaceMode: Bool = false

    /// Whether the search is case-sensitive.
    var caseSensitive: Bool = false

    /// Whether the search matches whole words only.
    var wholeWord: Bool = false

    /// Whether the search query is a regular expression.
    var regex: Bool = false

    /// Updates the search state from a BEAM gui_search_state command.
    ///
    /// The flags byte encodes boolean options as individual bits:
    /// - Bit 0 (0x01): replace_mode
    /// - Bit 1 (0x02): case_sensitive
    /// - Bit 2 (0x04): whole_word
    /// - Bit 3 (0x08): regex
    func update(active: Bool, matchCount: UInt16, currentIndex: UInt16, flags: UInt8) {
        self.visible = active
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.replaceMode = flags & SearchFlags.replaceMode != 0
        self.caseSensitive = flags & SearchFlags.caseSensitive != 0
        self.wholeWord = flags & SearchFlags.wholeWord != 0
        self.regex = flags & SearchFlags.regex != 0
    }

    /// Hides the search toolbar and resets match counters to avoid stale display on re-open.
    func hide() {
        visible = false
        matchCount = 0
        currentIndex = 0
    }
}
