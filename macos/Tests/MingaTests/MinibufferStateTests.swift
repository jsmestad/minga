import Testing

@Suite("MinibufferState Lifecycle")
struct MinibufferStateLifecycleTests {
    @Test("mode 10 text prompt reports input cursor and hides prompt actions")
    @MainActor func textPromptModeShowsCursor() {
        let state = MinibufferState()
        state.update(
            visible: true,
            mode: MinibufferMode.textPrompt.rawValue,
            cursorPos: 3,
            prompt: "Add project: ",
            input: "abc",
            context: "",
            selectedIndex: 0,
            rawCandidates: []
        )

        #expect(state.visible == true)
        #expect(state.mode == MinibufferMode.textPrompt.rawValue)
        #expect(state.cursorPos == 3)
        #expect(state.isInputMode == true)
        #expect(state.isPromptMode == false)
        #expect(state.showCursor == true)
    }
}
