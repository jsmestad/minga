/// SwiftUI wrapper for EditorNSView.
///
/// Uses NSViewRepresentable to host the AppKit-based editor surface
/// inside the SwiftUI window. The NSView handles all keyboard and mouse
/// input directly (SwiftUI's keyboard handling isn't sufficient for a
/// Vim-modal editor that needs raw key events).

import SwiftUI
import AppKit

/// SwiftUI view that wraps the Metal-backed EditorNSView.
struct EditorView: NSViewRepresentable {
    let editorNSView: EditorNSView

    func makeNSView(context: Context) -> EditorNSView {
        return editorNSView
    }

    func updateNSView(_ nsView: EditorNSView, context: Context) {
        // No SwiftUI state drives updates; the protocol reader handles everything.
    }
}
