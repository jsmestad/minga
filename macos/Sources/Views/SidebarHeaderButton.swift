/// Compact icon button for sidebar headers (file tree, git status).
///
/// Matches the hover treatment of StatusBarIconButton: subtle rounded-rect
/// fill on hover, consistent opacity ramp, reduced-motion aware animation.
/// Extracted as a shared component so both sidebars use identical interaction.

import SwiftUI

struct SidebarHeaderButton: View {
    let systemName: String
    let barFg: Color
    var tooltip: String = ""
    let action: () -> Void

    @State private var isHovered = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
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
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
