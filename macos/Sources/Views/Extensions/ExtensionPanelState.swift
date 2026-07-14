import Observation
import MingaProtocol

/// State for extension-registered panels.
///
/// Updated by `CommandDispatcher` from `gui_extension_panel` (0x9D) opcode.
/// Read by `ExtensionPanelView` to render structured content with native widgets.
@MainActor
@Observable
public final class ExtensionPanelState {
    public init() {}
    /// Active panel entries from all extensions.
    public private(set) var panels: [Wire.ExtensionPanelEntry] = []

    /// Updates panel entries from protocol data.
    public func update(_ entries: [Wire.ExtensionPanelEntry]) {
        panels = entries.filter { $0.visible }
    }

    /// Returns visible panels for a specific position (bottom, right, float).
    public func panels(forPosition position: UInt8) -> [Wire.ExtensionPanelEntry] {
        panels.filter { $0.position == position }
    }

    /// Whether any extension panels are visible.
    public var hasVisiblePanels: Bool { !panels.isEmpty }
}
