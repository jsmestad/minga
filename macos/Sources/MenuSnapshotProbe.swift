import AppKit
import Foundation

struct MenuItemSnapshot: Codable, Equatable {
    let title: String
    let action: String?
    let keyEquivalent: String
    let keyEquivalentModifierMask: UInt
    let isEnabled: Bool
    let isHidden: Bool
    let children: [MenuItemSnapshot]
}

enum MenuSnapshotProbe {
    static let outputPathEnvironmentKey = "MINGA_MENU_SNAPSHOT_PATH"
    static let connectedEnvironmentKey = "MINGA_MENU_SNAPSHOT_CONNECTED"

    @MainActor
    static func capture(_ menu: NSMenu) -> [MenuItemSnapshot] {
        menu.update()
        return menu.items.map(capture)
    }

    @MainActor
    static func writeMainMenu(to path: String) throws {
        guard let mainMenu = NSApp.mainMenu else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = try JSONEncoder().encode(capture(mainMenu))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @MainActor
    private static func capture(_ item: NSMenuItem) -> MenuItemSnapshot {
        item.submenu?.update()
        return MenuItemSnapshot(
            title: item.title,
            action: item.action.map(NSStringFromSelector),
            keyEquivalent: item.keyEquivalent,
            keyEquivalentModifierMask: item.keyEquivalentModifierMask.rawValue,
            isEnabled: item.isEnabled,
            isHidden: item.isHidden,
            children: item.submenu.map(capture) ?? []
        )
    }
}
