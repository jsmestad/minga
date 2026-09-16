import SwiftUI

/// Observable state for the workspace header and active-workspace file tabs.
@MainActor
@Observable
public final class WorkspaceState {
    public init(workspaces: [WorkspacePresentationEntry] = [], visibleTabs: [WorkspacePresentationTabEntry] = [], activeWorkspaceId: UInt16 = 0, viewMode: UInt8 = 0, flags: UInt8 = 0, hasCanonicalPayload: Bool = false) {
        self.workspaces = workspaces
        self.visibleTabs = visibleTabs
        self.activeWorkspaceId = activeWorkspaceId
        self.viewMode = viewMode
        self.flags = flags
        self.hasCanonicalPayload = hasCanonicalPayload
    }
    public var workspaces: [WorkspacePresentationEntry] = []
    public var visibleTabs: [WorkspacePresentationTabEntry] = []
    public var activeWorkspaceId: UInt16 = 0
    public var viewMode: UInt8 = 0
    public var flags: UInt8 = 0
    public var hasCanonicalPayload: Bool = false

    public var activeWorkspace: WorkspacePresentationEntry? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    public var hasAttention: Bool {
        flags & 0x01 != 0 || workspaces.contains(where: { $0.hasAttention })
    }

    public var shouldShowHeader: Bool {
        guard hasCanonicalPayload else { return false }
        guard let activeWorkspace else { return false }

        return workspaces.count > 1 ||
            activeWorkspace.isAgent ||
            activeWorkspace.isCloseable ||
            activeWorkspace.hasAttention ||
            activeWorkspace.draftCount > 0 ||
            activeWorkspace.conflictCount > 0 ||
            activeWorkspace.runningBackgroundCount > 0 ||
            backgroundRunningCount > 0 ||
            backgroundDraftCount > 0 ||
            backgroundConflictCount > 0 ||
            backgroundAttentionCount > 0 ||
            backgroundErrorCount > 0
    }

    public var backgroundWorkspaces: [WorkspacePresentationEntry] {
        workspaces.filter { $0.id != activeWorkspaceId }
    }

    public var backgroundRunningCount: Int {
        backgroundWorkspaces.reduce(0) { $0 + Int($1.runningBackgroundCount) }
    }

    public var backgroundDraftCount: Int {
        backgroundWorkspaces.reduce(0) { $0 + Int($1.draftCount) }
    }

    public var backgroundConflictCount: Int {
        backgroundWorkspaces.reduce(0) { $0 + Int($1.conflictCount) }
    }

    public var backgroundAttentionCount: Int {
        backgroundWorkspaces.filter { $0.hasAttention }.count
    }

    public var backgroundErrorCount: Int {
        backgroundWorkspaces.filter { $0.agentStatus == 3 }.count
    }

    public func install(_ snapshot: WorkspacePresentationSnapshot) {
        activeWorkspaceId = snapshot.activeWorkspaceId
        viewMode = snapshot.mode
        flags = snapshot.flags
        hasCanonicalPayload = snapshot.version > 0
        workspaces = snapshot.workspaces
        visibleTabs = snapshot.visibleTabs
    }

    public func switchCommand(for workspace: WorkspacePresentationEntry) -> String {
        "workspace_goto_id:\(workspace.id)"
    }

    public func hide() {
        workspaces = []
        visibleTabs = []
        activeWorkspaceId = 0
        viewMode = 0
        flags = 0
        hasCanonicalPayload = false
    }
}
