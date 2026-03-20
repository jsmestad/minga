/// Native Messages tab content: structured log entries with level and subsystem badges.
///
/// Renders log entries as a scrollable list with color-coded level indicators,
/// subsystem badges, timestamps, and clickable file paths. Auto-scrolls to
/// the bottom when new entries arrive, with a "jump to latest" button when
/// the user scrolls up.

import SwiftUI

struct MessagesContentView: View {
    @Bindable var state: MessagesContentState
    let theme: ThemeColors
    let encoder: InputEncoder?

    /// Tracks whether the bottom anchor is visible in the scroll viewport.
    @State private var bottomAnchorVisible: Bool = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.entries) { entry in
                            MessageEntryRow(entry: entry, theme: theme, encoder: encoder)
                                .id(entry.id)
                        }

                        // Invisible anchor at the bottom to detect scroll position.
                        // When this is visible, the user is at the bottom of the list.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                            .onAppear { handleScrollToBottom() }
                            .onDisappear { handleScrollUp() }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: state.entries.count) { _, _ in
                    if state.isAutoScrolling, let last = state.entries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: state.isAutoScrolling) { _, scrolling in
                    if scrolling, let last = state.entries.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
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

    private func handleScrollToBottom() {
        bottomAnchorVisible = true
        state.scrolledToBottom()
    }

    private func handleScrollUp() {
        bottomAnchorVisible = false
        state.scrolledUp()
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
