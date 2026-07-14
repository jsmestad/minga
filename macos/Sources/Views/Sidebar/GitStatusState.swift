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

/// Observable state for the git status sidebar panel, driven by BEAM protocol messages.
@MainActor
@Observable
public final class GitStatusState {
    public init(visible: Bool = false, repoState: GitRepoState = .notARepo, syncing: Bool = false, branchName: String = "", ahead: UInt16 = 0, behind: UInt16 = 0, entryBasePath: String = "", stashCount: UInt16 = 0, toastMessage: String? = nil, toastLevel: ToastLevel = .success, toastAction: ToastAction = .none, stagedEntries: [GitStatusEntry] = [], changedEntries: [GitStatusEntry] = [], untrackedEntries: [GitStatusEntry] = [], conflictedEntries: [GitStatusEntry] = [], duplicatePathHashes: Set<UInt32> = [], collapsedSections: Set<GitStatusSection> = [], commitMessage: String = "", previousCommitMessage: String = "", amendMode: Bool = false, entriesRevision: UInt64 = 0) {
        self.visible = visible
        self.repoState = repoState
        self.syncing = syncing
        self.branchName = branchName
        self.ahead = ahead
        self.behind = behind
        self.entryBasePath = entryBasePath
        self.stashCount = stashCount
        self.toastMessage = toastMessage
        self.toastLevel = toastLevel
        self.toastAction = toastAction
        self.stagedEntries = stagedEntries
        self.changedEntries = changedEntries
        self.untrackedEntries = untrackedEntries
        self.conflictedEntries = conflictedEntries
        self.duplicatePathHashes = duplicatePathHashes
        self.collapsedSections = collapsedSections
        self.commitMessage = commitMessage
        self.previousCommitMessage = previousCommitMessage
        self.amendMode = amendMode
        self.entriesRevision = entriesRevision
    }
    public var visible: Bool = false
    public var repoState: GitRepoState = .notARepo
    public var syncing: Bool = false

    // Branch info
    public var branchName: String = ""
    public var ahead: UInt16 = 0
    public var behind: UInt16 = 0
    public var entryBasePath: String = ""
    public var stashCount: UInt16 = 0

    // Toast notification (shown after remote operations)
    public var toastMessage: String? = nil
    public var toastLevel: ToastLevel = .success
    public var toastAction: ToastAction = .none

    // File entries grouped by section
    public var stagedEntries: [GitStatusEntry] = []
    public var changedEntries: [GitStatusEntry] = []
    public var untrackedEntries: [GitStatusEntry] = []
    public var conflictedEntries: [GitStatusEntry] = []
    public var duplicatePathHashes: Set<UInt32> = []

    // Section collapsed state (local UI state, not sent by BEAM)
    public var collapsedSections: Set<GitStatusSection> = []

    // Commit message (local UI state, typed by the user)
    public var commitMessage: String = ""
    public var previousCommitMessage: String = ""

    // Amend mode (local UI state, toggled by the user)
    public var amendMode: Bool = false

    // Changes whenever BEAM-provided entries update. Views use this to animate moves between sections.
    public var entriesRevision: UInt64 = 0

    /// Total number of entries across all sections.
    public var totalCount: Int {
        stagedEntries.count + changedEntries.count
            + untrackedEntries.count + conflictedEntries.count
    }

    /// Whether the working tree is clean (nothing to commit).
    public var isClean: Bool {
        totalCount == 0 && repoState == .normal
    }

    /// Whether the commit button should be enabled.
    public var canCommit: Bool {
        !stagedEntries.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Entries for a given section.
    public func entries(for section: GitStatusSection) -> [GitStatusEntry] {
        switch section {
        case .staged: stagedEntries
        case .changed: changedEntries
        case .untracked: untrackedEntries
        case .conflicted: conflictedEntries
        }
    }

    /// Update from a decoded gui_git_status protocol message.
    public func update(repoState: GitRepoState, branchName: String, ahead: UInt16, behind: UInt16, syncing: Bool, entries: [GitStatusEntry], toast: (String, ToastLevel, ToastAction)?, entryBasePath: String, lastCommitMessage: String, stashCount: UInt16) {
        self.visible = true
        self.repoState = repoState
        self.branchName = branchName
        self.ahead = ahead
        self.behind = behind
        self.syncing = syncing
        self.entryBasePath = entryBasePath
        self.previousCommitMessage = lastCommitMessage
        self.stashCount = stashCount

        // Partition entries by section in a single pass.
        var staged: [GitStatusEntry] = []
        var changed: [GitStatusEntry] = []
        var untracked: [GitStatusEntry] = []
        var conflicted: [GitStatusEntry] = []

        for entry in entries {
            switch entry.section {
            case .staged: staged.append(entry)
            case .changed: changed.append(entry)
            case .untracked: untracked.append(entry)
            case .conflicted: conflicted.append(entry)
            }
        }

        self.stagedEntries = staged
        self.changedEntries = changed
        self.untrackedEntries = untracked
        self.conflictedEntries = conflicted
        self.duplicatePathHashes = duplicateHashes(in: entries)
        self.entriesRevision &+= 1
        applyToast(toast)
    }

    /// Matched-geometry identity for section moves. Falls back to row identity when the same path appears in multiple sections at once.
    public func animationID(for entry: GitStatusEntry) -> UInt32 {
        duplicatePathHashes.contains(entry.pathHash) ? entry.id : entry.pathHash
    }

    /// Hide the git status panel (BEAM toggled sidebar off or switched tab).
    public func hide(syncing: Bool = false, toast: (String, ToastLevel, ToastAction)? = nil) {
        visible = false
        self.syncing = syncing
        entryBasePath = ""
        stashCount = 0
        applyToast(toast)
    }

    /// Toggle amend mode and prefill the input with the last commit message when the user has not typed a message yet.
    public func setAmendMode(_ enabled: Bool) {
        guard amendMode != enabled else { return }
        amendMode = enabled
        if enabled && commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessage = previousCommitMessage
        }
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

    private func applyToast(_ toast: (String, ToastLevel, ToastAction)?) {
        if let (msg, level, action) = toast {
            self.toastMessage = msg
            self.toastLevel = level
            self.toastAction = action
        } else {
            self.toastMessage = nil
            self.toastLevel = .success
            self.toastAction = .none
        }
    }
}
