/// Observable picker/command palette state driven by BEAM gui_picker messages.
///
/// Holds all state needed to render the picker overlay: items with match
/// highlighting, annotations, filtered/total counts, preview content,
/// and multi-select marks.

import SwiftUI
import MingaProtocol

public struct PickerActivationIdentity: Equatable, Sendable {
    public init(generation: UInt32, activationID: UInt32) {
        self.generation = generation
        self.activationID = activationID
    }

    public let generation: UInt32
    public let activationID: UInt32

    public var isAvailable: Bool { generation != 0 && activationID != 0 }
}

public struct PickerItem: Identifiable {
    public init(id: Int, activation: PickerActivationIdentity = PickerActivationIdentity(generation: 0, activationID: 0), iconColor: UInt32, label: String, description: String, annotation: String, matchPositions: [UInt16], isMarked: Bool, isActive: Bool = false, status: String = "", statusTone: Wire.PickerStatusTone = .absent, group: String = "") {
        self.id = id
        self.activation = activation
        self.iconColor = iconColor
        self.label = label
        self.description = description
        self.annotation = annotation
        self.matchPositions = matchPositions
        self.isMarked = isMarked
        self.isActive = isActive
        self.status = status
        self.statusTone = statusTone
        self.group = group
    }
    public let id: Int
    public let activation: PickerActivationIdentity
    public let iconColor: UInt32
    public let label: String
    public let description: String
    public let annotation: String
    public let matchPositions: [UInt16]
    public let isMarked: Bool
    /// The item is the current value, such as the current model.
    public let isActive: Bool
    /// BEAM-authored status chip text, such as a model row's readiness and plan usage. Rendered verbatim.
    public let status: String
    public let statusTone: Wire.PickerStatusTone
    /// The BEAM-authored section, such as a model's route. Empty when the item has no section.
    public let group: String

    /// Whether the row shows a status chip.
    public var hasStatus: Bool {
        !status.isEmpty && statusTone != .absent
    }

    /// A row with a status chip puts its description on a second line and keeps the description's start. A row without one stays inline and keeps the end of a path.
    public var stacksDescription: Bool {
        hasStatus && !description.isEmpty
    }

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

public struct PickerActionEntry: Identifiable {
    public init(id: Int, label: String, activation: PickerActivationIdentity) {
        self.id = id
        self.label = label
        self.activation = activation
    }

    public let id: Int
    public let label: String
    public let activation: PickerActivationIdentity
}

/// Action menu state for the picker (the ⌃. act menu).
public struct PickerActionMenu {
    public init(selectedIndex: Int, entries: [PickerActionEntry]) {
        self.selectedIndex = selectedIndex
        self.entries = entries
    }

    public let selectedIndex: Int
    public let entries: [PickerActionEntry]
    public var actions: [String] { entries.map(\.label) }
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

@Observable
public final class PickerState {
    public init(visible: Bool = false, selectedIndex: Int = 0, previewSelectedIndex: Int? = nil, filteredCount: Int = 0, totalCount: Int = 0, markedCount: Int = 0, title: String = "", query: String = "", modePrefix: String = "", hasPreview: Bool = false, loadStatus: Wire.PickerLoadStatus = .ready, items: [PickerItem] = [], previewLines: [PreviewLine] = [], actionMenu: PickerActionMenu? = nil, queryGeneration: UInt32 = 0, acknowledgedQueryEditSeq: UInt32 = 0, localPresentationStore: LocalPresentationStore = LocalPresentationStore()) {
        self.localPresentationStore = localPresentationStore
        self.visible = visible
        self.selectedIndex = selectedIndex
        self.previewSelectedIndex = previewSelectedIndex
        self.filteredCount = filteredCount
        self.totalCount = totalCount
        self.markedCount = markedCount
        self.title = title
        self.query = query
        self.queryGeneration = queryGeneration
        self.acknowledgedQueryEditSeq = acknowledgedQueryEditSeq
        self.modePrefix = modePrefix
        self.hasPreview = hasPreview
        self.loadStatus = loadStatus
        self.items = items
        self.previewLines = previewLines
        self.actionMenu = actionMenu
        self.activationGeneration = items.first?.activation.generation ?? 0
    }
    @ObservationIgnored private let localPresentationStore: LocalPresentationStore
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
    public var queryGeneration: UInt32 = 0
    public var acknowledgedQueryEditSeq: UInt32 = 0
    public var activationGeneration: UInt32 = 0
    public var modePrefix: String = ""
    public var hasPreview: Bool = false
    public var loadStatus: Wire.PickerLoadStatus = .ready
    public var items: [PickerItem] = []
    public var previewLines: [PreviewLine] = []
    public var actionMenu: PickerActionMenu? = nil
    /// Set while the picker offers its source's next steps instead of results: the header says what happened and why, and `items` are the next-step rows.
    public var empty: Wire.EmptyList? = nil
    /// True while the picker has nothing to filter: it takes no text, so the query field steps aside and the editor view's keys (j and k move, q closes) reach the picker.
    public var listKeys: Bool = false
    /// The single keys the BEAM's picker keymap scope binds for this picker. The query field forwards exactly these and keeps every other key for the text.
    public var keys: [Wire.PickerKey] = []
    /// Names the list of offered rows. A selection preview is kept only under the revision it was made under.
    public var listRevision: UInt32 = 0

    public func update(visible: Bool, selectedIndex: UInt16, filteredCount: UInt16, totalCount: UInt16, markedCount: UInt16, title: String, query: String, hasPreview: Bool, rawItems: [Wire.PickerItem], actionMenu: Wire.PickerActionMenu?, modePrefix: String = "", loadStatus: Wire.PickerLoadStatus = .ready, queryGeneration: UInt32 = 0, acknowledgedQueryEditSeq: UInt32 = 0, activationGeneration: UInt32 = 0, empty: Wire.EmptyList? = nil, listKeys: Bool = false, keys: [Wire.PickerKey] = [], listRevision: UInt32 = 0) {
        self.visible = visible
        self.empty = empty
        self.listKeys = listKeys
        self.keys = keys
        self.listRevision = listRevision
        self.filteredCount = Int(filteredCount)
        self.totalCount = Int(totalCount)
        self.markedCount = Int(markedCount)
        self.title = title
        self.query = query
        self.queryGeneration = queryGeneration
        self.acknowledgedQueryEditSeq = acknowledgedQueryEditSeq
        self.modePrefix = modePrefix
        self.hasPreview = hasPreview
        self.loadStatus = loadStatus
        let nextItems = rawItems.enumerated().map { i, item in
            PickerItem(
                id: i,
                activation: PickerActivationIdentity(
                    generation: activationGeneration,
                    activationID: item.activationID
                ),
                iconColor: item.iconColor,
                label: item.label,
                description: item.description,
                annotation: item.annotation,
                matchPositions: item.matchPositions,
                isMarked: item.isMarked,
                isActive: item.isActive,
                status: item.status,
                statusTone: item.statusTone,
                group: item.group
            )
        }
        self.items = nextItems
        self.activationGeneration = activationGeneration
        self.selectedIndex = min(Int(selectedIndex), max(nextItems.count - 1, 0))
        let selectedActivationID = nextItems[safe: self.selectedIndex]?.activation.activationID ?? 0
        let retainedIDs = Set(nextItems.map { String($0.activation.activationID) })
        // An open act menu owns the list keys, so a preview made before its frame arrived was a move of the menu on the BEAM; the picker row stays where the BEAM has it.
        let effectiveID = localPresentationStore.reconcile(surface: .picker, generation: activationGeneration, revision: listRevision, committedItemID: String(selectedActivationID), retainedItemIDs: retainedIDs, visible: visible && actionMenu == nil)
        self.previewSelectedIndex = nextItems.firstIndex(where: { String($0.activation.activationID) == effectiveID }).flatMap { $0 == self.selectedIndex ? nil : $0 }
        if let am = actionMenu {
            self.actionMenu = PickerActionMenu(
                selectedIndex: Int(am.selectedIndex),
                entries: am.actions.enumerated().map { index, label in
                    PickerActionEntry(
                        id: index,
                        label: label,
                        activation: PickerActivationIdentity(
                            generation: activationGeneration,
                            activationID: index < am.activationIDs.count ? am.activationIDs[index] : 0
                        )
                    )
                }
            )
        } else {
            self.actionMenu = nil
        }
    }

    public func updateSelection(generation: UInt32, selectedItemID: UInt32, selectedActionID: UInt32) {
        guard generation == activationGeneration else {
            localPresentationStore.discard(.picker)
            previewSelectedIndex = nil
            return
        }
        if let committedIndex = items.firstIndex(where: { $0.activation.activationID == selectedItemID }) {
            selectedIndex = committedIndex
            let retainedIDs = Set(items.map { String($0.activation.activationID) })
            let effectiveID = localPresentationStore.reconcile(surface: .picker, generation: generation, revision: listRevision, committedItemID: String(selectedItemID), retainedItemIDs: retainedIDs)
            previewSelectedIndex = items.firstIndex(where: { String($0.activation.activationID) == effectiveID }).flatMap { $0 == committedIndex ? nil : $0 }
        } else {
            localPresentationStore.discard(.picker)
            previewSelectedIndex = nil
        }
        if let menu = actionMenu,
           let actionIndex = menu.entries.firstIndex(where: { $0.activation.activationID == selectedActionID }) {
            actionMenu = PickerActionMenu(selectedIndex: actionIndex, entries: menu.entries)
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

    /// True when the BEAM lists that exact key press as a key this picker binds, so it is sent to the BEAM and not typed into the query.
    public func binds(codepoint: UInt32, modifiers: UInt8) -> Bool {
        keys.contains { $0.codepoint == codepoint && $0.modifiers == modifiers }
    }

    /// Returns the rows a key press may move the highlighted row before the BEAM answers, or nil when the BEAM allows no preview for that exact key.
    public func movementDelta(codepoint: UInt32, modifiers: UInt8) -> Int? {
        guard let delta = keys.first(where: { $0.codepoint == codepoint && $0.modifiers == modifiers })?.delta, delta != 0 else { return nil }
        return delta
    }

    /// Moves the highlighted row ahead of the BEAM for a key press that is being sent to it, when the BEAM allows a preview for that exact key.
    ///
    /// Any other key (a page, a character, a close) moves the BEAM's selection in a way the frontend does not predict, so a highlight that ran ahead is dropped and the next frame's row is shown.
    @discardableResult
    public func previewNavigation(codepoint: UInt32, modifiers: UInt8) -> Bool {
        guard let delta = movementDelta(codepoint: codepoint, modifiers: modifiers) else {
            // The editor view calls this for every key press, so nothing is written unless a preview is held.
            if previewSelectedIndex != nil || localPresentationStore.preview(for: .picker) != nil {
                localPresentationStore.discard(.picker)
                previewSelectedIndex = nil
            }
            return false
        }
        return previewNavigation(delta: delta)
    }

    public func previewNavigation(delta: Int) -> Bool {
        // The open act menu owns the list keys; the picker's highlighted row stays where it is.
        guard visible, actionMenu == nil, !items.isEmpty else { return false }
        let current = previewSelectedIndex ?? selectedIndex
        let next = previewTarget(from: current, delta: delta)
        guard next != current else { return false }
        localPresentationStore.setPreview(LocalPresentationIdentity(generation: activationGeneration, revision: listRevision, itemID: String(items[next].activation.activationID)), for: .picker)
        previewSelectedIndex = next
        return true
    }

    /// The row a move of `delta` rows from `current` lands on, or `current` when there is nothing to preview.
    ///
    /// The BEAM wraps a one-row move at the ends of the list, so the preview wraps with it, but only when the rows held are the whole list. At the edge of a partial window the row the BEAM moves to is not here, so the highlight stays until the frame arrives.
    private func previewTarget(from current: Int, delta: Int) -> Int {
        let next = current + delta
        if items.indices.contains(next) { return next }
        guard abs(delta) == 1, holdsWholeList else { return min(max(next, 0), items.count - 1) }
        return next < 0 ? items.count - 1 : 0
    }

    /// True when `items` are every row the BEAM's selection can reach. The BEAM offers at most a window of a long result list, and counts no matches while the rows are a source's next steps.
    private var holdsWholeList: Bool {
        empty != nil || items.count == filteredCount
    }

    public func hide() {
        localPresentationStore.discard(.picker)
        visible = false
        markedCount = 0
        items = []
        previewLines = []
        previewSelectedIndex = nil
        queryGeneration = 0
        acknowledgedQueryEditSeq = 0
        activationGeneration = 0
        modePrefix = ""
        hasPreview = false
        empty = nil
        listKeys = false
        loadStatus = .ready
        actionMenu = nil
        keys = []
        listRevision = 0
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
