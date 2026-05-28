/// Native Messages tab content: structured log entries with a low-noise filter bar.
///
/// Renders log entries as a scrollable list with a level dot, timestamp, a muted
/// subsystem label, the message, and an optional clickable file path. The filter
/// bar keeps a small set of always-visible controls (level dots, a subsystems
/// menu, search) and surfaces a live severity summary on the trailing side.
///
/// Auto-scroll follows the tail only while the user is at the bottom. Scrolling
/// up pins the view in place; new entries surface a "jump to latest" affordance
/// instead of yanking the viewport down.

import SwiftUI

struct MessagesContentView: View {
    @Bindable var state: MessagesContentState
    let theme: ThemeColors
    let encoder: InputEncoder?
    /// Snapshot-only: render the list as a plain, non-lazy stack so every row
    /// lays out for capture. The live lazy ScrollView path renders blank in the
    /// preview harness (same pattern as FileTreeView / GitStatusView).
    var usesPreviewEagerLayout: Bool = false

    /// Tracks whether the bottom anchor is visible in the scroll viewport.
    @State private var bottomAnchorVisible: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            MessagesFilterBar(state: state, theme: theme)
            entryList
        }
    }

    @ViewBuilder
    private var entryList: some View {
        if usesPreviewEagerLayout {
            VStack(spacing: 0) {
                ForEach(state.filteredEntries) { entry in
                    MessageEntryRow(entry: entry, theme: theme, encoder: encoder)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            liveEntryList
        }
    }

    private var liveEntryList: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.filteredEntries) { entry in
                            MessageEntryRow(entry: entry, theme: theme, encoder: encoder)
                                .id(entry.id)
                        }

                        // Invisible anchor at the bottom to detect scroll position.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                            .onAppear { handleScrollToBottom() }
                            .onDisappear { handleScrollUp() }
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                }
                // Start pinned to the newest entry. We intentionally do NOT use
                // .defaultScrollAnchor(.bottom): that keeps the view pinned to the
                // bottom on every content change, which yanks the user down while
                // they read history. Tailing is handled explicitly below, gated on
                // isAutoScrolling, so scrolling up stays put.
                .onAppear {
                    if state.isAutoScrolling, let last = state.filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: state.filteredEntries.count) { _, _ in
                    guard state.isAutoScrolling, let last = state.filteredEntries.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: state.isAutoScrolling) { _, scrolling in
                    guard scrolling, let last = state.filteredEntries.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if state.hasNewEntries && !state.isAutoScrolling {
                jumpToLatestButton
            }
        }
    }

    private var jumpToLatestButton: some View {
        Button(action: { state.jumpToLatest() }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text("New messages")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 5)
            .background(theme.accent.opacity(0.9))
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(Spacing.md)
    }

    private func handleScrollToBottom() {
        bottomAnchorVisible = true
        state.scrolledToBottom()
    }

    private func handleScrollUp() {
        bottomAnchorVisible = false
        state.scrolledUp()
    }
}

// MARK: - Filter bar

private struct MessagesFilterBar: View {
    @Bindable var state: MessagesContentState
    let theme: ThemeColors

    var body: some View {
        HStack(spacing: Spacing.sm) {
            levelDots
            subsystemMenu
            searchField
                .layoutPriority(1)

            Spacer(minLength: Spacing.sm)

            severitySummary
            if state.isFiltering {
                resetButton
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(theme.tabBg.opacity(0.5))
    }

    // MARK: Level dots

    /// Severity is a small set, so dots-only (no D/I/W/E letters) keeps the bar
    /// quiet. Inactive levels fade hard so "Debug is off" reads at a glance.
    private var levelDots: some View {
        HStack(spacing: Spacing.xs) {
            ForEach([UInt8(0), 1, 2, 3], id: \.self) { level in
                levelDot(level)
            }
        }
    }

    private func levelDot(_ level: UInt8) -> some View {
        let isActive = state.activeLevels.contains(level)
        let color = MessageEntry.levelColor(for: level)
        return Button(action: { state.toggleLevel(level) }) {
            Circle()
                .fill(isActive ? color : color.opacity(0.2))
                .frame(width: 8, height: 8)
                .padding(Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(MessageEntry.levelName(for: level))
    }

    // MARK: Subsystems menu

    /// Eight subsystems collapse into one menu so the bar isn't a wall of colored
    /// pills. The label reflects state: all-on reads muted, a single selection
    /// shows that subsystem in its color, otherwise a count.
    private var subsystemMenu: some View {
        Menu {
            Button("All Subsystems") {
                state.activeSubsystems = MessagesContentState.allSubsystems
            }
            Button("Warnings & Errors Only") {
                state.activeLevels = [2, 3]
                state.activeSubsystems = MessagesContentState.allSubsystems
                state.searchText = ""
            }
            Divider()
            ForEach(Array(state.presentSubsystems).sorted(), id: \.self) { sub in
                Button {
                    state.toggleSubsystem(sub)
                } label: {
                    if state.activeSubsystems.contains(sub) {
                        Label(MessageEntry.subsystemName(for: sub), systemImage: "checkmark")
                    } else {
                        Text(MessageEntry.subsystemName(for: sub))
                    }
                }
            }
        } label: {
            subsystemMenuLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var subsystemMenuLabel: some View {
        let active = state.activeSubsystems
        HStack(spacing: Spacing.xs) {
            if active == MessagesContentState.allSubsystems {
                Text("Subsystems")
                    .foregroundStyle(theme.modelineBarFg.opacity(0.6))
            } else if active.count == 1, let only = active.first {
                Text(MessageEntry.subsystemName(for: only))
                    .foregroundStyle(MessageEntry.subsystemColor(for: only))
            } else {
                Text("Subsystems (\(active.count))")
                    .foregroundStyle(theme.accent)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.modelineBarFg.opacity(0.4))
        }
        .font(.system(size: 10, weight: .medium))
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(theme.modelineBarFg.opacity(0.4))
            TextField("Filter messages…", text: $state.searchText)
                .font(.system(size: 10))
                .textFieldStyle(.plain)
                .frame(minWidth: 120, maxWidth: 220)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 3)
        .background(theme.editorBg.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.treeSeparatorFg.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: Severity summary

    /// A live count per severity (errors first) replaces the dead total. Color
    /// carries meaning here, so a non-zero error count is visible at a glance.
    private var severitySummary: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(levelCounts(), id: \.level) { item in
                HStack(spacing: 3) {
                    Circle()
                        .fill(MessageEntry.levelColor(for: item.level))
                        .frame(width: 6, height: 6)
                    Text("\(item.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MessageEntry.levelColor(for: item.level).opacity(0.85))
                }
            }
            if state.isFiltering {
                Text("filtered")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.4))
            }
        }
    }

    /// Counts of the currently shown entries by severity, errors first. Levels
    /// with no visible entries are omitted to avoid a row of zeros.
    private func levelCounts() -> [(level: UInt8, count: Int)] {
        var counts: [UInt8: Int] = [:]
        for entry in state.filteredEntries {
            counts[entry.level, default: 0] += 1
        }
        return [3, 2, 1, 0].compactMap { level in
            counts[level].map { (level, $0) }
        }
    }

    private var resetButton: some View {
        Button(action: { state.resetFilters() }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.modelineBarFg.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help("Reset all filters")
    }
}

// MARK: - Entry row

private struct MessageEntryRow: View {
    let entry: MessageEntry
    let theme: ThemeColors
    let encoder: InputEncoder?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            // Level dot
            Circle()
                .fill(entry.levelColor)
                .frame(width: 6, height: 6)
                .padding(.top, Spacing.xs)

            // Timestamp
            Text(entry.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.modelineBarFg.opacity(0.5))

            // Subsystem: muted colored text in a fixed column (not a filled badge)
            // so it stays scannable without interrupting the message reading path.
            Text(entry.subsystemName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(entry.subsystemColor.opacity(0.7))
                .frame(width: 52, alignment: .leading)

            // Message text
            Text(entry.text)
                .font(.system(size: 11))
                .foregroundStyle(theme.editorFg)
                .textSelection(.enabled)
                .lineLimit(nil)

            Spacer(minLength: 0)

            // Clickable file path
            if !entry.filePath.isEmpty {
                Button(action: {
                    encoder?.sendOpenFile(path: entry.filePath)
                }) {
                    Text(entry.filePath)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.hairline)
        // Subtle full-row tint so warnings/errors are scannable in peripheral
        // vision during a fast scroll. Info/debug stay untinted.
        .background(rowTint)
    }

    @ViewBuilder
    private var rowTint: some View {
        if entry.level >= 3 {
            Color.red.opacity(0.06)
        } else if entry.level == 2 {
            Color.yellow.opacity(0.045)
        } else {
            Color.clear
        }
    }
}
