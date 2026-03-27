/// Native SwiftUI hover popup overlay for LSP hover tooltips.
///
/// Positioned above the anchor token by default, flipping below when
/// near the top of the viewport. Renders markdown-styled content with
/// code blocks, headers, bold/italic text, and blockquotes.
/// Non-interactive by default; interactive when focused for scrolling.

import SwiftUI

/// PreferenceKey to measure the popup's rendered height.
/// Single reporter: only one GeometryReader writes to this key.
private struct HoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey to measure the popup's rendered width.
/// Single reporter: only one GeometryReader writes to this key.
private struct HoverWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct HoverPopupOverlay: View {
    let state: HoverPopupState
    let theme: ThemeColors
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let viewportHeight: CGFloat
    let viewportWidth: CGFloat

    @State private var popupHeight: CGFloat = 0
    @State private var popupWidth: CGFloat = 0

    private let maxWidth: CGFloat = 500
    private let maxHeight: CGFloat = 300
    private let gap: CGFloat = 4

    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    /// Whether to show the popup above the anchor (preferred) or below.
    private var showAbove: Bool {
        let anchorY = CGFloat(state.anchorRow) * cellHeight
        return anchorY > popupHeight + gap + cellHeight
    }

    /// Vertical offset: bottom of popup above anchor row, or top of popup below anchor row.
    /// Clamped to stay within the viewport height.
    private var offsetY: CGFloat {
        let anchorY = CGFloat(state.anchorRow) * cellHeight
        if showAbove {
            return max(anchorY - popupHeight - gap, 0)
        } else {
            let y = anchorY + cellHeight + gap
            let maxY = max(viewportHeight - popupHeight - 8, 0)
            return min(y, maxY)
        }
    }

    /// Horizontal offset clamped so the popup doesn't extend past the right edge.
    private var offsetX: CGFloat {
        let rawX = CGFloat(state.anchorCol) * cellWidth
        let maxX = max(viewportWidth - popupWidth - 8, 0)
        return min(rawX, maxX)
    }

    var body: some View {
        if state.visible && !state.lines.isEmpty {
            popupContent
                .frame(maxWidth: maxWidth)
                .frame(maxHeight: maxHeight)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: HoverHeightKey.self, value: geo.size.height)
                            .preference(key: HoverWidthKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(HoverHeightKey.self) { popupHeight = $0 }
                .onPreferenceChange(HoverWidthKey.self) { popupWidth = $0 }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.popupBg)
                        .shadow(color: .black.opacity(0.4), radius: 12,
                                y: showAbove ? -4 : 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            state.focused
                                ? theme.accent.opacity(0.8)
                                : theme.popupBorder.opacity(0.5),
                            lineWidth: state.focused ? 2 : 1
                        )
                )
                .offset(x: offsetX, y: offsetY)
                .allowsHitTesting(state.focused)
                .transition(.opacity.animation(.easeIn(duration: animDuration)))
        }
    }

    @ViewBuilder
    private var popupContent: some View {
        ScrollView(.vertical, showsIndicators: state.focused) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.lines) { line in
                    lineView(line)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func lineView(_ line: HoverLine) -> some View {
        switch line.lineType {
        case .empty:
            Spacer().frame(height: 6)

        case .rule:
            Divider()
                .background(theme.popupBorder.opacity(0.3))
                .padding(.vertical, 4)

        case .code, .codeHeader:
            HStack(spacing: 0) {
                ForEach(line.segments) { seg in
                    segmentText(seg)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.popupBg.opacity(0.6))
            )
            .font(.system(size: 12, design: .monospaced))

        case .blockquote:
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.popupBorder.opacity(0.5))
                    .frame(width: 3)

                HStack(spacing: 0) {
                    ForEach(line.segments) { seg in
                        segmentText(seg)
                    }
                }
            }
            .padding(.vertical, 1)

        case .header:
            HStack(spacing: 0) {
                ForEach(line.segments) { seg in
                    segmentText(seg)
                }
            }
            .padding(.bottom, 2)

        default:
            HStack(spacing: 0) {
                ForEach(line.segments) { seg in
                    segmentText(seg)
                }
            }
        }
    }

    @ViewBuilder
    private func segmentText(_ seg: HoverSegment) -> some View {
        Text(seg.text)
            .font(segmentFont(seg.style))
            .foregroundStyle(segmentColor(seg.style))
    }

    private func segmentFont(_ style: Wire.HoverStyle) -> Font {
        switch style {
        case .bold:
            return .system(size: 13, weight: .semibold)
        case .italic:
            return .system(size: 13).italic()
        case .boldItalic:
            return .system(size: 13, weight: .semibold).italic()
        case .code, .codeBlock, .codeContent:
            return .system(size: 12, design: .monospaced)
        case .header1:
            return .system(size: 16, weight: .bold)
        case .header2:
            return .system(size: 14, weight: .bold)
        case .header3:
            return .system(size: 13, weight: .semibold)
        default:
            return .system(size: 13)
        }
    }

    private func segmentColor(_ style: Wire.HoverStyle) -> Color {
        switch style {
        case .code, .codeBlock, .codeContent:
            return theme.popupFg.opacity(0.85)
        case .header1, .header2, .header3:
            return theme.popupFg
        case .blockquote:
            return theme.popupFg.opacity(0.7)
        case .listBullet:
            return theme.popupFg.opacity(0.6)
        case .rule:
            return theme.popupBorder
        default:
            return theme.popupFg.opacity(0.9)
        }
    }
}
