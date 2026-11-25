/// Tests for the space-leader chord detector.
///
/// `SpaceLeaderChord` owns the chord-versus-space decision that `EditorNSView` performs for every SPC press.
/// Each transition is tested from every phase so a new phase or event fails here first.

@testable import MingaUI
import Testing

@Suite("Space leader chord detector")
@MainActor
struct SpaceLeaderChordTests {
    enum Event: Sendable {
        case spaceDown
        case spaceRepeat
        case key(UInt32, UInt8)
        case grace
        case spaceUp
    }

    private static let keyA: UInt32 = 0x61
    private static let shiftedA: UInt32 = 0x41
    private static let shift: UInt8 = 0x01

    private func run(_ events: [Event]) -> (effects: [SpaceLeaderChord.Effect], phase: SpaceLeaderChord.Phase) {
        var detector = SpaceLeaderChord()
        let effects = events.map { event -> SpaceLeaderChord.Effect in
            switch event {
            case .spaceDown: detector.spaceDown(isRepeat: false)
            case .spaceRepeat: detector.spaceDown(isRepeat: true)
            case .key(let codepoint, let modifiers): detector.keyDown(codepoint: codepoint, modifiers: modifiers)
            case .grace: detector.graceExpired()
            case .spaceUp: detector.spaceUp()
            }
        }
        return (effects, detector.phase)
    }

    private func phase(after events: [Event]) -> SpaceLeaderChord.Phase {
        run(events).phase
    }

    @Test("every phase answers every event", arguments: [
        // From idle.
        ([], Event.spaceDown, SpaceLeaderChord.Effect.startGrace, SpaceLeaderChord.Phase.pending),
        ([], .spaceRepeat, .sendSpaces(1), .idle),
        ([], .key(0x61, 0), .passThrough, .idle),
        ([], .grace, .consumed, .idle),
        ([], .spaceUp, .consumed, .idle),
        // From pending: SPC is held inside the grace window and nothing was sent.
        ([.spaceDown], .key(0x61, 0), .chord(codepoint: 0x61, modifiers: 0), .idle),
        ([.spaceDown], .key(0x41, 0x01), .chord(codepoint: 0x41, modifiers: 0x01), .idle),
        ([.spaceDown], .grace, .sendSpaces(1), .sent),
        ([.spaceDown], .spaceUp, .sendSpaces(1), .idle),
        ([.spaceDown], .spaceRepeat, .sendSpaces(2), .idle),
        ([.spaceDown], .spaceDown, .startGrace, .pending),
        // From sent: the grace window ended with SPC still held, so one space is already out.
        ([.spaceDown, .grace], .key(0x61, 0), .retract(codepoint: 0x61, modifiers: 0), .idle),
        ([.spaceDown, .grace], .grace, .consumed, .sent),
        ([.spaceDown, .grace], .spaceUp, .consumed, .idle),
        ([.spaceDown, .grace], .spaceRepeat, .sendSpaces(1), .idle),
        ([.spaceDown, .grace], .spaceDown, .startGrace, .pending),
    ] as [([Event], Event, SpaceLeaderChord.Effect, SpaceLeaderChord.Phase)])
    func transition(prefix: [Event], event: Event, effect: SpaceLeaderChord.Effect, next: SpaceLeaderChord.Phase) {
        let result = run(prefix + [event])
        #expect(result.effects.last == effect)
        #expect(result.phase == next)
    }

    @Test("a held SPC chord emits one chord and no space, whichever key is released first")
    func chordInBothReleaseOrders() {
        for releases in [[Event.spaceUp, .grace], [.grace, .spaceUp]] {
            let effects = run([.spaceDown, .key(Self.keyA, 0)] + releases).effects
            #expect(effects.filter { if case .chord = $0 { true } else { false } }.count == 1)
            #expect(!effects.contains { if case .sendSpaces = $0 { true } else { false } })
        }
    }

    @Test("a SPC tap and a held SPC released alone each type exactly one space")
    func lonelySpaceTypesOneSpace() {
        for events in [[Event.spaceDown, .spaceUp, .grace], [.spaceDown, .grace, .spaceUp]] {
            let effects = run(events).effects
            let spaces = effects.reduce(0) { total, effect in
                if case .sendSpaces(let count) = effect { total + count } else { total }
            }
            #expect(spaces == 1)
            #expect(phase(after: events) == .idle)
        }
    }

    @Test("auto-repeat while SPC is held types spaces and a later key is ordinary text")
    func repeatEndsTheLeader() {
        let effects = run([.spaceDown, .grace, .spaceRepeat, .spaceRepeat, .key(Self.keyA, 0), .spaceUp]).effects
        #expect(effects == [.startGrace, .sendSpaces(1), .sendSpaces(1), .sendSpaces(1), .passThrough, .consumed])
    }
}
