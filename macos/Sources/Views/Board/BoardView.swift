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
    let dispatchSheet: DispatchSheetState
    let theme: ThemeColors
    let encoder: InputEncoder?

    /// Golden ratio for proportional spacing.
    private let phi: CGFloat = 1.618

    /// State for drag-to-reorder tracking.
    @State private var draggedCardId: UInt32?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if state.filterMode {
                    searchBar
                }

                ScrollView {
                    if filteredCards.isEmpty {
                        if state.filterMode {
                            noMatchesState
                        } else {
                            emptyState
                        }
                    } else {
                        cardGrid(width: geometry.size.width)
                    }
                }
            }
            .background(theme.editorBg)
        }
        .overlay {
            DispatchSheetView(state: dispatchSheet, theme: theme, encoder: encoder)
        }
    }

    /// Computes the number of columns based on window width.
    /// 2 columns on narrow (< 900pt), 3 on medium (900-1400pt), 4 on wide (> 1400pt).
    private func columnCount(for width: CGFloat) -> Int {
        if width < 900 {
            return 2
        } else if width < 1400 {
            return 3
        } else {
            return 4
        }
    }

    /// Generates responsive grid columns for the given width.
    private func columns(for width: CGFloat) -> [GridItem] {
        let count = columnCount(for: width)
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    /// Cards filtered by search text.
    private var filteredCards: [BoardCard] {
        if state.filterText.isEmpty {
            return state.cards
        }
        let needle = state.filterText.lowercased()
        return state.cards.filter { card in
            card.task.lowercased().contains(needle) ||
            card.model.lowercased().contains(needle)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(state.filterText)
                .font(.system(size: 14))
                .foregroundStyle(theme.editorFg)
            Text("▏")
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.38, green: 0.69, blue: 0.93))
            Spacer()
            Text("ESC to clear")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blend(theme.editorBg, with: .white, amount: 0.05))
    }

    // MARK: - No Matches

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No cards matching \"\(state.filterText)\"")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Press Escape to clear")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card Grid

    private func cardGrid(width: CGFloat) -> some View {
        LazyVGrid(columns: columns(for: width), spacing: CGFloat(16 / phi)) {
            ForEach(filteredCards) { card in
                BoardCardView(card: card, theme: theme)
                    .onTapGesture {
                        encoder?.sendBoardSelectCard(id: card.id)
                    }
                    .draggable(String(card.id)) {
                        // Drag preview: mini card with just the task
                        Text(card.task)
                            .font(.system(size: 13, weight: .medium))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.blend(theme.editorBg, with: .white, amount: 0.15))
                            )
                    }
                    .dropDestination(for: String.self) { droppedIds, _ in
                        guard let draggedIdStr = droppedIds.first,
                              let draggedId = UInt32(draggedIdStr) else { return false }
                        handleCardDrop(draggedId: draggedId, targetId: card.id)
                        return true
                    }
            }
        }
        // Outer margin = inner gap × φ (golden ratio breathing room)
        .padding(.horizontal, 16 * phi)
        .padding(.vertical, 16)
    }

    /// Handles dropping a card onto another card.
    /// Calculates the new index and sends the reorder action to the BEAM.
    private func handleCardDrop(draggedId: UInt32, targetId: UInt32) {
        guard draggedId != targetId else { return }

        // Find the index of the target card in the current sorted list
        let allCards = state.cards
        guard let targetIndex = allCards.firstIndex(where: { $0.id == targetId }) else { return }

        // Animate the reorder with a spring curve
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            // Send the reorder action with the target index
            encoder?.sendBoardReorder(cardId: draggedId, newIndex: UInt16(targetIndex))
        }
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
        // TimelineView updates elapsed time every minute
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                // Header: status badge + elapsed time
                HStack {
                    statusBadge
                    Spacer()
                    Text(card.elapsedDisplay)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                // Task description (or "Manual editing" for You card)
                Text(card.isYouCard ? "Manual editing" : card.task)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.editorFg.opacity(0.9))
                    .lineLimit(2)

                Spacer(minLength: 4)

                // Sparkline (activity indicator, hidden for You card)
                if !card.isYouCard && !card.sparkline.isEmpty {
                    SparklineView(data: card.sparkline, color: statusColor)
                        .frame(height: 24)
                }

                // Footer: model name + touched files
                HStack {
                    if !card.model.isEmpty {
                        Text(card.model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !card.recentFiles.isEmpty {
                        Text(formattedFiles)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            // Internal padding: vertical = horizontal × φ (golden ratio emphasis)
            .padding(.horizontal, 12)
            .padding(.vertical, 12 * phi)
        }
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
        .accessibilityLabel("\(card.isYouCard ? "Manual editing" : card.task), \(card.isYouCard ? "You" : card.status.label), \(card.elapsedDisplay)")
        .accessibilityHint("Double tap to open")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Formatted Files

    /// Formats touched files as comma-separated basenames, max 3 with "+N more" suffix.
    private var formattedFiles: String {
        let basenames = card.recentFiles.map { URL(fileURLWithPath: $0).lastPathComponent }
        let total = basenames.count
        if total <= 3 {
            return basenames.joined(separator: ", ")
        } else {
            let first3 = basenames.prefix(3).joined(separator: ", ")
            let remaining = total - 3
            return "\(first3) +\(remaining) more"
        }
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
