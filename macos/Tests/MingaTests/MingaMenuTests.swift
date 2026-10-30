import AppKit
import Foundation
import Testing

@Suite("Minga Edit Menu")
struct MingaMenuTests {
    private struct ExpectedItem {
        let title: String
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
    }

    private let expectedItems = [
        ExpectedItem(title: "Undo", keyEquivalent: "z", modifiers: .command),
        ExpectedItem(title: "Redo", keyEquivalent: "z", modifiers: [.command, .shift]),
        ExpectedItem(title: "Cut", keyEquivalent: "x", modifiers: .command),
        ExpectedItem(title: "Copy", keyEquivalent: "c", modifiers: .command),
        ExpectedItem(title: "Paste", keyEquivalent: "v", modifiers: .command),
        ExpectedItem(title: "Select All", keyEquivalent: "a", modifiers: .command)
    ]

    @Test("the assembled production Edit menu has one active owner per standard shortcut")
    @MainActor func assembledProductionMenu() async throws {
        let menu = try await launchProductionMenuSnapshot(connected: true)
        let editMenu = try #require(menu.first { $0.title == "Edit" })
        let visibleItems = editMenu.children.filter { !$0.isHidden }

        for expected in expectedItems {
            let titled = visibleItems.filter { $0.title == expected.title }
            #expect(titled.count == 1)
            let item = try #require(titled.first)
            #expect(item.keyEquivalent == expected.keyEquivalent)
            #expect(item.keyEquivalentModifierMask == expected.modifiers.rawValue)
            #expect(item.isEnabled)

            let shortcutOwners = allItems(in: menu).filter {
                !$0.isHidden && $0.isEnabled && $0.keyEquivalent == expected.keyEquivalent && $0.keyEquivalentModifierMask == expected.modifiers.rawValue
            }
            #expect(shortcutOwners.map(\.title) == [expected.title])
        }
    }

    @Test("the assembled production Edit menu disables editor actions without a connection")
    @MainActor func assembledDisconnectedMenu() async throws {
        let menu = try await launchProductionMenuSnapshot(connected: false)
        let editMenu = try #require(menu.first { $0.title == "Edit" })

        for expected in expectedItems {
            let item = try #require(editMenu.children.first { $0.title == expected.title })
            #expect(!item.isEnabled)
        }
    }

    @MainActor
    private func launchProductionMenuSnapshot(connected: Bool) async throws -> [MenuItemSnapshot] {
        let applicationPath = try #require(ProcessInfo.processInfo.environment["MINGA_TEST_PRODUCTION_APP_PATH"])
        let applicationURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
        try #require(applicationURL.lastPathComponent == "Minga.app", "Probe requires the separately built production app")
        let bundle = try #require(Bundle(url: applicationURL))
        let executable = try #require(bundle.executableURL)
        try #require(executable.lastPathComponent == "Minga" && FileManager.default.isExecutableFile(atPath: executable.path))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("minga-menu-\(UUID().uuidString).json")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment.merging([
            MenuSnapshotProbe.outputPathEnvironmentKey: output.path,
            MenuSnapshotProbe.connectedEnvironmentKey: connected ? "1" : "0"
        ]) { _, probeValue in probeValue }

        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)

        for _ in 0..<500 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            application.terminate()
            throw CocoaError(.fileReadNoSuchFile)
        }
        let data = try Data(contentsOf: output)
        try? FileManager.default.removeItem(at: output)
        return try JSONDecoder().decode([MenuItemSnapshot].self, from: data)
    }

    private func allItems(in items: [MenuItemSnapshot]) -> [MenuItemSnapshot] {
        items + items.flatMap { allItems(in: $0.children) }
    }
}
