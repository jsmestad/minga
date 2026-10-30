/// Native SwiftUI minibuffer with inline completion candidates.
///
/// Replaces the cell-grid minibuffer for GUI frontends. Positioned between
/// the editor surface and the status bar. The input bar (32px) shows the
/// prompt, typed text, and a blinking cursor. When completion candidates
/// are present, a candidate list expands upward above the input field.
///
/// All input still flows through EditorNSView -> BEAM. This view is
/// purely a renderer; it never captures keyboard focus.

import SwiftUI
import MingaProtocol

public struct MinibufferView: View {
    public enum Action: Equatable, Sendable {
        case select(generation: UInt32, itemID: String)
    }

    public init(state: MinibufferState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }
    public let state: MinibufferState
    @Environment(\.themeColors) private var theme

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    public let sendAction: ViewActionHandler<Action>?

    @State private var hoveredIndex: Int? = nil
    @AccessibilityFocusState private var accessibilityFocus: Int?

    private let barHeight: CGFloat = 32
    private let candidateHeight: CGFloat = 26
    private let maxCandidateCount: Int = 15

    public var body: some View {
        VStack(spacing: 0) {
            // Candidate list (expands upward above the input bar)
            if state.hasCandidates {
                candidateList
            }

            // Count indicator (when more results exist than visible)
            if state.totalCandidates > state.candidates.count {
                HStack {
                    Spacer()
                    Text("↕ \(state.candidates.count) of \(state.totalCandidates)")
                        .font(Typography.font(.caption))
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                        .padding(.trailing, Spacing.lg)
                        .padding(.vertical, Spacing.hairline)
                }
            }

            // Top border (fully opaque when Increase Contrast is on)
            Rectangle()
                .fill(theme.popupBorder.opacity(
                    colorSchemeContrast == .increased ? 1.0 : 0.3
                ))
                .frame(height: 1)

            // Input bar
            inputBar
        }
        .background {
            theme.popupBg
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Minibuffer")
        .onChange(of: state.visible) { _, visible in
            updateAccessibilityFocus()
            NSAccessibility.post(
                element: NSApp.mainWindow as Any,
                notification: visible ? .layoutChanged : .layoutChanged
            )
        }
        .onChange(of: state.selectedIndex) { _, _ in
            updateAccessibilityFocus()
        }
        .onAppear {
            updateAccessibilityFocus()
        }
    }

    // MARK: - Input bar

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 0) {
            // Prompt prefix (accent-colored)
            Text(state.prompt)
                .font(Typography.font(.emphasis, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.leading, Spacing.lg)

            if state.isInputMode {
                // Input text with cursor
                inputTextWithCursor
            }

            Spacer(minLength: 4)

            // Context (right-aligned, dimmed)
            if !state.context.isEmpty {
                if state.isPromptMode {
                    actionKeyBadges
                } else {
                    Text(state.context)
                        .font(Typography.font(.small, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.4))
                }
            }

            Spacer().frame(width: 12)
        }
        .frame(height: barHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.prompt)
        .accessibilityValue(state.input)
        .accessibilityAddTraits(state.isInputMode ? .isSearchField : .isStaticText)
    }

    // MARK: - Input text with blinking cursor

    @ViewBuilder
    private var inputTextWithCursor: some View {
        let chars = Array(state.input)
        let cursorIdx = min(Int(state.cursorPos), chars.count)

        HStack(spacing: 0) {
            // Text before cursor
            if cursorIdx > 0 {
                Text(String(chars[0..<cursorIdx]))
                    .font(Typography.font(.emphasis, design: .monospaced))
                    .foregroundStyle(theme.popupFg)
            }

            // Blinking cursor (resets on every input change via inputVersion)
            if state.showCursor {
                BlinkingCursor(color: theme.accent, resetToken: state.inputVersion)
            }

            // Text after cursor
            if cursorIdx < chars.count {
                Text(String(chars[cursorIdx...]))
                    .font(Typography.font(.emphasis, design: .monospaced))
                    .foregroundStyle(theme.popupFg)
            }
        }
        .padding(.leading, Spacing.xs)
    }

    // MARK: - Action key badges (for prompt modes like substitute confirm)

    @ViewBuilder
    private var actionKeyBadges: some View {
        // Parse "y/n/a/q (2 of 15)" into key badges + context.
        // Format contract: the BEAM sends context as "keys count_text" where keys
        // are slash-separated single chars. If the BEAM's substitute_confirm context
        // format changes, update this parsing logic to match.
        let parts = state.context.split(separator: " ", maxSplits: 1)
        let keysPart = parts.first.map(String.init) ?? state.context
        let countPart = parts.count > 1 ? String(parts[1]) : ""

        HStack(spacing: Spacing.sm) {
            ForEach(keysPart.split(separator: "/"), id: \.self) { key in
                Text(String(key))
                    .font(Typography.monospacedSmall)
                    .foregroundStyle(theme.popupFg.opacity(0.8))
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.hairline)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .fill(theme.popupFg.opacity(0.1))
                    )
                    .accessibilityLabel("Press \(key)")
            }

            if !countPart.isEmpty {
                Text(countPart)
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.popupFg.opacity(0.35))
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Candidate list

    @ViewBuilder
    private var candidateList: some View {
        let visibleCount = min(state.candidates.count, maxCandidateCount)

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(state.candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
            .frame(maxHeight: CGFloat(visibleCount) * candidateHeight)
            .onChange(of: state.selectedIndex) { _, newIndex in
                withAnimation(nil) {
                    proxy.scrollTo(Int(newIndex), anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Minibuffer choices")
        .accessibilityValue("\(state.candidates.count) of \(max(state.candidates.count, Int(state.totalCandidates))) choices")
    }

    @ViewBuilder
    private func candidateRow(_ candidate: MinibufferCandidate) -> some View {
        let isSelected = candidate.id == Int(state.selectedIndex)
        let isHovered = hoveredIndex == candidate.id
        let offeredInputVersion = state.inputVersion
        let offeredGeneration = state.generation

        Button {
            activate(candidate, offeredGeneration: offeredGeneration)
        } label: {
            HStack(spacing: Spacing.md) {
                // Command name with fuzzy match highlighting
                highlightedLabel(candidate, isSelected: isSelected)

                // Description (dimmed)
                if !candidate.description.isEmpty {
                    Text(candidate.description)
                        .font(Typography.font(.body))
                        .foregroundStyle(isSelected
                            ? theme.popupSelFg.opacity(0.75)
                            : theme.popupFg.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                // Keybinding annotation (right-aligned)
                if !candidate.annotation.isEmpty {
                    Text(candidate.annotation)
                        .font(Typography.font(.small, design: .monospaced))
                        .foregroundStyle(isSelected
                            ? theme.popupSelFg.opacity(0.65)
                            : theme.popupFg.opacity(0.3))
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, Spacing.pixel)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .fill(isSelected
                                    ? theme.popupSelFg.opacity(0.08)
                                    : theme.popupFg.opacity(0.06))
                        )
                }
            }
            .padding(.horizontal, Spacing.lg)
            .frame(height: candidateHeight)
            .background(candidateBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            hoveredIndex = hovering ? candidate.id : nil
        }
        .id(candidate.id)
        .transition(.opacity)
        .animation(
            SystemBlinkTiming.blinkingDisabled
                ? nil
                : .easeOut(duration: 0.15).delay(Double(candidate.id) * 0.02),
            value: state.inputVersion
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("minibuffer-choice-\(offeredInputVersion)-\(candidate.id)")
        .accessibilityLabel(candidate.label)
        .accessibilityValue(candidateAccessibilityValue(candidate, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($accessibilityFocus, equals: candidate.id)
    }

    private func candidateAccessibilityValue(_ candidate: MinibufferCandidate, isSelected: Bool) -> String {
        let selection = isSelected ? "selected" : "available"
        return candidate.description.isEmpty ? selection : "\(selection), \(candidate.description)"
    }

    private func activate(_ offeredCandidate: MinibufferCandidate, offeredGeneration: UInt32) {
        guard state.visible,
              state.generation == offeredGeneration,
              state.candidates.contains(where: { $0.itemID == offeredCandidate.itemID }) else { return }
        sendAction?(.select(generation: offeredGeneration, itemID: offeredCandidate.itemID))
    }

    private func updateAccessibilityFocus() {
        let selected = Int(state.selectedIndex)
        accessibilityFocus = state.visible && state.candidates.contains(where: { $0.id == selected }) ? selected : nil
    }

    @ViewBuilder
    private func highlightedLabel(_ candidate: MinibufferCandidate, isSelected: Bool) -> some View {
        if candidate.matchPositions.isEmpty {
            Text(candidate.label)
                .font(Typography.font(.emphasis, design: .monospaced))
                .foregroundStyle(isSelected ? theme.popupSelFg : theme.popupFg)
                .lineLimit(1)
        } else {
            let baseColor = isSelected ? theme.popupSelFg.opacity(0.82) : theme.popupFg
            let matchColor = isSelected ? theme.popupSelFg : Color(theme.accent)
            let attributed = TextHighlighting.attributedString(
                candidate.label,
                matchPositions: candidate.matchPositions,
                baseFont: Typography.font(.emphasis, design: .monospaced),
                matchFont: Typography.font(.emphasis, weight: .semibold, design: .monospaced),
                baseColor: baseColor,
                matchColor: matchColor
            )
            Text(attributed)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func candidateBackground(isSelected: Bool, isHovered: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(theme.popupSelBg)
                .padding(.horizontal, Spacing.xs)
        } else if isHovered {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(theme.popupFg.opacity(0.06))
                .padding(.horizontal, Spacing.xs)
        } else {
            Color.clear
        }
    }
}

#Preview("Minibuffer") {
    let theme = PreviewFixtures.theme()
    let state = MinibufferState()
    state.update(
        visible: true,
        mode: .command,
        cursorPos: 7,
        prompt: "M-x ",
        input: "org-mod",
        context: "",
        selectedIndex: 0,
        totalCandidates: 23,
        generation: 1,
        rawCandidates: [
            Wire.MinibufferCandidate(id: "org-mode", matchScore: 95, label: "org-mode", description: "Toggle Org major mode", annotation: "SPC m o", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
            Wire.MinibufferCandidate(id: "org-mode-restart", matchScore: 80, label: "org-mode-restart", description: "Restart Org mode parser", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
            Wire.MinibufferCandidate(id: "org-modernize", matchScore: 72, label: "org-modernize", description: "Modernize Org buffer syntax", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6, 8]),
        ]
    )
    return MinibufferView(state: state, sendAction: { _ in })
        .frame(width: 600, height: 140)
        .background(theme.editorBg)
        .environment(theme)
}
