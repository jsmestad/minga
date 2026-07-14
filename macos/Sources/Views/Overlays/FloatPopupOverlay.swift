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

    /// Preferred maximum panel width in points, derived from cell dimensions.
    private var panelMaxWidth: CGFloat {
        CGFloat(state.width) * cellWidth
    }

    /// Preferred maximum panel height in points, derived from cell dimensions.
    private var panelMaxHeight: CGFloat {
        CGFloat(state.height) * cellHeight
    }

    public var body: some View {
        if state.visible && !state.lines.isEmpty {
            VStack(spacing: 0) {
                // Title bar
                if !state.title.isEmpty {
                    HStack {
                        Text(state.title)
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
                        ForEach(Array(state.lines.enumerated()), id: \.offset) { _, line in
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
            .frame(maxWidth: panelMaxWidth, maxHeight: panelMaxHeight)
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
