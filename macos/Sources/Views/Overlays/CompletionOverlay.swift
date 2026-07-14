/// Floating completion popup matching Zed's overlay aesthetic.
///
/// Rounded corners, dark background, subtle border. Positioned near
/// the cursor in the Metal editor view. Items show kind indicators
/// and detail text.

import SwiftUI
import MingaProtocol

public struct CompletionOverlay: View {
    public init(state: CompletionState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    public let state: CompletionState
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    @Environment(\.anchoredOverlayContext) private var overlayContext
    public let encoder: InputEncoder?

    private let maxVisibleItems = 10
    private let itemHeight: CGFloat = 24
    private let popupWidth: CGFloat = 340

    @State private var hoveredItemId: Int? = nil

    private let docPaneMaxHeight: CGFloat = 160

    public var body: some View {
        let _ = frameVersion
        if state.visible && !state.items.isEmpty {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: state.items.count > maxVisibleItems) {
                        LazyVStack(spacing: 0) {
                            ForEach(state.items.prefix(maxVisibleItems)) { item in
                                completionRow(item)
                            }
                        }
                    }
                    .onChange(of: state.effectiveSelectedIndex) { _, newIndex in
                        withAnimation(nil) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(state.items.count, maxVisibleItems)) * itemHeight + 8)

                // Documentation preview for the selected item. Renders only when the
                // item carries docs, so items without docs show no pane (no layout
                // shift). Markdown is shown as plain styled text for v1.
                documentationPane
            }
            .frame(width: popupWidth)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.popupBg)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: overlayContext.shadowYOffset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .padding(4)
        }
    }

    @ViewBuilder
    private var documentationPane: some View {
        let doc = state.documentation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !doc.isEmpty {
            Divider()
                .overlay(theme.popupBorder.opacity(0.4))
            ScrollView(.vertical, showsIndicators: true) {
                Text(doc)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.popupFg.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .frame(maxHeight: docPaneMaxHeight)
        }
    }

    @ViewBuilder
    private func completionRow(_ item: CompletionItem) -> some View {
        let isSelected = item.id == state.effectiveSelectedIndex

        HStack(spacing: 6) {
            // Kind indicator
            kindBadge(item.kind)

            // Label
            Text(item.label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isSelected ? theme.popupSelFg : theme.popupFg)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Detail (type info)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? theme.popupSelFg.opacity(0.72) : theme.popupMutedFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: itemHeight)
        .background(
            isSelected
                ? theme.popupSelBg.opacity(0.7)
                : (hoveredItemId == item.id ? theme.popupFg.opacity(0.06) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .id(item.id)
        .contentShape(Rectangle())
        .onHover { isHovered in
            hoveredItemId = isHovered ? item.id : nil
        }
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            encoder?.sendCompletionSelect(index: UInt16(item.id))
        }
    }

    @ViewBuilder
    private func kindBadge(_ kind: UInt8) -> some View {
        let (letter, color) = kindDisplay(kind)
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
    }

    /// Maps LSP completion kind to a display letter and theme-driven color.
    /// Colors use existing theme slots for consistency across light/dark themes.
    ///
    /// Semantic grouping:
    /// - `popupKeyFg` (blue): callable things (functions, methods)
    /// - `popupGroupFg` (purple): structural things (modules, keywords)
    /// - `gutterWarningFg` (yellow): data things (variables, structs, enums)
    /// - `statusbarAccentFg` (accent): reference things (fields, constants)
    /// - `gitAddedFg` (green): snippets
    private func kindDisplay(_ kind: UInt8) -> (String, Color) {
        switch kind {
        case 1:  return ("ƒ", theme.popupKeyFg)         // function
        case 2:  return ("m", theme.popupKeyFg)         // method
        case 3:  return ("v", theme.gutterWarningFg)    // variable
        case 4:  return ("f", theme.statusbarAccentFg)  // field
        case 5:  return ("M", theme.popupGroupFg)       // module
        case 7:  return ("k", theme.popupGroupFg)       // keyword
        case 8:  return ("s", theme.gitAddedFg)         // snippet
        case 9:  return ("c", theme.statusbarAccentFg)  // constant
        case 11: return ("S", theme.gutterWarningFg)    // struct
        case 12: return ("E", theme.gutterWarningFg)    // enum
        default: return ("·", theme.popupFg.opacity(0.5))
        }
    }
}

@MainActor
private func completionPreviewState() -> CompletionState {
    let state = CompletionState()
    state.update(
        visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 1,
        rawItems: [
            Wire.CompletionItem(kind: 7, label: "defmodule", detail: "keyword"),
            Wire.CompletionItem(kind: 7, label: "defstruct", detail: "keyword"),
            Wire.CompletionItem(kind: 7, label: "defdelegate", detail: "keyword"),
            Wire.CompletionItem(kind: 2, label: "def", detail: "keyword"),
            Wire.CompletionItem(kind: 1, label: "Document", detail: "Minga.Buffer.Document"),
        ],
        documentation: "Defines a struct for the module.\n\nFields are given as a keyword list."
    )
    return state
}

#Preview("Completion") {
    let theme = PreviewFixtures.theme()
    CompletionOverlay(state: completionPreviewState(), encoder: nil)
        .frame(width: 400, height: 300)
        .background(theme.editorBg)
        .environment(\.themeColors, theme)
}
