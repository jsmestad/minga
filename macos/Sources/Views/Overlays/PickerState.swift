/// Observable picker/command palette state driven by BEAM gui_picker messages.
///
/// Holds all state needed to render the picker overlay: items with match
/// highlighting, annotations, filtered/total counts, preview content,
/// and multi-select marks.

import SwiftUI
import MingaProtocol

public struct PickerItem: Identifiable {
    public init(id: Int, iconColor: UInt32, label: String, description: String, annotation: String, matchPositions: [UInt16], isTwoLine: Bool, isMarked: Bool) {
        self.id = id
        self.iconColor = iconColor
        self.label = label
        self.description = description
        self.annotation = annotation
        self.matchPositions = matchPositions
        self.isTwoLine = isTwoLine
        self.isMarked = isMarked
    }
    public let id: Int
    public let iconColor: UInt32
    public let label: String
    public let description: String
    public let annotation: String
    public let matchPositions: [UInt16]
    public let isTwoLine: Bool
    public let isMarked: Bool

    /// Whether the label starts with a separate icon glyph.
    public var hasLeadingIcon: Bool {
        guard let first = label.first else { return false }
        return first.isPrivateUseScalar
    }

    /// Extract the leading icon glyph when the label intentionally includes one.
    public var icon: String {
        guard hasLeadingIcon, let first = label.first else { return "" }
        return String(first)
    }

    /// The label text without the leading icon glyph and its spacer.
    public var displayLabel: String {
        String(label.dropFirst(displayPrefixLength))
    }

    /// Match positions adjusted for the visible label after removing an icon prefix.
    /// Only includes positions that fall within the display label range.
    public var displayMatchPositions: Set<Int> {
        Set(matchPositions.compactMap { pos in
            let adjusted = Int(pos) - displayPrefixLength
            return adjusted >= 0 && adjusted < displayLabel.count ? adjusted : nil
        })
    }

    private var displayPrefixLength: Int {
        guard hasLeadingIcon else { return 0 }
        let afterIcon = label.dropFirst()
        return afterIcon.first == " " ? 2 : 1
    }
}

/// Action menu state for the picker (C-o menu).
public struct PickerActionMenu {
    public init(selectedIndex: Int, actions: [String]) {
        self.selectedIndex = selectedIndex
        self.actions = actions
    }
    public let selectedIndex: Int
    public let actions: [String]
}

/// A line of preview content with styled segments.
public struct PreviewLine: Identifiable {
    public init(id: Int, segments: [PreviewSegment]) {
        self.id = id
        self.segments = segments
    }
    public let id: Int
    public let segments: [PreviewSegment]
}

public struct PreviewSegment: Identifiable {
    public init(id: Int, text: String, fgColor: UInt32, bold: Bool) {
        self.id = id
        self.text = text
        self.fgColor = fgColor
        self.bold = bold
    }
    public let id: Int
    public let text: String
    public let fgColor: UInt32
    public let bold: Bool
}

@MainActor
@Observable
public final class PickerState {
    public init(visible: Bool = false, selectedIndex: Int = 0, previewSelectedIndex: Int? = nil, filteredCount: Int = 0, totalCount: Int = 0, markedCount: Int = 0, title: String = "", query: String = "", modePrefix: String = "", hasPreview: Bool = false, loadStatus: Wire.PickerLoadStatus = .ready, items: [PickerItem] = [], previewLines: [PreviewLine] = [], actionMenu: PickerActionMenu? = nil) {
        self.visible = visible
        self.selectedIndex = selectedIndex
        self.previewSelectedIndex = previewSelectedIndex
        self.filteredCount = filteredCount
        self.totalCount = totalCount
        self.markedCount = markedCount
        self.title = title
        self.query = query
        self.modePrefix = modePrefix
        self.hasPreview = hasPreview
        self.loadStatus = loadStatus
        self.items = items
        self.previewLines = previewLines
        self.actionMenu = actionMenu
    }
    public var visible: Bool = false
    public var selectedIndex: Int = 0
    public var previewSelectedIndex: Int?

    public var effectiveSelectedIndex: Int {
        if let preview = previewSelectedIndex, preview >= 0, preview < items.count {
            return preview
        }
        return selectedIndex
    }
    public var filteredCount: Int = 0
    public var totalCount: Int = 0
    public var markedCount: Int = 0
    public var title: String = ""
    public var query: String = ""
    public var modePrefix: String = ""
    public var hasPreview: Bool = false
    public var loadStatus: Wire.PickerLoadStatus = .ready
    public var items: [PickerItem] = []
    public var previewLines: [PreviewLine] = []
    public var actionMenu: PickerActionMenu? = nil

    public func update(visible: Bool, selectedIndex: UInt16, filteredCount: UInt16, totalCount: UInt16, markedCount: UInt16, title: String, query: String, hasPreview: Bool, rawItems: [Wire.PickerItem], actionMenu: Wire.PickerActionMenu?, modePrefix: String = "", loadStatus: Wire.PickerLoadStatus = .ready) {
        self.visible = visible
        self.selectedIndex = Int(selectedIndex)
        self.previewSelectedIndex = nil
        self.filteredCount = Int(filteredCount)
        self.totalCount = Int(totalCount)
        self.markedCount = Int(markedCount)
        self.title = title
        self.query = query
        self.modePrefix = modePrefix
        self.hasPreview = hasPreview
        self.loadStatus = loadStatus
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

    public func updatePreview(lines: [Wire.PickerPreviewLine]) {
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

    public func clearPreview() {
        self.previewLines = []
    }

    public func previewNavigation(delta: Int) -> Bool {
        guard visible, !items.isEmpty else { return false }
        let current = previewSelectedIndex ?? selectedIndex
        let next = min(max(current + delta, 0), items.count - 1)
        guard next != current else { return false }
        previewSelectedIndex = next
        return true
    }

    public func hide() {
        visible = false
        markedCount = 0
        items = []
        previewLines = []
        previewSelectedIndex = nil
        modePrefix = ""
        hasPreview = false
        loadStatus = .ready
        actionMenu = nil
    }
}

private extension Character {
    var isPrivateUseScalar: Bool {
        unicodeScalars.contains { scalar in
            let value = scalar.value
            return (value >= 0xE000 && value <= 0xF8FF) ||
                (value >= 0xF0000 && value <= 0xFFFFD) ||
                (value >= 0x100000 && value <= 0x10FFFD)
        }
    }
}
