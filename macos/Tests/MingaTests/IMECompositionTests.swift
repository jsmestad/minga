/// Tests for IMEComposition pure state tracker.

import Testing
import Foundation
@testable import minga_mac

@Suite("IMEComposition")
struct IMECompositionTests {
    @Test("Fresh composition has no marked text")
    func freshComposition() {
        let comp = IMEComposition()
        #expect(comp.hasMarkedText == false)
        #expect(comp.markedRange.location == NSNotFound)
        #expect(comp.markedText == nil)
    }

    @Test("setMarked stores composition text and selected range")
    func setMarkedStores() {
        var comp = IMEComposition()
        comp.setMarked(text: "にほ", selectedRange: NSRange(location: 1, length: 1),
                       replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(comp.markedText == "にほ")
        #expect(comp.selectedRange == NSRange(location: 1, length: 1))
        #expect(comp.hasMarkedText == true)
    }

    @Test("markedRange returns valid range during composition")
    func markedRangeDuringComposition() {
        var comp = IMEComposition()
        comp.setMarked(text: "abc", selectedRange: NSRange(location: 3, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(comp.markedRange == NSRange(location: 0, length: 3))
    }

    @Test("markedRange returns NSNotFound when no composition")
    func markedRangeNoComposition() {
        let comp = IMEComposition()
        #expect(comp.markedRange.location == NSNotFound)
        #expect(comp.markedRange.length == 0)
    }

    @Test("unmark clears composition and returns text")
    func unmarkReturnsText() {
        var comp = IMEComposition()
        comp.setMarked(text: "日本", selectedRange: NSRange(location: 2, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))

        let committed = comp.unmark()
        #expect(committed == "日本")
        #expect(comp.hasMarkedText == false)
        #expect(comp.markedRange.location == NSNotFound)
    }

    @Test("unmark with no active composition returns nil")
    func unmarkNoComposition() {
        var comp = IMEComposition()
        let committed = comp.unmark()
        #expect(committed == nil)
    }

    @Test("setMarked replaces previous composition")
    func setMarkedReplacesPrevious() {
        var comp = IMEComposition()
        comp.setMarked(text: "に", selectedRange: NSRange(location: 1, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(comp.markedText == "に")

        comp.setMarked(text: "にほ", selectedRange: NSRange(location: 2, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(comp.markedText == "にほ")

        comp.setMarked(text: "にほん", selectedRange: NSRange(location: 3, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(comp.markedText == "にほん")
    }

    @Test("clear resets all state")
    func clearResetsAll() {
        var comp = IMEComposition()
        comp.setMarked(text: "test", selectedRange: NSRange(location: 2, length: 1),
                       replacementRange: NSRange(location: 0, length: 3))

        comp.clear()
        #expect(comp.hasMarkedText == false)
        #expect(comp.markedText == nil)
        #expect(comp.markedRange.location == NSNotFound)
        #expect(comp.selectedRange.location == NSNotFound)
    }

    @Test("Empty composition string clears state")
    func emptyStringClears() {
        var comp = IMEComposition()
        comp.setMarked(text: "partial", selectedRange: NSRange(location: 7, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(comp.hasMarkedText == true)

        // Some IMEs send empty string when user deletes back through composition.
        comp.setMarked(text: "", selectedRange: NSRange(location: 0, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(comp.hasMarkedText == false)
    }

    @Test("markedRange length matches NSString length for CJK")
    func markedRangeCJKLength() {
        var comp = IMEComposition()
        let text = "日本語"  // 3 characters, 3 NSString length
        comp.setMarked(text: text, selectedRange: NSRange(location: 3, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(comp.markedRange == NSRange(location: 0, length: 3))
    }
}
