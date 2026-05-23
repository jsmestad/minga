/// State for extension-registered overlays on the editor surface.
///
/// Updated by `CommandDispatcher` from `gui_extension_overlay` (0x9C) opcode.
/// Read by `ExtensionOverlayView` to render positioned overlays.
@MainActor @Observable
final class ExtensionOverlayState {
    /// Active overlay entries from all extensions.
    private(set) var entries: [OverlayEntry] = []

    /// A single overlay for rendering.
    struct OverlayEntry: Identifiable, Equatable {
        let extensionName: String
        let overlayID: String
        let windowID: UInt16
        let row: UInt16
        let col: UInt16
        let shape: UInt8
        let colorR: UInt8
        let colorG: UInt8
        let colorB: UInt8
        let opacity: UInt8
        let content: String

        var id: String { "\(extensionName):\(overlayID)" }

        var color: (Double, Double, Double) {
            (Double(colorR) / 255.0, Double(colorG) / 255.0, Double(colorB) / 255.0)
        }

        var opacityValue: Double {
            Double(opacity) / 255.0
        }
    }

    /// Updates overlay entries from protocol data.
    func update(_ wireEntries: [Wire.ExtensionOverlayEntry]) {
        entries = wireEntries.map { wire in
            OverlayEntry(
                extensionName: wire.extensionName,
                overlayID: wire.overlayID,
                windowID: wire.windowID,
                row: wire.row,
                col: wire.col,
                shape: wire.shape,
                colorR: wire.colorR,
                colorG: wire.colorG,
                colorB: wire.colorB,
                opacity: wire.opacity,
                content: wire.content
            )
        }
    }

    /// Returns entries for a specific window.
    func entries(forWindow windowID: UInt16) -> [OverlayEntry] {
        entries.filter { $0.windowID == windowID }
    }
}
