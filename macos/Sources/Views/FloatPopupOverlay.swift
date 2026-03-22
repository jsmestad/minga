/// Native SwiftUI float popup overlay for buffer content popups.
///
/// Renders as a centered, bordered panel with a title bar and
/// scrollable monospace content. Used for the *Help* buffer and
/// similar float-display popups.

import SwiftUI

struct FloatPopupOverlay: View {
    let state: FloatPopupState
    let theme: ThemeColors
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    /// Panel width in points, derived from cell dimensions.
    private var panelWidth: CGFloat {
        CGFloat(state.width) * cellWidth
    }

    /// Panel height in points, derived from cell dimensions.
    private var panelHeight: CGFloat {
        CGFloat(state.height) * cellHeight
    }

    var body: some View {
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
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .frame(width: panelWidth, height: panelHeight)
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
