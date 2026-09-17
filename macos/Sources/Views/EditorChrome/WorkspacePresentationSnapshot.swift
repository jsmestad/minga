import MingaProtocol
import SwiftUI

enum ChromePresentationColor {
    static func color(red: UInt8, green: UInt8, blue: UInt8) -> Color {
        Color(
            .sRGB,
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }

    static func optionalColor(from rgb: UInt32) -> Color? {
        guard rgb != 0 else { return nil }
        return color(
            red: UInt8((rgb >> 16) & 0xFF),
            green: UInt8((rgb >> 8) & 0xFF),
            blue: UInt8(rgb & 0xFF)
        )
    }
}

/// Immutable UI interpretation of one canonical workspace payload.
public struct WorkspacePresentationSnapshot {
    public init(version: UInt8, activeWorkspaceId: UInt16, mode: WorkspaceViewMode, flags: WorkspaceFlags, workspaces: [Wire.WorkspaceEntry], visibleTabs: [Wire.WorkspaceTabEntry]) {
        self.version = version
        self.activeWorkspaceId = activeWorkspaceId
        self.mode = mode
        self.flags = flags
        self.workspaces = workspaces.map(WorkspacePresentationEntry.init)
        self.visibleTabs = visibleTabs.map(WorkspacePresentationTabEntry.init)
    }

    public let version: UInt8
    public let activeWorkspaceId: UInt16
    public let mode: WorkspaceViewMode
    public let flags: WorkspaceFlags
    public let workspaces: [WorkspacePresentationEntry]
    public let visibleTabs: [WorkspacePresentationTabEntry]
}

/// Shared workspace value consumed by workspace-header and tab-bar state.
public struct WorkspacePresentationEntry: Identifiable {
    public let id: UInt16
    public let kind: WorkspaceKind
    public let agentStatus: AgentStatus
    public let flags: WorkspaceEntryFlags
    public let color: Color
    public let tabCount: UInt16
    public let draftCount: UInt16
    public let conflictCount: UInt16
    public let runningBackgroundCount: UInt16
    public let label: String
    public let icon: String

    public var isManual: Bool { kind == .manual }
    public var isAgent: Bool { kind == .agent }
    public var hasAttention: Bool { flags.contains(.attention) }
    public var isCloseable: Bool { flags.contains(.closeable) }

    fileprivate init(_ entry: Wire.WorkspaceEntry) {
        id = entry.id
        kind = entry.kind
        agentStatus = entry.agentStatus
        flags = entry.flags
        color = ChromePresentationColor.color(red: entry.colorR, green: entry.colorG, blue: entry.colorB)
        tabCount = entry.tabCount
        draftCount = entry.draftCount
        conflictCount = entry.conflictCount
        runningBackgroundCount = entry.runningBackgroundCount
        label = entry.label
        icon = entry.icon
    }
}

/// Shared visible-tab value consumed by workspace-header and tab-bar state.
public struct WorkspacePresentationTabEntry: Identifiable {
    public let id: UInt32
    public let workspaceId: UInt16
    public let kind: WorkspaceTabKind
    public let flags: WorkspaceTabFlags
    public let pathHash: UInt32
    public let tintColor: Color?
    public let icon: String
    public let label: String
    public let path: String

    public var isAgent: Bool { kind == .agent }
    public var isDirty: Bool { flags.contains(.dirty) }
    public var hasAttention: Bool { flags.contains(.attention) }
    public var isDraft: Bool { flags.contains(.draft) }
    public var isDraftElsewhere: Bool { flags.contains(.draftElsewhere) }
    public var hasConflict: Bool { flags.contains(.conflict) }
    public var isPinned: Bool { flags.contains(.pinned) }
    /// File tab backed by no file on disk (for example, Untitled-1).
    public var isEphemeral: Bool { !isAgent && flags.contains(.ephemeral) }

    fileprivate init(_ entry: Wire.WorkspaceTabEntry) {
        id = entry.id
        workspaceId = entry.workspaceId
        kind = entry.kind
        flags = entry.flags
        pathHash = entry.pathHash
        tintColor = ChromePresentationColor.optionalColor(from: entry.tintColorRGB)
        icon = entry.icon
        label = entry.label
        path = entry.path
    }
}
