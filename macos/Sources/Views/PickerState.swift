/// Observable picker/command palette state driven by BEAM gui_picker messages.
///
/// Holds all state needed to render the picker overlay: items with match
/// highlighting, annotations, filtered/total counts, preview content,
/// and multi-select marks.

import SwiftUI

struct PickerItem: Identifiable {
    let id: Int
    let iconColor: UInt32
    let label: String
    let description: String
    let annotation: String
    let matchPositions: [UInt16]
    let isTwoLine: Bool
    let isMarked: Bool

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

    /// Match positions adjusted for the display label (offset by -1 to skip icon).
    /// Only includes positions that fall within the display label range.
    var displayMatchPositions: Set<Int> {
        Set(matchPositions.compactMap { pos in
            let adjusted = Int(pos) - 1  // Skip icon character
            return adjusted >= 0 && adjusted < displayLabel.count ? adjusted : nil
        })
    }
}

/// Action menu state for the picker (C-o menu).
struct PickerActionMenu {
    let selectedIndex: Int
    let actions: [String]
}

/// A line of preview content with styled segments.
struct PreviewLine: Identifiable {
    let id: Int
    let segments: [PreviewSegment]
}

struct PreviewSegment: Identifiable {
    let id: Int
    let text: String
    let fgColor: UInt32
    let bold: Bool
}

@MainActor
@Observable
final class PickerState {
    var visible: Bool = false
    var selectedIndex: Int = 0
    var filteredCount: Int = 0
    var totalCount: Int = 0
    var title: String = ""
    var query: String = ""
    var hasPreview: Bool = false
    var items: [PickerItem] = []
    var previewLines: [PreviewLine] = []
    var actionMenu: PickerActionMenu? = nil

    func update(visible: Bool, selectedIndex: UInt16, filteredCount: UInt16, totalCount: UInt16, title: String, query: String, hasPreview: Bool, rawItems: [GUIPickerItem], actionMenu: GUIPickerActionMenu?) {
        self.visible = visible
        self.selectedIndex = Int(selectedIndex)
        self.filteredCount = Int(filteredCount)
        self.totalCount = Int(totalCount)
        self.title = title
        self.query = query
        self.hasPreview = hasPreview
        self.items = rawItems.enumerated().map { i, item in
            PickerItem(
                id: i,
                iconColor: item.iconColor,
                label: item.label,
                description: item.description,
                annotation: item.annotation,
                matchPositions: item.matchPositions,
                isTwoLine: item.isTwoLine,
                isMarked: item.isMarked
            )
        }
        if let am = actionMenu {
            self.actionMenu = PickerActionMenu(
                selectedIndex: Int(am.selectedIndex),
                actions: am.actions
            )
        } else {
            self.actionMenu = nil
        }
    }

    func updatePreview(lines: [GUIPickerPreviewLine]) {
        self.previewLines = lines.enumerated().map { lineIdx, segments in
            PreviewLine(
                id: lineIdx,
                segments: segments.enumerated().map { segIdx, seg in
                    PreviewSegment(
                        id: segIdx,
                        text: seg.text,
                        fgColor: seg.fgColor,
                        bold: seg.bold
                    )
                }
            )
        }
    }

    func clearPreview() {
        self.previewLines = []
    }

    func hide() {
        visible = false
        items = []
        previewLines = []
        hasPreview = false
        actionMenu = nil
    }
}
