/// Floating which-key popup matching Zed's overlay aesthetic.
///
/// Shows available key continuations after a leader key press (SPC).
/// Rounded corners, dark background, column grid layout.
/// Anchored to the bottom of the editor view.

import SwiftUI
import MingaProtocol

public struct WhichKeyOverlay: View {
    public init(state: WhichKeyState) {
        self.state = state
    }
    public let state: WhichKeyState
    @Environment(\.themeColors) private var theme


    private let columnWidth: CGFloat = 220
    private let rowHeight: CGFloat = 22
    private let maxColumns = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animDuration: Double {
        reduceMotion ? 0 : 0.15
    }

    public var body: some View {
        if state.visible && !state.bindings.isEmpty {
            VStack(spacing: 0) {
                // Prefix header
                if !state.prefix.isEmpty {
                    HStack {
                        Text(state.prefix)
                            .font(Typography.font(.small, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.popupKeyFg)
                        Spacer()
                        if state.pageCount > 1 {
                            Text("\(state.page + 1)/\(state.pageCount)")
                                .font(Typography.font(.caption))
                                .foregroundStyle(theme.popupFg.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)

                    Rectangle()
                        .fill(theme.popupBorder.opacity(0.3))
                        .frame(height: 1)
                }

                // Binding grid
                bindingGrid
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(theme.popupBg)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: -4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .frame(maxWidth: columnWidth * CGFloat(min(columnCount, maxColumns)) + 24)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.md)
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

        HStack(alignment: .top, spacing: Spacing.xs) {
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
        HStack(spacing: Spacing.sm) {
            // Key badge
            Text(binding.key)
                .font(Typography.monospacedSmall)
                .foregroundStyle(theme.popupKeyFg)
                .frame(minWidth: 24, alignment: .trailing)

            // Description
            Text(binding.description)
                .font(Typography.font(.small))
                .foregroundStyle(binding.isGroup ? theme.popupGroupFg : theme.popupFg.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(height: rowHeight)
    }
}

#Preview("Which Key") {
    let theme = PreviewFixtures.theme()
    let state = WhichKeyState()
    state.update(
        visible: true,
        prefix: "SPC",
        page: 0,
        pageCount: 1,
        rawBindings: [
            Wire.WhichKeyBinding(kind: 1, key: "f", description: "+file", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "b", description: "+buffer", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "w", description: "+window", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "g", description: "+git", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "s", description: "+search", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: ":", description: "M-x command", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: ".", description: "repeat", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "/", description: "search project", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "p", description: "+project", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "t", description: "+toggle", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "c", description: "+code", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "e", description: "file tree", icon: ""),
        ]
    )
    return WhichKeyOverlay(state: state)
        .frame(width: 520, height: 300)
        .background(theme.editorBg)
        .environment(theme)
}

#Preview("Which Key Paged") {
    let theme = PreviewFixtures.theme()
    let state = WhichKeyState()
    state.update(
        visible: true,
        prefix: "SPC g",
        page: 1,
        pageCount: 3,
        rawBindings: [
            Wire.WhichKeyBinding(kind: 0, key: "s", description: "stage file", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "u", description: "unstage file", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "c", description: "commit", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "p", description: "push", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "f", description: "fetch", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "d", description: "diff", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "b", description: "+branch", icon: ""),
            Wire.WhichKeyBinding(kind: 1, key: "r", description: "+rebase", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "l", description: "log", icon: ""),
            Wire.WhichKeyBinding(kind: 0, key: "z", description: "stash", icon: ""),
        ]
    )
    return WhichKeyOverlay(state: state)
        .frame(width: 520, height: 300)
        .background(theme.editorBg)
        .environment(theme)
}
