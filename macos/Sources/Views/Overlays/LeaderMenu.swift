/// The macOS menu bar's mirror of the leader keymap (docs/design/surfaces.md, Mouse, pattern 2).
///
/// The BEAM sends every group and command under SPC in which-key order (gui_menu_bar). Each leader group lands in the
/// menu it belongs to (SPC a in the app menu, SPC f in File, SPC s in Search, and so on); its commands become items
/// whose title carries the key sequence dimmed after the label, because a native menu cannot draw a key sequence in
/// its shortcut column. A ⌘ equivalent goes in the shortcut column unless the app's own menu items or the system
/// already use that key. Nested groups become submenus.
///
/// SwiftUI owns the main menu and rebuilds it whenever its commands change, so the mirror is declared in SwiftUI
/// `Commands` (`LeaderMenuCommands`, in the app target) from the tree `tree(_:reserved:)` builds once per update. Items inserted into
/// AppKit menus behind SwiftUI's back do not survive.

import SwiftUI
import MingaProtocol

/// One leader item as the menu bar shows it: a command, or a group whose children form a submenu.
public struct LeaderMenuNode: Identifiable, Equatable, Sendable {
    /// The key path after SPC (`f s`), unique in the keymap.
    public let id: String
    public let title: String
    /// The sequence shown dimmed after the title (`SPC f s`).
    public let sequence: String
    public let command: String
    /// The ⌘ key equivalent, or nil when there is none or another menu item already uses that key.
    public let shortcut: Character?
    /// A divider goes before this node.
    public let startsSection: Bool
    public let children: [LeaderMenuNode]

    func startingSection() -> LeaderMenuNode {
        LeaderMenuNode(id: id, title: title, sequence: sequence, command: command, shortcut: shortcut,
                       startsSection: true, children: children)
    }
}

public enum LeaderMenu {
    /// The menus the mirror fills. Search, Code and Git are menus of their own; the rest join the system's menus.
    public enum Host: Hashable, CaseIterable, Sendable {
        case app, file, view, window, help, search, code, git

        /// Whether the mirror joins a menu that already has items, so a divider separates the two.
        public var joinsSystemMenu: Bool {
            switch self {
            case .search, .code, .git: false
            case .app, .file, .view, .window, .help: true
            }
        }
    }

    /// The host of a top-level leader key, or nil for a group no host lists (it becomes a submenu of the app menu).
    public static func host(forKey key: String) -> Host? {
        switch key {
        case "a", "q": .app
        case "f", "p", "b", "SPC", ",": .file
        case "o", "t": .view
        case "w", "TAB", "1", "2", "3", "4", "5", "6", "7", "8", "9": .window
        case "h": .help
        case "s", "/": .search
        case "c", "m", ";", ":": .code
        case "g": .git
        default: nil
        }
    }

    /// ⌘ keys the app's own menu items (`MingaMenuCommands`) and the system menus already use. A leader item never
    /// takes one of them, so no key has two menu items. Update this set with any new ⌘ shortcut in the app's menus.
    public static let reservedCommandKeys: Set<Character> = [
        "-", "+", "=", "0", "[", "]", "a", "b", "c", "f", "h", "l", "m", "n", "o", "q", "s", "v", "w", "x", "z", ",",
        "`",
    ]

    /// The top-level group whose label titles a host menu of its own (`s` titles Search).
    static func titleKey(_ host: Host) -> String? {
        switch host {
        case .search: "s"
        case .code: "c"
        case .git: "g"
        case .app, .file, .view, .window, .help: nil
        }
    }

    /// The title of a host menu of its own, in the BEAM's words: the label of the group it is named after.
    public static func title(_ host: Host, in items: [Wire.MenuBarItem]) -> String? {
        guard let key = titleKey(host), let group = items.first(where: { $0.path == key && $0.isGroup }) else { return nil }
        return group.label.replacingOccurrences(of: " ›", with: "")
    }

    /// The nodes each host shows, in leader order: a top-level command, or a group's contents with its nested groups
    /// as submenus. A group's contents start a new section after what the host already holds. A ⌘ key goes to the first
    /// item that names it, in menu order, so no key has two items.
    public static func tree(_ items: [Wire.MenuBarItem],
                            reserved: Set<Character> = reservedCommandKeys) -> [Host: [LeaderMenuNode]] {
        var claimed = reserved
        var result: [Host: [LeaderMenuNode]] = [:]
        for (host, nodes) in rawTree(items, reserved: reserved) {
            result[host] = nodes
        }
        for host in Host.allCases {
            guard let nodes = result[host] else { continue }
            result[host] = nodes.map { claimShortcuts($0, claimed: &claimed) }
        }
        return result
    }

    /// Clears a ⌘ key an earlier item already took.
    static func claimShortcuts(_ node: LeaderMenuNode, claimed: inout Set<Character>) -> LeaderMenuNode {
        var shortcut = node.shortcut
        if let key = shortcut {
            if claimed.contains(key) { shortcut = nil } else { claimed.insert(key) }
        }
        let children = node.children.map { claimShortcuts($0, claimed: &claimed) }
        return LeaderMenuNode(id: node.id, title: node.title, sequence: node.sequence, command: node.command,
                              shortcut: shortcut, startsSection: node.startsSection, children: children)
    }

    static func rawTree(_ items: [Wire.MenuBarItem], reserved: Set<Character>) -> [Host: [LeaderMenuNode]] {
        var result: [Host: [LeaderMenuNode]] = [:]
        for top in items where top.keys.count == 1 {
            let listed = host(forKey: top.path)
            let target = listed ?? .app
            var nodes = result[target] ?? []
            if top.isGroup, listed != nil {
                let contents = children(of: top, in: items, reserved: reserved)
                for (index, child) in contents.enumerated() {
                    nodes.append(index == 0 && !nodes.isEmpty ? child.startingSection() : child)
                }
            } else {
                let contents = top.isGroup ? children(of: top, in: items, reserved: reserved) : []
                nodes.append(node(top, children: contents, startsSection: false, reserved: reserved))
            }
            result[target] = nodes
        }
        return result
    }

    /// The direct children of a group, in leader order, with a divider where the section changes.
    static func children(of group: Wire.MenuBarItem, in items: [Wire.MenuBarItem],
                         reserved: Set<Character>) -> [LeaderMenuNode] {
        let depth = group.keys.count + 1
        let prefix = group.path + " "
        var result: [LeaderMenuNode] = []
        var section: String?
        for child in items where child.keys.count == depth && child.path.hasPrefix(prefix) {
            let startsSection = section != nil && section != child.section
            section = child.section
            let contents = child.isGroup ? children(of: child, in: items, reserved: reserved) : []
            result.append(node(child, children: contents, startsSection: startsSection, reserved: reserved))
        }
        return result
    }

    static func node(_ entry: Wire.MenuBarItem, children: [LeaderMenuNode], startsSection: Bool,
                     reserved: Set<Character>) -> LeaderMenuNode {
        let shortcut = keyEquivalent(entry.platformKey).flatMap { reserved.contains($0) ? nil : $0 }
        return LeaderMenuNode(
            id: entry.path, title: entry.label.replacingOccurrences(of: " ›", with: ""), sequence: "SPC " + entry.path,
            command: entry.command, shortcut: shortcut, startsSection: startsSection, children: children)
    }

    /// The key a ⌘ equivalent names (`⌘S` is `s`), or nil when there is none.
    public static func keyEquivalent(_ platformKey: String) -> Character? {
        guard platformKey.hasPrefix("⌘"), platformKey.count == 2, let last = platformKey.last else { return nil }
        return Character(last.lowercased())
    }
}

/// The items of one host menu or submenu. A named view, so a submenu can show its own children.
public struct LeaderMenuItems: View {
    let nodes: [LeaderMenuNode]
    /// A divider separates the mirror from the system items it joins.
    let startsWithDivider: Bool
    let connected: Bool
    let send: (String) -> Void

    public init(nodes: [LeaderMenuNode], startsWithDivider: Bool = false, connected: Bool,
                send: @escaping (String) -> Void) {
        self.nodes = nodes
        self.startsWithDivider = startsWithDivider
        self.connected = connected
        self.send = send
    }

    public var body: some View {
        if startsWithDivider { Divider() }
        ForEach(nodes) { node in
            if node.startsSection { Divider() }
            if node.children.isEmpty {
                Button { send(node.command) } label: {
                    Text(node.title) + Text("   " + node.sequence).foregroundStyle(.secondary)
                }
                .keyboardShortcut(node.shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
                .disabled(!connected || node.command.isEmpty)
            } else {
                Menu {
                    LeaderMenuItems(nodes: node.children, connected: connected, send: send)
                } label: {
                    Text(node.title)
                }
            }
        }
    }
}
