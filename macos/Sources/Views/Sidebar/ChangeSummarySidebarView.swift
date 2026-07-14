import SwiftUI

public struct ChangeSummarySidebarView: View {
    public init(changeSummaryState: ChangeSummaryState, encoder: InputEncoder? = nil, width: Binding<CGFloat>) {
        self.changeSummaryState = changeSummaryState
        self.encoder = encoder
        self._width = width
    }
    public let changeSummaryState: ChangeSummaryState
    public let encoder: InputEncoder?
    @Binding public var width: CGFloat
    @Environment(\.themeColors) private var theme


    @State private var minWidth: CGFloat = 200
    @State private var maxWidth: CGFloat = 400
    @State private var isDraggingResize: Bool = false

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ChangeSummaryView(
                    state: changeSummaryState,
                    encoder: encoder
                )
            }
            .frame(width: width)
            .background(theme.treeBg)

            Color.clear
                .frame(width: 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isDraggingResize ? theme.treeActiveFg.opacity(0.3) : theme.treeSeparatorFg.opacity(0.4))
                        .frame(width: 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            isDraggingResize = true
                            let newWidth = width + value.translation.width
                            width = min(max(newWidth, minWidth), maxWidth)
                        }
                        .onEnded { _ in
                            isDraggingResize = false
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .accessibilityLabel("Change summary resize handle")
                .accessibilityAdjustableAction { direction in
                    let step: CGFloat = 20
                    switch direction {
                    case .increment:
                        width = min(width + step, maxWidth)
                    case .decrement:
                        width = max(width - step, minWidth)
                    @unknown default:
                        break
                    }
                }
        }
    }
}
