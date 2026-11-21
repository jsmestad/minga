import SwiftUI

/// Bounded, source-ordered review offers. Selection and focus remain BEAM-owned.
public struct EditTimelineView: View {
    public enum Action: Equatable, Sendable {
        case navigate(generation: UInt32, entryID: String)
        /// Requests the cumulative review for the exact path in this timeline offer.
        case reviewFile(generation: UInt32, path: String)
        case browseFiles
    }

    public init(state: EditTimelineState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }
    public let state: EditTimelineState
    @Environment(\.themeColors) private var themeColors

    public let sendAction: ViewActionHandler<Action>?

    private let timelineHeight: CGFloat = 24
    private let fileControlWidth: CGFloat = 320
    private let summaryWidth: CGFloat = 100

    public var body: some View {
        HStack(spacing: 0) {
            if state.visible {
                Button("All Changes") { sendAction?(.browseFiles) }
                    .buttonStyle(.plain)
                    .font(Typography.font(.small, weight: .semibold))
                    .foregroundStyle(themeColors.accent)
                    .accessibilityLabel("All Changes")
                    .padding(.horizontal, Spacing.md)
                    .disabled(sendAction == nil || state.generation == 0)
                    .help("Search all Agent changed files")
            }
            timelineBody
        }
    }

    @ViewBuilder private var timelineBody: some View {
        if state.visible && !state.files.isEmpty {
            let generation = state.generation
            // Stable widths keep count updates and appended files from moving controls. The scroll view retains the reader's position; new offers never scroll it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(state.files) { file in
                        Button {
                            sendAction?(.reviewFile(generation: generation, path: file.path))
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Circle()
                                    .fill(file.isReviewing ? themeColors.accent : themeColors.editorFg.opacity(0.35))
                                    .frame(width: 6, height: 6)

                                Text("Review")
                                    .font(Typography.font(.small, weight: .semibold))
                                    .foregroundStyle(themeColors.accent)
                                    .fixedSize()

                                Text(file.path)
                                    .font(Typography.font(.small, weight: .medium))
                                    .foregroundStyle(themeColors.editorFg)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(file.hasLineCounts
                                     ? "\(file.entryCount) +\(file.linesAdded)/-\(file.linesRemoved)"
                                     : "\(file.entryCount) edits")
                                    .font(Typography.font(.caption, design: .monospaced))
                                    .foregroundStyle(themeColors.editorFg.opacity(0.65))
                                    .lineLimit(1)
                                    .frame(width: summaryWidth, alignment: .trailing)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .frame(width: fileControlWidth, height: timelineHeight)
                            .background(themeColors.editorFg.opacity(0.08))
                            .clipShape(.rect(cornerRadius: Radius.sm))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(sendAction == nil || generation == 0)
                        .accessibilityLabel("Review \(file.path)")
                        .accessibilityValue(file.hasLineCounts
                                            ? "\(file.entryCount) edits, \(file.linesAdded) lines added, \(file.linesRemoved) lines removed"
                                            : "\(file.entryCount) edits, line counts unavailable")
                        .accessibilityHint("Opens cumulative changes for this file")
                        .help("Review cumulative changes in \(file.path)")
                    }
                }
                .padding(.horizontal, Spacing.md)
            }
            .frame(maxWidth: .infinity)
            .frame(height: timelineHeight)
            .background(themeColors.editorBg.opacity(0.95))
        } else if state.visible && !state.entries.isEmpty {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let count = state.entries.count
                    let generation = state.generation
                    let width = max(0, geometry.size.width - Spacing.section)
                    let spacing = count > 1 ? width / CGFloat(count - 1) : width / 2

                    ZStack(alignment: .leading) {
                        // Track line
                        Rectangle()
                            .fill(themeColors.editorFg.opacity(0.15))
                            .frame(height: 2)
                            .padding(.horizontal, Spacing.xl)

                        // Markers
                        ForEach(state.entries) { entry in
                            let x = count > 1
                                ? Spacing.xl + spacing * CGFloat(entry.index)
                                : Spacing.xl + width / 2

                            let isActive = entry.index == state.viewingIndex
                            let isLast = entry.index == count - 1 && state.viewingIndex == -1

                            Button {
                                sendAction?(.navigate(generation: generation, entryID: entry.entryID))
                            } label: {
                                Circle()
                                    .fill(isActive || isLast
                                        ? themeColors.accent
                                        : themeColors.editorFg.opacity(0.5))
                                    .frame(width: isActive || isLast ? 10 : 7,
                                           height: isActive || isLast ? 10 : 7)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(sendAction == nil || generation == 0)
                            .accessibilityLabel("View \(entry.toolName) edit \(entry.index + 1) of \(count)")
                            .help("\(entry.toolName) (edit \(entry.index + 1)/\(count))")
                            .position(x: x, y: geometry.size.height / 2)
                        }
                    }
                }
            }
            .frame(height: timelineHeight)
            .background(themeColors.editorBg.opacity(0.95))
        } else if state.visible {
            Text("No changed files")
                .font(Typography.font(.small))
                .foregroundStyle(themeColors.editorFg.opacity(0.65))
                .padding(.horizontal, Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: timelineHeight)
                .background(themeColors.editorBg.opacity(0.95))
        }
    }
}

// MARK: - Previews

#Preview("Single cumulative Review", traits: .mingaChrome) {
    EditTimelineView(
        state: EditTimelineState(
            visible: true,
            files: [.init(path: "Sources/Editor.swift", entryCount: 1, linesAdded: 12, linesRemoved: 3, reviewStatus: 0)],
            generation: 1
        ),
        sendAction: { _ in }
    )
    .frame(width: 900, height: 80, alignment: .top)
}

#Preview("Narrow Review burst", traits: .mingaChrome) {
    EditTimelineView(
        state: EditTimelineState(
            visible: true,
            files: (0..<100).map { (index: Int) -> EditTimelineState.TimelineFile in
                EditTimelineState.TimelineFile(
                    path: "Sources/LongDirectoryName/Feature\(index)/Editor.swift",
                    entryCount: index + 1,
                    linesAdded: UInt32(index * 10),
                    linesRemoved: UInt32(index),
                    reviewStatus: 0
                )
            },
            generation: 1
        ),
        sendAction: { _ in }
    )
    .frame(width: 280, height: 80, alignment: .top)
}

#Preview("Review without connection", traits: .mingaChrome) {
    EditTimelineView(
        state: EditTimelineState(
            visible: true,
            files: [.init(path: "Tests/Editor.swift", entryCount: 1, linesAdded: 12, linesRemoved: 3, reviewStatus: 0)],
            generation: 1
        ),
        sendAction: nil
    )
    .frame(width: 400, height: 80, alignment: .top)
}
