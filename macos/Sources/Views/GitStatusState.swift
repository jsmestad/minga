/// Observable git status state driven by the BEAM via gui_git_status protocol messages.

import SwiftUI

/// Git file status codes sent by the BEAM. Matches the values in
/// `lib/minga_editor/frontend/protocol/gui.ex` for the git status panel.
enum GitFileStatus: UInt8, Sendable {
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
enum GitStatusSection: UInt8, Sendable, CaseIterable {
    case staged = 0
    case changed = 1
    case untracked = 2
    case conflicted = 3

    var label: String {
        switch self {
        case .staged: "Staged Changes"
        case .changed: "Changes"
        case .untracked: "Untracked"
        case .conflicted: "Merge Conflicts"
        }
    }
}

/// A single file entry in the git status panel.
struct GitStatusEntry: Identifiable, Sendable, Equatable {
    /// Stable path hash from the BEAM. This stays stable when the entry moves between sections, which lets SwiftUI animate staged/unstaged moves.
    let pathHash: UInt32
    /// Row identity must stay unique when the same file appears in staged and unstaged sections at the same time.
    var id: UInt32 { (UInt32(section.rawValue) << 24) | (pathHash & 0x00FFFFFF) }
    let section: GitStatusSection
    let status: GitFileStatus
    /// Relative path from project root (e.g., "lib/minga/editor.ex").
    let path: String
    /// Just the filename for display (e.g., "editor.ex").
    var filename: String {
        (path as NSString).lastPathComponent
    }
    /// Parent directory for context (e.g., "lib/minga/").
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

/// The overall state of the repository for display purposes.
enum GitRepoState: UInt8, Sendable {
    case normal = 0
    case notARepo = 1
    case loading = 2
}

/// Severity level for a git toast notification.
enum ToastLevel: UInt8, Sendable {
    case success = 0
    case error = 1
}

/// Suggested recovery action for a git toast notification.
enum ToastAction: UInt8, Sendable {
    case none = 0
    case pullAndRetry = 1
}

/// Observable state for the git status sidebar panel, driven by BEAM protocol messages.
@MainActor
@Observable
final class GitStatusState {
    var visible: Bool = false
    var repoState: GitRepoState = .notARepo
    var syncing: Bool = false

    // Branch info
    var branchName: String = ""
    var ahead: UInt16 = 0
    var behind: UInt16 = 0
    var entryBasePath: String = ""

    // Toast notification (shown after remote operations)
    var toastMessage: String? = nil
    var toastLevel: ToastLevel = .success
    var toastAction: ToastAction = .none

    // File entries grouped by section
    var stagedEntries: [GitStatusEntry] = []
    var changedEntries: [GitStatusEntry] = []
    var untrackedEntries: [GitStatusEntry] = []
    var conflictedEntries: [GitStatusEntry] = []
    var duplicatePathHashes: Set<UInt32> = []

    // Section collapsed state (local UI state, not sent by BEAM)
    var collapsedSections: Set<GitStatusSection> = []

    // Commit message (local UI state, typed by the user)
    var commitMessage: String = ""
    var previousCommitMessage: String = ""

    // Amend mode (local UI state, toggled by the user)
    var amendMode: Bool = false

    // Changes whenever BEAM-provided entries update. Views use this to animate moves between sections.
    var entriesRevision: UInt64 = 0

    /// Total number of entries across all sections.
    var totalCount: Int {
        stagedEntries.count + changedEntries.count
            + untrackedEntries.count + conflictedEntries.count
    }

    /// Whether the working tree is clean (nothing to commit).
    var isClean: Bool {
        totalCount == 0 && repoState == .normal
    }

    /// Whether the commit button should be enabled.
    var canCommit: Bool {
        !stagedEntries.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Entries for a given section.
    func entries(for section: GitStatusSection) -> [GitStatusEntry] {
        switch section {
        case .staged: stagedEntries
        case .changed: changedEntries
        case .untracked: untrackedEntries
        case .conflicted: conflictedEntries
        }
    }

    /// Update from a decoded gui_git_status protocol message.
    func update(repoState: GitRepoState, branchName: String, ahead: UInt16, behind: UInt16, syncing: Bool, entries: [GitStatusEntry], toast: (String, ToastLevel, ToastAction)?, entryBasePath: String, lastCommitMessage: String) {
        self.visible = true
        self.repoState = repoState
        self.branchName = branchName
        self.ahead = ahead
        self.behind = behind
        self.syncing = syncing
        self.entryBasePath = entryBasePath
        self.previousCommitMessage = lastCommitMessage

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
    func animationID(for entry: GitStatusEntry) -> UInt32 {
        duplicatePathHashes.contains(entry.pathHash) ? entry.id : entry.pathHash
    }

    /// Hide the git status panel (BEAM toggled sidebar off or switched tab).
    func hide(syncing: Bool = false, toast: (String, ToastLevel, ToastAction)? = nil) {
        visible = false
        self.syncing = syncing
        entryBasePath = ""
        applyToast(toast)
    }

    /// Toggle amend mode and prefill the input with the last commit message when the user has not typed a message yet.
    func setAmendMode(_ enabled: Bool) {
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
