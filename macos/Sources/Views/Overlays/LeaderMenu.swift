/// The macOS menu bar's mirror of the leader keymap (docs/design/surfaces.md, Mouse, pattern 2).
///
/// The BEAM sends every group and command under SPC in which-key order (gui_menu_bar). Each leader group lands in the
/// menu it belongs to (SPC a in the app menu, SPC f in File, SPC s in Search, and so on); its commands become items
/// whose title carries the key sequence dimmed after the label, because a native menu cannot draw a key sequence in
/// its shortcut column. A ⌘ equivalent goes in the shortcut column, unless another item in the menu bar already owns
/// that key. Nested groups become submenus. Every injected item is tagged so a reinstall replaces exactly them.

import AppKit
import MingaProtocol

@MainActor
public enum LeaderMenu {
    /// Tags every item the mirror owns.
    public static let itemTag = 0x5350_4320 // "SPC "

    /// Where a top-level leader key lands: the app menu (nil title), or a menu by title.
    public enum Host: Hashable {
        case appMenu
        case menu(String)
    }

    /// The host of a top-level leader key. Unlisted groups get a menu of their own, titled by the group label.
    public static func host(forKey key: String, label: String) -> Host {
        switch key {
        case "a", "q": .appMenu
        case "f", "p", "b", "SPC", ",": .menu("File")
        case "o", "t": .menu("View")
        case "w", "TAB", "1", "2", "3", "4", "5", "6", "7", "8", "9": .menu("Window")
        case "h": .menu("Help")
        case "s", "/": .menu("Search")
        case "c", "m", ";", ":": .menu("Code")
        case "g": .menu("Git")
        default: .menu(label.replacingOccurrences(of: " ›", with: ""))
        }
    }

    /// The items each host receives, in leader order: a top-level command, or a group's contents (with its nested
    /// groups as submenus). Groups are separated from what comes before them.
    public static func itemsByHost(_ items: [Wire.MenuBarItem], action: Selector, target: AnyObject?,
                                   claimedKeys: Set<String> = []) -> [(Host, [NSMenuItem])] {
        var order: [Host] = []
        var byHost: [Host: [NSMenuItem]] = [:]
        for top in items where top.keys.count == 1 {
            let host = host(forKey: top.path, label: top.label)
            if byHost[host] == nil { order.append(host); byHost[host] = [] }
            if top.isGroup {
                if !(byHost[host]?.isEmpty ?? true) { byHost[host]?.append(separator()) }
                byHost[host]?.append(contentsOf: children(of: top, in: items, action: action, target: target, claimedKeys: claimedKeys))
            } else {
                byHost[host]?.append(item(top, action: action, target: target, claimedKeys: claimedKeys))
            }
        }
        return order.map { ($0, byHost[$0] ?? []) }
    }

    /// The direct children of a group, in leader order, with a separator between sections.
    static func children(of group: Wire.MenuBarItem, in items: [Wire.MenuBarItem], action: Selector, target: AnyObject?,
                         claimedKeys: Set<String>) -> [NSMenuItem] {
        let depth = group.keys.count + 1
        let prefix = group.path + " "
        var result: [NSMenuItem] = []
        var section: String?
        for child in items where child.keys.count == depth && child.path.hasPrefix(prefix) {
            if let section, section != child.section { result.append(separator()) }
            section = child.section
            let menuItem = item(child, action: action, target: target, claimedKeys: claimedKeys)
            if child.isGroup {
                let submenu = NSMenu(title: child.label)
                submenu.items = children(of: child, in: items, action: action, target: target, claimedKeys: claimedKeys)
                menuItem.submenu = submenu
            }
            result.append(menuItem)
        }
        return result
    }

    /// One item: the label, then the leader sequence dimmed, and the ⌘ equivalent in the shortcut column.
    public static func item(_ entry: Wire.MenuBarItem, action: Selector, target: AnyObject?,
                            claimedKeys: Set<String> = []) -> NSMenuItem {
        let label = entry.label.replacingOccurrences(of: " ›", with: "")
        let menuItem = NSMenuItem(title: label, action: entry.command.isEmpty ? nil : action, keyEquivalent: "")
        menuItem.tag = itemTag
        menuItem.target = target
        menuItem.representedObject = entry.command
        let sequence = "SPC " + entry.path
        let title = NSMutableAttributedString(string: label, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "   " + sequence, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        menuItem.attributedTitle = title
        menuItem.toolTip = sequence
        if let key = keyEquivalent(entry.platformKey), !claimedKeys.contains(key) {
            menuItem.keyEquivalent = key
            menuItem.keyEquivalentModifierMask = .command
        }
        return menuItem
    }

    /// The key a ⌘ equivalent names (`⌘S` is `s`), or nil when there is none.
    public static func keyEquivalent(_ platformKey: String) -> String? {
        guard platformKey.hasPrefix("⌘"), platformKey.count == 2, let last = platformKey.last else { return nil }
        return String(last).lowercased()
    }

    static func separator() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.tag = itemTag
        return item
    }

    /// Every ⌘ key equivalent the menu bar's own items already use, so the mirror never claims one twice.
    public static func claimedCommandKeys(in menu: NSMenu) -> Set<String> {
        var keys: Set<String> = []
        for item in menu.items where item.tag != itemTag {
            if !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask == .command {
                keys.insert(item.keyEquivalent.lowercased())
            }
            if let submenu = item.submenu { keys.formUnion(claimedCommandKeys(in: submenu)) }
        }
        return keys
    }

    /// Replaces the mirror in `mainMenu`: removes every tagged item and menu, then installs `items`.
    public static func install(_ items: [Wire.MenuBarItem], into mainMenu: NSMenu, action: Selector, target: AnyObject?) {
        remove(from: mainMenu)
        guard !items.isEmpty else { return }
        let claimed = claimedCommandKeys(in: mainMenu)
        for (host, hostItems) in itemsByHost(items, action: action, target: target, claimedKeys: claimed) where !hostItems.isEmpty {
            let menu = hostMenu(host, in: mainMenu)
            switch host {
            case .appMenu:
                // The app menu leads with the mirror, before About and Settings.
                var index = 0
                for item in hostItems + [separator()] { menu.insertItem(item, at: index); index += 1 }
            case .menu:
                if !menu.items.isEmpty, menu.items.last?.tag != itemTag { menu.addItem(separator()) }
                for item in hostItems { menu.addItem(item) }
            }
        }
    }

    /// Whether the mirror is in `mainMenu` (SwiftUI rebuilds the menu bar when its commands change).
    public static func isInstalled(in mainMenu: NSMenu) -> Bool {
        mainMenu.items.contains { item in item.tag == itemTag || (item.submenu?.items.contains { $0.tag == itemTag } ?? false) }
    }

    static func remove(from mainMenu: NSMenu) {
        for item in mainMenu.items where item.tag == itemTag { mainMenu.removeItem(item) }
        for item in mainMenu.items {
            guard let submenu = item.submenu else { continue }
            for child in submenu.items where child.tag == itemTag { submenu.removeItem(child) }
        }
    }

    static func hostMenu(_ host: Host, in mainMenu: NSMenu) -> NSMenu {
        switch host {
        case .appMenu:
            if let menu = mainMenu.items.first?.submenu { return menu }
        case .menu(let title):
            if let menu = mainMenu.items.first(where: { $0.title == title })?.submenu { return menu }
            let menu = NSMenu(title: title)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.tag = itemTag
            holder.submenu = menu
            // New leader menus sit before Window and Help, as the macOS menu bar orders them.
            let index = mainMenu.items.firstIndex { $0.title == "Window" } ?? mainMenu.items.count
            mainMenu.insertItem(holder, at: index)
            return menu
        }
        let menu = NSMenu(title: "Minga")
        mainMenu.insertItem(withTitle: "Minga", action: nil, keyEquivalent: "", at: 0).submenu = menu
        return menu
    }
}

/// Installs the mirror into the app's main menu and keeps it there: SwiftUI rebuilds the menu bar when its commands
/// change, so the installer puts the mirror back after each AppKit update in which it went missing.
@MainActor
public final class LeaderMenuInstaller: NSObject {
    private let send: (OutboundAction) -> Void
    private var items: [Wire.MenuBarItem] = []
    private var observer: NSObjectProtocol?

    public init(send: @escaping (OutboundAction) -> Void) {
        self.send = send
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reinstallIfMissing() }
        }
    }

    public func install(_ items: [Wire.MenuBarItem]) {
        self.items = items
        guard let mainMenu = NSApp.mainMenu else {
            PortLogger.info("Leader menu: \(items.count) items arrived before the main menu exists")
            return
        }
        LeaderMenu.install(items, into: mainMenu, action: #selector(run(_:)), target: self)
        PortLogger.info("Leader menu: installed \(items.count) items; menu bar \(Self.titles(mainMenu))")
    }

    private func reinstallIfMissing() {
        guard !items.isEmpty, let mainMenu = NSApp.mainMenu, !LeaderMenu.isInstalled(in: mainMenu) else { return }
        LeaderMenu.install(items, into: mainMenu, action: #selector(run(_:)), target: self)
        PortLogger.info("Leader menu: reinstalled after the menu bar was rebuilt; menu bar \(Self.titles(mainMenu))")
    }

    private static func titles(_ menu: NSMenu) -> String {
        menu.items.map { item in "\(item.title)(\(item.submenu?.items.count ?? 0))" }.joined(separator: " ")
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String, !command.isEmpty else { return }
        send(.executeCommand(name: command))
    }
}
