import AppKit
import Combine

/// Owns AppKit focus reclamation and overlay key-routing lifetime for one editor view.
@MainActor
final class EditorFocusPolicy {
    private weak var editorView: EditorNSView?
    private weak var attachedWindow: NSWindow?
    private var firstResponderTask: Task<Void, Never>?
    private var windowUpdateTask: Task<Void, Never>?
    private var applicationActivationTask: Task<Void, Never>?
    private var deferredReclaimTask: Task<Void, Never>?
    private var agentKeyMonitor: Any?
    private var nativeModalDepth = 0
    private var presentationFocusRequested = false

    private(set) var agentOverlayVisible = false

    init(editorView: EditorNSView) {
        self.editorView = editorView
    }

    deinit {
        firstResponderTask?.cancel()
        firstResponderTask = nil
        windowUpdateTask?.cancel()
        applicationActivationTask?.cancel()
        deferredReclaimTask?.cancel()
    }

    /// Attaches the policy to the editor's current window and installs its focus hooks.
    func attach(to window: NSWindow) {
        guard attachedWindow !== window else {
            reconcileAgentKeyMonitor()
            return
        }

        detach()
        attachedWindow = window
        window.initialFirstResponder = editorView
        firstResponderTask = Task { @MainActor [weak self, weak window] in
            guard let window else { return }
            for await _ in window.publisher(for: \.firstResponder, options: [.new]).values {
                guard let self else { return }
                self.windowFirstResponderDidChange()
            }
        }
        windowUpdateTask = Task { @MainActor [weak self, weak window] in
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didUpdateNotification, object: window) {
                guard let self else { return }
                self.reclaimEditorIfNeeded(in: window, respectingNativeTextInput: true)
            }
        }
        applicationActivationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification,
                object: NSApp
            ) {
                guard let self else { return }
                self.applicationDidBecomeActive()
            }
        }
        reconcileAgentKeyMonitor()
        scheduleDeferredReclaim()
    }

    /// Detaches all focus hooks and invalidates work queued for the old window.
    func detach() {
        if attachedWindow?.initialFirstResponder === editorView {
            attachedWindow?.initialFirstResponder = nil
        }
        firstResponderTask?.cancel()
        firstResponderTask = nil
        windowUpdateTask?.cancel()
        windowUpdateTask = nil
        applicationActivationTask?.cancel()
        applicationActivationTask = nil
        deferredReclaimTask?.cancel()
        deferredReclaimTask = nil
        removeAgentKeyMonitor()
        attachedWindow = nil
        presentationFocusRequested = false
    }

    /// Rechecks editor focus after SwiftUI updates its hosted AppKit hierarchy.
    func swiftUIUpdateDidOccur() {
        scheduleDeferredReclaim()
    }

    /// Reclaims editor focus after the attached window becomes key.
    func windowDidBecomeKey() {
        reconcileRequestedPresentationFocus()
        scheduleDeferredReclaim()
    }

    /// Reclaims editor focus immediately when a pointer interaction explicitly returns to the editor.
    func pointerReturnedToEditor() {
        guard let window = attachedWindow else { return }
        reclaimEditorIfNeeded(in: window, respectingNativeTextInput: false)
    }

    /// Reclaims editor focus after AppKit completes a file-drop interaction.
    func fileDropDidComplete() {
        scheduleDeferredReclaim()
    }

    /// Suspends editor focus reclamation while an AppKit sheet or modal panel owns focus.
    func beginNativeModal() {
        nativeModalDepth += 1
        deferredReclaimTask?.cancel()
        deferredReclaimTask = nil
    }

    /// Ends one native modal scope and restores the editor responder when the last scope closes.
    func endNativeModalAndRestore() {
        nativeModalDepth = max(0, nativeModalDepth - 1)
        guard nativeModalDepth == 0 else { return }
        restoreAfterNativeModal()
    }

    /// Brings the attached editor window forward and restores its responder after a native modal closes.
    func restoreAfterNativeModal() {
        guard let window = attachedWindow else { return }
        window.makeKeyAndOrderFront(nil)
        reclaimEditorIfNeeded(in: window, respectingNativeTextInput: false)
    }

    /// Updates overlay key routing and returns focus when the overlay closes.
    func agentOverlayVisibilityDidChange(_ visible: Bool) {
        guard agentOverlayVisible != visible else { return }
        agentOverlayVisible = visible
        reconcileAgentKeyMonitor()
        if !visible {
            scheduleDeferredReclaim()
        }
    }

    /// Returns true while AppKit's native field editor owns text input or IME composition.
    func nativeTextEditingIsActive() -> Bool {
        guard let window = attachedWindow else { return false }
        return window.firstResponder is NSText
    }

    /// Returns native keyboard focus to the editor for an accessibility focus request.
    func requestAccessibilityFocus() -> Bool {
        guard let window = attachedWindow,
              let editorView,
              editorView.window === window
        else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if window.firstResponder !== editorView {
            window.makeFirstResponder(editorView)
        }
        return NSApp.isActive && window.isKeyWindow && window.firstResponder === editorView
    }

    /// Activates the app and returns whether the requested editor focus postcondition now holds.
    func requestPresentationFocus() -> Bool {
        guard nativeModalDepth == 0 else { return false }
        guard let window = attachedWindow,
              let editorView,
              editorView.window === window
        else { return false }
        presentationFocusRequested = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !nativeTextEditingIsActive(), window.firstResponder !== editorView {
            window.makeFirstResponder(editorView)
        }
        reconcileRequestedPresentationFocus()
        return presentationFocusReady()
    }

    /// Reclaims and verifies the AppKit responder state required by a native open receipt.
    func presentationFocusReady() -> Bool {
        guard nativeModalDepth == 0 else { return false }
        guard let window = attachedWindow,
              let editorView,
              editorView.window === window,
              window.isVisible,
              !window.isMiniaturized,
              NSApp.isActive,
              window.isKeyWindow,
              !nativeTextEditingIsActive()
        else { return false }
        if window.firstResponder !== editorView {
            window.makeFirstResponder(editorView)
        }
        return window.firstResponder === editorView
    }

    /// Routes one overlay event through the editor's existing responder methods when policy permits.
    func routeAgentOverlayEvent(_ event: NSEvent) -> NSEvent? {
        guard nativeModalDepth == 0,
              agentOverlayVisible,
              let window = attachedWindow,
              let editorView,
              editorView.window === window
        else {
            return event
        }
        if event.windowNumber != window.windowNumber {
            return event
        }
        if event.type == .keyDown, Self.shouldYieldSystemCommandShortcut(event) {
            return event
        }
        if nativeTextEditingIsActive() {
            return event
        }

        switch event.type {
        case .keyDown:
            editorView.keyDown(with: event)
        case .keyUp:
            editorView.keyUp(with: event)
        case .flagsChanged:
            editorView.flagsChanged(with: event)
        default:
            return event
        }
        return nil
    }

    /// Returns true for shortcuts that AppKit or the menu bar must handle.
    static func shouldYieldSystemCommandShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "q", "h", "m", "n", "o", "s", "w", "z", "x", "c", "v", "a", "f", "b", ",", "=", "+", "-", "0":
                return true
            default:
                return false
            }
        }

        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "s", "S", "z", "Z", "=", "+":
                return true
            default:
                return false
            }
        }

        if modifiers == [.command, .control] {
            return event.charactersIgnoringModifiers == "f"
        }

        return false
    }

    private func scheduleDeferredReclaim() {
        guard nativeModalDepth == 0 else { return }
        deferredReclaimTask?.cancel()
        deferredReclaimTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let window = self.attachedWindow else { return }
            self.reclaimEditorIfNeeded(in: window, respectingNativeTextInput: true)
        }
    }

    private func applicationDidBecomeActive() {
        reconcileRequestedPresentationFocus()
    }

    private func windowFirstResponderDidChange() {
        reconcileRequestedPresentationFocus()
    }

    private func reconcileRequestedPresentationFocus() {
        guard presentationFocusRequested,
              presentationFocusReady(),
              let editorView
        else { return }
        presentationFocusRequested = false
        editorView.nativeApplicationFocusDidSettle()
    }

    private func reclaimEditorIfNeeded(in window: NSWindow, respectingNativeTextInput: Bool) {
        guard nativeModalDepth == 0,
              attachedWindow === window,
              let editorView,
              editorView.window === window
        else {
            return
        }
        if respectingNativeTextInput, window.firstResponder is NSText {
            return
        }
        if window.firstResponder !== editorView {
            window.makeFirstResponder(editorView)
        }
    }

    private func reconcileAgentKeyMonitor() {
        guard agentOverlayVisible, attachedWindow != nil else {
            removeAgentKeyMonitor()
            return
        }
        guard agentKeyMonitor == nil else { return }

        agentKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.routeAgentOverlayEvent(event)
        }
    }

    private func removeAgentKeyMonitor() {
        guard let agentKeyMonitor else { return }
        NSEvent.removeMonitor(agentKeyMonitor)
        self.agentKeyMonitor = nil
    }
}
