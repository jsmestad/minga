/// Observable hover popup state driven by BEAM gui_hover_popup messages.

import SwiftUI
import MingaProtocol

/// A styled text segment for rendering in the hover popup.
public struct HoverSegment: Identifiable {
    public init(id: Int, style: Wire.HoverStyle, fgColor: UInt32? = nil, flags: UInt8, text: String) {
        self.id = id
        self.style = style
        self.fgColor = fgColor
        self.flags = flags
        self.text = text
    }
    public let id: Int
    public let style: Wire.HoverStyle
    public let fgColor: UInt32?
    public let flags: UInt8
    public let text: String
}

/// A line of hover content with its block type.
public struct HoverLine: Identifiable {
    public init(id: Int, lineType: Wire.HoverLineType, segments: [HoverSegment]) {
        self.id = id
        self.lineType = lineType
        self.segments = segments
    }
    public let id: Int
    public let lineType: Wire.HoverLineType
    public let segments: [HoverSegment]
}

@MainActor
@Observable
public final class HoverPopupState {
    public init(visible: Bool = false, anchorRow: Int = 0, anchorCol: Int = 0, focused: Bool = false, scrollOffset: Int = 0, lines: [HoverLine] = [], openActionName: String? = nil) {
        self.visible = visible
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.focused = focused
        self.scrollOffset = scrollOffset
        self.lines = lines
        self.openActionName = openActionName
    }
    public var visible: Bool = false
    public var anchorRow: Int = 0
    public var anchorCol: Int = 0
    public var focused: Bool = false
    public var scrollOffset: Int = 0
    public var lines: [HoverLine] = []
    public var openActionName: String? = nil

    public var visibleLines: [HoverLine] {
        Array(lines.dropFirst(min(scrollOffset, lines.count)))
    }

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16,
                focused: Bool, scrollOffset: UInt16, rawLines: [Wire.HoverLine]) {
        self.visible = visible
        self.anchorRow = Int(anchorRow)
        self.anchorCol = Int(anchorCol)
        self.focused = focused
        self.scrollOffset = Int(scrollOffset)
        var segId = 0
        self.lines = rawLines.enumerated().map { i, line in
            let segments = line.segments.map { seg in
                let s = HoverSegment(id: segId, style: seg.style, fgColor: seg.fgColor, flags: seg.flags, text: seg.text)
                segId += 1
                return s
            }
            return HoverLine(id: i, lineType: line.lineType, segments: segments)
        }
    }

    public func setOpenAction(name: String) {
        openActionName = name.isEmpty ? nil : name
    }

    public func clearOpenAction() {
        openActionName = nil
    }

    public func hide() {
        visible = false
        lines = []
        openActionName = nil
    }
}
