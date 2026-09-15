/// Observable git status state driven by the BEAM via gui_git_status protocol messages.

import SwiftUI

/// Git file status codes sent by the BEAM. Matches the values in
/// `lib/minga_editor/frontend/protocol/gui.ex` for the git status panel.
public enum GitFileStatus: UInt8, Sendable {
    case unknown = 0
    case modified = 1
    case added = 2
    case deleted = 3
    case renamed = 4
    case copied = 5
    case untracked = 6
    case conflicted = 7
}

/// Which section a file entry belongs to.
public enum GitStatusSection: UInt8, Sendable, CaseIterable {
    case staged = 0
    case changed = 1
    case untracked = 2
    case conflicted = 3

    public var label: String {
        switch self {
        case .staged: "Staged Changes"
        case .changed: "Changes"
        case .untracked: "Untracked"
        case .conflicted: "Merge Conflicts"
        }
    }
}

/// A single file entry in the git status panel.
public struct GitStatusEntry: Identifiable, Sendable, Equatable {
    public init(pathHash: UInt32, section: GitStatusSection, status: GitFileStatus, path: String) {
        self.pathHash = pathHash
        self.section = section
        self.status = status
        self.path = path
    }
    /// Stable path hash from the BEAM. This stays stable when the entry moves between sections, which lets SwiftUI animate staged/unstaged moves.
    public let pathHash: UInt32
    /// Row identity must stay unique when the same file appears in staged and unstaged sections at the same time.
    public var id: UInt32 { (UInt32(section.rawValue) << 24) | (pathHash & 0x00FFFFFF) }
    public let section: GitStatusSection
    public let status: GitFileStatus
    /// Relative path from project root (e.g., "lib/minga/editor.ex").
    public let path: String
    /// Just the filename for display (e.g., "editor.ex").
    public var filename: String {
        (path as NSString).lastPathComponent
    }
    /// Parent directory for context (e.g., "lib/minga/").
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

/// The overall state of the repository for display purposes.
public enum GitRepoState: UInt8, Sendable {
    case normal = 0
    case notARepo = 1
    case loading = 2
}

/// Severity level for a git toast notification.
public enum ToastLevel: UInt8, Sendable {
    case success = 0
    case error = 1
}

/// Suggested recovery action for a git toast notification.
public enum ToastAction: UInt8, Sendable {
    case none = 0
    case pullAndRetry = 1
}

/// Published file entries and the revision used to animate section changes.
fileprivate struct GitStatusEntriesSnapshot: Sendable, Equatable {
    init() {}

    private(set) var staged: [GitStatusEntry] = []
    private(set) var changed: [GitStatusEntry] = []
    private(set) var untracked: [GitStatusEntry] = []
    private(set) var conflicted: [GitStatusEntry] = []
    private(set) var revision: UInt64 = 0
    private var duplicatePathHashes: Set<UInt32> = []

    fileprivate func installing(_ entries: [GitStatusEntry]) -> Self {
        var updated = self
        updated.staged = []
        updated.changed = []
        updated.untracked = []
        updated.conflicted = []

        for entry in entries {
            switch entry.section {
            case .staged: updated.staged.append(entry)
            case .changed: updated.changed.append(entry)
            case .untracked: updated.untracked.append(entry)
            case .conflicted: updated.conflicted.append(entry)
            }
        }

        updated.duplicatePathHashes = updated.duplicateHashes(in: entries)
        updated.revision &+= 1
        return updated
    }

    fileprivate func entries(for section: GitStatusSection) -> [GitStatusEntry] {
        switch section {
        case .staged: staged
        case .changed: changed
        case .untracked: untracked
        case .conflicted: conflicted
        }
    }

    fileprivate func animationID(for entry: GitStatusEntry) -> UInt32 {
        duplicatePathHashes.contains(entry.pathHash) ? entry.id : entry.pathHash
    }

    private func duplicateHashes(in entries: [GitStatusEntry]) -> Set<UInt32> {
        var seen = Set<UInt32>()
        var duplicates = Set<UInt32>()

        for entry in entries {
            if seen.contains(entry.pathHash) {
                duplicates.insert(entry.pathHash)
            } else {
                seen.insert(entry.pathHash)
            }
        }

        return duplicates
    }
}

/// Repository facts published by the BEAM for the Git status presentation.
public struct GitStatusSnapshot: Sendable, Equatable {
    public init() {}

    public fileprivate(set) var visible: Bool = false
    public fileprivate(set) var repoState: GitRepoState = .notARepo
    public fileprivate(set) var syncing: Bool = false
    public fileprivate(set) var branchName: String = ""
    public fileprivate(set) var ahead: UInt16 = 0
    public fileprivate(set) var behind: UInt16 = 0
    public fileprivate(set) var entryBasePath: String = ""
    public fileprivate(set) var stashCount: UInt16 = 0
    public fileprivate(set) var toastMessage: String? = nil
    public fileprivate(set) var toastLevel: ToastLevel = .success
    public fileprivate(set) var toastAction: ToastAction = .none
    public fileprivate(set) var lastCommitMessage: String = ""
    fileprivate var entryGroups = GitStatusEntriesSnapshot()

    public var stagedEntries: [GitStatusEntry] { entryGroups.staged }
    public var changedEntries: [GitStatusEntry] { entryGroups.changed }
    public var untrackedEntries: [GitStatusEntry] { entryGroups.untracked }
    public var conflictedEntries: [GitStatusEntry] { entryGroups.conflicted }

    /// Changes whenever BEAM-provided entries update. Views use this to animate moves between sections.
    public var entriesRevision: UInt64 { entryGroups.revision }

    /// Total number of entries across all sections.
    public var totalCount: Int {
        stagedEntries.count + changedEntries.count + untrackedEntries.count + conflictedEntries.count
    }

    /// Whether the working tree is clean.
    public var isClean: Bool {
        totalCount == 0 && repoState == .normal
    }

    /// Entries for a given section.
    public func entries(for section: GitStatusSection) -> [GitStatusEntry] {
        entryGroups.entries(for: section)
    }

    /// Matched-geometry identity for section moves. Falls back to row identity when the same path appears in multiple sections at once.
    public func animationID(for entry: GitStatusEntry) -> UInt32 {
        entryGroups.animationID(for: entry)
    }

    fileprivate func updating(repoState: GitRepoState, branchName: String, ahead: UInt16, behind: UInt16, syncing: Bool, entries: [GitStatusEntry], toast: (String, ToastLevel, ToastAction)?, entryBasePath: String, lastCommitMessage: String, stashCount: UInt16) -> Self {
        var updated = self
        updated.visible = true
        updated.repoState = repoState
        updated.branchName = branchName
        updated.ahead = ahead
        updated.behind = behind
        updated.syncing = syncing
        updated.entryBasePath = entryBasePath
        updated.lastCommitMessage = lastCommitMessage
        updated.stashCount = stashCount
        updated.entryGroups = entryGroups.installing(entries)
        updated.applyToast(toast)
        return updated
    }

    fileprivate func hiding(syncing: Bool, toast: (String, ToastLevel, ToastAction)?) -> Self {
        var updated = self
        updated.visible = false
        updated.syncing = syncing
        updated.entryBasePath = ""
        updated.stashCount = 0
        updated.applyToast(toast)
        return updated
    }

    private mutating func applyToast(_ toast: (String, ToastLevel, ToastAction)?) {
        if let (message, level, action) = toast {
            toastMessage = message
            toastLevel = level
            toastAction = action
        } else {
            toastMessage = nil
            toastLevel = .success
            toastAction = .none
        }
    }
}

/// The kind of commit operation captured from the local Git status session.
public enum GitCommitAction: Sendable, Equatable {
    case commit
    case amend
}

/// A complete commit request captured before the local draft resets.
public struct GitCommitSubmission: Sendable, Equatable {
    public init(action: GitCommitAction, message: String) {
        self.action = action
        self.message = message
    }

    public let action: GitCommitAction
    public let message: String
}

/// Local Git sidebar editing and interaction state that survives BEAM refreshes and view reconstruction.
public struct GitStatusSession: Sendable, Equatable {
    public init() {}

    public fileprivate(set) var draft: String = ""
    public fileprivate(set) var amendMode: Bool = false
    public fileprivate(set) var collapsedSections: Set<GitStatusSection> = []

    fileprivate func updatingDraft(_ draft: String) -> Self {
        var updated = self
        updated.draft = draft
        return updated
    }

    fileprivate func settingAmendMode(_ enabled: Bool, lastCommitMessage: String) -> Self {
        guard amendMode != enabled else { return self }
        var updated = self
        updated.amendMode = enabled
        if enabled && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.draft = lastCommitMessage
        }
        return updated
    }

    fileprivate func togglingSection(_ section: GitStatusSection) -> Self {
        var updated = self
        if updated.collapsedSections.contains(section) {
            updated.collapsedSections.remove(section)
        } else {
            updated.collapsedSections.insert(section)
        }
        return updated
    }

    fileprivate func takingSubmission(hasStagedChanges: Bool) -> (GitCommitSubmission?, Self) {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return (nil, self) }
        guard amendMode || hasStagedChanges else { return (nil, self) }

        let action: GitCommitAction = amendMode ? .amend : .commit
        var updated = self
        updated.draft = ""
        updated.amendMode = false
        return (GitCommitSubmission(action: action, message: message), updated)
    }
}

/// Stable presentation owner for BEAM-published Git status and the local Git sidebar session.
@MainActor
@Observable
public final class GitStatusState {
    public init(snapshot: GitStatusSnapshot = GitStatusSnapshot(), session: GitStatusSession = GitStatusSession()) {
        self.snapshot = snapshot
        self.session = session
    }

    /// The latest repository status published by the BEAM.
    public private(set) var snapshot: GitStatusSnapshot

    /// Local editing and section interaction state.
    public private(set) var session: GitStatusSession

    /// Total number of entries across all sections.
    public var totalCount: Int {
        snapshot.totalCount
    }

    /// Whether the working tree is clean (nothing to commit).
    public var isClean: Bool {
        snapshot.isClean
    }

    /// Whether the commit button should be enabled.
    public var canSubmit: Bool {
        let hasMessage = !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return session.amendMode ? hasMessage : !snapshot.stagedEntries.isEmpty && hasMessage
    }

    /// Entries for a given section.
    public func entries(for section: GitStatusSection) -> [GitStatusEntry] {
        snapshot.entries(for: section)
    }

    /// Update from a decoded gui_git_status protocol message.
    public func update(repoState: GitRepoState, branchName: String, ahead: UInt16, behind: UInt16, syncing: Bool, entries: [GitStatusEntry], toast: (String, ToastLevel, ToastAction)?, entryBasePath: String, lastCommitMessage: String, stashCount: UInt16) {
        snapshot = snapshot.updating(repoState: repoState, branchName: branchName, ahead: ahead, behind: behind, syncing: syncing, entries: entries, toast: toast, entryBasePath: entryBasePath, lastCommitMessage: lastCommitMessage, stashCount: stashCount)
    }

    /// Matched-geometry identity for section moves. Falls back to row identity when the same path appears in multiple sections at once.
    public func animationID(for entry: GitStatusEntry) -> UInt32 {
        snapshot.animationID(for: entry)
    }

    /// Hide the git status panel (BEAM toggled sidebar off or switched tab).
    public func hide(syncing: Bool = false, toast: (String, ToastLevel, ToastAction)? = nil) {
        snapshot = snapshot.hiding(syncing: syncing, toast: toast)
    }

    /// Replace the current local commit draft.
    public func updateDraft(_ draft: String) {
        session = session.updatingDraft(draft)
    }

    /// Toggle amend mode and prefill the input with the last commit message when the user has not typed a message yet.
    public func setAmendMode(_ enabled: Bool) {
        session = session.settingAmendMode(enabled, lastCommitMessage: snapshot.lastCommitMessage)
    }

    /// Toggle one file section's collapsed state.
    public func toggleSection(_ section: GitStatusSection) {
        session = session.togglingSection(section)
    }

    /// Capture the current commit action and trimmed message, then reset the draft and amend mode immediately.
    public func submit() -> GitCommitSubmission? {
        let (submission, updatedSession) = session.takingSubmission(hasStagedChanges: !snapshot.stagedEntries.isEmpty)
        session = updatedSession
        return submission
    }
}
