/// Native SwiftUI float popup overlay for semantic popup content.
///
/// Renders as a centered, bordered panel with a title bar and
/// scrollable content. The BEAM provides preferred size hints, while this view
/// owns native text wrapping, measurement, and final size.

import SwiftUI

public struct FloatPopupOverlay: View {
    public init(state: FloatPopupState, cellWidth: CGFloat, cellHeight: CGFloat) {
        self.state = state
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }
    public let state: FloatPopupState
    @Environment(\.themeColors) private var theme

    public let cellWidth: CGFloat
    public let cellHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animDuration: Double {
        reduceMotion ? 0 : 0.15
    }

    public var body: some View {
        if let content = state.content, !content.lines.isEmpty {
            VStack(spacing: 0) {
                // Title bar
                if !content.title.isEmpty {
                    HStack {
                        Text(content.title)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.popupFg)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.popupBg.opacity(0.8))

                    Divider()
                        .background(theme.popupBorder.opacity(0.3))
                }

                // Content area
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.popupFg.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: CGFloat(content.width) * cellWidth, maxHeight: CGFloat(content.height) * cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.popupBg)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .transition(.opacity.animation(.easeIn(duration: animDuration)))
        }
    }
}
