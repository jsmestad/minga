import SwiftUI

/// Renders extension overlays as positioned SwiftUI content on the editor surface.
///
/// Each overlay entry specifies a cell position (row, col), color, opacity,
/// shape, and optional content text. The view positions overlay elements
/// using the cell dimensions from the editor's font metrics.
struct ExtensionOverlayView: View {
    let overlayState: ExtensionOverlayState
    let windowID: UInt16
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let contentOrigin: CGPoint

    var body: some View {
        let entries = overlayState.entries(forWindow: windowID)

        ZStack(alignment: .topLeading) {
            ForEach(entries) { entry in
                overlayContent(for: entry)
                    .position(
                        x: contentOrigin.x + CGFloat(entry.col) * cellWidth + cellWidth / 2,
                        y: contentOrigin.y + CGFloat(entry.row) * cellHeight + cellHeight / 2
                    )
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func overlayContent(for entry: ExtensionOverlayState.OverlayEntry) -> some View {
        let (r, g, b) = entry.color
        let color = Color(red: r, green: g, blue: b)

        switch entry.shape {
        case 0: // cursor
            Rectangle()
                .fill(color.opacity(entry.opacityValue))
                .frame(width: cellWidth, height: cellHeight)

        case 1: // cursor_with_label
            VStack(spacing: 0) {
                Text(entry.content)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .offset(y: -2)

                Rectangle()
                    .fill(color.opacity(entry.opacityValue))
                    .frame(width: cellWidth, height: cellHeight)
            }

        case 2: // label
            Text(entry.content)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))

        default: // indicator
            Circle()
                .fill(color.opacity(entry.opacityValue))
                .frame(width: 6, height: 6)
        }
    }
}
