import SwiftUI

/// A workspace summary for native workspace chrome.
struct WorkspaceSummaryEntry: Identifiable {
    let id: UInt16
    let kind: UInt8
    let agentStatus: UInt8
    let flags: UInt16
    let color: Color
    let tabCount: UInt16
    let draftCount: UInt16
    let conflictCount: UInt16
    let runningBackgroundCount: UInt16
    let label: String
    let icon: String

    var isManual: Bool { kind == 0 }
    var isAgent: Bool { kind == 1 }
    var hasAttention: Bool { flags & 0x0001 != 0 }
    var isCloseable: Bool { flags & 0x0002 != 0 }
}

/// A visible file tab for the active workspace.
struct WorkspaceFileTabEntry: Identifiable {
    let id: UInt32
    let workspaceId: UInt16
    let kind: UInt8
    let flags: UInt16
    let pathHash: UInt32
    let icon: String
    let label: String
    let path: String

    var isDirty: Bool { flags & 0x0001 != 0 }
    var hasAttention: Bool { flags & 0x0002 != 0 }
    var isDraft: Bool { flags & 0x0004 != 0 }
    var isDraftElsewhere: Bool { flags & 0x0008 != 0 }
    var hasConflict: Bool { flags & 0x0010 != 0 }
}

/// Observable state for the workspace header and active-workspace file tabs.
@MainActor
@Observable
final class WorkspaceState {
    var workspaces: [WorkspaceSummaryEntry] = []
    var visibleTabs: [WorkspaceFileTabEntry] = []
    var activeWorkspaceId: UInt16 = 0
    var viewMode: UInt8 = 0
    var flags: UInt8 = 0
    var hasCanonicalPayload: Bool = false

    var activeWorkspace: WorkspaceSummaryEntry? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    var hasAttention: Bool {
        flags & 0x01 != 0 || workspaces.contains(where: { $0.hasAttention })
    }

    var backgroundWorkspaces: [WorkspaceSummaryEntry] {
        workspaces.filter { $0.id != activeWorkspaceId }
    }

    var backgroundRunningCount: Int {
        backgroundWorkspaces.reduce(0) { $0 + Int($1.runningBackgroundCount) }
    }

    var backgroundDraftCount: Int {
        backgroundWorkspaces.reduce(0) { $0 + Int($1.draftCount) }
    }

    var backgroundConflictCount: Int {
        backgroundWorkspaces.reduce(0) { $0 + Int($1.conflictCount) }
    }

    var backgroundAttentionCount: Int {
        backgroundWorkspaces.filter { $0.hasAttention }.count
    }

    var backgroundErrorCount: Int {
        backgroundWorkspaces.filter { $0.agentStatus == 3 }.count
    }

    func update(version: UInt8, activeWorkspaceId: UInt16, mode: UInt8, flags: UInt8, workspaces: [Wire.WorkspaceEntry], visibleTabs: [Wire.WorkspaceTabEntry]) {
        self.activeWorkspaceId = activeWorkspaceId
        self.viewMode = mode
        self.flags = flags
        self.hasCanonicalPayload = version > 0
        self.workspaces = workspaces.map { entry in
            WorkspaceSummaryEntry(
                id: entry.id,
                kind: entry.kind,
                agentStatus: entry.agentStatus,
                flags: entry.flags,
                color: Color(
                    .sRGB,
                    red: Double(entry.colorR) / 255.0,
                    green: Double(entry.colorG) / 255.0,
                    blue: Double(entry.colorB) / 255.0
                ),
                tabCount: entry.tabCount,
                draftCount: entry.draftCount,
                conflictCount: entry.conflictCount,
                runningBackgroundCount: entry.runningBackgroundCount,
                label: entry.label,
                icon: entry.icon
            )
        }
        self.visibleTabs = visibleTabs.map { entry in
            WorkspaceFileTabEntry(
                id: entry.id,
                workspaceId: entry.workspaceId,
                kind: entry.kind,
                flags: entry.flags,
                pathHash: entry.pathHash,
                icon: entry.icon,
                label: entry.label,
                path: entry.path
            )
        }
    }

    func switchCommand(for workspace: WorkspaceSummaryEntry) -> String {
        if workspace.isManual { return "manual_workspace" }

        let agentWorkspaces = workspaces.filter { $0.isAgent }
        guard let idx = agentWorkspaces.firstIndex(where: { $0.id == workspace.id }), idx < 9 else {
            return "workspace_next_agent"
        }
        return "workspace_goto_\(idx + 1)"
    }

    func hide() {
        workspaces = []
        visibleTabs = []
        activeWorkspaceId = 0
        viewMode = 0
        flags = 0
        hasCanonicalPayload = false
    }
}
