/// Breadcrumb path bar between the tab bar and editor content.
///
/// Shows the active buffer's file path as clickable segments separated
/// by chevrons. Search icon on the right edge.

import SwiftUI

@MainActor
@Observable
final class BreadcrumbState {
    var segments: [String] = []

    func update(segments: [String]) {
        self.segments = segments
    }
}

struct BreadcrumbBar: View {
    let state: BreadcrumbState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let barHeight: CGFloat = 26

    var body: some View {
        if !state.segments.isEmpty {
            HStack(spacing: 0) {
                // Path segments with chevron separators
                ForEach(Array(state.segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(theme.breadcrumbSeparatorFg)
                            .padding(.horizontal, 4)
                    }

                    Text(segment)
                        .font(.system(size: 11.5))
                        .foregroundStyle(
                            index == state.segments.count - 1
                                ? theme.breadcrumbFg
                                : theme.breadcrumbFg.opacity(0.6)
                        )
                        .onTapGesture {
                            encoder?.sendBreadcrumbClick(index: UInt8(index))
                        }
                }

                Spacer()

                // Search icon
                Button(action: {}) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.breadcrumbFg.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)

                // Settings icon
                Button(action: {}) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.breadcrumbFg.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: barHeight)
            .background(theme.breadcrumbBg)
            .focusable(false)
            .focusEffectDisabled()

            // Bottom border
            Rectangle()
                .fill(theme.breadcrumbSeparatorFg.opacity(0.3))
                .frame(height: 1)
        }
    }
}
