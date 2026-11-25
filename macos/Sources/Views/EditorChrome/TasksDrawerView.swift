import AppKit
import MingaProtocol
import SwiftUI

/// `*minga-tasks*`: every task Minga is working on, in a bottom drawer that is a real split of the window.
///
/// The BEAM decides every word, the order, the selection and the actions (`Wire.TasksDrawer`); this view lays them out
/// by the "Drawer" and "List row" anatomy in `docs/design/anatomy.md`. A click names the row it hit by identity and
/// what it did there, so it acts on the task the user saw even when rows move.
public struct TasksDrawerView: View {
    public enum Action: Equatable, Sendable {
        /// `select`, an approval key (`y`, `a`, `t`, `n`), or `q` with an empty row id to close the drawer.
        case rowAction(rowID: String, action: String)
        /// An empty state's next step: the command its action names.
        case runCommand(name: String)
    }

    public init(state: TasksDrawerState, sendAction: ViewActionHandler<Action>?, availableHeight: CGFloat) {
        self.state = state
        self.sendAction = sendAction
        self.availableHeight = availableHeight
    }

    public let state: TasksDrawerState
    public let sendAction: ViewActionHandler<Action>?
    /// Height of the window's content column, for the drawer's share of it.
    public let availableHeight: CGFloat

    @Environment(\.themeColors) private var theme
    /// The drawer's share of the column, a frontend-local presentation the user can drag; double-click resets it.
    @State private var share: CGFloat = TasksDrawerMetrics.defaultShare
    @State private var dragStartShare: CGFloat?

    public var body: some View {
        let drawer = state.drawer
        VStack(spacing: 0) {
            divider
            header(drawer)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if drawer.view == .list, let empty = drawer.empty {
                            emptyBody(empty)
                        } else if drawer.view == .list {
                            ForEach(drawer.rows) { row in
                                TasksDrawerRowView(row: row, focused: drawer.focused, sendAction: sendAction)
                                    .id(row.id)
                            }
                        } else {
                            viewBody(drawer)
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.sm)
                }
                // The selected row stays on screen, so a key never acts on a task you cannot see.
                .onChange(of: selectedID(drawer)) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            if !drawer.prompt.isEmpty {
                Text(drawer.prompt)
                    .font(Typography.font(.body, weight: .semibold))
                    .foregroundStyle(theme.stateColor(.needsYou))
                    .padding(.horizontal, Spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: TasksDrawerMetrics.rowPitch, alignment: .leading)
                    .anatomyPart("drawer.prompt", text: drawer.prompt, font: .body)
            }
        }
        .frame(height: max(availableHeight * share, TasksDrawerMetrics.minimumHeight))
        .background(theme.editorBg)
        // A click on empty space gives the drawer the keyboard; rows and actions handle their own clicks first.
        .contentShape(Rectangle())
        .onTapGesture { sendAction?(.rowAction(rowID: "", action: "focus")) }
        .anatomyPart("drawer")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(drawer.title)
    }

    private func selectedID(_ drawer: Wire.TasksDrawer) -> String? {
        drawer.rows.first(where: \.isSelected)?.id
    }

    /// The empty state (docs/design/anatomy.md, "Empty state"): what happened, why, and the next steps, on the rows' leading edge.
    @ViewBuilder private func emptyBody(_ empty: Wire.EmptyList) -> some View {
        // One leading edge: the title and why line start where the action keys do, and the selection spans the list.
        EmptyListHeader(empty: empty, textColor: theme.editorFg, mutedColor: theme.chromeSecondaryFg)
            .padding(.leading, EmptyStateMetrics.inset)
            .padding(.top, EmptyStateMetrics.inset)
            .padding(.bottom, EmptyStateMetrics.whyToActions)
        EmptyListActions(
            empty: empty, textColor: theme.editorFg, accentColor: theme.accent,
            selectionColor: theme.treeSelectionBg
        ) { action in
            sendAction?(.runCommand(name: action.id))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// One request's diff or one task's output, from the BEAM's scroll offset; a diff's lines in their colours.
    @ViewBuilder private func viewBody(_ drawer: Wire.TasksDrawer) -> some View {
        Text(drawer.viewTitle)
            .font(Typography.font(.body, weight: .semibold))
            .foregroundStyle(theme.editorFg)
            .padding(.bottom, Spacing.xs)
        ForEach(Array(drawer.viewLines.dropFirst(drawer.viewOffset).enumerated()), id: \.offset) { _, line in
            Text(line.isEmpty ? " " : line)
                .font(Typography.font(.small, design: .monospaced))
                .foregroundStyle(lineColor(line, diff: drawer.view == .diff))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lineColor(_ line: String, diff: Bool) -> Color {
        guard diff else { return theme.editorFg }
        if line.hasPrefix("+") { return theme.gitAddedFg }
        if line.hasPrefix("-") { return theme.gitDeletedFg }
        if line.hasPrefix("@@") { return theme.chromeMutedFg }
        return theme.editorFg
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.treeSeparatorFg)
            .frame(height: Spacing.pixel)
            .overlay(
                Color.clear
                    .frame(height: TasksDrawerMetrics.dividerHitHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .onTapGesture(count: 2) { share = TasksDrawerMetrics.defaultShare }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStartShare ?? share
                                dragStartShare = start
                                guard availableHeight > 0 else { return }
                                let next = start - value.translation.height / availableHeight
                                share = min(max(next, TasksDrawerMetrics.minimumShare), TasksDrawerMetrics.maximumShare)
                            }
                            .onEnded { _ in dragStartShare = nil }
                    )
            )
            .anatomyPart("drawer.divider")
    }

    private func header(_ drawer: Wire.TasksDrawer) -> some View {
        HStack(spacing: Spacing.md) {
            Text(drawer.title)
                .font(Typography.font(.emphasis, weight: .semibold))
                .foregroundStyle(theme.editorFg)
                .anatomyPart("drawer.title", text: drawer.title, font: .emphasis)
            if !drawer.note.isEmpty {
                Text(drawer.note)
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.chromeSecondaryFg)
            }
            // Count groups sit `xl` apart, the same gap as the terminal's two columns (anatomy: Drawer, counts).
            HStack(spacing: Spacing.xl) {
                ForEach(Array(drawer.counts.enumerated()), id: \.offset) { _, count in
                    HStack(spacing: Spacing.xs) {
                        StateMark(state: count.state)
                            .frame(width: TasksDrawerMetrics.countMarkSize, height: TasksDrawerMetrics.countMarkSize)
                        Text("\(count.count)")
                            .font(Typography.font(.small))
                            .foregroundStyle(theme.chromeSecondaryFg)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(count.count) \(count.state.word)")
                    .anatomyPart("drawer.count", text: "\(count.count)", font: .small)
                }
            }
            Spacer(minLength: Spacing.xl)
            if drawer.focused {
                ForEach(Array(drawer.hints.enumerated()), id: \.offset) { _, hint in
                    hintView(hint)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: TasksDrawerMetrics.headerHeight)
        .anatomyPart("drawer.header")
    }

    @ViewBuilder private func hintView(_ hint: Wire.TasksDrawer.Hint) -> some View {
        let label = HStack(spacing: Spacing.xs) {
            Text(hint.key)
                .font(Typography.font(.small, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accent)
            Text(hint.label)
                .font(Typography.font(.small))
                .foregroundStyle(theme.chromeSecondaryFg)
        }
        .anatomyPart("drawer.hint", text: "\(hint.key) \(hint.label)", font: .small)
        if hint.key == "q" {
            Button { sendAction?(.rowAction(rowID: "", action: "q")) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the tasks drawer")
        } else {
            label
        }
    }
}

/// One task or subagent row, with the needs-you row's request and answers beneath it while it is selected.
struct TasksDrawerRowView: View {
    let row: Wire.TasksDrawer.Row
    let focused: Bool
    let sendAction: ViewActionHandler<TasksDrawerView.Action>?

    @Environment(\.themeColors) private var theme

    private var stateColor: Color {
        row.state.map { theme.stateColor($0) } ?? theme.chromeMutedFg
    }

    private var expanded: Bool { row.isSelected && !row.detail.isEmpty }

    /// The selected row is a list selection, like the file tree's: its text takes the selection's own foreground so it
    /// reads on the selection in every theme. The state mark keeps the state's colour.
    private var barred: Bool { row.isSelected && focused }
    private var textColor: Color { barred ? theme.treeSelectionFg : theme.editorFg }
    private var mutedColor: Color { barred ? theme.treeSelectionFg : theme.chromeMutedFg }
    private var wordsColor: Color { barred ? theme.treeSelectionFg : stateColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.sm) {
                if row.depth > 0 {
                    Text(row.isLastChild ? "└─" : "├─")
                        .font(Typography.font(.small, design: .monospaced))
                        .foregroundStyle(theme.chromeMutedFg)
                }
                mark
                Text(row.title)
                    .font(Typography.font(.body))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .anatomyPart("listRow.title", text: row.title, font: .body)
                Spacer(minLength: Spacing.xl)
                // State words, the row's one action and its age are separate parts, an xl gap apart.
                HStack(spacing: Spacing.xl) {
                    Text(row.words)
                        .font(Typography.font(.small))
                        .foregroundStyle(wordsColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .anatomyPart("listRow.meta", text: row.words, font: .small)
                    if !expanded, let action = row.actions.first {
                        actionButton(action)
                    }
                    Text(row.age)
                        .font(Typography.font(.caption))
                        .foregroundStyle(mutedColor)
                }
            }
            .frame(height: TasksDrawerMetrics.rowPitch)
            if expanded {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(row.detail, id: \.self) { line in
                        Text(line)
                            .font(Typography.font(.small, design: .monospaced))
                            .foregroundStyle(textColor)
                    }
                    HStack(spacing: Spacing.xl) {
                        ForEach(row.actions, id: \.key) { action in
                            actionButton(action)
                        }
                    }
                }
                .padding(.leading, TasksDrawerMetrics.markSize + Spacing.sm)
                .padding(.bottom, Spacing.sm)
            }
        }
        .padding(.leading, Spacing.lg)
        .padding(.trailing, Spacing.lg)
        .background(selectionBackground)
        .overlay(alignment: .leading) {
            // The selection edge is the row's state role, flush with the selection fill's leading edge.
            if row.isSelected {
                Rectangle().fill(stateColor).frame(width: TasksDrawerMetrics.selectionEdgeWidth)
                    .padding(.leading, Spacing.xs)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { sendAction?(.rowAction(rowID: row.id, action: "select")) }
        .anatomyPart("listRow")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.words), \(row.age)")
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    }

    @ViewBuilder private var mark: some View {
        if let state = row.state {
            StateMark(state: state)
                .frame(width: TasksDrawerMetrics.markSize, height: TasksDrawerMetrics.markSize)
        } else {
            Color.clear.frame(width: TasksDrawerMetrics.markSize, height: TasksDrawerMetrics.markSize)
        }
    }

    private func actionButton(_ action: Wire.TasksDrawer.Hint) -> some View {
        Button {
            sendAction?(.rowAction(rowID: row.id, action: action.key))
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(action.key)
                    .font(Typography.font(.small, weight: .semibold, design: .monospaced))
                    .foregroundStyle(barred ? theme.treeSelectionFg : theme.accent)
                Text(action.label)
                    .font(Typography.font(.small))
                    .foregroundStyle(textColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
    }

    @ViewBuilder private var selectionBackground: some View {
        if row.isSelected {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(focused ? theme.treeSelectionBg : theme.treeSelectionBg.opacity(0.5))
                .padding(.horizontal, Spacing.xs)
        }
    }
}

/// The drawer's measures that are not spacing steps: heights, mark sizes and its share of the window.
enum TasksDrawerMetrics {
    static let headerHeight: CGFloat = 24
    static let rowPitch: CGFloat = 24
    static let markSize: CGFloat = 10
    static let countMarkSize: CGFloat = 8
    static let selectionEdgeWidth: CGFloat = 3
    static let dividerHitHeight: CGFloat = 5
    static let minimumHeight: CGFloat = 96
    static let defaultShare: CGFloat = 0.4
    static let minimumShare: CGFloat = 0.15
    static let maximumShare: CGFloat = 0.7
}
