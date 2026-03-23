/// Git status panel for the left sidebar.
///
/// Shows branch info, file changes grouped by section (staged, changes,
/// untracked, conflicts), and a commit message input. Matches the visual
/// density and interaction patterns of FileTreeView.

import SwiftUI

struct GitStatusView: View {
    let state: GitStatusState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let rowHeight: CGFloat = 24
    private let sectionHeaderHeight: CGFloat = 26

    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    @State private var hoveredEntryId: UInt32? = nil
    @State private var hoveredSection: GitStatusSection? = nil

    var body: some View {
        VStack(spacing: 0) {
            if state.repoState == .notARepo {
                notARepoView
            } else if state.repoState == .loading {
                loadingView
            } else if state.isClean {
                cleanView
            } else {
                fileList
            }

            Spacer(minLength: 0)

            // Commit area (only when there's a repo with changes)
            if state.repoState == .normal && !state.isClean {
                commitArea
            }
        }
        .background(theme.treeBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    // MARK: - Empty states

    @ViewBuilder
    private var notARepoView: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 20))
                .foregroundStyle(theme.treeFg.opacity(0.2))
            Text("Not a git repository")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.treeFg.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 6) {
            Spacer()
            ProgressView()
                .scaleEffect(0.6)
                .tint(theme.treeFg.opacity(0.4))
            Text("Loading\u{2026}")
                .font(.system(size: 11))
                .foregroundStyle(theme.treeFg.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cleanView: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(theme.gitAddedFg.opacity(0.4))
            Text("Nothing to commit")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.treeFg.opacity(0.5))
            Text("Working tree clean")
                .font(.system(size: 11))
                .foregroundStyle(theme.treeFg.opacity(0.3))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - File list

    @ViewBuilder
    private var fileList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                sectionBlock(.conflicted)
                sectionBlock(.staged)
                sectionBlock(.changed)
                sectionBlock(.untracked)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: GitStatusSection) -> some View {
        let entries = state.entries(for: section)
        if !entries.isEmpty {
            sectionHeader(section, count: entries.count)
            if !state.collapsedSections.contains(section) {
                ForEach(entries) { entry in
                    fileRow(entry)
                }
            }
        }
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(_ section: GitStatusSection, count: Int) -> some View {
        let isCollapsed = state.collapsedSections.contains(section)
        let isHovered = hoveredSection == section

        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.treeFg.opacity(0.5))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .animation(.easeInOut(duration: animDuration), value: isCollapsed)
                .frame(width: 12)

            Text(section.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.treeFg.opacity(0.7))
                .textCase(.uppercase)

            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.treeFg.opacity(0.4))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(theme.treeFg.opacity(0.08))
                )

            Spacer()

            // Bulk action buttons (visible on hover)
            if isHovered {
                sectionActions(section)
                    .transition(.opacity.animation(.easeInOut(duration: animDuration)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: sectionHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: animDuration)) {
                if state.collapsedSections.contains(section) {
                    state.collapsedSections.remove(section)
                } else {
                    state.collapsedSections.insert(section)
                }
            }
        }
        .onHover { isHovered in
            hoveredSection = isHovered ? section : nil
        }
    }

    @ViewBuilder
    private func sectionActions(_ section: GitStatusSection) -> some View {
        HStack(spacing: 2) {
            switch section {
            case .staged:
                actionButton(systemName: "minus", tooltip: "Unstage All") {
                    encoder?.sendGitUnstageAll()
                }
            case .changed:
                actionButton(systemName: "plus", tooltip: "Stage All") {
                    encoder?.sendGitStageAll()
                }
            case .untracked:
                actionButton(systemName: "plus", tooltip: "Stage All") {
                    encoder?.sendGitStageAll()
                }
            case .conflicted:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func actionButton(systemName: String, tooltip: String, action: @escaping () -> Void) -> some View {
        SidebarHeaderButton(
            systemName: systemName,
            barFg: theme.treeFg,
            tooltip: tooltip,
            action: action
        )
    }

    // MARK: - File row

    @ViewBuilder
    private func fileRow(_ entry: GitStatusEntry) -> some View {
        let isHovered = hoveredEntryId == entry.id

        HStack(spacing: 0) {
            // Status letter (M, A, D, R, C, ?, !)
            Text(statusLetter(entry.status))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor(entry.status))
                .frame(width: 18, alignment: .center)

            Spacer().frame(width: 4)

            // Filename
            Text(entry.filename)
                .font(.system(size: 12))
                .foregroundStyle(statusColor(entry.status))
                .lineLimit(1)
                .truncationMode(.middle)

            // Parent directory (dimmed)
            if !entry.directory.isEmpty {
                Text(" " + entry.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.treeFg.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            // Hover-revealed action buttons
            if isHovered {
                rowActions(entry)
                    .transition(.opacity.animation(.easeInOut(duration: animDuration)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovered in
            hoveredEntryId = hovered ? entry.id : nil
        }
        .onTapGesture {
            encoder?.sendGitOpenFile(path: entry.path)
        }
        .accessibilityLabel("\(statusAccessibilityLabel(entry.status)) file: \(entry.filename)")
    }

    @ViewBuilder
    private func rowActions(_ entry: GitStatusEntry) -> some View {
        HStack(spacing: 2) {
            switch entry.section {
            case .staged:
                actionButton(systemName: "minus", tooltip: "Unstage") {
                    encoder?.sendGitUnstageFile(path: entry.path)
                }
            case .changed:
                actionButton(systemName: "arrow.uturn.backward", tooltip: "Discard Changes") {
                    encoder?.sendGitDiscardFile(path: entry.path)
                }
                actionButton(systemName: "plus", tooltip: "Stage") {
                    encoder?.sendGitStageFile(path: entry.path)
                }
            case .untracked:
                actionButton(systemName: "plus", tooltip: "Stage") {
                    encoder?.sendGitStageFile(path: entry.path)
                }
            case .conflicted:
                actionButton(systemName: "plus", tooltip: "Stage (mark resolved)") {
                    encoder?.sendGitStageFile(path: entry.path)
                }
            }
        }
    }

    @ViewBuilder
    private func rowBackground(isHovered: Bool) -> some View {
        if isHovered {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.treeFg.opacity(0.06))
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }

    // MARK: - Commit area

    @ViewBuilder
    private var commitArea: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.treeSeparatorFg.opacity(0.3))
                .frame(height: 1)

            VStack(spacing: 6) {
                // Commit message input
                ZStack(alignment: .topLeading) {
                    if state.commitMessage.isEmpty {
                        Text("Commit message\u{2026}")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.treeFg.opacity(0.3))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                    }

                    TextEditor(text: Bindable(state).commitMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.treeFg)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 40, maxHeight: 80)
                }
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.editorBg.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(theme.treeSeparatorFg, lineWidth: 1)
                        )
                )

                // Commit button
                Button {
                    let message = state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !message.isEmpty else { return }
                    encoder?.sendGitCommit(message: message)
                    state.commitMessage = ""
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Commit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .foregroundStyle(state.canCommit ? theme.treeBg : theme.treeFg.opacity(0.3))
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(state.canCommit ? theme.accent : theme.treeFg.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!state.canCommit)
                .help(state.stagedEntries.isEmpty
                    ? "Stage files before committing"
                    : state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Enter a commit message"
                        : "Commit staged changes")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Status formatting

    private func statusLetter(_ status: GitFileStatus) -> String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .conflicted: "!"
        }
    }

    private func statusColor(_ status: GitFileStatus) -> Color {
        switch status {
        case .modified: theme.gitModifiedFg
        case .added: theme.gitAddedFg
        case .deleted: theme.gitDeletedFg
        case .renamed: theme.gitModifiedFg
        case .copied: theme.gitAddedFg
        case .untracked: theme.treeFg.opacity(0.5)
        case .conflicted: theme.gutterErrorFg
        }
    }

    private func statusAccessibilityLabel(_ status: GitFileStatus) -> String {
        switch status {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }
}
