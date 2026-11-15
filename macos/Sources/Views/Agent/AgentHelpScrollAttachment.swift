import AppKit
import SwiftUI

/// A discardable attachment to the currently mounted Help scroll view, not another input or layout owner.
@MainActor
final class AgentHelpScrollAttachment {
    private weak var probe: NSView?

    func attach(_ view: NSView) {
        probe = view
    }

    func detach(_ view: NSView) {
        if probe === view { probe = nil }
    }

    func scrollView(in window: NSWindow?) -> NSScrollView? {
        guard let window, let probe, probe.window === window,
              let scroll = probe.enclosingScrollView, scroll.window === window else { return nil }
        return scroll
    }

    func previewNavigation(_ event: NSEvent, in window: NSWindow?) {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return }
        switch event.keyCode {
        case 115, 116, 119, 121, 125, 126: break
        default: return
        }
        guard let scroll = scrollView(in: window), let document = scroll.documentView else { return }

        let clip = scroll.contentView
        var proposed = clip.bounds
        let line = max(scroll.verticalLineScroll, 1)
        let page = max(proposed.height - scroll.verticalPageScroll, line)
        let direction: CGFloat = document.isFlipped ? 1 : -1
        switch event.keyCode {
        case 125: proposed.origin.y += direction * line
        case 126: proposed.origin.y -= direction * line
        case 121: proposed.origin.y += direction * page
        case 116: proposed.origin.y -= direction * page
        case 115:
            proposed.origin.y = document.isFlipped
                ? document.bounds.minY - scroll.contentInsets.top
                : document.bounds.maxY - proposed.height + scroll.contentInsets.top
        case 119:
            proposed.origin.y = document.isFlipped
                ? document.bounds.maxY - proposed.height + scroll.contentInsets.bottom
                : document.bounds.minY - scroll.contentInsets.bottom
        default: return
        }
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

/// Mounted inside Help content so ancestry is resolved from the current native hierarchy at use time.
struct AgentHelpScrollProbe: NSViewRepresentable {
    let attachment: AgentHelpScrollAttachment

    final class ProbeView: NSView {
        weak var attachment: AgentHelpScrollAttachment?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { attachment?.detach(self) }
            else { attachment?.attach(self) }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.attachment = attachment
        view.setAccessibilityHidden(true)
        attachment.attach(view)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        attachment.attach(view)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.attachment?.detach(view)
    }
}
