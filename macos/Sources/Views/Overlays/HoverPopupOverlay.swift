/// Native SwiftUI hover popup overlay for LSP hover tooltips.
///
/// Renders markdown-styled content with code blocks, headers, bold/italic text,
/// and blockquotes. `EditorOverlayHost` owns anchor placement, viewport
/// clipping, and z-order.
/// Non-interactive by default; interactive when focused for scrolling.

import SwiftUI
import MingaProtocol

public struct HoverPopupOverlay: View {
    public init(state: HoverPopupState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    public let state: HoverPopupState
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    @Environment(\.anchoredOverlayContext) private var overlayContext
    public let encoder: InputEncoder?

    private let maxWidth: CGFloat = 500

    private var showsScrollIndicators: Bool {
        state.focused || state.scrollOffset > 0 || state.lines.count > 12
    }

    public var body: some View {
        let _ = frameVersion
        if state.visible && !state.lines.isEmpty {
            popupContent
                .frame(maxWidth: maxWidth)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.popupBg)
                        .shadow(color: .black.opacity(0.4), radius: 12, y: overlayContext.shadowYOffset)
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
                // Always intercept mouse events inside the popup (#2629). SwiftUI
                // then handles motion (keeping the popup alive instead of the
                // motion reaching EditorNSView and dismissing it via the BEAM),
                // scrolling, clicks, and the Open button without requiring the
                // user to keyboard-focus the popup first. Moving the pointer back
                // out resumes editor motion events, which dismiss on leaving.
                .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private var popupContent: some View {
        ScrollView(.vertical, showsIndicators: showsScrollIndicators) {
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
    HoverPopupOverlay(state: hoverPopupPreviewState(), encoder: nil)
        .frame(width: 500, height: 300)
        .background(theme.editorBg)
        .environment(\.themeColors, theme)
}
