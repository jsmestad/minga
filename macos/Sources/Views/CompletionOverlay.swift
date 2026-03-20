/// Floating completion popup matching Zed's overlay aesthetic.
///
/// Rounded corners, dark background, subtle border. Positioned near
/// the cursor in the Metal editor view. Items show kind indicators
/// and detail text.

import SwiftUI

struct CompletionOverlay: View {
    let state: CompletionState
    let theme: ThemeColors
    let encoder: InputEncoder?
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    private let maxVisibleItems = 10
    private let itemHeight: CGFloat = 24
    private let popupWidth: CGFloat = 340

    var body: some View {
        if state.visible && !state.items.isEmpty {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(state.items.prefix(maxVisibleItems)) { item in
                                completionRow(item)
                            }
                        }
                    }
                    .onChange(of: state.selectedIndex) { _, newIndex in
                        withAnimation(nil) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: popupWidth)
            .frame(maxHeight: CGFloat(min(state.items.count, maxVisibleItems)) * itemHeight + 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.popupBg)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .padding(4)
        }
    }

    @ViewBuilder
    private func completionRow(_ item: CompletionItem) -> some View {
        let isSelected = item.id == state.selectedIndex

        HStack(spacing: 6) {
            // Kind indicator
            kindBadge(item.kind)

            // Label
            Text(item.label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isSelected ? theme.popupFg : theme.popupFg.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 4)

            // Detail (type info)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.popupFg.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: itemHeight)
        .background(isSelected ? theme.popupSelBg.opacity(0.7) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .id(item.id)
        .contentShape(Rectangle())
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

    private func kindDisplay(_ kind: UInt8) -> (String, Color) {
        switch kind {
        case 1:  return ("ƒ", Color(red: 0.56, green: 0.74, blue: 0.96))  // function
        case 2:  return ("m", Color(red: 0.56, green: 0.74, blue: 0.96))  // method
        case 3:  return ("v", Color(red: 0.73, green: 0.74, blue: 0.41))  // variable
        case 4:  return ("f", Color(red: 0.86, green: 0.55, blue: 0.19))  // field
        case 5:  return ("M", Color(red: 0.78, green: 0.47, blue: 0.86))  // module
        case 7:  return ("k", Color(red: 0.78, green: 0.47, blue: 0.86))  // keyword
        case 8:  return ("s", Color(red: 0.60, green: 0.74, blue: 0.40))  // snippet
        case 9:  return ("c", Color(red: 0.86, green: 0.55, blue: 0.19))  // constant
        case 11: return ("S", Color(red: 0.86, green: 0.75, blue: 0.48))  // struct
        case 12: return ("E", Color(red: 0.86, green: 0.75, blue: 0.48))  // enum
        default: return ("·", theme.popupFg.opacity(0.5))
        }
    }
}
