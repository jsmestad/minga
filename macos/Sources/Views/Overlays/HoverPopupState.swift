/// Observable hover popup state driven by BEAM gui_hover_popup messages.

import SwiftUI
import MingaProtocol

/// A styled text segment for rendering in the hover popup.
public struct HoverSegment: Identifiable {
    public init(id: Int, style: Wire.HoverStyle, fgColor: UInt32? = nil, flags: UInt8, text: String, linkID: UInt16? = nil) {
        self.id = id
        self.style = style
        self.fgColor = fgColor
        self.flags = flags
        self.linkID = linkID
        self.text = text
    }
    public let id: Int
    public let style: Wire.HoverStyle
    public let fgColor: UInt32?
    public let flags: UInt8
    public let linkID: UInt16?
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
    fileprivate init(anchorRow: Int, anchorCol: Int, focused: Bool, scrollOffset: Int, lines: [HoverLine], offer: Wire.HoverOffer?) {
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.focused = focused
        self.scrollOffset = scrollOffset
        self.lines = lines
        self.offer = offer
    }

    public let anchorRow: Int
    public let anchorCol: Int
    public let focused: Bool
    public let scrollOffset: Int
    public let lines: [HoverLine]
    public fileprivate(set) var offer: Wire.HoverOffer?

    public var visibleLines: ArraySlice<HoverLine> {
        lines.dropFirst(scrollOffset)
    }
}

@Observable
public final class HoverPopupState {
    public init() {}

    /// The complete visible presentation, or `nil` when hidden.
    public private(set) var content: HoverPopupContent?

    // This is a weak reference to the measured native surface, not protocol state.
    @ObservationIgnored private weak var pointerSurface: NSView?

    @MainActor
    func registerPointerSurface(_ view: NSView) {
        pointerSurface = view
    }

    /// Returns whether a visible hover owns the pointer in this native window.
    @MainActor
    public func capturesPointer(at locationInWindow: NSPoint, window: NSWindow?) -> Bool {
        guard content != nil,
              let window, let surface = pointerSurface, surface.window === window else { return false }
        return surface.bounds.contains(surface.convert(locationInWindow, from: nil))
    }

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16,
                focused: Bool, scrollOffset: UInt16, rawLines: [Wire.HoverLine],
                openAction: Wire.HoverOffer? = nil) {
        guard visible else {
            hide()
            return
        }

        var segId = 0
        let lines = rawLines.enumerated().map { i, line in
            let segments = line.segments.map { seg in
                let s = HoverSegment(id: segId, style: seg.style, fgColor: seg.fgColor, flags: seg.flags, text: seg.text, linkID: seg.linkID)
                segId += 1
                return s
            }
            return HoverLine(id: i, lineType: line.lineType, segments: segments)
        }
        content = HoverPopupContent(
            anchorRow: Int(anchorRow), anchorCol: Int(anchorCol), focused: focused,
            scrollOffset: Int(scrollOffset), lines: lines,
            offer: resolvedOffer(openAction)
        )
    }

    /// Applies an independently delivered hover action without changing popup visibility.
    public func updateOpenAction(_ offer: Wire.HoverOffer) {
        guard var content else { return }
        content.offer = offer.id == 0 ? nil : offer
        self.content = content
    }

    public func hide() {
        content = nil
    }

    private func resolvedOffer(_ update: Wire.HoverOffer?) -> Wire.HoverOffer? {
        guard let update else { return content?.offer }
        return update.id == 0 ? nil : update
    }
}
