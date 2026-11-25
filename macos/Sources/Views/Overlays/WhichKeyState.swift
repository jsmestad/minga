/// Observable which-key state driven by BEAM gui_which_key messages.

import SwiftUI
import MingaProtocol

/// One section of the which-key panel: a run of entries that share a section name, drawn as a column
/// with the name dim above it (an empty name has no heading).
public struct WhichKeySection: Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let entries: [Wire.WhichKeyEntry]
}

@Observable
public final class WhichKeyState {
    public init(model: Wire.WhichKey = .hidden) {
        self.model = model
    }

    public private(set) var model: Wire.WhichKey

    public var visible: Bool { model.visible }
    public var path: String { model.path }
    public var breadcrumb: [Wire.WhichKeyCrumb] { model.breadcrumb }
    public var count: String { model.count }
    public var countTone: Wire.WhichKeyCountTone { model.countTone }
    public var hints: [Wire.WhichKeyHint] { model.hints }
    public var entries: [Wire.WhichKeyEntry] { model.entries }

    /// The entries grouped into sections, in the BEAM's order.
    public var sections: [WhichKeySection] {
        var sections: [WhichKeySection] = []
        for entry in model.entries {
            if let last = sections.last, last.title == entry.section {
                sections[sections.count - 1] = WhichKeySection(id: last.id, title: last.title, entries: last.entries + [entry])
            } else {
                sections.append(WhichKeySection(id: sections.count, title: entry.section, entries: [entry]))
            }
        }
        return sections
    }

    public func update(_ model: Wire.WhichKey) {
        if self.model != model { self.model = model }
    }

    public func hide() {
        if model.visible { model = .hidden }
    }
}
