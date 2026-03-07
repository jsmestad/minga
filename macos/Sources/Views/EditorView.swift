/// SwiftUI wrapper for EditorNSView.
///
/// Uses NSViewRepresentable to host the AppKit-based editor surface
/// inside the SwiftUI window. Manages first responder status to ensure
/// the EditorNSView always receives keyboard events, even after SwiftUI
/// layout passes that can reassign focus.

import SwiftUI
import AppKit

/// SwiftUI view that wraps the Metal-backed EditorNSView.
struct EditorView: NSViewRepresentable {
    let editorNSView: EditorNSView?

    func makeNSView(context: Context) -> NSView {
        guard let view = editorNSView else {
            // Return a placeholder until the editor view is initialized.
            let placeholder = NSView()
            placeholder.wantsLayer = true
            placeholder.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).cgColor
            return placeholder
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // When SwiftUI updates the view hierarchy (e.g., title change triggers
        // a body re-evaluation), it can steal first responder. Reclaim it.
        guard let editorView = nsView as? EditorNSView else { return }
        editorView.claimFirstResponder()
    }
}
