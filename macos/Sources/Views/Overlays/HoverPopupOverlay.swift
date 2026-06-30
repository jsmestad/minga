/// Native SwiftUI hover popup overlay for LSP hover tooltips.
///
/// Positioned above the anchor token by default, flipping below when
/// near the top of the viewport. Renders markdown-styled content with
/// code blocks, headers, bold/italic text, and blockquotes.
/// Non-interactive by default; interactive when focused for scrolling.

import SwiftUI
import MingaProtocol

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

public struct HoverPopupOverlay: View {
    public init(state: HoverPopupState, cellWidth: CGFloat, cellHeight: CGFloat, viewportHeight: CGFloat, viewportWidth: CGFloat, encoder: InputEncoder? = nil) {
        self.state = state
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.viewportHeight = viewportHeight
        self.viewportWidth = viewportWidth
        self.encoder = encoder
    }
    public let state: HoverPopupState
    @Environment(\.themeColors) private var theme
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let viewportHeight: CGFloat
    public let viewportWidth: CGFloat
    public let encoder: InputEncoder?

    @State private var popupHeight: CGFloat = 0
    @State private var popupWidth: CGFloat = 0

    private let maxWidth: CGFloat = 500
    private let maxHeight: CGFloat = 300
    private let gap: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animDuration: Double {
        reduceMotion ? 0 : 0.15
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

    public var body: some View {
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
                // Always intercept mouse events inside the popup (#2629). SwiftUI
                // then handles motion (keeping the popup alive instead of the
                // motion reaching EditorNSView and dismissing it via the BEAM),
                // scrolling, clicks, and the Open button without requiring the
                // user to keyboard-focus the popup first. Moving the pointer back
                // out resumes editor motion events, which dismiss on leaving.
                .allowsHitTesting(true)
                .transition(.opacity.animation(.easeIn(duration: animDuration)))
        }
    }

    @ViewBuilder
    private var popupContent: some View {
        ScrollView(.vertical, showsIndicators: state.focused) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.visibleLines) { line in
                    lineView(line)
                }

                if state.openActionName != nil {
                    Divider()
                        .background(theme.popupBorder.opacity(0.3))
                        .padding(.vertical, 4)

                    Button("Open") {
                        encoder?.sendHoverOpenAction()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
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
            .font(segmentFont(seg))
            .foregroundStyle(segmentColor(seg))
            .underline(segmentUnderline(seg))
    }

    private func segmentFont(_ seg: HoverSegment) -> Font {
        let style = seg.style
        switch style {
        case .bold:
            return .system(size: 13, weight: .semibold)
        case .italic:
            return .system(size: 13).italic()
        case .boldItalic:
            return .system(size: 13, weight: .semibold).italic()
        case .code, .codeBlock, .codeContent:
            return .system(size: 12, design: .monospaced)
        case .syntaxHighlighted:
            let weight: Font.Weight = seg.flags & 0x01 != 0 ? .semibold : .regular
            let font = Font.system(size: 12, weight: weight, design: .monospaced)
            return seg.flags & 0x02 != 0 ? font.italic() : font
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

    private func segmentUnderline(_ seg: HoverSegment) -> Bool {
        seg.style == .syntaxHighlighted && seg.flags & 0x04 != 0
    }

    private func segmentColor(_ seg: HoverSegment) -> Color {
        let style = seg.style
        switch style {
        case .code, .codeBlock, .codeContent:
            return theme.popupFg.opacity(0.85)
        case .syntaxHighlighted:
            guard let fgColor = seg.fgColor else { return theme.popupFg.opacity(0.85) }
            return rgbColor(fgColor)
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

    private func rgbColor(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

// MARK: - Previews

@MainActor
private func hoverPopupPreviewState() -> HoverPopupState {
    let state = HoverPopupState()
    state.update(
        visible: true, anchorRow: 8, anchorCol: 4,
        focused: false, scrollOffset: 0,
        rawLines: [
            Wire.HoverLine(lineType: .header, segments: [
                Wire.HoverSegment(style: .header2, fgColor: nil, flags: 0, text: "Buffer.open/1"),
            ]),
            Wire.HoverLine(lineType: .empty, segments: []),
            Wire.HoverLine(lineType: .text, segments: [
                Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "Opens a file from disk and returns a managed buffer process."),
            ]),
            Wire.HoverLine(lineType: .text, segments: [
                Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "The buffer is registered under the given path and will be reused"),
            ]),
            Wire.HoverLine(lineType: .text, segments: [
                Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "on subsequent calls with the same path."),
            ]),
            Wire.HoverLine(lineType: .empty, segments: []),
            Wire.HoverLine(lineType: .codeHeader, segments: [
                Wire.HoverSegment(style: .codeBlock, fgColor: nil, flags: 0, text: "elixir"),
            ]),
            Wire.HoverLine(lineType: .code, segments: [
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xC678DD, flags: 1, text: "@spec "),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0x61AFEF, flags: 0, text: "open"),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: "("),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xE5C07B, flags: 0, text: "String.t()"),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: ") :: "),
                Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xE5C07B, flags: 0, text: "{:ok, pid()}"),
            ]),
            Wire.HoverLine(lineType: .empty, segments: []),
            Wire.HoverLine(lineType: .blockquote, segments: [
                Wire.HoverSegment(style: .blockquote, fgColor: nil, flags: 0, text: "Since: v0.4.0"),
            ]),
        ]
    )
    return state
}

#Preview("Hover Popup") {
    let theme = PreviewFixtures.theme()
    HoverPopupOverlay(state: hoverPopupPreviewState(), cellWidth: 8, cellHeight: 18, viewportHeight: 300, viewportWidth: 500, encoder: nil)
        .frame(width: 500, height: 300)
        .background(theme.editorBg)
        .environment(\.themeColors, theme)
}
