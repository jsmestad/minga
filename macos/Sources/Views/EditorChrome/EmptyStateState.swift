/// Observable project home state, `*home*` (#4056), driven by the BEAM via gui_empty_state (0xA5).
///
/// The home is a resting view: a header that says where you are, then recent files or recent
/// projects, Minga's tasks and the next actions. It is data-driven; the BEAM sends semantic rows
/// (label, number key or chord, state) and this frontend owns all layout. `CommandDispatcher` is
/// the single writer; the view only reads.

import SwiftUI
import MingaProtocol

/// Section identifiers from the gui_empty_state wire format.
public enum EmptyStateSectionKind: UInt8 {
    case recent = 1
    case projects = 4
    case tasks = 5
    case next = 6
}

/// Row kinds from the gui_empty_state wire format.
public enum EmptyStateItemKind: UInt8 {
    case recentFile = 1
    case action = 2
    case project = 4
    case task = 5
}

/// A single home row for SwiftUI rendering.
public struct EmptyStateItemModel: Identifiable, Equatable {
    public init(kind: UInt8, itemId: String, label: String, detail: String, jumpKey: String, chord: String, icon: String, iconColor: Color?, meta: String = "", state: String = "") {
        self.kind = kind
        self.itemId = itemId
        self.label = label
        self.detail = detail
        self.jumpKey = jumpKey
        self.chord = chord
        self.icon = icon
        self.iconColor = iconColor
        self.meta = meta
        self.state = state
    }
    public let kind: UInt8
    public let itemId: String
    public let label: String
    public let detail: String
    public let jumpKey: String
    public let chord: String
    public let icon: String
    public let iconColor: Color?
    public let meta: String
    /// Design-token state name for a task row ("needs_you"), empty otherwise.
    public let state: String

    public var id: String { itemId }

    public var kindEnum: EmptyStateItemKind? { EmptyStateItemKind(rawValue: kind) }

    /// What the key column shows: the number key or the chord.
    public var keyText: String { jumpKey.isEmpty ? chord : jumpKey }
}

/// A home section for SwiftUI rendering.
public struct EmptyStateSectionModel: Identifiable, Equatable {
    public init(sectionId: UInt8, title: String, items: [EmptyStateItemModel], empty: String = "") {
        self.sectionId = sectionId
        self.title = title
        self.empty = empty
        self.items = items
    }
    public let sectionId: UInt8
    public let title: String
    /// Muted line shown when the section has no rows.
    public let empty: String
    public let items: [EmptyStateItemModel]

    public var id: UInt8 { sectionId }

    public var kindEnum: EmptyStateSectionKind? { EmptyStateSectionKind(rawValue: sectionId) }
}

/// Observable state for the project home, driven by BEAM protocol messages.
@Observable
public final class EmptyStateState {
    public init(visible: Bool = false, title: String = "", path: String = "", status: String = "", note: String = "", focusedId: String = "", sections: [EmptyStateSectionModel] = []) {
        self.visible = visible
        self.title = title
        self.path = path
        self.status = status
        self.note = note
        self.focusedId = focusedId
        self.sections = sections
    }

    public var visible: Bool = false
    /// Project or folder name, or "Minga" outside a project.
    public var title: String = ""
    /// Home-relative path of the root.
    public var path: String = ""
    /// One line: branch and change count, or why there is no project.
    public var status: String = ""
    /// Optional muted second line.
    public var note: String = ""
    /// Item id of the currently focused row (BEAM-authoritative).
    public var focusedId: String = ""
    public var sections: [EmptyStateSectionModel] = []

    /// Update from a decoded gui_empty_state protocol message.
    public func update(header: Wire.EmptyStateHeader, focusedId: String, sections: [Wire.EmptyStateSection]) {
        self.title = header.title
        self.path = header.path
        self.status = header.status
        self.note = header.note
        self.focusedId = focusedId
        self.sections = sections.map { section in
            EmptyStateSectionModel(
                sectionId: section.sectionId,
                title: section.title,
                items: section.items.map { item in
                    EmptyStateItemModel(
                        kind: item.kind,
                        itemId: item.id,
                        label: item.label,
                        detail: item.detail,
                        jumpKey: item.jumpKey,
                        chord: item.chord,
                        icon: item.icon,
                        iconColor: Self.color(from: item.iconColorRGB),
                        meta: item.meta,
                        state: item.state
                    )
                },
                empty: section.empty
            )
        }
        self.visible = true
    }

    /// Whether `itemId` is the focused row.
    public func isFocused(_ itemId: String) -> Bool {
        !focusedId.isEmpty && focusedId == itemId
    }

    /// Clear all home state.
    public func hide() {
        visible = false
        title = ""
        path = ""
        status = ""
        note = ""
        focusedId = ""
        sections = []
    }

    private static func color(from rgb: UInt32) -> Color? {
        guard rgb != 0 else { return nil }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
