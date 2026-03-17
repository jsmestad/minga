/// Observable picker/command palette state driven by BEAM gui_picker messages.

import SwiftUI

struct PickerItem: Identifiable {
    let id: Int
    let iconColor: UInt32
    let label: String
    let description: String

    /// Extract the first character as the icon (Nerd Font devicon).
    var icon: String {
        guard let first = label.first else { return "" }
        return String(first)
    }

    /// The label text without the leading icon character.
    var displayLabel: String {
        guard label.count > 1 else { return label }
        return String(label.dropFirst())
    }
}

@MainActor
@Observable
final class PickerState {
    var visible: Bool = false
    var selectedIndex: Int = 0
    var title: String = ""
    var query: String = ""
    var items: [PickerItem] = []

    func update(visible: Bool, selectedIndex: UInt16, title: String, query: String, rawItems: [GUIPickerItem]) {
        self.visible = visible
        self.selectedIndex = Int(selectedIndex)
        self.title = title
        self.query = query
        self.items = rawItems.enumerated().map { i, item in
            PickerItem(id: i, iconColor: item.iconColor, label: item.label, description: item.description)
        }
    }

    func hide() {
        visible = false
        items = []
    }
}
