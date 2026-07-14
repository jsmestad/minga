import Observation
import MingaProtocol

/// State for extension-registered overlays on the editor surface.
///
/// Updated by `CommandDispatcher` from `gui_extension_overlay` (0x9C) opcode.
/// Read by `ExtensionOverlayView` to render positioned overlays.
@MainActor
@Observable
public final class ExtensionOverlayState {
    public init() {}
    /// Active overlay entries from all extensions.
    public private(set) var entries: [OverlayEntry] = []

    /// A single overlay for rendering.
    public struct OverlayEntry: Identifiable, Equatable {
        public init(extensionName: String, overlayID: String, windowID: UInt16, row: UInt16, col: UInt16, shape: UInt8, colorR: UInt8, colorG: UInt8, colorB: UInt8, opacity: UInt8, content: String) {
            self.extensionName = extensionName
            self.overlayID = overlayID
            self.windowID = windowID
            self.row = row
            self.col = col
            self.shape = shape
            self.colorR = colorR
            self.colorG = colorG
            self.colorB = colorB
            self.opacity = opacity
            self.content = content
        }
        public let extensionName: String
        public let overlayID: String
        public let windowID: UInt16
        public let row: UInt16
        public let col: UInt16
        public let shape: UInt8
        public let colorR: UInt8
        public let colorG: UInt8
        public let colorB: UInt8
        public let opacity: UInt8
        public let content: String

        public var id: String { "\(extensionName):\(overlayID)" }

        public var color: (Double, Double, Double) {
            (Double(colorR) / 255.0, Double(colorG) / 255.0, Double(colorB) / 255.0)
        }

        public var opacityValue: Double {
            Double(opacity) / 255.0
        }
    }

    /// Updates overlay entries from protocol data.
    public func update(_ wireEntries: [Wire.ExtensionOverlayEntry]) {
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
    public func entries(forWindow windowID: UInt16) -> [OverlayEntry] {
        entries.filter { $0.windowID == windowID }
    }

    /// Distinct window IDs that currently have overlay entries, in first-seen order.
    public var windowIDs: [UInt16] {
        var seen = Set<UInt16>()
        return entries.compactMap { seen.insert($0.windowID).inserted ? $0.windowID : nil }
    }

    /// Whether an overlay entry falls inside a window's visible text viewport.
    ///
    /// `firstColumn` is the leftmost visible text column (the window's `scrollLeft`),
    /// `columnCount`/`rowCount` are the visible text rect size in cells. Entries scrolled
    /// out of the viewport would otherwise draw over the gutter or an adjacent split pane,
    /// since (unlike the Metal text path) SwiftUI does not clip them. When the viewport
    /// size is unknown (no retained pane geometry) nothing is suppressed.
    nonisolated static func isVisible(
        _ entry: OverlayEntry,
        firstColumn: UInt16,
        columnCount: UInt16,
        rowCount: UInt16
    ) -> Bool {
        guard columnCount > 0, rowCount > 0 else { return true }
        return entry.col >= firstColumn
            && entry.col < firstColumn &+ columnCount
            && entry.row < rowCount
    }
}
