/// Observable which-key state driven by BEAM gui_which_key messages.

import SwiftUI

struct WhichKeyBinding: Identifiable {
    let id: Int
    let isGroup: Bool
    let key: String
    let description: String
    let icon: String
}

@MainActor
@Observable
final class WhichKeyState {
    var visible: Bool = false
    var prefix: String = ""
    var page: Int = 0
    var pageCount: Int = 0
    var bindings: [WhichKeyBinding] = []

    func update(visible: Bool, prefix: String, page: UInt8, pageCount: UInt8, rawBindings: [Wire.WhichKeyBinding]) {
        self.visible = visible
        self.prefix = prefix
        self.page = Int(page)
        self.pageCount = Int(pageCount)
        self.bindings = rawBindings.enumerated().map { i, b in
            WhichKeyBinding(id: i, isGroup: b.kind == 1, key: b.key, description: b.description, icon: b.icon)
        }
    }

    func hide() {
        visible = false
        bindings = []
    }
}
