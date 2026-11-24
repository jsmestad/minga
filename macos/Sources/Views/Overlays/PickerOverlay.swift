/// Native command palette / file finder anchored at the top of the window.
///
/// The panel drops down from the top-center (like VSCode/Zed), leaving the
/// editor area visible below for live file preview. The BEAM switches the
/// active buffer on navigation so the preview appears behind the picker.

import SwiftUI
import MingaProtocol

public struct PickerOverlay: View {
    public enum Action: Equatable, Sendable {
        case queryChanged(generation: UInt32, editSequence: UInt32, text: String)
        case keyPress(codepoint: UInt32, modifiers: UInt8, sequence: UInt32)
        case activateItem(generation: UInt32, activationID: UInt32)
        case activateAction(generation: UInt32, activationID: UInt32)
    }

    public init(state: PickerState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }
    public let state: PickerState
    @Environment(\.themeColors) private var theme

    public let sendAction: ViewActionHandler<Action>?

    private let panelWidth: CGFloat = 600
    /// Where a row's label starts: the row inset, the 14pt leading slot and its gap. An empty state's title shares this leading edge.
    static let rowTextLeading: CGFloat = Spacing.md + 14 + Spacing.sm
    static let itemHeight: CGFloat = 24
    /// Status rows stack their description under the label so readiness and plan usage get the full row width.
    static let stackedItemHeight: CGFloat = 40
    /// A section header names the group of the rows below it, such as a model route.
    static let sectionHeaderHeight: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var accessibilityFocus: PickerAccessibilityFocus?

    private var animDuration: Double {
        reduceMotion ? 0 : 0.1
    }

    public var body: some View {
        if state.visible {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        searchField

                        Divider()
                            .overlay(theme.popupBorder.opacity(0.3))

                        let totalItemsHeight = Self.listContentHeight(state.items)
                        let maxHeight = geo.size.height * 0.4
                        let listHeight = min(totalItemsHeight, max(maxHeight, 120))
                        resultsList(maxListHeight: listHeight)
                        if state.hasPreview && !state.previewLines.isEmpty {
                            Divider().overlay(theme.popupBorder.opacity(0.3))
                            previewPanel(maxHeight: geo.size.height * 0.18)
                        }
                    }
                    .frame(width: min(panelWidth, geo.size.width - 40))
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(theme.popupBg)
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .strokeBorder(theme.popupBorder.opacity(0.4), lineWidth: 1)
                    )
                    .overlay(alignment: .center) {
                        if let menu = state.actionMenu {
                            actionMenuOverlay(menu)
                        }
                    }
                    .padding(.top, Spacing.pixel)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .transition(.opacity.animation(.easeInOut(duration: animDuration)))
            .onAppear {
                updateAccessibilityFocus()
            }
            .onChange(of: state.visible) { _, _ in
                updateAccessibilityFocus()
            }
            .onChange(of: state.effectiveSelectedIndex) { _, _ in
                updateAccessibilityFocus()
            }
            .onChange(of: currentActivationGeneration) { _, _ in
                updateAccessibilityFocus()
            }
            .onChange(of: currentActionSelection) { _, _ in
                updateAccessibilityFocus()
            }
        }
    }

    private func previewPanel(maxHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(state.previewLines) { line in
                    Text(attributedPreviewLine(line))
                        .font(Typography.font(.small, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .textSelection(.enabled)
        }
        .frame(maxHeight: maxHeight)
        .accessibilityLabel("Selected result preview")
    }

    private func attributedPreviewLine(_ line: PreviewLine) -> AttributedString {
        var text = AttributedString()
        for segment in line.segments {
            let color = segment.fgColor
            var span = AttributedString(segment.text)
            span.foregroundColor = Color(
                red: Double((color >> 16) & 255) / 255,
                green: Double((color >> 8) & 255) / 255,
                blue: Double(color & 255) / 255
            )
            if segment.bold {
                span.inlinePresentationIntent = .stronglyEmphasized
            }
            text.append(span)
        }
        return text
    }

    // MARK: - Search field

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(Typography.font(.emphasis))
                .foregroundStyle(theme.popupFg.opacity(0.4))

            if !state.modePrefix.isEmpty {
                modePrefixBadge
            }

            if state.listKeys {
                // Nothing to filter, so there is no query to type: the title stands in for the field and the editor view keeps the keyboard.
                Text(pickerTitle)
                    .font(Typography.font(.body))
                    .foregroundStyle(theme.popupFg)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            } else {
            PickerQueryField(
                authoritativeText: state.query,
                generation: state.queryGeneration,
                acknowledgedEditSequence: state.acknowledgedQueryEditSeq,
                placeholder: state.title.isEmpty ? "Search..." : state.title,
                isEditable: state.actionMenu == nil,
                style: InlineEditFieldStyle(
                    textColor: theme.popupFg,
                    selectionBackgroundColor: theme.accent.opacity(0.35),
                    selectionForegroundColor: theme.popupFg,
                    insertionPointColor: theme.accent
                ),
                sendAction: queryFieldAction
            )
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            }

            if state.empty != nil {
                Text(state.listKeys ? "j k move   ↩ run   q close" : "⌃J ⌃K move   ↩ run   esc close")
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.popupFg.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
                    .anatomyPart("picker.hints", text: "move run close", font: .small)
            }

            if state.markedCount > 0 {
                Text("\(state.markedCount) marked")
                    .font(Typography.font(.small, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.hairline)
                    .background(
                        Capsule()
                            .fill(theme.accent.opacity(0.14))
                    )
            }

            if state.totalCount > 0 && state.empty == nil {
                Text("\(state.filteredCount)/\(state.totalCount)")
                    .font(Typography.font(.small, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    @ViewBuilder
    private var modePrefixBadge: some View {
        Text("[\(state.modePrefix)]")
            .font(Typography.font(.body, design: .monospaced))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.hairline)
            .background(
                Capsule()
                    .fill(theme.accent.opacity(0.14))
            )
            .accessibilityLabel(Text("Picker mode \(state.modePrefix)"))
    }

    // MARK: - Results list

    @ViewBuilder
    private func resultsList(maxListHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if case .loading = state.loadStatus {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(state.title.isEmpty ? "Loading..." : "\(state.title)...")
                        .font(Typography.font(.emphasis))
                        .foregroundStyle(theme.popupFg.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(minHeight: 48)
            } else if case .error(let message) = state.loadStatus {
                Text(message)
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(theme.popupFg)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(minHeight: 48)
            }

            if let empty = state.empty {
                EmptyListHeader(empty: empty, textColor: theme.popupFg, mutedColor: theme.popupFg.opacity(0.6))
                    .padding(.leading, Self.rowTextLeading)
                    .padding(.trailing, Spacing.md)
                    .padding(.top, EmptyStateMetrics.inset)
                    .padding(.bottom, EmptyStateMetrics.whyToActions)
            }

            if case .ready = state.loadStatus, state.empty == nil, state.items.isEmpty && !state.query.isEmpty {
                Text("No matches")
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: maxListHeight)
                    .frame(minHeight: 48)
            } else if !state.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(state.items) { item in
                                // A section header is presentation only: it is not a button, has no activation identity, and selection, scrolling and clicks address the item below it.
                                if let header = Self.sectionHeader(state.items, at: item.id) {
                                    PickerSectionHeader(title: header)
                                }
                                Button {
                                    activate(item)
                                } label: {
                                    PickerItemRow(
                                        item: item,
                                        isSelected: item.id == state.effectiveSelectedIndex,
                                        query: state.query,
                                        itemHeight: Self.rowHeight(item)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .disabled(!item.activation.isAvailable)
                                .accessibilityIdentifier("picker-choice-\(item.activation.generation)-\(item.activation.activationID)")
                                .accessibilityLabel(Text(item.displayLabel))
                                .accessibilityValue(pickerItemAccessibilityValue(item))
                                .accessibilityAddTraits(item.id == state.effectiveSelectedIndex ? .isSelected : [])
                                .accessibilityFocused(
                                    $accessibilityFocus,
                                    equals: .item(item.activation.generation, item.activation.activationID)
                                )
                            }
                        }
                    }
                    .frame(maxHeight: maxListHeight)
                    .onChange(of: state.effectiveSelectedIndex) { _, newIndex in
                        withAnimation(nil) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                    .onChange(of: state.items.count) { _, _ in
                        withAnimation(nil) {
                            proxy.scrollTo(state.effectiveSelectedIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pickerTitle) choices")
        .accessibilityValue(resultsAccessibilityValue)
    }

    // MARK: - Action menu (⌃.)

    @ViewBuilder
    private func actionMenuOverlay(_ menu: PickerActionMenu) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Actions")
                    .font(Typography.font(.body, weight: .semibold))
                    .foregroundStyle(theme.popupFg.opacity(0.6))
                Spacer()
                Text("⌃.")
                    .font(Typography.font(.caption, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.3))
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)

            Rectangle()
                .fill(theme.popupBorder.opacity(0.3))
                .frame(height: 1)

            ForEach(menu.entries) { entry in
                let isSelected = entry.id == menu.selectedIndex

                Button {
                    activate(entry)
                } label: {
                    HStack {
                        Text(entry.label)
                            .font(Typography.font(.emphasis))
                            .foregroundStyle(isSelected ? theme.popupSelFg : theme.popupFg)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background(
                        isSelected
                            ? RoundedRectangle(cornerRadius: Radius.sm).fill(theme.accent).padding(.horizontal, Spacing.xs)
                            : nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(!entry.activation.isAvailable)
                .accessibilityIdentifier("picker-action-\(entry.activation.generation)-\(entry.activation.activationID)")
                .accessibilityLabel(Text(entry.label))
                .accessibilityValue(entry.activation.isAvailable ? (isSelected ? "selected" : "available") : "unavailable")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityFocused(
                    $accessibilityFocus,
                    equals: .action(entry.activation.generation, entry.activation.activationID)
                )
            }
        }
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(theme.popupBg)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions choices")
        .accessibilityValue("\(menu.entries.count) actions")
    }

    private var pickerTitle: String {
        state.title.isEmpty ? "Picker" : state.title
    }

    private var currentActivationGeneration: UInt32 {
        state.items.first?.activation.generation ?? state.actionMenu?.entries.first?.activation.generation ?? 0
    }

    private var currentActionSelection: String? {
        guard let menu = state.actionMenu else { return nil }
        return "\(currentActivationGeneration):\(menu.selectedIndex)"
    }

    private var resultsAccessibilityValue: String {
        switch state.loadStatus {
        case .loading:
            return "Loading"
        case .error(let message):
            return "Error: \(message)"
        case .ready:
            return state.items.isEmpty ? "No choices" : "\(state.items.count) choices"
        }
    }

    /// The row's spoken label: the name, then its status, then its description.
    static func rowAccessibilityLabel(_ item: PickerItem) -> String {
        [item.displayLabel, item.hasStatus ? item.status : "", item.description]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func rowHeight(_ item: PickerItem) -> CGFloat {
        item.stacksDescription ? stackedItemHeight : itemHeight
    }

    /// The group to name in a section header above `items[index]`, or nil. A header goes above an item whose group is not empty and differs from the previous item's.
    static func sectionHeader(_ items: [PickerItem], at index: Int) -> String? {
        guard index >= 0, index < items.count else { return nil }
        let group = items[index].group
        if group.isEmpty { return nil }
        if index > 0 && items[index - 1].group == group { return nil }
        return group
    }

    /// The unclipped height of every row and section header, which bounds the scrolling list.
    static func listContentHeight(_ items: [PickerItem]) -> CGFloat {
        var height: CGFloat = 0
        for index in items.indices {
            height += rowHeight(items[index])
            if sectionHeader(items, at: index) != nil {
                height += sectionHeaderHeight
            }
        }
        return height
    }

    private func pickerItemAccessibilityValue(_ item: PickerItem) -> String {
        var values: [String] = []
        values.append(item.id == state.effectiveSelectedIndex ? "selected" : "available")
        if item.isMarked {
            values.append("marked")
        }
        if item.isActive {
            values.append("current")
        }
        if item.hasStatus {
            values.append(item.status)
        }
        if !item.activation.isAvailable {
            values.append("unavailable")
        }
        if !item.description.isEmpty {
            values.append(item.description)
        }
        return values.joined(separator: ", ")
    }

    private func activate(_ item: PickerItem) {
        guard item.activation.isAvailable else { return }
        sendAction?(.activateItem(generation: item.activation.generation, activationID: item.activation.activationID))
    }

    private func activate(_ entry: PickerActionEntry) {
        guard entry.activation.isAvailable else { return }
        sendAction?(.activateAction(generation: entry.activation.generation, activationID: entry.activation.activationID))
    }

    private var queryFieldAction: ViewActionHandler<PickerQueryField.Action>? {
        guard let sendAction else { return nil }
        return { action in
            switch action {
            case .queryChanged(let generation, let editSequence, let text): sendAction(.queryChanged(generation: generation, editSequence: editSequence, text: text))
            case .keyPress(let codepoint, let modifiers, let sequence): sendAction(.keyPress(codepoint: codepoint, modifiers: modifiers, sequence: sequence))
            }
        }
    }

    private func updateAccessibilityFocus() {
        guard state.visible else {
            accessibilityFocus = nil
            return
        }
        if let menu = state.actionMenu,
           let entry = menu.entries.first(where: { $0.id == menu.selectedIndex }),
           entry.activation.isAvailable {
            accessibilityFocus = .action(entry.activation.generation, entry.activation.activationID)
            return
        }
        guard let item = state.items.first(where: { $0.id == state.effectiveSelectedIndex }),
              item.activation.isAvailable else {
            accessibilityFocus = nil
            return
        }
        accessibilityFocus = .item(item.activation.generation, item.activation.activationID)
    }

}

private enum PickerAccessibilityFocus: Hashable {
    case item(UInt32, UInt32)
    case action(UInt32, UInt32)
}

// MARK: - Section header

/// A non-selectable row that names the group of the items below it.
private struct PickerSectionHeader: View {
    let title: String

    @Environment(\.themeColors) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(title)
                .font(Typography.font(.small, weight: .semibold))
                .foregroundStyle(theme.popupFg.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.xs)
        .frame(height: PickerOverlay.sectionHeaderHeight, alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Picker item row (separate View for observation isolation)

private struct PickerItemRow: View {
    let item: PickerItem
    let isSelected: Bool
    let query: String
    let itemHeight: CGFloat

    @Environment(\.themeColors) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            leadingSlot
            itemIcon
            if item.stacksDescription {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    HStack(spacing: Spacing.sm) {
                        highlightedLabel
                        Spacer(minLength: 4)
                        itemAnnotation
                        statusChip
                    }
                    highlightedDescription
                }
            } else {
                highlightedLabel

                if !item.description.isEmpty {
                    highlightedDescription
                }

                Spacer(minLength: 4)
                itemAnnotation
                statusChip
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: itemHeight)
        .background(selectionBackground)
        .id(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(PickerOverlay.rowAccessibilityLabel(item)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Subviews

    /// The 14pt leading slot: a checkmark for a marked row, otherwise a dot for the current value.
    @ViewBuilder
    private var leadingSlot: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(Typography.font(.small))
            .foregroundStyle(theme.accent)
            .frame(width: 14)
            .opacity(item.isMarked ? 1 : 0)
            .overlay {
                if !item.isMarked && item.isActive {
                    Image(systemName: "circle.fill")
                        .font(Typography.font(.symbol))
                        .foregroundStyle(theme.accent)
                }
            }
            .accessibilityHidden(true)
    }

    /// The BEAM's status text in a tinted chip. The text always carries the meaning; the tone only colors it.
    @ViewBuilder
    private var statusChip: some View {
        if item.hasStatus {
            let tone = statusToneColor(item.statusTone)
            Text(item.status)
                .font(Typography.font(.small, design: .monospaced))
                .foregroundStyle(tone)
                .lineLimit(1)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.pixel)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(tone.opacity(0.12))
                )
                .fixedSize()
                .layoutPriority(1)
        }
    }

    private func statusToneColor(_ tone: Wire.PickerStatusTone) -> Color {
        switch tone {
        case .ready: return theme.gitAddedFg
        case .warn: return theme.gutterWarningFg
        case .error: return theme.gutterErrorFg
        case .checking, .neutral, .absent: return theme.popupFg.opacity(0.5)
        }
    }

    @ViewBuilder
    private var itemIcon: some View {
        if item.hasLeadingIcon {
            Text(item.icon)
                .font(.custom("Symbols Nerd Font Mono", size: Typography.Step.emphasis.rawValue))
                .foregroundStyle(iconColor(item.iconColor))
                .frame(width: 18, alignment: .center)
        }
    }

    @ViewBuilder
    private var itemAnnotation: some View {
        if !item.annotation.isEmpty {
            Text(item.annotation)
                .font(Typography.font(.small, design: .monospaced))
                .foregroundStyle(theme.popupFg.opacity(0.3))
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.pixel)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(theme.popupFg.opacity(0.06))
                )
                .layoutPriority(item.hasStatus ? 1 : 0)
        }
    }

    // MARK: - Match highlighting

    @ViewBuilder
    private var highlightedLabel: some View {
        let label = item.displayLabel
        let matchSet = item.displayMatchPositions
        let fg = isSelected ? theme.popupSelFg : theme.popupFg

        if matchSet.isEmpty {
            Text(label)
                .font(Typography.monospacedSmall)
                .foregroundStyle(fg)
                .lineLimit(1)
        } else {
            Text(TextHighlighting.attributedString(
                label,
                matchPositions: matchSet,
                baseFont: Typography.monospacedSmall,
                matchFont: Typography.font(.small, weight: .semibold, design: .monospaced),
                baseColor: Color(fg),
                matchColor: Color(theme.accent)
            ))
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var highlightedDescription: some View {
        let desc = item.description
        let descPositions = TextHighlighting.fuzzyMatchPositions(desc, query: query)
        let fg = isSelected ? theme.popupSelFg.opacity(0.6) : theme.popupFg.opacity(0.35)

        if descPositions.isEmpty {
            Text(desc)
                .font(Typography.font(.body))
                .foregroundStyle(fg)
                .lineLimit(1)
                .truncationMode(descriptionTruncation)
        } else {
            Text(TextHighlighting.attributedString(
                desc,
                matchPositions: descPositions,
                baseFont: Typography.font(.body),
                matchFont: Typography.font(.body, weight: .semibold),
                baseColor: Color(fg),
                matchColor: Color(theme.accent)
            ))
            .lineLimit(1)
            .truncationMode(descriptionTruncation)
        }
    }

    /// Paths keep their end (the file name). A row with a status chip keeps the start of its description (the route and account).
    private var descriptionTruncation: Text.TruncationMode {
        item.hasStatus ? .tail : .head
    }

    // MARK: - Helpers

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(theme.popupSelBg.opacity(0.7))
                .padding(.horizontal, Spacing.hairline)
        } else {
            Color.clear
        }
    }

    private func iconColor(_ rgb: UInt32) -> Color {
        if rgb == 0 { return theme.popupFg.opacity(0.5) }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

private func pickerPreviewState() -> PickerState {
    let state = PickerState()
    state.update(
        visible: true,
        selectedIndex: 1,
        filteredCount: 5,
        totalCount: 42,
        markedCount: 0,
        title: "Find File",
        query: "edit",
        hasPreview: false,
        rawItems: [
            Wire.PickerItem(iconColor: 0x98BE65, flags: 0, label: "\u{f0e7}editor.ex", description: "lib/minga/editor.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0x98BE65, flags: 0, label: "\u{f0e7}editor_test.exs", description: "test/minga/editor_test.exs", annotation: "test", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0x51AFEF, flags: 0, label: "\u{f0e7}EditorNSView.swift", description: "macos/Sources/EditorNSView.swift", annotation: "swift", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0xECBE7B, flags: 0, label: "\u{f085}edit_mode.ex", description: "lib/minga/mode/edit_mode.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
            Wire.PickerItem(iconColor: 0xC678DD, flags: 0, label: "\u{f0e7}editor_config.ex", description: "lib/minga/editor/config.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
        ],
        actionMenu: nil,
        modePrefix: ""
    )
    return state
}

#Preview("Picker") {
    let theme = PreviewFixtures.theme()
    ZStack(alignment: .top) {
        theme.editorBg
        PickerOverlay(state: pickerPreviewState(), sendAction: { _ in })
    }
    .frame(width: 700, height: 500)
    .clipped()
    .environment(\.themeColors, theme)
}
