/// Observable minibuffer state driven by BEAM gui_minibuffer messages (0x7F).
///
/// Holds all state needed to render the native SwiftUI minibuffer:
/// prompt, input text, cursor position, context, and completion candidates.
/// Updated by CommandDispatcher when a guiMinibuffer command arrives.

import SwiftUI
import MingaProtocol

/// A single completion candidate for the minibuffer.
public struct MinibufferCandidate: Identifiable {
    public init(id: Int, matchScore: UInt8, label: String, description: String, annotation: String, matchPositions: Set<Int>) {
        self.id = id
        self.matchScore = matchScore
        self.label = label
        self.description = description
        self.annotation = annotation
        self.matchPositions = matchPositions
    }
    public let id: Int
    public let matchScore: UInt8
    public let label: String
    public let description: String
    public let annotation: String
    /// Character indices that matched the fuzzy query, for accent highlighting.
    public let matchPositions: Set<Int>
}

@MainActor
@Observable
public final class MinibufferState {
    public init(visible: Bool = false, mode: MinibufferMode = .command, cursorPos: UInt16 = 0xFFFF, prompt: String = "", input: String = "", context: String = "", selectedIndex: UInt16 = 0, candidates: [MinibufferCandidate] = [], totalCandidates: UInt16 = 0, inputVersion: Int = 0) {
        self.visible = visible
        self.mode = mode
        self.cursorPos = cursorPos
        self.prompt = prompt
        self.input = input
        self.context = context
        self.selectedIndex = selectedIndex
        self.candidates = candidates
        self.totalCandidates = totalCandidates
        self.inputVersion = inputVersion
    }
    public var visible: Bool = false
    public var mode: MinibufferMode = .command
    public var cursorPos: UInt16 = 0xFFFF
    public var prompt: String = ""
    public var input: String = ""
    public var context: String = ""
    public var selectedIndex: UInt16 = 0
    public var candidates: [MinibufferCandidate] = []
    /// Total matching candidates before the BEAM caps at 15. Used for
    /// the "3 of 47" count indicator when there are more results than visible.
    public var totalCandidates: UInt16 = 0

    /// Monotonically increasing counter that increments on every update().
    /// Used as a reset token for BlinkingCursor so the cursor snaps to
    /// visible on every BEAM frame, regardless of whether the input string
    /// changed length (e.g., delete one char then type one char).
    public var inputVersion: Int = 0

    /// Whether the current mode accepts text input (shows a cursor).
    public var isInputMode: Bool {
        mode.acceptsTextInput
    }

    /// Whether to show a blinking cursor in the input field.
    public var showCursor: Bool {
        cursorPos != 0xFFFF && isInputMode
    }

    /// Whether this is a prompt-only mode (no text input, shows action keys).
    public var isPromptMode: Bool {
        mode.presentsActionKeys
    }

    /// Whether completion candidates are present.
    public var hasCandidates: Bool {
        !candidates.isEmpty
    }

    public func update(visible: Bool, mode: MinibufferMode, cursorPos: UInt16, prompt: String,
                input: String, context: String, selectedIndex: UInt16,
                totalCandidates: UInt16 = 0,
                rawCandidates: [Wire.MinibufferCandidate]) {
        self.visible = visible
        self.mode = mode
        self.cursorPos = cursorPos
        self.prompt = prompt
        self.input = input
        self.context = context
        self.selectedIndex = selectedIndex
        self.totalCandidates = totalCandidates
        self.candidates = rawCandidates.enumerated().map { i, c in
            MinibufferCandidate(
                id: i, matchScore: c.matchScore,
                label: c.label, description: c.description,
                annotation: c.annotation,
                matchPositions: Set(c.matchPositions.map { Int($0) })
            )
        }
        self.inputVersion += 1
    }

    public func hide() {
        visible = false
        candidates = []
    }
}
