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

struct MinibufferView: View {
    let state: MinibufferState
    let theme: ThemeColors
    let encoder: InputEncoder?

    @State private var hoveredIndex: Int? = nil

    private let barHeight: CGFloat = 32
    private let candidateHeight: CGFloat = 26
    private let maxCandidateCount: Int = 15

    var body: some View {
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
                        .font(.system(size: 10))
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                        .padding(.trailing, 12)
                        .padding(.vertical, 2)
                }
            }

            // Top border (fully opaque when Increase Contrast is on)
            Rectangle()
                .fill(theme.popupBorder.opacity(
                    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.0 : 0.3
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
            NSAccessibility.post(
                element: NSApp.mainWindow as Any,
                notification: visible ? .layoutChanged : .layoutChanged
            )
        }
    }

    // MARK: - Input bar

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 0) {
            // Prompt prefix (accent-colored)
            Text(state.prompt)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.leading, 12)

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
                        .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.popupFg)
            }

            // Blinking cursor (resets on every input change via inputVersion)
            if state.showCursor {
                BlinkingCursor(color: theme.accent, resetToken: state.inputVersion)
            }

            // Text after cursor
            if cursorIdx < chars.count {
                Text(String(chars[cursorIdx...]))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.popupFg)
            }
        }
        .padding(.leading, 4)
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

        HStack(spacing: 6) {
            ForEach(keysPart.split(separator: "/"), id: \.self) { key in
                Text(String(key))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.popupFg.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.popupFg.opacity(0.1))
                    )
                    .accessibilityLabel("Press \(key)")
            }

            if !countPart.isEmpty {
                Text(countPart)
                    .font(.system(size: 11))
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
        .accessibilityLabel("\(state.candidates.count) results")
    }

    @ViewBuilder
    private func candidateRow(_ candidate: MinibufferCandidate) -> some View {
        let isSelected = candidate.id == Int(state.selectedIndex)
        let isHovered = hoveredIndex == candidate.id

        HStack(spacing: 8) {
            // Command name with fuzzy match highlighting
            highlightedLabel(candidate, isSelected: isSelected)

            // Description (dimmed)
            if !candidate.description.isEmpty {
                Text(candidate.description)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected
                        ? theme.editorBg.opacity(0.7)
                        : theme.popupFg.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // Keybinding annotation (right-aligned)
            if !candidate.annotation.isEmpty {
                Text(candidate.annotation)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(isSelected
                        ? theme.editorBg.opacity(0.5)
                        : theme.popupFg.opacity(0.3))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill((isSelected ? theme.editorBg : theme.popupFg).opacity(0.06))
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: candidateHeight)
        .background(candidateBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredIndex = hovering ? candidate.id : nil
        }
        .onTapGesture {
            encoder?.sendMinibufferSelect(index: UInt16(candidate.id))
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
        .accessibilityLabel(candidate.label)
        .accessibilityValue(candidate.description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func highlightedLabel(_ candidate: MinibufferCandidate, isSelected: Bool) -> some View {
        if candidate.matchPositions.isEmpty {
            Text(candidate.label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(isSelected ? theme.editorBg : theme.popupFg)
                .lineLimit(1)
        } else {
            let baseColor = isSelected ? Color(theme.editorBg) : Color(theme.popupFg)
            let matchColor = isSelected ? Color(theme.editorBg) : Color(theme.accent)
            let attributed = TextHighlighting.attributedString(
                candidate.label,
                matchPositions: candidate.matchPositions,
                baseFont: .system(size: 13, design: .monospaced),
                matchFont: .system(size: 13, weight: .semibold, design: .monospaced),
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
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.accent.opacity(0.8))
                .padding(.horizontal, 4)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.popupFg.opacity(0.06))
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }
}
