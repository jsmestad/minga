import SwiftUI
import MingaProtocol

/// A workspace summary for native workspace chrome.
public struct WorkspaceSummaryEntry: Identifiable {
    public init(id: UInt16, kind: UInt8, agentStatus: UInt8, flags: UInt16, color: Color, tabCount: UInt16, draftCount: UInt16, conflictCount: UInt16, runningBackgroundCount: UInt16, label: String, icon: String) {
        self.id = id
        self.kind = kind
        self.agentStatus = agentStatus
        self.flags = flags
        self.color = color
        self.tabCount = tabCount
        self.draftCount = draftCount
        self.conflictCount = conflictCount
        self.runningBackgroundCount = runningBackgroundCount
        self.label = label
        self.icon = icon
    }
    public let id: UInt16
    public let kind: UInt8
    public let agentStatus: UInt8
    public let flags: UInt16
    public let color: Color
    public let tabCount: UInt16
    public let draftCount: UInt16
    public let conflictCount: UInt16
    public let runningBackgroundCount: UInt16
    public let label: String
    public let icon: String

    public var isManual: Bool { kind == 0 }
    public var isAgent: Bool { kind == 1 }
    public var hasAttention: Bool { flags & 0x0001 != 0 }
    public var isCloseable: Bool { flags & 0x0002 != 0 }
}

/// A visible file tab for the active workspace.
public struct WorkspaceFileTabEntry: Identifiable {
    public init(id: UInt32, workspaceId: UInt16, kind: UInt8, flags: UInt16, pathHash: UInt32, icon: String, label: String, path: String) {
        self.id = id
        self.workspaceId = workspaceId
        self.kind = kind
        self.flags = flags
        self.pathHash = pathHash
        self.icon = icon
        self.label = label
        self.path = path
    }
    public let id: UInt32
    public let workspaceId: UInt16
    public let kind: UInt8
    public let flags: UInt16
    public let pathHash: UInt32
    public let icon: String
    public let label: String
    public let path: String

    public var isDirty: Bool { flags & 0x0001 != 0 }
    public var hasAttention: Bool { flags & 0x0002 != 0 }
    public var isDraft: Bool { flags & 0x0004 != 0 }
    public var isDraftElsewhere: Bool { flags & 0x0008 != 0 }
    public var hasConflict: Bool { flags & 0x0010 != 0 }
}

/// Observable state for the workspace header and active-workspace file tabs.
@MainActor
@Observable
public final class WorkspaceState {
    public init(workspaces: [WorkspaceSummaryEntry] = [], visibleTabs: [WorkspaceFileTabEntry] = [], activeWorkspaceId: UInt16 = 0, viewMode: UInt8 = 0, flags: UInt8 = 0, hasCanonicalPayload: Bool = false) {
        self.workspaces = workspaces
        self.visibleTabs = visibleTabs
        self.activeWorkspaceId = activeWorkspaceId
        self.viewMode = viewMode
        self.flags = flags
        self.hasCanonicalPayload = hasCanonicalPayload
    }
    public var workspaces: [WorkspaceSummaryEntry] = []
    public var visibleTabs: [WorkspaceFileTabEntry] = []
    public var activeWorkspaceId: UInt16 = 0
    public var viewMode: UInt8 = 0
    public var flags: UInt8 = 0
    public var hasCanonicalPayload: Bool = false

    public var activeWorkspace: WorkspaceSummaryEntry? {
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

    public var backgroundWorkspaces: [WorkspaceSummaryEntry] {
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

    public func update(version: UInt8, activeWorkspaceId: UInt16, mode: UInt8, flags: UInt8, workspaces: [Wire.WorkspaceEntry], visibleTabs: [Wire.WorkspaceTabEntry]) {
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

    public func switchCommand(for workspace: WorkspaceSummaryEntry) -> String {
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
