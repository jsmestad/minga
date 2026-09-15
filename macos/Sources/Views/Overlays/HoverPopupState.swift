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

/// Complete presentation value for one visible hover popup.
public struct HoverPopupContent {
    fileprivate init(anchorRow: Int, anchorCol: Int, focused: Bool, scrollOffset: Int, lines: [HoverLine], openActionName: String?) {
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.focused = focused
        self.scrollOffset = scrollOffset
        self.lines = lines
        self.openActionName = openActionName
    }

    public let anchorRow: Int
    public let anchorCol: Int
    public let focused: Bool
    public let scrollOffset: Int
    public let lines: [HoverLine]
    public fileprivate(set) var openActionName: String?

    public var visibleLines: [HoverLine] {
        Array(lines.dropFirst(min(scrollOffset, lines.count)))
    }
}

@MainActor
@Observable
public final class HoverPopupState {
    public init() {}

    /// The complete visible presentation, or `nil` when hidden.
    public private(set) var content: HoverPopupContent?

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16,
                focused: Bool, scrollOffset: UInt16, rawLines: [Wire.HoverLine],
                openAction: (visible: Bool, name: String)? = nil) {
        guard visible else {
            hide()
            return
        }

        var segId = 0
        let lines = rawLines.enumerated().map { i, line in
            let segments = line.segments.map { seg in
                let s = HoverSegment(id: segId, style: seg.style, fgColor: seg.fgColor, flags: seg.flags, text: seg.text)
                segId += 1
                return s
            }
            return HoverLine(id: i, lineType: line.lineType, segments: segments)
        }
        content = HoverPopupContent(
            anchorRow: Int(anchorRow), anchorCol: Int(anchorCol), focused: focused,
            scrollOffset: Int(scrollOffset), lines: lines,
            openActionName: resolvedOpenActionName(openAction)
        )
    }

    /// Applies an independently delivered hover action without changing popup visibility.
    public func updateOpenAction(visible: Bool, name: String) {
        let actionName = visible && !name.isEmpty ? name : nil
        guard var content else { return }
        content.openActionName = actionName
        self.content = content
    }

    public func hide() {
        content = nil
    }

    private func resolvedOpenActionName(_ update: (visible: Bool, name: String)?) -> String? {
        guard let update else { return content?.openActionName }
        return update.visible && !update.name.isEmpty ? update.name : nil
    }
}
