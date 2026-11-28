import AppKit
import SwiftUI

/// Handles a secondary press without covering primary clicks, scrolling, or drag and drop.
struct SecondaryClick: NSViewRepresentable {
    let perform: () -> Void

    func makeNSView(context: Context) -> HitView {
        let view = HitView()
        view.perform = perform
        return view
    }

    func updateNSView(_ view: HitView, context: Context) {
        view.perform = perform
    }

    final class HitView: NSView {
        var perform: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.window === window,
                  event.type == .rightMouseDown ||
                    (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { perform?() }
        override func mouseDown(with event: NSEvent) { perform?() }
        override func rightMouseUp(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }
}
