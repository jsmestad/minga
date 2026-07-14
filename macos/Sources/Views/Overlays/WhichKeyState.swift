/// Observable which-key state driven by BEAM gui_which_key messages.

import SwiftUI
import MingaProtocol

public struct WhichKeyBinding: Identifiable {
    public init(id: Int, isGroup: Bool, key: String, description: String, icon: String) {
        self.id = id
        self.isGroup = isGroup
        self.key = key
        self.description = description
        self.icon = icon
    }
    public let id: Int
    public let isGroup: Bool
    public let key: String
    public let description: String
    public let icon: String
}

@MainActor
@Observable
public final class WhichKeyState {
    public init(visible: Bool = false, prefix: String = "", page: Int = 0, pageCount: Int = 0, bindings: [WhichKeyBinding] = []) {
        self.visible = visible
        self.prefix = prefix
        self.page = page
        self.pageCount = pageCount
        self.bindings = bindings
    }
    public var visible: Bool = false
    public var prefix: String = ""
    public var page: Int = 0
    public var pageCount: Int = 0
    public var bindings: [WhichKeyBinding] = []

    public func update(visible: Bool, prefix: String, page: UInt8, pageCount: UInt8, rawBindings: [Wire.WhichKeyBinding]) {
        self.visible = visible
        self.prefix = prefix
        self.page = Int(page)
        self.pageCount = Int(pageCount)
        self.bindings = rawBindings.enumerated().map { i, b in
            WhichKeyBinding(id: i, isGroup: b.kind == 1, key: b.key, description: b.description, icon: b.icon)
        }
    }

    public func hide() {
        visible = false
        bindings = []
    }
}
