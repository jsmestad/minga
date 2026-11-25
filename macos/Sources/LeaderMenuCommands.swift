import SwiftUI
import MingaProtocol
import MingaUI

/// Declares the leader mirror in the menu bar. Search, Code and Git appear once the BEAM has sent their items.
///
/// Like `MingaMenuCommands`, it reads the app state in its body, so SwiftUI re-runs it when the items or the
/// connection change.
struct LeaderMenuCommands: Commands {
    let appState: AppState

    private var state: MenuBarState { appState.gui.menuBarState }
    private var connected: Bool { appState.encoder != nil }

    private func send(_ command: String) {
        appState.encoder?.send(.executeCommand(name: command))
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) { items(.app) }
        CommandGroup(after: .saveItem) { items(.file) }
        CommandGroup(after: .toolbar) { items(.view) }
        CommandGroup(after: .windowArrangement) { items(.window) }
        CommandGroup(after: .help) { items(.help) }
        if !state.nodes(.search).isEmpty { CommandMenu("Search") { items(.search) } }
        if !state.nodes(.code).isEmpty { CommandMenu("Code") { items(.code) } }
        if !state.nodes(.git).isEmpty { CommandMenu("Git") { items(.git) } }
    }

    private func items(_ host: LeaderMenu.Host) -> LeaderMenuItems {
        let nodes = state.nodes(host)
        return LeaderMenuItems(nodes: nodes, startsWithDivider: host.joinsSystemMenu && !nodes.isEmpty,
                               connected: connected, send: send)
    }
}
