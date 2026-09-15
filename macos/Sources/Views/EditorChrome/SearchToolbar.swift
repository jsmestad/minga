/// Native SwiftUI find/replace toolbar for the editor.
///
/// Positioned between the breadcrumb/context bar and the editor surface.
/// Design follows VS Code/Zed conventions: a compact horizontal bar with
/// search field, match count, navigation buttons, toggle buttons for
/// search options (case, whole word, regex), and an optional replace row.
///
/// Committed native edits are reconciled with the complete BEAM-owned search session.

import SwiftUI

/// Find/replace toolbar view.
public struct SearchToolbar: View {
    public init(searchState: SearchState, encoder: (any InputEncoder)? = nil) {
        self.searchState = searchState
        self.encoder = encoder
    }
    public let searchState: SearchState
    @Environment(\.themeColors) private var theme

    public let encoder: (any InputEncoder)?

    @State private var replaceText: String = ""

    /// Formatted match count string, e.g. "3 of 12" or "No results".
    private var matchCountText: String {
        guard searchState.matchCount > 0 else {
            return searchState.query.isEmpty ? "" : "No results"
        }
        return "\(searchState.currentIndex) of \(searchState.matchCount)"
    }

    public var body: some View {
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find and Replace")
    }

    // MARK: - Search Row

    @ViewBuilder
    private var searchRow: some View {
        HStack(spacing: 4) {
            // Replace mode toggle (chevron)
            Button {
                encoder?.sendSearchFocus(replaceMode: !searchState.replaceMode)
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
                SearchQueryField(
                    searchState: searchState,
                    style: InlineEditFieldStyle(
                        textColor: theme.editorFg,
                        selectionBackgroundColor: theme.accent.opacity(0.35),
                        selectionForegroundColor: theme.editorFg,
                        insertionPointColor: theme.accent
                    ),
                    encoder: encoder
                )
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)

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
                sendEdit(searchState.toggle(.caseSensitive))
            }

            // Whole word toggle
            toggleButton(label: "ab", accessibilityLabel: "Match Whole Word", isActive: searchState.wholeWord, bordered: true) {
                sendEdit(searchState.toggle(.wholeWord))
            }

            // Regex toggle
            toggleButton(label: ".*", accessibilityLabel: "Use Regular Expression", isActive: searchState.regex) {
                sendEdit(searchState.toggle(.regex))
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

    private func sendEdit(_ edit: SearchEdit?) {
        guard let edit else { return }
        encoder?.sendSearchQuery(sessionID: edit.sessionID, editSeq: edit.sequence, query: edit.query, flags: edit.flags)
    }
}
