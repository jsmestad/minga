/// Observable launchpad state driven by the BEAM via gui_empty_state (0xA5).
///
/// The launchpad is the "nothing open" surface: zero buffers, a resume/get-started
/// hero card, recent files, action rows, and a footer. It is data-driven; the BEAM
/// sends semantic rows (label, activation key/chord, icon) and this frontend owns
/// all layout. `CommandDispatcher` is the single writer; the view only reads.

import SwiftUI
import MingaProtocol

/// Section identifiers from the gui_empty_state wire format.
public enum EmptyStateSectionKind: UInt8 {
    case session = 0
    case recent = 1
    case start = 2
    case footer = 3
}

/// Row kinds from the gui_empty_state wire format.
public enum EmptyStateItemKind: UInt8 {
    case resume = 0
    case recentFile = 1
    case action = 2
    case hint = 3
}

/// A single launchpad row for SwiftUI rendering.
public struct EmptyStateItemModel: Identifiable, Equatable {
    public init(kind: UInt8, itemId: String, label: String, detail: String, jumpKey: String, chord: String, icon: String, iconColor: Color?) {
        self.kind = kind
        self.itemId = itemId
        self.label = label
        self.detail = detail
        self.jumpKey = jumpKey
        self.chord = chord
        self.icon = icon
        self.iconColor = iconColor
    }
    public let kind: UInt8
    public let itemId: String
    public let label: String
    public let detail: String
    public let jumpKey: String
    public let chord: String
    public let icon: String
    public let iconColor: Color?

    public var id: String { itemId }

    public var kindEnum: EmptyStateItemKind? { EmptyStateItemKind(rawValue: kind) }

    /// Chord broken into its individual keystroke tokens (e.g. "SPC f f").
    public var chordTokens: [String] {
        chord.split(separator: " ").map(String.init)
    }

    /// Whether the trailing visual should render `detail` as an ex-command:
    /// accent monospace text with no chip (input-visual class 3).
    public var isExCommandDetail: Bool {
        jumpKey.isEmpty && chord.isEmpty && detail.hasPrefix(":")
    }
}

/// A launchpad section for SwiftUI rendering.
public struct EmptyStateSectionModel: Identifiable, Equatable {
    public init(sectionId: UInt8, title: String, items: [EmptyStateItemModel]) {
        self.sectionId = sectionId
        self.title = title
        self.items = items
    }
    public let sectionId: UInt8
    public let title: String
    public let items: [EmptyStateItemModel]

    public var id: UInt8 { sectionId }

    public var kindEnum: EmptyStateSectionKind? { EmptyStateSectionKind(rawValue: sectionId) }
}

/// Observable state for the launchpad, driven by BEAM protocol messages.
@MainActor
@Observable
public final class EmptyStateState {
    public init(visible: Bool = false, crashed: Bool = false, version: String = "", focusedId: String = "", sections: [EmptyStateSectionModel] = []) {
        self.visible = visible
        self.crashed = crashed
        self.version = version
        self.focusedId = focusedId
        self.sections = sections
    }

    public var visible: Bool = false
    /// Previous session did not shut down cleanly; the hero card tints to warning.
    public var crashed: Bool = false
    public var version: String = ""
    /// Item id of the currently focused row (BEAM-authoritative).
    public var focusedId: String = ""
    public var sections: [EmptyStateSectionModel] = []

    /// Update from a decoded gui_empty_state protocol message.
    public func update(crashed: Bool, version: String, focusedId: String, sections: [Wire.EmptyStateSection]) {
        self.crashed = crashed
        self.version = version
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
                        iconColor: Self.color(from: item.iconColorRGB)
                    )
                }
            )
        }
        self.visible = true
    }

    /// Whether `itemId` is the focused row.
    public func isFocused(_ itemId: String) -> Bool {
        !focusedId.isEmpty && focusedId == itemId
    }

    /// Clear all launchpad state.
    public func hide() {
        visible = false
        crashed = false
        version = ""
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
