import SwiftUI

/// The Board: a spatial card grid for agent supervision.
///
/// Displays agent sessions as cards in a responsive grid using
/// golden ratio proportions for spacing. Each card shows the agent's
/// task, status badge, model, and elapsed time.
///
/// Card clicks send `gui_action` events to the BEAM, which handles
/// zoom-in by switching the workspace and hiding the Board.
struct BoardView: View {
    let state: BoardState
    let theme: ThemeColors
    let encoder: InputEncoder?

    /// Golden ratio for proportional spacing.
    private let phi: CGFloat = 1.618

    /// Responsive columns: minimum card width 220pt, adapts to window size.
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 16)]

    var body: some View {
        ScrollView {
            if state.cards.isEmpty {
                emptyState
            } else {
                cardGrid
            }
        }
        .background(theme.editorBg)
    }

    // MARK: - Card Grid

    private var cardGrid: some View {
        LazyVGrid(columns: columns, spacing: CGFloat(16 / phi)) {
            ForEach(state.cards) { card in
                BoardCardView(card: card, theme: theme)
                    .onTapGesture {
                        encoder?.sendBoardSelectCard(id: card.id)
                    }
            }
        }
        // Outer margin = inner gap × φ (golden ratio breathing room)
        .padding(.horizontal, 16 * phi)
        .padding(.vertical, 16)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("What should we work on?")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Press n to dispatch a new agent")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Individual card on The Board.
///
/// Shows task description, status badge, model name, and elapsed time.
/// Uses system shadows, rounded corners, and hover state for native
/// macOS feel. The keyboard focus ring uses the system focus indicator
/// color per swift-expert recommendation.
struct BoardCardView: View {
    let card: BoardCard
    let theme: ThemeColors

    /// Golden ratio for internal padding proportions.
    private let phi: CGFloat = 1.618

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: status badge + elapsed time
            HStack {
                statusBadge
                Spacer()
                Text(card.elapsedDisplay)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            // Task description
            Text(card.task)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.editorFg.opacity(0.9))
                .lineLimit(2)

            Spacer(minLength: 4)

            // Footer: model name + file count
            HStack {
                if !card.model.isEmpty {
                    Text(card.model)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !card.recentFiles.isEmpty {
                    Text(card.recentFiles.prefix(3).joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        // Internal padding: vertical = horizontal × φ (golden ratio emphasis)
        .padding(.horizontal, 12)
        .padding(.vertical, 12 * phi)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    card.isFocused
                        ? Color(nsColor: .keyboardFocusIndicatorColor)
                        : Color.clear,
                    lineWidth: 2
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        // VoiceOver: announce card as a single element with combined label
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.task), \(card.isYouCard ? "You" : card.status.label), \(card.elapsedDisplay)")
        .accessibilityHint("Double tap to open")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Status Badge

    @State private var isPulsing = false

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if card.isYouCard {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .opacity(isPulsing && card.status == .working ? 0.4 : 1.0)
                    .animation(
                        card.status == .working
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .default,
                        value: isPulsing
                    )
                    .onAppear { isPulsing = true }
            }

            Text(card.isYouCard ? "You" : card.status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(card.isYouCard ? .primary : .secondary)
        }
    }

    private var statusColor: Color {
        let c = card.status.color
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: - Background

    private var cardBackground: Color {
        if isHovered {
            Color.blend(theme.editorBg, with: .white, amount: 0.12)
        } else {
            Color.blend(theme.editorBg, with: .white, amount: 0.05)
        }
    }
}

// MARK: - Color Blending Extension

private extension Color {
    /// Blends two colors by the given amount (0 = all base, 1 = all target).
    /// Uses NSColor component interpolation for true color mixing.
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
