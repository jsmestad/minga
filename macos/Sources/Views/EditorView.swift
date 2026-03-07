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
    let editorNSView: EditorNSView

    func makeNSView(context: Context) -> EditorNSView {
        return editorNSView
    }

    func updateNSView(_ nsView: EditorNSView, context: Context) {
        // When SwiftUI updates the view hierarchy (e.g., title change triggers
        // a body re-evaluation), it can steal first responder. Reclaim it.
        nsView.claimFirstResponder()
    }
}
