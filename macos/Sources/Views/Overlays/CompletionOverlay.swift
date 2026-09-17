/// Floating completion popup matching Zed's overlay aesthetic.
///
/// Rounded corners, dark background, subtle border. Positioned near
/// the cursor in the Metal editor view. Items show kind indicators
/// and detail text.

import SwiftUI
import MingaProtocol

public struct CompletionOverlay: View {
    public init(state: CompletionState, sendAction: OutboundActionHandler?) {
        self.state = state
        self.sendAction = sendAction
    }
    public let state: CompletionState
    @Environment(\.themeColors) private var theme

    @Environment(\.anchoredOverlayContext) private var overlayContext
    public let sendAction: OutboundActionHandler?

    private let maxVisibleItems = 10
    private let itemHeight: CGFloat = 24
    private let popupWidth: CGFloat = 340

    @State private var hoveredItemId: Int? = nil
    @AccessibilityFocusState private var accessibilityFocus: CompletionAccessibilityIdentity?

    private let docPaneMaxHeight: CGFloat = 160

    public var body: some View {
        Group {
            if let content = state.content, !content.items.isEmpty {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: content.items.count > maxVisibleItems) {
                            LazyVStack(spacing: 0) {
                                ForEach(content.items.prefix(maxVisibleItems)) { item in
                                    completionRow(item, content: content)
                                }
                            }
                        }
                        .onChange(of: content.effectiveSelectedIndex) { _, newIndex in
                            withAnimation(nil) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                    .frame(maxHeight: CGFloat(min(content.items.count, maxVisibleItems)) * itemHeight + 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Completion choices")
                    .accessibilityValue("\(content.items.count) choices")

                    // Documentation preview for the selected item. Renders only when the
                    // item carries docs, so items without docs show no pane (no layout
                    // shift). Markdown is shown as plain styled text for v1.
                    documentationPane(content)
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
        .onAppear {
            updateAccessibilityFocus()
        }
        .onChange(of: completionSelectionSignature) { _, _ in
            updateAccessibilityFocus()
        }
    }

    @ViewBuilder
    private func documentationPane(_ content: CompletionContent) -> some View {
        let doc = content.documentation.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private func completionRow(_ item: CompletionItem, content: CompletionContent) -> some View {
        let isSelected = item.id == content.effectiveSelectedIndex
        let identity = accessibilityIdentity(for: item, content: content)

        Button {
            activate(item, offeredContent: content)
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .id(item.id)
        .onHover { isHovered in
            hoveredItemId = isHovered ? item.id : nil
        }
        .accessibilityIdentifier("completion-choice-\(content.presentationRevision)-\(item.id)")
        .accessibilityLabel(item.label)
        .accessibilityValue(item.detail.isEmpty ? (isSelected ? "selected" : "available") : "\(isSelected ? "selected" : "available"), \(item.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($accessibilityFocus, equals: identity)
    }

    private var completionSelectionSignature: String? {
        guard let content = state.content,
              let item = content.items.first(where: { $0.id == content.effectiveSelectedIndex }) else { return nil }
        return "\(content.presentationRevision):\(item.id):\(item.kind):\(item.label):\(item.detail)"
    }

    private func accessibilityIdentity(for item: CompletionItem, content: CompletionContent) -> CompletionAccessibilityIdentity {
        CompletionAccessibilityIdentity(
            presentationRevision: content.presentationRevision,
            anchorRow: content.anchorRow,
            anchorCol: content.anchorCol,
            id: item.id,
            kind: item.kind,
            label: item.label,
            detail: item.detail
        )
    }

    private func activate(_ offeredItem: CompletionItem, offeredContent: CompletionContent) {
        guard let currentContent = state.content,
              currentContent.presentationRevision == offeredContent.presentationRevision,
              currentContent.anchorRow == offeredContent.anchorRow,
              currentContent.anchorCol == offeredContent.anchorCol,
              let currentItem = currentContent.items.first(where: { $0.id == offeredItem.id }),
              currentItem.kind == offeredItem.kind,
              currentItem.label == offeredItem.label,
              currentItem.detail == offeredItem.detail else { return }
        sendAction?(.completionSelect(index: UInt16(currentItem.id)))
    }

    private func updateAccessibilityFocus() {
        guard let content = state.content,
              let item = content.items.first(where: { $0.id == content.effectiveSelectedIndex }) else {
            accessibilityFocus = nil
            return
        }
        accessibilityFocus = accessibilityIdentity(for: item, content: content)
    }

    @ViewBuilder
    private func kindBadge(_ kind: CompletionKind) -> some View {
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
    private func kindDisplay(_ kind: CompletionKind) -> (String, Color) {
        switch kind {
        case .function: return ("ƒ", theme.popupKeyFg)
        case .method: return ("m", theme.popupKeyFg)
        case .variable: return ("v", theme.gutterWarningFg)
        case .field: return ("f", theme.statusbarAccentFg)
        case .module: return ("M", theme.popupGroupFg)
        case .keyword: return ("k", theme.popupGroupFg)
        case .snippet: return ("s", theme.gitAddedFg)
        case .constant: return ("c", theme.statusbarAccentFg)
        case .struct: return ("S", theme.gutterWarningFg)
        case .enum: return ("E", theme.gutterWarningFg)
        case .unknown: return ("·", theme.popupFg.opacity(0.5))
        }
    }
}

private struct CompletionAccessibilityIdentity: Hashable {
    let presentationRevision: UInt64
    let anchorRow: Int
    let anchorCol: Int
    let id: Int
    let kind: CompletionKind
    let label: String
    let detail: String
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
    CompletionOverlay(state: completionPreviewState(), sendAction: { _ in })
        .frame(width: 400, height: 300)
        .background(theme.editorBg)
        .environment(\.themeColors, theme)
}
