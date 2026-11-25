/// The leader keymap the macOS menu bar mirrors, driven by BEAM gui_menu_bar messages.
///
/// The app installs it into the main menu (`LeaderMenuInstaller`); the which-key panel reads the same keymap in the
/// same order, so the two cannot drift (docs/design/surfaces.md, Mouse).

import Foundation
import MingaProtocol

@MainActor
public final class MenuBarState {
    public init() {}

    public private(set) var items: [Wire.MenuBarItem] = []

    /// Called on the main actor whenever the items change; the app's menu installer listens here.
    public var onChange: (([Wire.MenuBarItem]) -> Void)?

    public func update(_ items: [Wire.MenuBarItem]) {
        guard items != self.items else { return }
        self.items = items
        onChange?(items)
    }
}
