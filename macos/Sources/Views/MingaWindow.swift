/// First responder guard that prevents SwiftUI from stealing keyboard focus.
///
/// The EditorNSView (MTKView) must always be first responder for vim keybindings
/// to work. When SwiftUI chrome views (tab bar, file tree, etc.) are clicked,
/// AppKit's responder chain tries to make the hosting NSView first responder.
///
/// Since SwiftUI creates the NSWindow and we can't easily subclass it,
/// this helper installs itself as a first-responder guard by observing
/// all first responder changes and immediately redirecting them to the
/// editor view.
///
/// Combined with `.focusable(false)` on all SwiftUI chrome views, this
/// provides two layers of defense:
/// 1. SwiftUI views don't participate in the focus system at all
/// 2. If anything does steal focus, this guard reclaims it immediately

import AppKit

/// Installs a first-responder guard on the given window.
/// Uses a polling approach since NSWindow.firstResponder KVO
/// is not available under Swift 6 strict concurrency.
///
/// The guard observes NSWindow.didUpdateNotification (fires on every
/// event cycle) and reclaims first responder if something stole it.
/// This is lightweight: just a pointer comparison per event cycle.
@MainActor
final class FirstResponderGuard {
    private weak var window: NSWindow?
    private weak var editorView: EditorNSView?
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(window: NSWindow, editorView: EditorNSView) {
        self.window = window
        self.editorView = editorView

        // Observe window update notifications. These fire on every
        // event cycle, giving us a chance to reclaim first responder
        // if SwiftUI or AppKit stole it.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkFirstResponder()
            }
        }
    }

    private func checkFirstResponder() {
        guard let window, let editor = editorView else { return }
        if window.firstResponder !== editor {
            window.makeFirstResponder(editor)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
