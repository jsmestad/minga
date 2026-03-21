/// Native Messages tab content: structured log entries with level and subsystem badges.
///
/// Renders log entries as a scrollable list with color-coded level indicators,
/// subsystem badges, timestamps, and clickable file paths. Auto-scrolls to
/// the bottom when new entries arrive, with a "jump to latest" button when
/// the user scrolls up. A filter bar at the top provides level, subsystem,
/// and text search filtering.

import SwiftUI

struct MessagesContentView: View {
    @Bindable var state: MessagesContentState
    let theme: ThemeColors
    let encoder: InputEncoder?

    /// Tracks whether the bottom anchor is visible in the scroll viewport.
    @State private var bottomAnchorVisible: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            MessagesFilterBar(state: state, theme: theme)

            // Entry list
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.filteredEntries.count) { _, _ in
                        if state.isAutoScrolling, let last = state.filteredEntries.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: state.isAutoScrolling) { _, scrolling in
                        if scrolling, let last = state.filteredEntries.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .defaultScrollAnchor(.bottom)
                }

                // "Jump to latest" button
                if state.hasNewEntries && !state.isAutoScrolling {
                    Button(action: {
                        state.jumpToLatest()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text("New messages")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.accent.opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
        }
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
        HStack(spacing: 6) {
            // Level toggles
            levelToggles

            // Separator
            Rectangle()
                .fill(theme.treeSeparatorFg.opacity(0.3))
                .frame(width: 1, height: 16)

            // Subsystem toggles (only show subsystems that have entries)
            subsystemToggles

            // Separator
            Rectangle()
                .fill(theme.treeSeparatorFg.opacity(0.3))
                .frame(width: 1, height: 16)

            // "Warnings" preset button
            warningsPreset

            Spacer()

            // Search field
            searchField

            // Entry count
            entryCount

            // Reset button
            if state.isFiltering {
                Button(action: { state.resetFilters() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.modelineBarFg.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Reset all filters")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.tabBg.opacity(0.5))
    }

    // MARK: - Level toggles

    private var levelToggles: some View {
        HStack(spacing: 2) {
            levelButton(level: 0, label: "D", color: .gray)
            levelButton(level: 1, label: "I", color: .green)
            levelButton(level: 2, label: "W", color: .yellow)
            levelButton(level: 3, label: "E", color: .red)
        }
    }

    private func levelButton(level: UInt8, label: String, color: Color) -> some View {
        let isActive = state.activeLevels.contains(level)
        return Button(action: { state.toggleLevel(level) }) {
            HStack(spacing: 3) {
                Circle()
                    .fill(isActive ? color : color.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? theme.editorFg : theme.modelineBarFg.opacity(0.4))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isActive ? color.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subsystem toggles

    private var subsystemToggles: some View {
        HStack(spacing: 2) {
            ForEach(Array(state.presentSubsystems).sorted(), id: \.self) { sub in
                subsystemPill(sub: sub)
            }
        }
    }

    private func subsystemPill(sub: UInt8) -> some View {
        let isActive = state.activeSubsystems.contains(sub)
        let name = MessageEntry.subsystemName(for: sub)
        let color = MessageEntry.subsystemColor(for: sub)

        return Button(action: { state.toggleSubsystem(sub) }) {
            Text(name)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(isActive ? .white : theme.modelineBarFg.opacity(0.4))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(isActive ? color.opacity(0.7) : color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Warnings preset

    private var warningsPreset: some View {
        let isActive = state.activeLevels == [2, 3]
            && state.activeSubsystems == MessagesContentState.allSubsystems
            && state.searchText.isEmpty

        return Button(action: {
            state.activeLevels = [2, 3]
            state.activeSubsystems = MessagesContentState.allSubsystems
            state.searchText = ""
        }) {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 8, weight: .bold))
                Text("Warnings")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(isActive ? .white : theme.modelineBarFg.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isActive ? Color.orange.opacity(0.7) : Color.orange.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help("Show only warnings and errors")
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(theme.modelineBarFg.opacity(0.4))
            TextField("Filter...", text: $state.searchText)
                .font(.system(size: 10))
                .textFieldStyle(.plain)
                .frame(width: 100)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.editorBg.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.treeSeparatorFg.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Count

    private var entryCount: some View {
        let filtered = state.filteredEntries.count
        let total = state.entries.count
        let text = state.isFiltering ? "\(filtered) of \(total)" : "\(total)"
        return Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(theme.modelineBarFg.opacity(0.5))
    }
}

// MARK: - Entry row

private struct MessageEntryRow: View {
    let entry: MessageEntry
    let theme: ThemeColors
    let encoder: InputEncoder?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Level dot
            Circle()
                .fill(entry.levelColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            // Timestamp
            Text(entry.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.modelineBarFg.opacity(0.5))

            // Subsystem badge
            Text(entry.subsystemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(entry.subsystemColor.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 3))

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
        .padding(.vertical, 2)
    }
}
