/// Native SwiftUI hover popup overlay for LSP hover tooltips.
///
/// Renders markdown-styled content with code blocks, headers, bold/italic text,
/// and blockquotes. `EditorOverlayHost` owns anchor placement, viewport
/// clipping, and z-order.
/// Pointer users can select and scroll text. Editor focus also moves VoiceOver to the card.

import SwiftUI
import MingaProtocol

private struct HoverPointerSurface: NSViewRepresentable {
    let state: HoverPopupState

    func makeNSView(context: Context) -> NSView {
        let view = RegionView()
        state.registerPointerSurface(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        state.registerPointerSurface(view)
    }

    private final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

public struct HoverPopupOverlay: View {
    public enum Action: Equatable, Sendable {
        case activate(offer: UInt64, action: UInt16)
    }

    public init(state: HoverPopupState, maxWidth: CGFloat = 500, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
        self.maxWidth = min(maxWidth, 500)
    }
    public let state: HoverPopupState
    @Environment(\.themeColors) private var theme

    @AccessibilityFocusState(for: .voiceOver) private var accessibilityFocused: Bool
    public let sendAction: ViewActionHandler<Action>?

    private let maxWidth: CGFloat

    private func showsScrollIndicators(_ content: HoverPopupContent) -> Bool {
        content.focused || content.scrollOffset > 0 || content.lines.count > 12
    }

    public var body: some View {
        if let content = state.content, !content.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .vertical) {
                    let document = popupContent(content)
                    document.fixedSize(horizontal: false, vertical: true)
                    ScrollView(.vertical, showsIndicators: showsScrollIndicators(content)) {
                        document
                    }
                    .mask {
                        // The document's bottom inset keeps its last line fully visible at the end of the scroll.
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [theme.popupBg, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: Spacing.md)
                        }
                    }
                }
                .anatomyPart("hover.document", text: "Hover documentation")
                if let offer = content.offer, offer.showsActions || !offer.openLabel.isEmpty {
                    Divider()
                        .overlay(theme.popupBorder)
                        .padding(.horizontal, Spacing.lg)
                    footer(offer)
                }
            }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .fill(theme.popupBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .strokeBorder(
                            content.focused
                                ? theme.accent.opacity(0.8)
                                : theme.popupBorder,
                            lineWidth: content.focused ? 2 : 1
                        )
                )
                .background {
                    HoverPointerSurface(state: state)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .anatomyPart("hover.panel")
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Hover details")
                .accessibilityIdentifier("editor-hover-details")
                .accessibilityFocused($accessibilityFocused)
                .onChange(of: content.focused, initial: true) { _, focused in
                    accessibilityFocused = focused
                }
                // Keep native selection, scrolling, and links inside the popup.
                .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private func popupContent(_ content: HoverPopupContent) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            ForEach(content.visibleLines) { line in
                lineView(line, offer: content.offer)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private func footer(_ offer: Wire.HoverOffer) -> some View {
        HStack(spacing: Spacing.lg) {
            if !offer.openLabel.isEmpty {
                Button {
                    sendAction?(.activate(offer: offer.id, action: 0))
                } label: {
                    Text(offer.openLabel)
                        .underline()
                        .anatomyPart("hover.openAction", text: offer.openLabel, font: .body, monospaced: true)
                }
            }
            if offer.showsActions {
                Button {
                    sendAction?(.activate(offer: offer.id, action: 1))
                } label: {
                    Text("g. actions")
                        .underline()
                        .anatomyPart("hover.actions", text: "g. actions", font: .body, monospaced: true)
                }
                .accessibilityLabel("Actions")
                .accessibilityHint("Shortcut: g then period")
            }
        }
        .buttonStyle(.plain)
        .font(Typography.font(.body, design: .monospaced))
        .foregroundStyle(theme.popupFg)
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.md)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func lineView(_ line: HoverLine, offer: Wire.HoverOffer?) -> some View {
        switch line.lineType {
        case .empty:
            Spacer().frame(height: 6)

        case .rule:
            Divider()
                .background(theme.popupBorder.opacity(0.3))
                .padding(.vertical, Spacing.xs)

        case .code, .codeHeader:
            HStack(spacing: 0) {
                ForEach(line.segments) { seg in
                    segmentView(seg, offer: offer)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.hairline)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(theme.popupBg.opacity(0.6))
            )
            .font(Typography.font(.body, design: .monospaced))

        case .blockquote:
            HStack(spacing: Spacing.md) {
                Rectangle()
                    .fill(theme.popupBorder.opacity(0.5))
                    .frame(width: 3)

                HStack(spacing: 0) {
                    ForEach(line.segments) { seg in
                        segmentView(seg, offer: offer)
                    }
                }
            }
            .padding(.vertical, Spacing.pixel)

        case .header:
            HStack(spacing: 0) {
                ForEach(line.segments) { seg in
                    segmentView(seg, offer: offer)
                }
            }
            .padding(.bottom, Spacing.hairline)

        default:
            HStack(spacing: 0) {
                ForEach(line.segments) { seg in
                    segmentView(seg, offer: offer)
                }
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: HoverSegment, offer: Wire.HoverOffer?) -> some View {
        if let id = segment.linkID, let offer {
            Button {
                sendAction?(.activate(offer: offer.id, action: id))
            } label: {
                Text(segment.text)
                    .font(Typography.font(.emphasis, weight: segment.style == .selectedLink ? .semibold : .regular))
                    .foregroundStyle(theme.popupFg)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(segment.style == .selectedLink ? [.isLink, .isSelected] : .isLink)
        } else {
            segmentText(segment)
        }
    }

    private func segmentText(_ seg: HoverSegment) -> some View {
        Text(seg.text)
            .font(segmentFont(seg))
            .foregroundStyle(segmentColor(seg))
            .underline(segmentUnderline(seg))
            .textSelection(.enabled)
    }

    private func segmentFont(_ seg: HoverSegment) -> Font {
        let style = seg.style
        switch style {
        case .bold:
            return Typography.font(.emphasis, weight: .semibold)
        case .italic:
            return Typography.font(.emphasis).italic()
        case .boldItalic:
            return Typography.font(.emphasis, weight: .semibold).italic()
        case .code, .codeBlock, .codeContent:
            return Typography.font(.body, design: .monospaced)
        case .syntaxHighlighted:
            let weight: Font.Weight = seg.flags & 0x01 != 0 ? .semibold : .regular
            let font = Typography.font(.body, weight: weight, design: .monospaced)
            return seg.flags & 0x02 != 0 ? font.italic() : font
        case .header1:
            return Typography.font(.heading, weight: .bold)
        case .header2:
            return Typography.font(.title, weight: .bold)
        case .header3:
            return Typography.font(.emphasis, weight: .semibold)
        default:
            return Typography.font(.emphasis)
        }
    }

    private func segmentUnderline(_ seg: HoverSegment) -> Bool {
        seg.style == .syntaxHighlighted && seg.flags & 0x04 != 0
    }

    private func segmentColor(_ seg: HoverSegment) -> Color {
        let style = seg.style
        switch style {
        case .syntaxHighlighted:
            guard let fgColor = seg.fgColor else { return theme.popupFg }
            return rgbColor(fgColor)
        case .rule:
            return theme.popupBorder
        default:
            return theme.popupFg
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
    HoverPopupOverlay(state: hoverPopupPreviewState(), sendAction: { _ in })
        .frame(width: 500, height: 300)
        .background(theme.editorBg)
        .environment(\.themeColors, theme)
}
