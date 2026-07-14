import SwiftUI

/// Renders extension overlays as positioned SwiftUI content on the editor surface.
///
/// Each overlay entry specifies a cell position (row, col), color, opacity,
/// shape, and optional content text. The view positions overlay elements
/// using the cell dimensions from the editor's font metrics.
public struct ExtensionOverlayView: View {
    public init(overlayState: ExtensionOverlayState, windowID: UInt16, cellWidth: CGFloat, cellHeight: CGFloat, contentOrigin: CGPoint, firstColumn: UInt16 = 0, columnCount: UInt16 = 0, rowCount: UInt16 = 0) {
        self.overlayState = overlayState
        self.windowID = windowID
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.contentOrigin = contentOrigin
        self.firstColumn = firstColumn
        self.columnCount = columnCount
        self.rowCount = rowCount
    }
    public let overlayState: ExtensionOverlayState
    public let windowID: UInt16
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let contentOrigin: CGPoint
    /// Visible text viewport for the window, in cells. Entries outside it are suppressed so
    /// scrolled-out overlays do not draw over the gutter or an adjacent pane. Defaults
    /// (0) mean "viewport unknown, do not suppress".
    public var firstColumn: UInt16 = 0
    public var columnCount: UInt16 = 0
    public var rowCount: UInt16 = 0
    @Environment(\.guiFrameVersion) private var frameVersion

    public var body: some View {
        let _ = frameVersion
        let entries = overlayState.entries(forWindow: windowID).filter {
            ExtensionOverlayState.isVisible(
                $0,
                firstColumn: firstColumn,
                columnCount: columnCount,
                rowCount: rowCount
            )
        }

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
