/// Decides whether a bare SPC is typed text or the start of a space-leader chord.
///
/// In CUA mode a held SPC is a leader key: SPC down then another key down while SPC is still held opens which-key at that key's group, while a tap types a space.
/// `EditorNSView` feeds key events in and performs the returned effect; this type owns the phase so every press and release order has one answer and can be tested without a window.
/// The view owns the grace timer: it starts the timer on `.startGrace` and calls `graceExpired()` when the timer fires.
struct SpaceLeaderChord: Equatable {
    /// Where the detector is in one SPC press.
    enum Phase: Equatable {
        /// No SPC is held, or a held SPC auto-repeated and stopped being a leader.
        case idle
        /// SPC is down inside the grace window and no space has been sent yet.
        case pending
        /// The grace window ended with SPC still down, so the space has already been sent.
        case sent
    }

    /// What the view sends to the BEAM for one event.
    enum Effect: Equatable {
        /// The detector does not consume the event; ordinary key handling continues.
        case passThrough
        /// The detector holds the SPC back; start the grace timer.
        case startGrace
        /// Send this many literal spaces.
        case sendSpaces(Int)
        /// A clean chord: no space was sent, so enter the leader at this key.
        case chord(codepoint: UInt32, modifiers: UInt8)
        /// A late chord: the space was already sent, so the BEAM retracts it and enters the leader at this key.
        case retract(codepoint: UInt32, modifiers: UInt8)
        /// The detector consumes the event and sends nothing.
        case consumed
    }

    private(set) var phase: Phase = .idle

    /// A bare SPC (no modifiers) went down.
    mutating func spaceDown(isRepeat: Bool) -> Effect {
        guard isRepeat else {
            phase = .pending
            return .startGrace
        }
        // Auto-repeat means the user is typing spaces, so the held SPC is no longer a leader.
        let held = phase == .pending ? 1 : 0
        phase = .idle
        return .sendSpaces(held + 1)
    }

    /// A key other than a bare SPC went down.
    mutating func keyDown(codepoint: UInt32, modifiers: UInt8) -> Effect {
        switch phase {
        case .idle:
            return .passThrough
        case .pending:
            phase = .idle
            return .chord(codepoint: codepoint, modifiers: modifiers)
        case .sent:
            phase = .idle
            return .retract(codepoint: codepoint, modifiers: modifiers)
        }
    }

    /// The grace timer fired.
    mutating func graceExpired() -> Effect {
        guard phase == .pending else { return .consumed }
        phase = .sent
        return .sendSpaces(1)
    }

    /// SPC went up. A tap inside the grace window sends its space now.
    mutating func spaceUp() -> Effect {
        let wasPending = phase == .pending
        phase = .idle
        return wasPending ? .sendSpaces(1) : .consumed
    }
}
