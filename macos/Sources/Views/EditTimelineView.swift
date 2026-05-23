import SwiftUI

struct EditTimelineView: View {
    let state: EditTimelineState
    let themeColors: ThemeColors
    let encoder: InputEncoder?

    var body: some View {
        if state.visible && !state.entries.isEmpty {
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
