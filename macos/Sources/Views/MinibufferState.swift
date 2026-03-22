/// Observable minibuffer state driven by BEAM gui_minibuffer messages (0x7F).
///
/// Holds all state needed to render the native SwiftUI minibuffer:
/// prompt, input text, cursor position, context, and completion candidates.
/// Updated by CommandDispatcher when a guiMinibuffer command arrives.

import SwiftUI

/// A single completion candidate for the minibuffer.
struct MinibufferCandidate: Identifiable {
    let id: Int
    let matchScore: UInt8
    let label: String
    let description: String
}

/// Minibuffer mode constants matching the BEAM protocol.
enum MinibufferMode: UInt8 {
    case command = 0
    case searchForward = 1
    case searchBackward = 2
    case searchPrompt = 3
    case eval = 4
    case substituteConfirm = 5
    case extensionConfirm = 6
    case describeKey = 7
}

@MainActor
@Observable
final class MinibufferState {
    var visible: Bool = false
    var mode: UInt8 = 0
    var cursorPos: UInt16 = 0xFFFF
    var prompt: String = ""
    var input: String = ""
    var context: String = ""
    var selectedIndex: UInt16 = 0
    var candidates: [MinibufferCandidate] = []

    /// Monotonically increasing counter that increments on every update().
    /// Used as a reset token for BlinkingCursor so the cursor snaps to
    /// visible on every BEAM frame, regardless of whether the input string
    /// changed length (e.g., delete one char then type one char).
    var inputVersion: Int = 0

    /// Whether the current mode accepts text input (shows a cursor).
    var isInputMode: Bool {
        mode <= MinibufferMode.eval.rawValue
    }

    /// Whether to show a blinking cursor in the input field.
    var showCursor: Bool {
        cursorPos != 0xFFFF && isInputMode
    }

    /// Whether this is a prompt-only mode (no text input, shows action keys).
    var isPromptMode: Bool {
        mode >= MinibufferMode.substituteConfirm.rawValue
    }

    /// Whether completion candidates are present.
    var hasCandidates: Bool {
        !candidates.isEmpty
    }

    func update(visible: Bool, mode: UInt8, cursorPos: UInt16, prompt: String,
                input: String, context: String, selectedIndex: UInt16,
                rawCandidates: [GUIMinibufferCandidate]) {
        self.visible = visible
        self.mode = mode
        self.cursorPos = cursorPos
        self.prompt = prompt
        self.input = input
        self.context = context
        self.selectedIndex = selectedIndex
        self.candidates = rawCandidates.enumerated().map { i, c in
            MinibufferCandidate(id: i, matchScore: c.matchScore,
                                label: c.label, description: c.description)
        }
        self.inputVersion += 1
    }

    func hide() {
        visible = false
        candidates = []
    }
}
