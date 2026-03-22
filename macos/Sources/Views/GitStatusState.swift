/// Observable git status state driven by the BEAM via gui_git_status protocol messages.

import SwiftUI

/// Git file status codes sent by the BEAM. Matches the values in
/// `lib/minga/port/protocol/gui.ex` for the git status panel.
enum GitFileStatus: UInt8, Sendable {
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
struct GitStatusEntry: Identifiable, Sendable {
    /// Stable ID: section byte << 24 | hash of path. Avoids SwiftUI
    /// treating every update as a full re-render.
    let id: UInt32
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

/// Observable state for the git status sidebar panel, driven by BEAM protocol messages.
@MainActor
@Observable
final class GitStatusState {
    var visible: Bool = false
    var repoState: GitRepoState = .notARepo

    // Branch info
    var branchName: String = ""
    var ahead: UInt16 = 0
    var behind: UInt16 = 0

    // File entries grouped by section
    var stagedEntries: [GitStatusEntry] = []
    var changedEntries: [GitStatusEntry] = []
    var untrackedEntries: [GitStatusEntry] = []
    var conflictedEntries: [GitStatusEntry] = []

    // Section collapsed state (local UI state, not sent by BEAM)
    var collapsedSections: Set<GitStatusSection> = []

    // Commit message (local UI state, typed by the user)
    var commitMessage: String = ""

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
    func update(repoState: GitRepoState, branchName: String, ahead: UInt16, behind: UInt16, entries: [GitStatusEntry]) {
        self.visible = true
        self.repoState = repoState
        self.branchName = branchName
        self.ahead = ahead
        self.behind = behind

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
    }

    /// Hide the git status panel (BEAM toggled sidebar off or switched tab).
    func hide() {
        visible = false
    }
}
