import CoreGraphics
@testable import MingaUI
import Testing

@Suite("Transcript follow")
@MainActor
struct TranscriptFollowTests {
    private func geometry(offset: CGFloat, visible: CGFloat = 600, content: CGFloat, rows: Int = 20) -> TranscriptScrollGeometry {
        TranscriptScrollGeometry(offsetY: offset, visibleHeight: visible, contentHeight: content, rowCount: rows)
    }

    /// Replays the frames a scroll view reports and returns whether the view still follows and how often it was asked to catch up.
    private func replay(_ frames: [(geometry: TranscriptScrollGeometry, turnActive: Bool)]) -> (following: Bool, catchUps: Int) {
        var following = true
        var catchUps = 0
        for (old, new) in zip(frames, frames.dropFirst()) {
            switch TranscriptFollow.decide(following: following, turnActive: new.turnActive, from: old.geometry, to: new.geometry) {
            case .following(let catchUp):
                following = true
                if catchUp { catchUps += 1 }
            case .holding:
                following = false
            }
        }
        return (following, catchUps)
    }

    @Test("text that grows while Minga works never stops the follow, however much lands in one frame", arguments: [10, 51, 300, 5_000] as [CGFloat])
    func streamingGrowthKeepsFollowing(growth: CGFloat) {
        let before = geometry(offset: 1_400, content: 2_000)
        let after = geometry(offset: 1_400, content: 2_000 + growth)

        let decision = TranscriptFollow.decide(following: true, turnActive: true, from: before, to: after)

        #expect(decision == .following(catchUp: growth > TranscriptFollow.bottomSlack))
    }

    @Test("stop a turn, send again, the reply starts: the view still follows")
    func followSurvivesAStoppedTurnAndANewReply() {
        // No scroll by the user. The turn is stopped, so nothing is running when the new prompt lands as a new row. The view animates toward it; the reply's first row and its first lines land before the animation ends, and the animation ends at the old bottom.
        let result = replay([
            (geometry(offset: 1_400, content: 2_000, rows: 20), false),
            (geometry(offset: 1_400, content: 2_070, rows: 21), false),
            (geometry(offset: 1_430, content: 2_070, rows: 21), false),
            (geometry(offset: 1_450, content: 2_130, rows: 22), true),
            (geometry(offset: 1_460, content: 2_250, rows: 22), true),
            (geometry(offset: 1_470, content: 2_250, rows: 22), true),
        ])

        #expect(result.following)
        // The new prompt, the reply's first row and its growth each ask the view to scroll to the new bottom.
        #expect(result.catchUps == 3)
    }

    @Test("a view on its way to the bottom is not a view you scrolled away")
    func catchingUpKeepsFollowing() {
        // Mid-animation frames: far from the bottom, moving down, nothing new.
        let before = geometry(offset: 1_400, content: 2_300)
        let after = geometry(offset: 1_500, content: 2_300)

        for turnActive in [true, false] {
            #expect(TranscriptFollow.decide(following: true, turnActive: turnActive, from: before, to: after) == .following(catchUp: false))
        }
    }

    @Test("scrolling up away from the bottom stops the follow, even while output arrives")
    func scrollingUpHolds() {
        let before = geometry(offset: 1_400, content: 2_000)

        for turnActive in [true, false] {
            #expect(TranscriptFollow.decide(following: true, turnActive: turnActive, from: before, to: geometry(offset: 1_200, content: 2_000)) == .holding)
            #expect(TranscriptFollow.decide(following: true, turnActive: turnActive, from: before, to: geometry(offset: 1_200, content: 2_300, rows: 21)) == .holding)
        }
    }

    @Test("a scroll that stays near the bottom keeps following")
    func smallScrollKeepsFollowing() {
        let before = geometry(offset: 1_400, content: 2_000)
        let after = geometry(offset: 1_360, content: 2_000)

        #expect(TranscriptFollow.decide(following: true, turnActive: false, from: before, to: after) == .following(catchUp: false))
    }

    @Test("a held view stays held while output arrives, and follows again at the bottom")
    func holdingStaysUntilTheBottom() {
        let held = geometry(offset: 800, content: 2_000)

        #expect(TranscriptFollow.decide(following: false, turnActive: true, from: held, to: geometry(offset: 800, content: 2_400, rows: 21)) == .holding)
        #expect(TranscriptFollow.decide(following: false, turnActive: true, from: held, to: geometry(offset: 900, content: 2_000)) == .holding)
        #expect(TranscriptFollow.decide(following: false, turnActive: false, from: held, to: geometry(offset: 1_390, content: 2_000)) == .following(catchUp: false))
    }

    @Test("opening a tool step while nothing runs holds the view and offers Follow output")
    func idleGrowthOfAnExistingRowHolds() {
        let before = geometry(offset: 1_400, content: 2_000)
        let after = geometry(offset: 1_400, content: 2_300)

        #expect(TranscriptFollow.decide(following: true, turnActive: false, from: before, to: after) == .holding)
    }

    @Test("a new row follows even when nothing runs yet")
    func newRowFollowsWhileIdle() {
        let before = geometry(offset: 1_400, content: 2_000, rows: 20)
        let after = geometry(offset: 1_400, content: 2_070, rows: 21)

        #expect(TranscriptFollow.decide(following: true, turnActive: false, from: before, to: after) == .following(catchUp: true))
    }

    @Test("a view that gets shorter while following catches up")
    func shrinkingViewCatchesUp() {
        // The composer grows by several lines and takes the room from the transcript.
        let before = geometry(offset: 1_400, visible: 600, content: 2_000)
        let after = geometry(offset: 1_400, visible: 520, content: 2_000)

        #expect(TranscriptFollow.decide(following: true, turnActive: false, from: before, to: after) == .following(catchUp: true))
    }

    @Test("a conversation shorter than the view always follows")
    func shortConversationFollows() {
        let before = geometry(offset: 0, content: 200, rows: 2)
        let after = geometry(offset: 0, content: 400, rows: 2)

        #expect(TranscriptFollow.decide(following: false, turnActive: false, from: before, to: after) == .following(catchUp: false))
    }
}
