/// Observable state for the native tool manager panel.
///
/// Driven by BEAM gui_tool_manager messages (opcode 0x7D).
/// The BEAM owns all tool data and status; this state is a pure
/// projection of what the protocol delivers.

import SwiftUI

// MARK: - Data models

enum ToolCategory: UInt8, CaseIterable {
    case lspServer = 0
    case formatter = 1
    case linter = 2
    case debugger = 3

    var label: String {
        switch self {
        case .lspServer: return "Language Servers"
        case .formatter: return "Formatters"
        case .linter: return "Linters"
        case .debugger: return "Debuggers"
        }
    }

    var icon: String {
        switch self {
        case .lspServer: return "server.rack"
        case .formatter: return "text.alignleft"
        case .linter: return "exclamationmark.triangle"
        case .debugger: return "ladybug"
        }
    }
}

enum ToolStatus: UInt8 {
    case notInstalled = 0
    case installed = 1
    case installing = 2
    case updateAvailable = 3

    var label: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .installing: return "Installing..."
        case .updateAvailable: return "Update available"
        }
    }
}

enum ToolMethod: UInt8 {
    case npm = 0
    case pip = 1
    case cargo = 2
    case goInstall = 3
    case githubRelease = 4

    var label: String {
        switch self {
        case .npm: return "npm"
        case .pip: return "pip"
        case .cargo: return "cargo"
        case .goInstall: return "go install"
        case .githubRelease: return "GitHub Release"
        }
    }

    var icon: String {
        switch self {
        case .npm: return "shippingbox"
        case .pip: return "cube"
        case .cargo: return "gearshape.2"
        case .goInstall: return "arrow.down.circle"
        case .githubRelease: return "arrow.down.doc"
        }
    }
}

enum ToolFilter: UInt8, CaseIterable {
    case all = 0
    case installed = 1
    case notInstalled = 2
    case lspServers = 3
    case formatters = 4

    var label: String {
        switch self {
        case .all: return "All"
        case .installed: return "Installed"
        case .notInstalled: return "Available"
        case .lspServers: return "Servers"
        case .formatters: return "Formatters"
        }
    }
}

struct ToolEntry: Identifiable {
    let id: String  // name atom as string
    let name: String
    let label: String
    let description: String
    let category: ToolCategory
    let status: ToolStatus
    let method: ToolMethod
    let languages: [String]
    let version: String
    let homepage: String
    let provides: [String]
}

// MARK: - Observable state

@MainActor
@Observable
final class ToolManagerState {
    var visible: Bool = false
    var filter: ToolFilter = .all
    var selectedIndex: Int = 0
    var tools: [ToolEntry] = []

    func update(
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

    func hide() {
        visible = false
        tools = []
    }

    var installedCount: Int {
        tools.filter { $0.status == .installed || $0.status == .updateAvailable }.count
    }

    var availableCount: Int {
        tools.filter { $0.status == .notInstalled }.count
    }

    var installingCount: Int {
        tools.filter { $0.status == .installing }.count
    }
}
