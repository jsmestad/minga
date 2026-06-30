import SwiftUI

/// Editor behavior settings.
public struct EditorSettingsView: View {
    public init(state: SettingsState) {
        self.state = state
    }
    @Bindable var state: SettingsState

    public var body: some View {
        Form {
            Section("Indentation") {
                Picker("Tab Width", selection: Binding(
                    get: { state.tabWidth },
                    set: { width in
                        state.update(key: "tab_width", value: .int(width))
                    }
                )) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("8 spaces").tag(8)
                }
                .pickerStyle(.segmented)
            }

            Section("Display") {
                Picker("Line Numbers", selection: Binding(
                    get: { state.lineNumbers },
                    set: { style in
                        state.update(key: "line_numbers", value: .atom(style.rawValue))
                    }
                )) {
                    ForEach(SettingsLineNumberStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Toggle("Word Wrap", isOn: Binding(
                    get: { state.wordWrap },
                    set: { enabled in
                        state.update(key: "wrap", value: .bool(enabled))
                    }
                ))

                Toggle("Highlight Current Line", isOn: Binding(
                    get: { state.cursorline },
                    set: { enabled in
                        state.update(key: "cursorline", value: .bool(enabled))
                    }
                ))

                Toggle("Cursor Blink", isOn: Binding(
                    get: { state.cursorBlink },
                    set: { enabled in
                        state.update(key: "cursor_blink", value: .bool(enabled))
                    }
                ))
            }
        }
        .padding(20)
    }
}

#Preview("Editor Settings") {
    let state = SettingsState()
    state.isLoading = false
    state.tabWidth = 2
    state.lineNumbers = .absolute
    state.wordWrap = false
    state.cursorBlink = true
    state.cursorline = true
    return EditorSettingsView(state: state)
        .frame(width: 520, height: 360)
}
