/// Observable hover popup state driven by BEAM gui_hover_popup messages.

import SwiftUI

/// A styled text segment for rendering in the hover popup.
struct HoverSegment: Identifiable {
    let id: Int
    let style: Wire.HoverStyle
    let text: String
}

/// A line of hover content with its block type.
struct HoverLine: Identifiable {
    let id: Int
    let lineType: Wire.HoverLineType
    let segments: [HoverSegment]
}

@MainActor
@Observable
final class HoverPopupState {
    var visible: Bool = false
    var anchorRow: Int = 0
    var anchorCol: Int = 0
    var focused: Bool = false
    var scrollOffset: Int = 0
    var lines: [HoverLine] = []

    func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16,
                focused: Bool, scrollOffset: UInt16, rawLines: [Wire.HoverLine]) {
        self.visible = visible
        self.anchorRow = Int(anchorRow)
        self.anchorCol = Int(anchorCol)
        self.focused = focused
        self.scrollOffset = Int(scrollOffset)
        var segId = 0
        self.lines = rawLines.enumerated().map { i, line in
            let segments = line.segments.map { seg in
                let s = HoverSegment(id: segId, style: seg.style, text: seg.text)
                segId += 1
                return s
            }
            return HoverLine(id: i, lineType: line.lineType, segments: segments)
        }
    }

    func hide() {
        visible = false
        lines = []
    }
}
