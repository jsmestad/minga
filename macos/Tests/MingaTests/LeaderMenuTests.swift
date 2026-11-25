import Testing
@testable import MingaUI
import AppKit
import MingaProtocol

/// The macOS menu bar mirrors SPC (docs/design/surfaces.md, Mouse): each leader group lands in its menu, items show
/// the key sequence dimmed after the label, ⌘ equivalents fill the shortcut column, and nested groups are submenus.
@Suite("Leader menu bar mirror")
@MainActor
struct LeaderMenuTests {
    private final class Target: NSObject {
        @objc func run(_ sender: NSMenuItem) {}
    }

    private let items: [Wire.MenuBarItem] = [
        .init(path: "a", label: "Minga ›", section: "Groups", kind: 1),
        .init(path: "a a", label: "Agent view", section: "Tasks", kind: 0, command: "toggle_agentic_view"),
        .init(path: "a s", label: "Stop", section: "Tasks", kind: 0, command: "agent_abort", platformKey: "⌘."),
        .init(path: "a q", label: "Queue ›", section: "Conversation", kind: 1),
        .init(path: "a q q", label: "Open queue", kind: 0, command: "agent_queued_inputs"),
        .init(path: "f", label: "Files ›", section: "Groups", kind: 1),
        .init(path: "f s", label: "Save file", kind: 0, command: "save", platformKey: "⌘S"),
        .init(path: "s", label: "Search ›", section: "Groups", kind: 1),
        .init(path: "s p", label: "Search project", kind: 0, command: "search_project"),
    ]

    /// The label part of an item's title; the key sequence follows it after three spaces.
    private func label(_ item: NSMenuItem) -> String {
        item.title.components(separatedBy: "   ").first ?? item.title
    }

    private func mainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        for title in ["Minga", "File", "Edit", "Window", "Help"] {
            let holder = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            holder.submenu = NSMenu(title: title)
        }
        main.item(withTitle: "File")?.submenu?.addItem(withTitle: "Save", action: nil, keyEquivalent: "s")
        return main
    }

    @Test("an item shows its label and the key sequence dimmed, and runs its command")
    func itemTitle() {
        let item = LeaderMenu.item(items[2], action: #selector(Target.run(_:)), target: nil)

        #expect(label(item) == "Stop")
        #expect(item.attributedTitle?.string == "Stop   SPC a s")
        let range = (item.attributedTitle!.string as NSString).range(of: "SPC a s")
        #expect(item.attributedTitle?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(item.representedObject as? String == "agent_abort")
        #expect(item.keyEquivalent == "." && item.keyEquivalentModifierMask == .command)
    }

    @Test("groups land in their menus, nested groups become submenus, and a ⌘ key another item owns is not claimed twice")
    func install() {
        let main = mainMenu()
        LeaderMenu.install(items, into: main, action: #selector(Target.run(_:)), target: nil)

        let app = main.item(withTitle: "Minga")!.submenu!
        #expect(app.items.prefix(3).map(label) == ["Agent view", "Stop", ""])
        let queue = app.items.first { label($0) == "Queue" }
        #expect(queue?.submenu?.items.map(label) == ["Open queue"])

        let file = main.item(withTitle: "File")!.submenu!
        let save = file.items.first { label($0) == "Save file" }
        #expect(save != nil && save?.keyEquivalent == "", "⌘S belongs to the existing Save item")

        // Search has no menu yet, so it gets one before Window.
        let titles = main.items.map(\.title)
        #expect(titles.firstIndex(of: "Search")! < titles.firstIndex(of: "Window")!)
        #expect(LeaderMenu.isInstalled(in: main))

        // A reinstall replaces the mirror instead of adding a second copy.
        LeaderMenu.install(items, into: main, action: #selector(Target.run(_:)), target: nil)
        #expect(main.item(withTitle: "Minga")!.submenu!.items.filter { label($0) == "Stop" }.count == 1)
        #expect(main.items.filter { $0.title == "Search" }.count == 1)
    }

    @Test("installing nothing removes the mirror")
    func remove() {
        let main = mainMenu()
        LeaderMenu.install(items, into: main, action: #selector(Target.run(_:)), target: nil)
        LeaderMenu.install([], into: main, action: #selector(Target.run(_:)), target: nil)
        #expect(!LeaderMenu.isInstalled(in: main))
        #expect(main.items.map(\.title) == ["Minga", "File", "Edit", "Window", "Help"])
    }
}
