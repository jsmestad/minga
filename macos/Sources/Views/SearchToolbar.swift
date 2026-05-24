/// Native SwiftUI find/replace toolbar for the editor.
///
/// Positioned between the breadcrumb/context bar and the editor surface.
/// Design follows VS Code/Zed conventions: a compact horizontal bar with
/// search field, match count, navigation buttons, toggle buttons for
/// search options (case, whole word, regex), and an optional replace row.
///
/// The search text field is locally managed (user types natively). On
/// text change, the query and flags are sent to the BEAM. Match count
/// and current index are BEAM-driven via SearchState.

import SwiftUI

/// Find/replace toolbar view.
struct SearchToolbar: View {
    let searchState: SearchState
    let theme: ThemeColors
    let encoder: (any InputEncoder)?

    @State private var searchText: String = ""
    @State private var replaceText: String = ""
    @FocusState private var searchFieldFocused: Bool

    /// Packs the current search option toggles into a flags byte.
    private var flagsByte: UInt8 {
        var flags: UInt8 = 0
        if searchState.replaceMode { flags |= SearchFlags.replaceMode }
        if searchState.caseSensitive { flags |= SearchFlags.caseSensitive }
        if searchState.wholeWord { flags |= SearchFlags.wholeWord }
        if searchState.regex { flags |= SearchFlags.regex }
        return flags
    }

    /// Formatted match count string, e.g. "3 of 12" or "No results".
    private var matchCountText: String {
        guard searchState.matchCount > 0 else {
            return searchText.isEmpty ? "" : "No results"
        }
        return "\(searchState.currentIndex) of \(searchState.matchCount)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top border
            Rectangle()
                .fill(theme.popupBorder.opacity(0.3))
                .frame(height: 1)

            VStack(spacing: 4) {
                searchRow
                if searchState.replaceMode {
                    replaceRow
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.editorBg)

            // Bottom border
            Rectangle()
                .fill(theme.popupBorder.opacity(0.3))
                .frame(height: 1)
        }
        .onAppear {
            searchFieldFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find and Replace")
    }

    // MARK: - Search Row

    @ViewBuilder
    private var searchRow: some View {
        HStack(spacing: 4) {
            // Replace mode toggle (chevron)
            Button {
                searchState.replaceMode.toggle()
                sendQuery()
            } label: {
                Image(systemName: searchState.replaceMode ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.editorFg.opacity(0.6))
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchState.replaceMode ? "Hide Replace" : "Show Replace")

            // Search text field with match count badge
            HStack(spacing: 0) {
                TextField("Find", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.editorFg)
                    .focused($searchFieldFocused)
                    .onSubmit {
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                            encoder?.sendSearchPrev()
                        } else {
                            encoder?.sendSearchNext()
                        }
                    }
                    .onChange(of: searchText) { _, _ in
                        sendQuery()
                    }
                    .onKeyPress(.escape) {
                        encoder?.sendSearchDismiss()
                        return .handled
                    }

                if !matchCountText.isEmpty {
                    Text(matchCountText)
                        .font(.system(size: 10))
                        .foregroundStyle(
                            searchState.matchCount > 0
                                ? theme.editorFg.opacity(0.5)
                                : theme.gutterErrorFg.opacity(0.8)
                        )
                        .padding(.trailing, 4)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.popupBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.popupBorder.opacity(0.4), lineWidth: 1)
            )

            // Previous match
            toolbarButton(icon: "chevron.up", label: "Previous Match") {
                encoder?.sendSearchPrev()
            }

            // Next match
            toolbarButton(icon: "chevron.down", label: "Next Match") {
                encoder?.sendSearchNext()
            }

            // Case sensitive toggle
            toggleButton(label: "Aa", accessibilityLabel: "Match Case", isActive: searchState.caseSensitive) {
                searchState.caseSensitive.toggle()
                sendQuery()
            }

            // Whole word toggle
            toggleButton(label: "ab", accessibilityLabel: "Match Whole Word", isActive: searchState.wholeWord, bordered: true) {
                searchState.wholeWord.toggle()
                sendQuery()
            }

            // Regex toggle
            toggleButton(label: ".*", accessibilityLabel: "Use Regular Expression", isActive: searchState.regex) {
                searchState.regex.toggle()
                sendQuery()
            }

            Spacer(minLength: 0)

            // Close button
            toolbarButton(icon: "xmark", label: "Close Search") {
                encoder?.sendSearchDismiss()
            }
        }
        .frame(height: 24)
    }

    // MARK: - Replace Row

    @ViewBuilder
    private var replaceRow: some View {
        HStack(spacing: 4) {
            // Spacer to align with search field (matches the chevron toggle width)
            Color.clear
                .frame(width: 20, height: 22)

            // Replace text field
            TextField("Replace", text: $replaceText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.editorFg)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.popupBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.popupBorder.opacity(0.4), lineWidth: 1)
                )
                .onSubmit {
                    encoder?.sendSearchReplace(replacement: replaceText)
                }

            // Replace
            toolbarButton(icon: "arrow.left.arrow.right", label: "Replace") {
                encoder?.sendSearchReplace(replacement: replaceText)
            }

            // Replace All
            toolbarButton(icon: "arrow.left.arrow.right.circle", label: "Replace All") {
                encoder?.sendSearchReplaceAll(replacement: replaceText)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }

    // MARK: - Buttons

    @ViewBuilder
    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.editorFg.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func toggleButton(label: String, accessibilityLabel: String, isActive: Bool, bordered: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .bold : .regular, design: .monospaced))
                .foregroundStyle(isActive ? theme.accent : theme.editorFg.opacity(0.6))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? theme.accent.opacity(0.15) : Color.clear)
                )
                .overlay {
                    if bordered && !isActive {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(theme.editorFg.opacity(0.15), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Helpers

    /// Sends the current search query and flags to the BEAM.
    private func sendQuery() {
        encoder?.sendSearchQuery(query: searchText, flags: flagsByte)
    }
}
