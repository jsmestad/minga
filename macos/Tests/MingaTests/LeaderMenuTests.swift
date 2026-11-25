import Testing
@testable import MingaUI
import MingaProtocol

/// The macOS menu bar mirrors SPC (docs/design/surfaces.md, Mouse): each leader group lands in its menu, items show
/// the key sequence after the label, ⌘ equivalents fill the shortcut column unless the app's menus already use the
/// key, and nested groups are submenus.
@Suite("Leader menu bar mirror")
@MainActor
struct LeaderMenuTests {
    private let items: [Wire.MenuBarItem] = [
        .init(path: "a", label: "Minga ›", section: "Groups", kind: 1),
        .init(path: "a a", label: "Agent view", section: "Tasks", kind: 0, command: "toggle_agentic_view"),
        .init(path: "a s", label: "Stop", section: "Tasks", kind: 0, command: "agent_abort", platformKey: "⌘."),
        .init(path: "a q", label: "Queue ›", section: "Conversation", kind: 1),
        .init(path: "a q q", label: "Open queue", kind: 0, command: "agent_queued_inputs"),
        .init(path: "f", label: "Files ›", section: "Groups", kind: 1),
        .init(path: "f s", label: "Save file", kind: 0, command: "save", platformKey: "⌘S"),
        .init(path: "p", label: "Project ›", section: "More", kind: 1),
        .init(path: "p p", label: "Switch project", kind: 0, command: "project_switch"),
        .init(path: "s", label: "Search ›", section: "Groups", kind: 1),
        .init(path: "s p", label: "Search project", kind: 0, command: "search_project"),
        .init(path: "c", label: "Code ›", section: "Groups", kind: 1),
        .init(path: "c a", label: "Code action", kind: 0, command: "code_action"),
        .init(path: "g", label: "Git ›", section: "Groups", kind: 1),
        .init(path: "g s", label: "Git status", kind: 0, command: "git_status"),
        .init(path: "x", label: "Extension ›", section: "More", kind: 1),
        .init(path: "x r", label: "Run extension", kind: 0, command: "extension_run"),
    ]

    @Test("groups land in their host menus, with Search, Code and Git as menus of their own")
    func hosts() {
        let tree = LeaderMenu.tree(items)

        #expect(tree[.app]?.map(\.title).prefix(3) == ["Agent view", "Stop", "Queue"])
        #expect(tree[.file]?.map(\.title) == ["Save file", "Switch project"])
        #expect(tree[.search]?.map(\.title) == ["Search project"])
        #expect(tree[.code]?.map(\.title) == ["Code action"])
        #expect(tree[.git]?.map(\.title) == ["Git status"])
    }

    @Test("an item carries its key sequence and command, and nested groups become submenus")
    func nodes() {
        let app = LeaderMenu.tree(items)[.app] ?? []
        let stop = app.first { $0.title == "Stop" }

        #expect(stop?.sequence == "SPC a s")
        #expect(stop?.command == "agent_abort")
        #expect(app.first { $0.title == "Queue" }?.children.map(\.title) == ["Open queue"])
        #expect(app.first { $0.title == "Queue" }?.startsSection == true, "Queue is in another section than Tasks")
    }

    @Test("a ⌘ equivalent is kept unless the app's own menus already use that key")
    func shortcuts() {
        let tree = LeaderMenu.tree(items)

        #expect(tree[.app]?.first { $0.title == "Stop" }?.shortcut == ".")
        #expect(tree[.file]?.first { $0.title == "Save file" }?.shortcut == nil, "⌘S belongs to File › Save")
    }

    @Test("a second group in one host starts a section, and a group no host lists is a submenu of the app menu")
    func sectionsAndUnlistedGroups() {
        let tree = LeaderMenu.tree(items)

        #expect(tree[.file]?.first { $0.title == "Switch project" }?.startsSection == true)
        let extensionGroup = tree[.app]?.first { $0.title == "Extension" }
        #expect(extensionGroup?.children.map(\.title) == ["Run extension"])
    }

    @Test("a group with nothing bound shows no menu, and a menu takes its title from the BEAM's group label")
    func menusAndTitles() {
        let state = MenuBarState()
        state.update([
            .init(path: "g", label: "Git ›", section: "Groups", kind: 1),
            .init(path: "s", label: "Find ›", section: "Groups", kind: 1),
            .init(path: "s p", label: "Search project", kind: 0, command: "search_project"),
        ])

        #expect(!state.showsMenu(.git), "Git has no bound items, so no empty Git menu")
        #expect(state.showsMenu(.search))
        #expect(state.title(.search, fallback: "Search") == "Find")
        #expect(state.title(.code, fallback: "Code") == "Code")
    }

    @Test("a ⌘ key goes to the first item that names it, never to two items")
    func shortcutsAreUnique() {
        let tree = LeaderMenu.tree([
            .init(path: "a", label: "Minga ›", section: "Groups", kind: 1),
            .init(path: "a s", label: "Stop", kind: 0, command: "agent_abort", platformKey: "⌘."),
            .init(path: "c", label: "Code ›", section: "Groups", kind: 1),
            .init(path: "c s", label: "Also stop", kind: 0, command: "agent_abort", platformKey: "⌘."),
            .init(path: "c w", label: "Save", kind: 0, command: "save", platformKey: "⌘S"),
        ])

        func shortcuts(_ nodes: [LeaderMenuNode]) -> [Character] {
            nodes.flatMap { node in (node.shortcut.map { [$0] } ?? []) + shortcuts(node.children) }
        }
        let all = LeaderMenu.Host.allCases.flatMap { shortcuts(tree[$0] ?? []) }

        #expect(all == ["."], "⌘. once, on Stop; ⌘S belongs to File › Save")
        #expect(Set(all).isDisjoint(with: LeaderMenu.reservedCommandKeys))
    }

    @Test("the menu bar state rebuilds the tree on each new list and ignores a repeat")
    func state() {
        let state = MenuBarState()
        state.update(items)
        #expect(state.nodes(.git).map(\.title) == ["Git status"])

        state.update([])
        #expect(state.nodes(.git).isEmpty)
    }
}
