import MingaProtocol
import SwiftUI

/// A window-level overlay, anchored in the Metal editor's physical coordinate space.
struct ActMenuOverlay: View {
    nonisolated struct Action: Sendable {
        let offerID: UInt64
        let actionID: UInt16
    }

    let state: ActMenuState
    let editorBounds: Anchor<CGRect>?
    let editorGeometry: () -> EditorGeometry
    let sendAction: ViewActionHandler<Action>?

    var body: some View {
        if let menu = state.menu {
            GeometryReader { proxy in
                let size = proxy.size
                let width = max(0, min(456, size.width - 2 * Spacing.md))
                let anchor = anchorRect(menu.anchor, in: proxy)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { sendAction?(.init(offerID: menu.offerID, actionID: 0)) }
                        .overlay {
                            SecondaryClick { sendAction?(.init(offerID: menu.offerID, actionID: 0)) }
                        }
                        .accessibilityHidden(true)

                    ActMenuPlacement(anchor: anchor, inset: Spacing.md, gap: Spacing.xs) {
                        ActMenuPanel(menu: menu, width: width, sendAction: sendAction)
                    }
                }
            }
        }
    }

    private func anchorRect(_ anchor: Wire.ActMenu.Anchor, in proxy: GeometryProxy) -> CGRect? {
        guard let editorBounds else { return nil }
        let origin = proxy[editorBounds].origin
        switch anchor {
        case .centered:
            return nil
        case .caret:
            return state.presentedCaret?.offsetBy(dx: origin.x, dy: origin.y)
        case .grid(let row, let column):
            let geometry = editorGeometry()
            let pitch = geometry.actMenuGridCellSize ?? CGSize(width: geometry.cellWidth, height: geometry.cellHeight)
            return CGRect(x: origin.x + CGFloat(column) * pitch.width, y: origin.y + CGFloat(row) * pitch.height,
                          width: pitch.width, height: pitch.height)
        }
    }
}

/// Place only the panel; the separate scrim keeps its full-window hit region.
private struct ActMenuPlacement: Layout {
    let anchor: CGRect?
    let inset: CGFloat
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let ideal = panel.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let size = CGSize(width: ideal.width, height: min(ideal.height, max(0, bounds.height - 2 * inset)))
        let target = anchor?.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let x = target?.minX ?? bounds.midX - size.width / 2
        let y = if let target {
            target.maxY + gap + size.height <= bounds.maxY - inset
                ? target.maxY + gap : target.minY - gap - size.height
        } else {
            bounds.midY - size.height / 2
        }
        panel.place(at: CGPoint(
            x: min(max(bounds.minX + inset, x), max(bounds.minX + inset, bounds.maxX - size.width - inset)),
            y: min(max(bounds.minY + inset, y), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        ), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// Measure both labels first so the two actual button hit regions have equal dimensions.
private struct ActMenuDecisionBar: Layout {
    let width: CGFloat
    let gap: CGFloat

    private var halfWidth: CGFloat { max(0, (width - gap) / 2) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let half = ProposedViewSize(width: halfWidth, height: nil)
        let height = subviews.reduce(CGFloat.zero) { max($0, $1.sizeThatFits(half).height) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let half = ProposedViewSize(width: halfWidth, height: bounds.height)
        for (index, button) in subviews.enumerated() {
            button.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (halfWidth + gap), y: bounds.minY),
                         anchor: .topLeading, proposal: half)
        }
    }
}

private struct ActMenuPanel: View {
    let menu: Wire.ActMenu
    let width: CGFloat
    let sendAction: ViewActionHandler<ActMenuOverlay.Action>?
    @Environment(\.themeColors) private var theme

    private var border: Color {
        switch menu.role {
        case .neutral: theme.popupBorder
        case .minga: theme.roleColor(.minga)
        case .failure: theme.roleColor(.failure)
        }
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                header
                list
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView { list }
                        .onChange(of: menu.selectedID, initial: true) { _, selected in
                            if selected != 0, menu.rows.contains(where: { $0.id == selected }) {
                                proxy.scrollTo(selected)
                            }
                        }
                }
            }
        }
        .frame(width: width)
        .background(theme.popupBg)
        .overlay(alignment: .leading) {
            Rectangle().fill(border).frame(width: Spacing.hairline + Spacing.pixel)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: Spacing.pixel)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("act-menu-\(menu.offerID)")
        .accessibilityLabel(Text(menu.title))
        .anatomyPart("actMenu.panel")
    }

    private var header: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(menu.title)
                        .font(Typography.font(.title, weight: .semibold))
                        .foregroundStyle(theme.popupFg)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                        .anatomyPart("actMenu.title", text: menu.title, font: .title)
                    Spacer(minLength: 0)
                    if menu.query.isEmpty { filterButton("› filter") }
                }
                if !menu.query.isEmpty { filterButton("› \(menu.query)") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)

            if let primary = menu.lead.first {
                rule
                if menu.lead.count == 2 {
                    let showsShortcut = !primary.hint.isEmpty || !menu.lead[1].hint.isEmpty
                    ActMenuDecisionBar(width: max(0, width - 2 * Spacing.lg), gap: Spacing.md) {
                        decision(primary, showsShortcut: showsShortcut)
                        decision(menu.lead[1], showsShortcut: showsShortcut)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                } else {
                    decision(primary, showsShortcut: !primary.hint.isEmpty)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.md)
                }
            }
        }
    }

    private func filterButton(_ label: String) -> some View {
        Button {
            sendAction?(.init(offerID: menu.offerID, actionID: .max))
        } label: {
            Text(label)
                .font(Typography.monospacedSmall)
                .foregroundStyle(theme.popupFg)
                .lineLimit(1)
                .contentShape(Rectangle())
                .anatomyPart("actMenu.filter", text: label, font: .small, monospaced: true)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("Filter actions")
        .accessibilityValue(Text(menu.query))
        .accessibilityIdentifier("act-menu-\(menu.offerID)-filter")
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(menu.rows.indices, id: \.self) { index in
                let row = menu.rows[index]
                if index == 0 || row.section != menu.rows[index - 1].section {
                    if row.section.isEmpty {
                        rule
                    } else {
                        HStack(spacing: Spacing.sm) {
                            Text(row.section)
                                .font(Typography.font(.caption, weight: .semibold))
                                .foregroundStyle(theme.popupFg)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityAddTraits(.isHeader)
                                .anatomyPart("actMenu.section", text: row.section, font: .caption)
                            rule
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.top, Spacing.sm)
                    }
                }
                action(row) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        key(row.key).frame(width: Spacing.panel, alignment: .leading)
                        wording(row)
                        if !row.hint.isEmpty {
                            shortcut(row.hint)
                        }
                    }
                }
                .id(row.id)
            }
        }
        .padding(.bottom, menu.rows.isEmpty ? 0 : Spacing.xs)
    }

    private var rule: some View {
        Rectangle().fill(theme.popupBorder.opacity(0.45)).frame(height: Spacing.pixel)
    }

    private func decision(_ row: Wire.ActMenu.Row, showsShortcut: Bool) -> some View {
        action(row, decision: true) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    key(row.key).frame(width: Spacing.xl, alignment: .leading)
                    Text(row.label)
                        .font(Typography.font(.emphasis, weight: .semibold))
                        .foregroundStyle(theme.popupFg)
                        .lineLimit(2)
                        .anatomyPart("actMenu.label", text: row.label, font: .emphasis)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(Typography.font(.small))
                        .foregroundStyle(theme.popupFg)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .anatomyPart("actMenu.detail", text: row.detail, font: .small)
                        .padding(.leading, Spacing.xl + Spacing.sm)
                }
                if showsShortcut {
                    Spacer(minLength: 0)
                    shortcut(row.hint)
                        .lineLimit(1, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func shortcut(_ text: String) -> some View {
        Text(text)
            .font(Typography.monospacedSmall)
            .foregroundStyle(theme.popupFg)
            .lineLimit(1)
            .anatomyPart("actMenu.shortcut", text: text, font: .small, monospaced: true, enabled: !text.isEmpty)
    }

    private func wording(_ row: Wire.ActMenu.Row) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            Text(row.label)
                .font(Typography.font(.body, weight: .medium))
                .foregroundStyle(theme.popupFg)
                .lineLimit(2)
                .anatomyPart("actMenu.label", text: row.label, font: .body)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.popupFg)
                    .lineLimit(3)
                    .anatomyPart("actMenu.detail", text: row.detail, font: .small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func key(_ text: String) -> some View {
        Text(text)
            .font(Typography.monospacedSmall)
            .foregroundStyle(theme.popupFg)
            .lineLimit(1)
            .anatomyPart("actMenu.key", text: text, font: .small, monospaced: true, enabled: !text.isEmpty)
    }

    private func action<Label: View>(_ row: Wire.ActMenu.Row, decision: Bool = false, @ViewBuilder label: () -> Label) -> some View {
        let selected = menu.selectedID != 0 && row.id == menu.selectedID
        return Button {
            sendAction?(.init(offerID: menu.offerID, actionID: row.id))
        } label: {
            label()
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if decision {
                        let shape = RoundedRectangle(cornerRadius: Radius.md)
                        shape.fill(selected ? border.opacity(0.08) : theme.popupFg.opacity(0.03))
                        shape.strokeBorder(selected ? border.opacity(0.65) : theme.popupBorder.opacity(0.5), lineWidth: Spacing.pixel)
                    } else if selected {
                        border.opacity(0.08)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityIdentifier("act-menu-\(menu.offerID)-action-\(row.id)")
        .accessibilityLabel(Text(row.label))
        .accessibilityValue(Text([row.key, row.hint].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityHint(Text(row.detail))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .anatomyPart(decision ? "actMenu.decision" : "actMenu.row")
    }
}
