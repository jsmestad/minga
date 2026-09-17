/// Git status panel for the left sidebar.
///
/// Shows branch info, file changes grouped by section (staged, changes,
/// untracked, conflicts), and a commit message input. Matches the visual
/// density and interaction patterns of FileTreeView.

import SwiftUI

public struct GitStatusView: View {
    public let state: GitStatusState
    @Environment(\.themeColors) private var theme

    public let encoder: InputEncoder?
    public let usesPreviewEagerLayout: Bool

    public init(
        state: GitStatusState,
        encoder: InputEncoder?,
        usesPreviewEagerLayout: Bool = false
    ) {
        self.state = state
        self.encoder = encoder
        self.usesPreviewEagerLayout = usesPreviewEagerLayout
    }

    private let rowHeight: CGFloat = 24
    private let sectionHeaderHeight: CGFloat = 26
    private let commitMessageEditorHeight: CGFloat = 64
    private let directoryMaxWidth: CGFloat = 110
    @Namespace private var fileMoveNamespace

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animDuration: Double {
        reduceMotion ? 0 : 0.15
    }

    @State private var hoveredEntryId: UInt32? = nil
    @State private var hoveredSection: GitStatusSection? = nil
    @State private var fileToDiscard: GitStatusEntry? = nil

    public var body: some View {
        VStack(spacing: 0) {
            // Toast banner
            if let toast = state.snapshot.toastMessage {
                toastBanner(message: toast, level: state.snapshot.toastLevel, action: state.snapshot.toastAction)
            }

            Group {
                if state.snapshot.repoState == .notARepo {
                    notARepoView
                } else if state.snapshot.repoState == .loading {
                    loadingView
                } else if state.isClean {
                    cleanView
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipped()
            .layoutPriority(0)

            // Git actions are available for any normal repo. A clean tree can still be ahead/behind, and amend does not require file changes.
            if state.snapshot.repoState == .normal {
                commitArea
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
        }
        .background(theme.treeBg)
        .focusable(false)
        .focusEffectDisabled()
        .alert("Discard Changes?", isPresented: Binding(
            get: { fileToDiscard != nil },
            set: { if !$0 { fileToDiscard = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                fileToDiscard = nil
            }
            Button("Discard", role: .destructive) {
                if let entry = fileToDiscard {
                    encoder?.sendGitDiscardFile(path: entry.path)
                    fileToDiscard = nil
                }
            }
        } message: {
            if let entry = fileToDiscard {
                Text("Discard changes in \(entry.filename)? This cannot be undone.")
            }
        }
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
        if usesPreviewEagerLayout {
            VStack(spacing: 0) {
                sectionBlock(.conflicted)
                sectionBlock(.staged)
                sectionBlock(.changed)
                sectionBlock(.untracked)
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(.easeInOut(duration: animDuration), value: state.snapshot.entriesRevision)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    sectionBlock(.conflicted)
                    sectionBlock(.staged)
                    sectionBlock(.changed)
                    sectionBlock(.untracked)
                }
                .padding(.top, 2)
                .animation(.easeInOut(duration: animDuration), value: state.snapshot.entriesRevision)
            }
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: GitStatusSection) -> some View {
        let entries = state.entries(for: section)
        if !entries.isEmpty {
            sectionHeader(section, count: entries.count)
            if !state.session.collapsedSections.contains(section) {
                ForEach(entries) { entry in
                    fileRow(entry)
                }
            }
        }
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(_ section: GitStatusSection, count: Int) -> some View {
        let isCollapsed = state.session.collapsedSections.contains(section)
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
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("git-section-\(section.rawValue)")
        .accessibilityLabel(section.label)
        .accessibilityValue("\(count) files, \(isCollapsed ? "collapsed" : "expanded")")
        .accessibilityHint(isCollapsed ? "Activate to expand" : "Activate to collapse")
        .accessibilityAction {
            toggleSection(section)
        }
        .modifier(GitSectionAccessibilityActions(section: section, perform: performSectionBulkAction))
        .onTapGesture {
            toggleSection(section)
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
                    performSectionBulkAction(.staged)
                }
            case .changed:
                actionButton(systemName: "plus", tooltip: "Stage All") {
                    performSectionBulkAction(.changed)
                }
            case .untracked:
                actionButton(systemName: "plus", tooltip: "Stage All") {
                    performSectionBulkAction(.untracked)
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
                .foregroundStyle(theme.treeFg)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)

            // Parent directory (dimmed)
            if !entry.directory.isEmpty {
                Text(" " + entry.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.treeDisabledFg)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: directoryMaxWidth, alignment: .leading)
                    .layoutPriority(0)
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
        .matchedGeometryEffect(id: state.animationID(for: entry), in: fileMoveNamespace)
        .onTapGesture {
            performEntryAction(.open, for: entry)
        }
        .contextMenu { fileContextMenu(entry) }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("git-file-\(entry.id)")
        .accessibilityLabel("\(statusAccessibilityLabel(entry.status)) file: \(entry.filename)")
        .accessibilityValue("\(entry.section.label), \(entry.path)")
        .accessibilityAction {
            performEntryAction(.open, for: entry)
        }
        .modifier(GitEntryAccessibilityActions(entry: entry, perform: performEntryAction))
    }

    @ViewBuilder
    private func rowActions(_ entry: GitStatusEntry) -> some View {
        HStack(spacing: 2) {
            switch entry.section {
            case .staged:
                actionButton(systemName: "minus", tooltip: "Unstage") {
                    performEntryAction(.unstage, for: entry)
                }
            case .changed:
                actionButton(systemName: "arrow.uturn.backward", tooltip: "Discard Changes") {
                    performEntryAction(.discard, for: entry)
                }
                actionButton(systemName: "plus", tooltip: "Stage") {
                    performEntryAction(.stage, for: entry)
                }
            case .untracked:
                actionButton(systemName: "plus", tooltip: "Stage") {
                    performEntryAction(.stage, for: entry)
                }
            case .conflicted:
                actionButton(systemName: "plus", tooltip: "Stage (mark resolved)") {
                    performEntryAction(.stage, for: entry)
                }
            }
        }
    }

    @ViewBuilder
    private func fileContextMenu(_ entry: GitStatusEntry) -> some View {
        Button("Open File") {
            performEntryAction(.open, for: entry)
        }
        Button("Open Diff") {
            performEntryAction(.openDiff, for: entry)
        }

        Divider()

        switch entry.section {
        case .staged:
            Button("Unstage") {
                performEntryAction(.unstage, for: entry)
            }
        case .changed, .untracked, .conflicted:
            Button(entry.section == .conflicted ? "Stage (Mark Resolved)" : "Stage") {
                performEntryAction(.stage, for: entry)
            }
            Button(role: .destructive) {
                performEntryAction(.discard, for: entry)
            } label: {
                Text("Discard Changes")
            }
        }

        Divider()

        Button("Copy Path") {
            performEntryAction(.copyPath, for: entry)
        }
        Button("Reveal in Finder") {
            performEntryAction(.revealInFinder, for: entry)
        }
    }

    private func toggleSection(_ section: GitStatusSection) {
        guard !state.entries(for: section).isEmpty else { return }
        withAnimation(.easeInOut(duration: animDuration)) {
            state.toggleSection(section)
        }
    }

    private func performSectionBulkAction(_ section: GitStatusSection) {
        guard !state.entries(for: section).isEmpty else { return }
        switch section {
        case .staged:
            encoder?.sendGitUnstageAll()
        case .changed, .untracked:
            encoder?.sendGitStageAll()
        case .conflicted:
            break
        }
    }

    private func performEntryAction(_ action: GitEntryAccessibilityAction, for offeredEntry: GitStatusEntry) {
        guard let entry = currentEntry(matching: offeredEntry) else { return }
        switch action {
        case .open:
            encoder?.sendGitOpenFile(path: entry.path)
        case .openDiff:
            encoder?.sendGitOpenDiff(path: entry.path, section: entry.section.rawValue)
        case .stage:
            encoder?.sendGitStageFile(path: entry.path)
        case .unstage:
            encoder?.sendGitUnstageFile(path: entry.path)
        case .discard:
            fileToDiscard = entry
        case .copyPath:
            copyToClipboard(entry.path)
        case .revealInFinder:
            revealInFinder(entry)
        }
    }

    private func currentEntry(matching offeredEntry: GitStatusEntry) -> GitStatusEntry? {
        state.entries(for: offeredEntry.section).first { $0.id == offeredEntry.id && $0 == offeredEntry }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func revealInFinder(_ entry: GitStatusEntry) {
        let path = fullPath(for: entry)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func fullPath(for entry: GitStatusEntry) -> String {
        guard !state.snapshot.entryBasePath.isEmpty else { return entry.path }
        return URL(fileURLWithPath: state.snapshot.entryBasePath).appendingPathComponent(entry.path).path
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
                // Amend toggle
                HStack {
                    Toggle(isOn: Binding(
                        get: { state.session.amendMode },
                        set: { state.setAmendMode($0) }
                    )) {
                        Text("Amend")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.treeMutedFg)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    Spacer()
                }

                // Commit message input with character counter
                ZStack(alignment: .topLeading) {
                    if state.session.draft.isEmpty {
                        Text("Commit message\u{2026}")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.treeDisabledFg)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                    }

                    TextEditor(text: Binding(
                        get: { state.session.draft },
                        set: { state.updateDraft($0) }
                    ))
                        .padding(.vertical, 6)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.treeFg)
                        .scrollContentBackground(.hidden)
                        .frame(height: commitMessageEditorHeight)

                    // Character counter (bottom-right)
                    charCounter
                }
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.editorBg.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(commitBorderColor, lineWidth: 1)
                        )
                )

                // Push / Pull / Fetch row
                HStack(spacing: 4) {
                    if state.snapshot.behind > 0 {
                        miniButton(systemName: "arrow.down.circle", label: "Pull \(state.snapshot.behind)") {
                            encoder?.sendGitPull()
                        }
                    }
                    if state.snapshot.ahead > 0 {
                        miniButton(systemName: "arrow.up.circle", label: "Push \(state.snapshot.ahead)") {
                            encoder?.sendGitPush()
                        }
                    }
                    miniButton(systemName: "arrow.2.circlepath", label: "Fetch") {
                        encoder?.sendGitFetch()
                    }
                    Spacer()
                }

                // Commit / Amend button
                Button {
                    guard let submission = state.submit() else { return }
                    switch submission.action {
                    case .commit:
                        encoder?.sendGitCommit(message: submission.message)
                    case .amend:
                        encoder?.sendGitCommitAmend(message: submission.message)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.session.amendMode ? "pencil" : "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text(state.session.amendMode ? "Amend" : "Commit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .foregroundStyle(commitButtonEnabled ? readableAccentForeground : theme.treeDisabledFg)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(commitButtonEnabled ? theme.accent : theme.treeFg.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!commitButtonEnabled)
                .help(commitButtonHelp)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var charCounter: some View {
        let firstLine = state.session.draft.components(separatedBy: "\n").first ?? ""
        let count = firstLine.count
        let color = subjectCountColor(count)

        if !state.session.draft.isEmpty {
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .padding(.trailing, 8)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
    }

    private func subjectCountColor(_ count: Int) -> Color {
        if count >= 72 {
            return theme.gutterErrorFg
        }
        if count >= 50 {
            return theme.gutterWarningFg
        }
        return theme.treeDisabledFg
    }

    private var commitBorderColor: Color {
        let firstLine = state.session.draft.components(separatedBy: "\n").first ?? ""
        if firstLine.count >= 72 {
            return theme.gutterErrorFg.opacity(0.5)
        } else if firstLine.count >= 50 {
            return theme.gutterWarningFg.opacity(0.5)
        }
        return theme.treeSeparatorFg
    }

    private var commitButtonEnabled: Bool {
        state.canSubmit
    }

    private var commitButtonHelp: String {
        if state.session.amendMode {
            return state.session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter a commit message"
                : "Amend the previous commit"
        }
        if state.snapshot.stagedEntries.isEmpty {
            return "Stage files before committing"
        }
        if state.session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a commit message"
        }
        return "Commit staged changes"
    }

    /// Derived locally for readable text on accent-filled controls.
    private var readableAccentForeground: Color {
        theme.treeBg
    }

    private func miniButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.treeMutedFg)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.treeFg.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toast banner

    @ViewBuilder
    private func toastBanner(message: String, level: ToastLevel, action: ToastAction) -> some View {
        HStack(spacing: 6) {
            Image(systemName: level == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(level == .success ? theme.gitAddedFg : theme.gutterErrorFg)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(theme.treeFg)
                .lineLimit(2)

            Spacer(minLength: 4)

            if action == .pullAndRetry {
                Button("Pull & Retry") {
                    encoder?.sendGitPullAndRetry()
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(level == .success
                    ? theme.gitAddedFg.opacity(0.1)
                    : theme.gutterErrorFg.opacity(0.1))
        )
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: state.snapshot.toastMessage)
    }

    // MARK: - Status formatting

    private func statusLetter(_ status: GitFileStatus) -> String {
        switch status {
        case .unknown: "•"
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
        case .unknown: theme.treeDisabledFg
        case .modified: theme.gitModifiedFg
        case .added: theme.gitAddedFg
        case .deleted: theme.gitDeletedFg
        case .renamed: theme.gitModifiedFg
        case .copied: theme.gitAddedFg
        case .untracked: theme.treeMutedFg
        case .conflicted: theme.gutterErrorFg
        }
    }

    private func statusAccessibilityLabel(_ status: GitFileStatus) -> String {
        switch status {
        case .unknown: "Unknown"
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

private enum GitEntryAccessibilityAction {
    case open
    case openDiff
    case stage
    case unstage
    case discard
    case copyPath
    case revealInFinder
}

private struct GitSectionAccessibilityActions: ViewModifier {
    let section: GitStatusSection
    let perform: (GitStatusSection) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        switch section {
        case .staged:
            content.accessibilityAction(named: Text("Unstage All")) { perform(section) }
        case .changed, .untracked:
            content.accessibilityAction(named: Text("Stage All")) { perform(section) }
        case .conflicted:
            content
        }
    }
}

private struct GitEntryAccessibilityActions: ViewModifier {
    let entry: GitStatusEntry
    let perform: (GitEntryAccessibilityAction, GitStatusEntry) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        let commonActions = content
            .accessibilityAction(named: Text("Open Diff")) { perform(.openDiff, entry) }
            .accessibilityAction(named: Text("Copy Path")) { perform(.copyPath, entry) }
            .accessibilityAction(named: Text("Reveal in Finder")) { perform(.revealInFinder, entry) }

        switch entry.section {
        case .staged:
            commonActions.accessibilityAction(named: Text("Unstage")) { perform(.unstage, entry) }
        case .changed:
            commonActions
                .accessibilityAction(named: Text("Stage")) { perform(.stage, entry) }
                .accessibilityAction(named: Text("Discard Changes")) { perform(.discard, entry) }
        case .untracked:
            commonActions
                .accessibilityAction(named: Text("Stage")) { perform(.stage, entry) }
                .accessibilityAction(named: Text("Discard Changes")) { perform(.discard, entry) }
        case .conflicted:
            commonActions
                .accessibilityAction(named: Text("Stage (Mark Resolved)")) { perform(.stage, entry) }
                .accessibilityAction(named: Text("Discard Changes")) { perform(.discard, entry) }
        }
    }
}

// MARK: - Previews

@MainActor
private func gitStatusPreviewState() -> GitStatusState {
    let state = GitStatusState()
    PreviewFixtures.populateGitStatus(state)
    return state
}

#Preview("Git Status") {
    let theme = PreviewFixtures.theme()
    GitStatusView(state: gitStatusPreviewState(), encoder: nil, usesPreviewEagerLayout: true)
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(\.themeColors, theme)
}
