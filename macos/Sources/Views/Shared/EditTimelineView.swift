import SwiftUI

public struct EditTimelineView: View {
    public init(state: EditTimelineState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    public let state: EditTimelineState
    @Environment(\.themeColors) private var themeColors
    @Environment(\.guiFrameVersion) private var frameVersion
    public let encoder: InputEncoder?

    public var body: some View {
        let _ = frameVersion
        if state.visible && !state.files.isEmpty {
            HStack(spacing: 8) {
                ForEach(state.files) { file in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(file.reviewStatus == 1 ? themeColors.accent : themeColors.editorFg.opacity(0.35))
                            .frame(width: 6, height: 6)

                        Text(file.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(themeColors.editorFg)
                            .lineLimit(1)

                        Text("\(file.entryCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeColors.editorFg.opacity(0.65))

                        Text("+\(file.linesAdded)/-\(file.linesRemoved)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(themeColors.editorFg.opacity(0.65))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeColors.editorFg.opacity(0.08))
                    .clipShape(.rect(cornerRadius: 4))
                    .help(file.path)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(themeColors.editorBg.opacity(0.95))
        } else if state.visible && !state.entries.isEmpty {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let count = state.entries.count
                    let width = geometry.size.width - 32
                    let spacing = count > 1 ? width / CGFloat(count - 1) : width / 2

                    ZStack(alignment: .leading) {
                        // Track line
                        Rectangle()
                            .fill(themeColors.editorFg.opacity(0.15))
                            .frame(height: 2)
                            .padding(.horizontal, 16)

                        // Markers
                        ForEach(state.entries) { entry in
                            let x = count > 1
                                ? 16 + spacing * CGFloat(entry.index)
                                : 16 + width / 2

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
                                    encoder?.sendTimelineNavigate(index: UInt16(entry.index))
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
