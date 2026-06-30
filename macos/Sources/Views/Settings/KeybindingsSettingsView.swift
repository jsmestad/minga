import SwiftUI
import MingaProtocol

/// Read-only keybinding browser with a shortcut to open the hand-written config file.
public struct KeybindingsSettingsView: View {
    public init(state: SettingsState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    @Bindable var state: SettingsState
    let encoder: InputEncoder?
    @State private var searchText: String = ""

    private var filteredBindings: [Wire.KeybindingEntry] {
        guard !searchText.isEmpty else { return state.keybindings }
        let needle = searchText.lowercased()
        return state.keybindings.filter { entry in
            entry.mode.lowercased().contains(needle) ||
                entry.key.lowercased().contains(needle) ||
                entry.command.lowercased().contains(needle) ||
                entry.description.lowercased().contains(needle)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keybindings")
                        .font(.headline)
                    Text("Bindings are read-only here. Edit config.exs for custom mappings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open Config File") {
                    encoder?.sendExecuteCommand(name: "open_config")
                }
            }

            Table(filteredBindings) {
                TableColumn("Mode", value: \.mode)
                    .width(min: 80, ideal: 100)
                TableColumn("Key", value: \.key)
                    .width(min: 80, ideal: 100)
                TableColumn("Command", value: \.command)
                    .width(min: 120, ideal: 160)
                TableColumn("Description", value: \.description)
            }
            .searchable(text: $searchText, placement: .automatic, prompt: "Search keybindings")
        }
        .padding(20)
    }
}

#Preview("Keybindings Settings") {
    let state = SettingsState()
    state.isLoading = false
    state.keybindings = [
        Wire.KeybindingEntry(mode: "normal", key: "j", command: "move_down", description: "Move cursor down"),
        Wire.KeybindingEntry(mode: "normal", key: "k", command: "move_up", description: "Move cursor up"),
        Wire.KeybindingEntry(mode: "normal", key: "h", command: "move_left", description: "Move cursor left"),
        Wire.KeybindingEntry(mode: "normal", key: "l", command: "move_right", description: "Move cursor right"),
        Wire.KeybindingEntry(mode: "normal", key: "SPC f f", command: "find_file", description: "Open file finder"),
        Wire.KeybindingEntry(mode: "normal", key: "SPC b b", command: "switch_buffer", description: "Switch buffer"),
        Wire.KeybindingEntry(mode: "insert", key: "Escape", command: "normal_mode", description: "Return to normal mode"),
    ]
    return KeybindingsSettingsView(state: state, encoder: nil)
        .frame(width: 520, height: 360)
}
