import SwiftUI

public struct EditTimelineView: View {
    public enum Action: Equatable, Sendable {
        case navigate(generation: UInt32, entryID: String)
    }

    public init(state: EditTimelineState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }
    public let state: EditTimelineState
    @Environment(\.themeColors) private var themeColors

    public let sendAction: ViewActionHandler<Action>?

    public var body: some View {
        if state.visible && !state.files.isEmpty {
            HStack(spacing: Spacing.md) {
                ForEach(state.files) { file in
                    HStack(spacing: Spacing.sm) {
                        Circle()
                            .fill(file.reviewStatus == 1 ? themeColors.accent : themeColors.editorFg.opacity(0.35))
                            .frame(width: 6, height: 6)

                        Text(file.name)
                            .font(Typography.font(.small, weight: .medium))
                            .foregroundStyle(themeColors.editorFg)
                            .lineLimit(1)

                        Text("\(file.entryCount)")
                            .font(Typography.font(.caption, design: .monospaced))
                            .foregroundStyle(themeColors.editorFg.opacity(0.65))

                        Text("+\(file.linesAdded)/-\(file.linesRemoved)")
                            .font(Typography.font(.caption, design: .monospaced))
                            .foregroundStyle(themeColors.editorFg.opacity(0.65))
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .background(themeColors.editorFg.opacity(0.08))
                    .clipShape(.rect(cornerRadius: Radius.sm))
                    .help(file.path)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: 24)
            .background(themeColors.editorBg.opacity(0.95))
        } else if state.visible && !state.entries.isEmpty {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let count = state.entries.count
                    let generation = state.generation
                    let width = geometry.size.width - Spacing.section
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

                            Circle()
                                .fill(isActive || isLast
                                    ? themeColors.accent
                                    : themeColors.editorFg.opacity(0.5))
                                .frame(width: isActive || isLast ? 10 : 7,
                                       height: isActive || isLast ? 10 : 7)
                                .position(x: x, y: geometry.size.height / 2)
                                .onTapGesture {
                                    sendAction?(.navigate(generation: generation, entryID: entry.entryID))
                                }
                                .help("\(entry.toolName) (edit \(entry.index + 1)/\(count))")
                        }
                    }
                }
            }
            .frame(height: 24)
            .background(themeColors.editorBg.opacity(0.95))
        }
    }
}
