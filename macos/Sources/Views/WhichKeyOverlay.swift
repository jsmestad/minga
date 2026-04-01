/// Floating which-key popup matching Zed's overlay aesthetic.
///
/// Shows available key continuations after a leader key press (SPC).
/// Rounded corners, dark background, column grid layout.
/// Anchored to the bottom of the editor view.

import SwiftUI

struct WhichKeyOverlay: View {
    let state: WhichKeyState
    let theme: ThemeColors

    private let columnWidth: CGFloat = 220
    private let rowHeight: CGFloat = 22
    private let maxColumns = 4

    /// Transition animation duration. Respects reduced motion.
    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    var body: some View {
        if state.visible && !state.bindings.isEmpty {
            VStack(spacing: 0) {
                // Prefix header
                if !state.prefix.isEmpty {
                    HStack {
                        Text(state.prefix)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.popupKeyFg)
                        Spacer()
                        if state.pageCount > 1 {
                            Text("\(state.page + 1)/\(state.pageCount)")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.popupFg.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    Rectangle()
                        .fill(theme.popupBorder.opacity(0.3))
                        .frame(height: 1)
                }

                // Binding grid
                bindingGrid
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.popupBg)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: -4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .frame(maxWidth: columnWidth * CGFloat(min(columnCount, maxColumns)) + 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeInOut(duration: animDuration)))
        }
    }

    private var columnCount: Int {
        let rows = 10
        return max(1, (state.bindings.count + rows - 1) / rows)
    }

    @ViewBuilder
    private var bindingGrid: some View {
        let cols = columnCount
        let rows = max(1, (state.bindings.count + cols - 1) / cols)

        HStack(alignment: .top, spacing: 4) {
            ForEach(0..<cols, id: \.self) { col in
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        let index = col * rows + row
                        if index < state.bindings.count {
                            bindingRow(state.bindings[index])
                        }
                    }
                }
                .frame(width: columnWidth)
            }
        }
    }

    @ViewBuilder
    private func bindingRow(_ binding: WhichKeyBinding) -> some View {
        HStack(spacing: 6) {
            // Key badge
            Text(binding.key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.popupKeyFg)
                .frame(minWidth: 24, alignment: .trailing)

            // Description
            Text(binding.description)
                .font(.system(size: 11))
                .foregroundStyle(binding.isGroup ? theme.popupGroupFg : theme.popupFg.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(height: rowHeight)
    }
}
