import SwiftUI

/// Read-only keybinding browser with a shortcut to open the hand-written config file.
struct KeybindingsSettingsView: View {
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

    var body: some View {
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
