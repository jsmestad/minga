import SwiftUI

/// The zoom header shown at the top of the zoomed card view.
///
/// When the user zooms into a Board card the grid is hidden and the card's
/// workspace renders through the normal editor pipeline. Without this header the
/// zoomed state has no card identity and no visible way back to the grid. The
/// header restores the capability the old cell-grid `build_zoom_context_bar`
/// provided before it was disposed (ticket #2328): a status icon, the task, the
/// model, and an "ESC back to Board" affordance. It is a native SwiftUI bar over
/// the editor, not a cell-grid draw path.
struct BoardZoomHeader: View {
    let card: BoardCard
    let theme: ThemeColors

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(card.isYouCard ? "Manual editing" : card.task)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.editorFg)
                .lineLimit(1)
                .truncationMode(.tail)
            if !card.model.isEmpty {
                Text("· \(card.model)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text("ESC back to Board")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.blend(theme.editorBg, with: .white, amount: 0.05))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.treeSeparatorFg.opacity(0.4))
                .frame(height: 1)
        }
        // VoiceOver: announce the zoomed card identity and the exit affordance.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Zoomed into \(card.isYouCard ? "Manual editing" : card.task), \(card.isYouCard ? "You" : card.status.label)")
        .accessibilityHint("Press Escape to go back to the Board")
    }

    /// Status icon mirroring the old cell-grid zoom bar glyphs.
    private var statusIcon: some View {
        Text(iconGlyph)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(iconColor)
    }

    private var iconGlyph: String {
        if card.isYouCard { return "◐" }
        switch card.status {
        case .idle: return "○"
        case .working: return "●"
        case .iterating: return "◉"
        case .needsYou: return "◆"
        case .done: return "✓"
        case .errored: return "✗"
        }
    }

    private var iconColor: Color {
        if card.isYouCard { return .secondary }
        switch card.status {
        case .idle: return theme.agentStatusIdle
        case .working: return theme.agentStatusWorking
        case .iterating: return theme.agentStatusIterating
        case .needsYou: return theme.agentStatusNeedsYou
        case .done: return theme.agentStatusDone
        case .errored: return theme.agentStatusErrored
        }
    }
}

// MARK: - Color Blending

private extension Color {
    /// Blends two colors by the given amount (0 = all base, 1 = all target).
    static func blend(_ base: Color, with target: Color, amount: Double) -> Color {
        let nsBase = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
        let nsTarget = NSColor(target).usingColorSpace(.sRGB) ?? NSColor(target)
        let t = max(0, min(1, amount))

        let r = nsBase.redComponent * (1 - t) + nsTarget.redComponent * t
        let g = nsBase.greenComponent * (1 - t) + nsTarget.greenComponent * t
        let b = nsBase.blueComponent * (1 - t) + nsTarget.blueComponent * t
        let a = nsBase.alphaComponent * (1 - t) + nsTarget.alphaComponent * t

        return Color(nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: a))
    }
}
