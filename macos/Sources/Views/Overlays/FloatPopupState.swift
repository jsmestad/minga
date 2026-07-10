/// Observable float popup state driven by BEAM gui_float_popup messages.
///
/// Float popups are centered, bordered native windows showing semantic content
/// such as markdown help or inspection text. The BEAM sends title, content
/// lines, and preferred size hints; the GUI measures and lays out the popup
/// natively with SwiftUI.

import SwiftUI

@MainActor
@Observable
public final class FloatPopupState {
    public init(visible: Bool = false, title: String = "", width: Int = 0, height: Int = 0, lines: [String] = []) {
        self.visible = visible
        self.title = title
        self.width = width
        self.height = height
        self.lines = lines
    }
    public var visible: Bool = false
    public var title: String = ""
    /// Preferred maximum width, in editor-cell units for protocol compatibility.
    public var width: Int = 0
    /// Preferred maximum height, in editor-cell units for protocol compatibility.
    public var height: Int = 0
    public var lines: [String] = []

    public func update(visible: Bool, width: UInt16, height: UInt16, title: String, lines: [String]) {
        self.visible = visible
        self.width = Int(width)
        self.height = Int(height)
        self.title = title
        self.lines = lines
    }

    public func hide() {
        visible = false
        lines = []
    }
}
