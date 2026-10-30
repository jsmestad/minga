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
    private let itemHeight: CGFloat = 24

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

                        let totalItemsHeight = CGFloat(state.items.count) * itemHeight
                        let maxHeight = geo.size.height * 0.4
                        let listHeight = min(totalItemsHeight, max(maxHeight, 120))
                        resultsList(maxListHeight: listHeight)
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

            if state.totalCount > 0 {
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
        Group {
            if case .loading = state.loadStatus {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(state.title.isEmpty ? "Loading..." : "\(state.title)...")
                        .font(Typography.font(.emphasis))
                        .foregroundStyle(theme.popupFg.opacity(0.35))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(maxHeight: maxListHeight)
                .frame(minHeight: 48)
            } else if case .error(let message) = state.loadStatus {
                Text(message)
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: maxListHeight)
                    .frame(minHeight: 48)
            } else if state.items.isEmpty && !state.query.isEmpty {
                Text("No matches")
                    .font(Typography.font(.emphasis))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: maxListHeight)
                    .frame(minHeight: 48)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(state.items) { item in
                                Button {
                                    activate(item)
                                } label: {
                                    PickerItemRow(
                                        item: item,
                                        isSelected: item.id == state.effectiveSelectedIndex,
                                        query: state.query,
                                        itemHeight: itemHeight
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

    // MARK: - Action menu (C-o)

    @ViewBuilder
    private func actionMenuOverlay(_ menu: PickerActionMenu) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Actions")
                    .font(Typography.font(.body, weight: .semibold))
                    .foregroundStyle(theme.popupFg.opacity(0.6))
                Spacer()
                Text("C-o")
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

    private func pickerItemAccessibilityValue(_ item: PickerItem) -> String {
        var values: [String] = []
        values.append(item.id == state.effectiveSelectedIndex ? "selected" : "available")
        if item.isMarked {
            values.append("marked")
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

// MARK: - Picker item row (separate View for observation isolation)

private struct PickerItemRow: View {
    let item: PickerItem
    let isSelected: Bool
    let query: String
    let itemHeight: CGFloat

    @Environment(\.themeColors) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            itemCheckmark
            itemIcon
            highlightedLabel

            if !item.description.isEmpty {
                highlightedDescription
            }

            Spacer(minLength: 4)
            itemAnnotation
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: itemHeight)
        .background(selectionBackground)
        .id(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.displayLabel + (item.description.isEmpty ? "" : ", " + item.description)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Subviews

    @ViewBuilder
    private var itemCheckmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(Typography.font(.small))
            .foregroundStyle(theme.accent)
            .frame(width: 14)
            .opacity(item.isMarked ? 1 : 0)
            .accessibilityHidden(true)
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
                .truncationMode(.head)
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
            .truncationMode(.head)
        }
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

@MainActor
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
            Wire.PickerItem(iconColor: 0x98BE65, flags: 0x01, label: "\u{f0e7}editor_test.exs", description: "test/minga/editor_test.exs", annotation: "test", matchPositions: [1, 2, 3, 4]),
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
