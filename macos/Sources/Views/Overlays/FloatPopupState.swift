/// Observable float popup state driven by BEAM gui_float_popup messages.
///
/// Float popups are centered, bordered native windows showing semantic content
/// such as markdown help or inspection text. The BEAM sends title, content
/// lines, and preferred size hints; the GUI measures and lays out the popup
/// natively with SwiftUI.

import SwiftUI

/// Complete presentation value for one visible float popup.
public struct FloatPopupContent {
    fileprivate init(title: String, width: Int, height: Int, lines: [String]) {
        self.title = title
        self.width = width
        self.height = height
        self.lines = lines
    }

    public let title: String
    /// Preferred maximum width, in editor-cell units for protocol compatibility.
    public let width: Int
    /// Preferred maximum height, in editor-cell units for protocol compatibility.
    public let height: Int
    public let lines: [String]
}

@MainActor
@Observable
public final class FloatPopupState {
    public init() {}

    /// The complete visible presentation, or `nil` when hidden.
    public private(set) var content: FloatPopupContent?

    public func update(visible: Bool, width: UInt16, height: UInt16, title: String, lines: [String]) {
        guard visible else {
            hide()
            return
        }
        content = FloatPopupContent(title: title, width: Int(width), height: Int(height), lines: lines)
    }

    public func hide() {
        content = nil
    }
}
