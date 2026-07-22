/// Breadcrumb path bar between the tab bar and editor content.
///
/// Shows the active buffer's file path as display-only segments separated
/// by chevrons. Search icon on the right edge.

import SwiftUI

@MainActor
@Observable
public final class BreadcrumbState {
    public init(segments: [String] = []) {
        self.segments = segments
    }
    public var segments: [String] = []

    public func update(segments: [String]) {
        self.segments = segments
    }

    /// Clear breadcrumb state. Called when no buffer is active or during
    /// error recovery to prevent stale path segments from persisting.
    public func hide() {
        segments = []
    }
}

public struct BreadcrumbBar: View {
    public init(state: BreadcrumbState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    public let state: BreadcrumbState
    @Environment(\.themeColors) private var theme

    public let encoder: InputEncoder?

    private let barHeight: CGFloat = 26

    public var body: some View {
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
                }

                Spacer()

                // Find file button
                breadcrumbButton(
                    systemIcon: "magnifyingglass",
                    tooltip: "Find file (SPC f f)"
                ) {
                    encoder?.sendExecuteCommand(name: "find_file")
                }

                // Open config button
                breadcrumbButton(
                    systemIcon: "gearshape",
                    tooltip: "Open config (SPC f p)"
                ) {
                    encoder?.sendExecuteCommand(name: "open_config")
                }
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

    /// Compact icon button for the breadcrumb bar with tooltip and pointer cursor.
    @ViewBuilder
    private func breadcrumbButton(
        systemIcon: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemIcon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.breadcrumbFg.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .padding(.trailing, 4)
        .pointingHandCursor()
    }
}

// MARK: - Previews

@MainActor
private func breadcrumbPreviewState() -> BreadcrumbState {
    let state = BreadcrumbState()
    state.update(segments: ["macos", "Sources", "Views", "EditorChrome", "BreadcrumbBar.swift"])
    return state
}

#Preview("Breadcrumb Bar", traits: .mingaChrome) {
    BreadcrumbBar(state: breadcrumbPreviewState(), encoder: nil)
        .frame(width: 700)
}
