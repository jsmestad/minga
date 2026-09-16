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
    public init(version: UInt8, activeWorkspaceId: UInt16, mode: UInt8, flags: UInt8, workspaces: [Wire.WorkspaceEntry], visibleTabs: [Wire.WorkspaceTabEntry]) {
        self.version = version
        self.activeWorkspaceId = activeWorkspaceId
        self.mode = mode
        self.flags = flags
        self.workspaces = workspaces.map(WorkspacePresentationEntry.init)
        self.visibleTabs = visibleTabs.map(WorkspacePresentationTabEntry.init)
    }

    public let version: UInt8
    public let activeWorkspaceId: UInt16
    public let mode: UInt8
    public let flags: UInt8
    public let workspaces: [WorkspacePresentationEntry]
    public let visibleTabs: [WorkspacePresentationTabEntry]
}

/// Shared workspace value consumed by workspace-header and tab-bar state.
public struct WorkspacePresentationEntry: Identifiable {
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
    public let kind: UInt8
    public let flags: UInt16
    public let pathHash: UInt32
    public let tintColor: Color?
    public let icon: String
    public let label: String
    public let path: String

    public var isAgent: Bool { kind == 1 }
    public var isDirty: Bool { flags & 0x0001 != 0 }
    public var hasAttention: Bool { flags & 0x0002 != 0 }
    public var isDraft: Bool { flags & 0x0004 != 0 }
    public var isDraftElsewhere: Bool { flags & 0x0008 != 0 }
    public var hasConflict: Bool { flags & 0x0010 != 0 }
    public var isPinned: Bool { flags & 0x0020 != 0 }
    /// File tab backed by no file on disk (for example, Untitled-1).
    public var isEphemeral: Bool { !isAgent && flags & 0x0040 != 0 }

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
