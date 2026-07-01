/// Observable state for the native tool manager panel.
///
/// Driven by BEAM gui_tool_manager messages (opcode 0x7D).
/// The BEAM owns all tool data and status; this state is a pure
/// projection of what the protocol delivers.

import SwiftUI

// MARK: - Data models

public enum ToolCategory: UInt8, CaseIterable {
    case lspServer = 0
    case formatter = 1
    case linter = 2
    case debugger = 3

    public var label: String {
        switch self {
        case .lspServer: return "Language Servers"
        case .formatter: return "Formatters"
        case .linter: return "Linters"
        case .debugger: return "Debuggers"
        }
    }

    public var icon: String {
        switch self {
        case .lspServer: return "server.rack"
        case .formatter: return "text.alignleft"
        case .linter: return "exclamationmark.triangle"
        case .debugger: return "ladybug"
        }
    }
}

public enum ToolStatus: UInt8 {
    case notInstalled = 0
    case installed = 1
    case installing = 2
    case updateAvailable = 3
    case failed = 4

    public var label: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .installing: return "Installing..."
        case .updateAvailable: return "Update available"
        case .failed: return "Failed"
        }
    }
}

public enum ToolMethod: UInt8 {
    case npm = 0
    case pip = 1
    case cargo = 2
    case goInstall = 3
    case githubRelease = 4

    public var label: String {
        switch self {
        case .npm: return "npm"
        case .pip: return "pip"
        case .cargo: return "cargo"
        case .goInstall: return "go install"
        case .githubRelease: return "GitHub Release"
        }
    }

    public var icon: String {
        switch self {
        case .npm: return "shippingbox"
        case .pip: return "cube"
        case .cargo: return "gearshape.2"
        case .goInstall: return "arrow.down.circle"
        case .githubRelease: return "arrow.down.doc"
        }
    }
}

public enum ToolFilter: UInt8, CaseIterable {
    case all = 0
    case installed = 1
    case notInstalled = 2
    case lspServers = 3
    case formatters = 4

    public var label: String {
        switch self {
        case .all: return "All"
        case .installed: return "Installed"
        case .notInstalled: return "Available"
        case .lspServers: return "Servers"
        case .formatters: return "Formatters"
        }
    }
}

public struct ToolEntry: Identifiable {
    public init(id: String, name: String, label: String, description: String, category: ToolCategory, status: ToolStatus, method: ToolMethod, languages: [String], version: String, homepage: String, provides: [String], errorReason: String) {
        self.id = id
        self.name = name
        self.label = label
        self.description = description
        self.category = category
        self.status = status
        self.method = method
        self.languages = languages
        self.version = version
        self.homepage = homepage
        self.provides = provides
        self.errorReason = errorReason
    }
    public let id: String  // name atom as string
    public let name: String
    public let label: String
    public let description: String
    public let category: ToolCategory
    public let status: ToolStatus
    public let method: ToolMethod
    public let languages: [String]
    public let version: String
    public let homepage: String
    public let provides: [String]
    public let errorReason: String
}

// MARK: - Observable state

@MainActor
@Observable
public final class ToolManagerState {
    public init(visible: Bool = false, filter: ToolFilter = .all, selectedIndex: Int = 0, tools: [ToolEntry] = []) {
        self.visible = visible
        self.filter = filter
        self.selectedIndex = selectedIndex
        self.tools = tools
    }
    public var visible: Bool = false
    public var filter: ToolFilter = .all
    public var selectedIndex: Int = 0
    public var tools: [ToolEntry] = []

    public func update(
        visible: Bool,
        filter: ToolFilter,
        selectedIndex: UInt16,
        tools: [ToolEntry]
    ) {
        self.visible = visible
        self.filter = filter
        self.selectedIndex = Int(selectedIndex)
        self.tools = tools
    }

    public func hide() {
        visible = false
        tools = []
    }

    public var installedCount: Int {
        tools.filter { $0.status == .installed || $0.status == .updateAvailable }.count
    }

    public var availableCount: Int {
        tools.filter { $0.status == .notInstalled }.count
    }

    public var installingCount: Int {
        tools.filter { $0.status == .installing }.count
    }
}
