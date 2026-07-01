/// Compact icon button for sidebar headers (file tree, git status).
///
/// Matches the hover treatment of StatusBarIconButton: subtle rounded-rect
/// fill on hover, consistent opacity ramp, reduced-motion aware animation.
/// Extracted as a shared component so both sidebars use identical interaction.

import SwiftUI

public struct SidebarHeaderButton: View {
    public init(systemName: String, barFg: Color, tooltip: String = "", action: @escaping () -> Void) {
        self.systemName = systemName
        self.barFg = barFg
        self.tooltip = tooltip
        self.action = action
    }
    public let systemName: String
    public let barFg: Color
    public var tooltip: String = ""
    public let action: () -> Void

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(barFg.opacity(isHovered ? 0.7 : 0.45))
                .frame(width: 28, height: 34)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barFg.opacity(isHovered ? 0.08 : 0))
                )
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.12),
                    value: isHovered
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
        }
        .pointingHandCursor()
    }
}
