import Foundation
import SwiftUI

public enum SearchFlags {
    public static let replaceMode: UInt8 = 0x01
    public static let caseSensitive: UInt8 = 0x02
    public static let wholeWord: UInt8 = 0x04
    public static let regex: UInt8 = 0x08
}

struct SearchEdit: Equatable {
    let sessionID: UInt32
    let sequence: UInt32
    let query: String
    let flags: UInt8
}

enum SearchOption {
    case caseSensitive
    case wholeWord
    case regex
}

/// Owns the native presentation of one authoritative BEAM search session.
/// Local committed edits are provisional until the BEAM acknowledges their sequence.
@MainActor
@Observable
public final class SearchState {
    public init(visible: Bool = false, matchCount: UInt16 = 0, currentIndex: UInt16 = 0, query: String = "", sessionID: UInt32 = 0, acknowledgedEditSeq: UInt32 = 0, replaceMode: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.visible = visible
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.query = query
        self.sessionID = sessionID
        self.acknowledgedEditSeq = acknowledgedEditSeq
        self.replaceMode = replaceMode
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
        self.latestSentSequence = acknowledgedEditSeq
        self.nextSequence = acknowledgedEditSeq
    }

    public private(set) var visible: Bool
    public private(set) var matchCount: UInt16
    public private(set) var currentIndex: UInt16
    public private(set) var query: String
    public private(set) var sessionID: UInt32
    public private(set) var acknowledgedEditSeq: UInt32
    public private(set) var replaceMode: Bool
    public private(set) var caseSensitive: Bool
    public private(set) var wholeWord: Bool
    public private(set) var regex: Bool

    private(set) var latestSentSequence: UInt32
    private var nextSequence: UInt32

    /// Reconciles a complete authoritative state without allowing an old session or echo to replace newer local input.
    public func update(active: Bool, matchCount: UInt16, currentIndex: UInt16, flags: UInt8, query: String, sessionID: UInt32, acknowledgedEditSeq: UInt32) {
        guard sessionID == self.sessionID || Self.isNewerSession(sessionID, than: self.sessionID) else { return }

        let changedSession = sessionID != self.sessionID
        visible = active
        replaceMode = flags & SearchFlags.replaceMode != 0

        if changedSession {
            self.sessionID = sessionID
            latestSentSequence = acknowledgedEditSeq
            nextSequence = acknowledgedEditSeq
            applyAuthoritativeValues(matchCount: matchCount, currentIndex: currentIndex, flags: flags, query: query, acknowledgedEditSeq: acknowledgedEditSeq)
            return
        }

        nextSequence = max(nextSequence, acknowledgedEditSeq)
        guard acknowledgedEditSeq >= latestSentSequence else { return }
        latestSentSequence = acknowledgedEditSeq
        applyAuthoritativeValues(matchCount: matchCount, currentIndex: currentIndex, flags: flags, query: query, acknowledgedEditSeq: acknowledgedEditSeq)
    }

    /// Clears connection-scoped identity so a replacement BEAM can start session numbering again.
    public func reset() {
        visible = false
        matchCount = 0
        currentIndex = 0
        query = ""
        sessionID = 0
        acknowledgedEditSeq = 0
        replaceMode = false
        caseSensitive = false
        wholeWord = false
        regex = false
        latestSentSequence = 0
        nextSequence = 0
    }

    func recordQueryEdit(_ query: String) -> SearchEdit? {
        guard visible, sessionID != 0, Self.queryFitsWire(query), nextSequence < UInt32.max else { return nil }
        self.query = query
        matchCount = 0
        currentIndex = 0
        return makeEdit()
    }

    func toggle(_ option: SearchOption) -> SearchEdit? {
        guard visible, sessionID != 0, nextSequence < UInt32.max else { return nil }
        switch option {
        case .caseSensitive:
            caseSensitive.toggle()
        case .wholeWord:
            wholeWord.toggle()
        case .regex:
            regex.toggle()
        }
        return makeEdit()
    }

    static func queryFitsWire(_ query: String) -> Bool {
        query.utf8.count <= Int(UInt16.max)
    }

    static func clampSelection(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let selectionLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: selectionLength)
    }

    private func makeEdit() -> SearchEdit {
        nextSequence += 1
        latestSentSequence = nextSequence
        return SearchEdit(sessionID: sessionID, sequence: nextSequence, query: query, flags: optionFlags)
    }

    private var optionFlags: UInt8 {
        var flags: UInt8 = 0
        if caseSensitive { flags |= SearchFlags.caseSensitive }
        if wholeWord { flags |= SearchFlags.wholeWord }
        if regex { flags |= SearchFlags.regex }
        return flags
    }

    private func applyAuthoritativeValues(matchCount: UInt16, currentIndex: UInt16, flags: UInt8, query: String, acknowledgedEditSeq: UInt32) {
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.query = query
        self.acknowledgedEditSeq = acknowledgedEditSeq
        caseSensitive = flags & SearchFlags.caseSensitive != 0
        wholeWord = flags & SearchFlags.wholeWord != 0
        regex = flags & SearchFlags.regex != 0
    }

    private static func isNewerSession(_ candidate: UInt32, than current: UInt32) -> Bool {
        guard candidate != current else { return false }
        return candidate &- current < 0x8000_0000
    }
}
