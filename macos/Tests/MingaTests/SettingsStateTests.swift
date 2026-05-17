import Testing

@MainActor
@Suite("Settings State")
struct SettingsStateTests {
    @Test("apply updates live fields from config state and only fires cursor blink changes on actual changes")
    func applyConfigState() {
        let state = SettingsState()
        var cursorBlinkChanges: [Bool] = []
        state.onCursorBlinkChanged = { cursorBlinkChanges.append($0) }

        let configState = Wire.ConfigState(
            options: [
                "theme": .atom("doom_one"),
                "font_family": .string("Iosevka"),
                "font_size": .int(18),
                "font_weight": .atom("bold"),
                "font_ligatures": .bool(false),
                "tab_width": .int(4),
                "line_numbers": .atom("relative"),
                "wrap": .bool(true),
                "cursor_blink": .bool(false),
                "cursorline": .bool(false)
            ],
            themePreviews: [
                Wire.ThemePreview(
                    name: "Doom One",
                    atom: "doom_one",
                    editorBg: 0x282C34,
                    editorFg: 0xBBC2CF,
                    accent: 0x51AFEF
                )
            ],
            keybindings: [
                Wire.KeybindingEntry(
                    mode: "normal",
                    key: "SPC f f",
                    command: "find_file",
                    description: "Find file"
                )
            ]
        )

        state.apply(configState: configState)
        state.apply(configState: configState)

        #expect(state.isLoading == false)
        #expect(state.currentThemeName == "doom_one")
        #expect(state.fontFamily == "Iosevka")
        #expect(state.fontSize == 18)
        #expect(state.fontWeight == "bold")
        #expect(state.fontLigatures == false)
        #expect(state.tabWidth == 4)
        #expect(state.lineNumbers == .relative)
        #expect(state.wordWrap == true)
        #expect(state.cursorBlink == false)
        #expect(state.cursorline == false)
        #expect(state.themePreviews.count == 1)
        #expect(state.keybindings.count == 1)
        #expect(cursorBlinkChanges == [false])
    }
}
