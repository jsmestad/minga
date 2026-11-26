/// The leader keymap the macOS menu bar mirrors, driven by BEAM gui_menu_bar messages.
///
/// `LeaderMenuCommands` declares it in the menu bar; the which-key panel reads the same keymap in the same order, so
/// the two cannot drift (docs/design/surfaces.md, Mouse). The tree is built once per update, never in a `Commands`
/// body, which SwiftUI re-runs on every observed change.

import Foundation
import MingaProtocol
import Observation

@MainActor
@Observable
public final class MenuBarState {
    public init() {}

    public private(set) var items: [Wire.MenuBarItem] = []
    public private(set) var menus: [LeaderMenu.Host: [LeaderMenuNode]] = [:]
    public private(set) var titles: [LeaderMenu.Host: String] = [:]

    public func update(_ items: [Wire.MenuBarItem]) {
        guard items != self.items else { return }
        self.items = items
        menus = LeaderMenu.tree(items)
        titles = Dictionary(uniqueKeysWithValues: LeaderMenu.Host.allCases.compactMap { host in
            LeaderMenu.title(host, in: items).map { (host, $0) }
        })
    }

    /// The nodes one host menu shows, in leader order.
    public func nodes(_ host: LeaderMenu.Host) -> [LeaderMenuNode] {
        menus[host] ?? []
    }

    /// Whether a host menu of its own (Search, Code, Git) appears: only when it has items, so a group with nothing
    /// bound never shows an empty menu.
    public func showsMenu(_ host: LeaderMenu.Host) -> Bool {
        !nodes(host).isEmpty
    }

    /// A host menu's title in the BEAM's words, or `fallback` when no group names it.
    public func title(_ host: LeaderMenu.Host, fallback: String) -> String {
        titles[host] ?? fallback
    }
}
