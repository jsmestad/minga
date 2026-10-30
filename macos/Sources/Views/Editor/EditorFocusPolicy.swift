import AppKit
import Combine
import MingaProtocol
@_spi(FocusPolicy) import MingaUI

/// Owns AppKit focus reclamation and overlay key-routing lifetime for one editor view.
@MainActor
final class EditorFocusPolicy: EditorFocusControlling {
    private static let maximumLoggedFirstResponderEvents = 32

    private weak var editorView: NSView?
    private weak var attachedWindow: NSWindow?
    private let focusDiagnosticLog = EditorFocusDiagnosticLog()
    private var firstResponderTask: Task<Void, Never>?
    private var windowUpdateTask: Task<Void, Never>?
    private var applicationActivationTask: Task<Void, Never>?
    private var deferredReclaimTask: Task<Void, Never>?
    private var agentKeyMonitor: Any?
    private var nativeModalDepth = 0
    private var presentationFocusRequested = false
    private var firstResponderEventCount = 0
    let focusOwnerState: FocusOwnerState
    private(set) var decodedOwner: Wire.FocusOwner?
    private(set) var localTextEditing: LocalTextEditing?
    private(set) var pendingOwnerApply = false
    private weak var pickerQuery: NSResponder?
    private weak var searchQuery: NSResponder?
    private weak var inlineEdit: NSResponder?
    private var applyingOwner = false

    private(set) var agentOverlayVisible = false

    convenience init(editorView: EditorNSView) {
        self.init(editorView: editorView, focusOwnerState: editorView.dispatcher.guiState.focusOwnerState)
    }

    /// Accepts a real NSView so offscreen-window tests exercise the AppKit responder chain.
    init(editorView: NSView, focusOwnerState: FocusOwnerState) {
        self.editorView = editorView
        self.focusOwnerState = focusOwnerState
    }

    /// Records the authoritative owner only after its frame commits.
    func focusOwnerDidChange(_ owner: Wire.FocusOwner) {
        decodedOwner = owner
        focusOwnerState.publish(owner: owner)
        applyDecodedOwner()
    }

    /// Registers a field even when SwiftUI has not attached it to its window yet.
    func register(_ responder: NSResponder, as kind: Wire.FocusOwner.Responder) {
        switch kind {
        case .editorView: return
        case .pickerQuery: pickerQuery = responder
        case .searchQuery: searchQuery = responder
        case .inlineEdit: inlineEdit = responder
        }
        applyDecodedOwner()
        scheduleDeferredReclaim()
    }

    /// Removes only this instance; dismantling an old hierarchy cannot unregister its replacement.
    func unregister(_ responder: NSResponder, as kind: Wire.FocusOwner.Responder) {
        guard self.responder(for: kind) === responder else { return }
        unregister(kind: kind)
    }

    func unregister(kind: Wire.FocusOwner.Responder) {
        switch kind {
        case .editorView: return
        case .pickerQuery: pickerQuery = nil
        case .searchQuery: searchQuery = nil
        case .inlineEdit: inlineEdit = nil
        }
        applyDecodedOwner()
    }

    /// Grants immediate frontend-local focus, without a BEAM round trip.
    func beginLocalTextEditing(_ editing: LocalTextEditing) {
        guard nativeModalDepth == 0 else { return }
        localTextEditing = editing
        focusOwnerState.publish(localTextEditing: editing)
    }

    /// Releases only the matching lease, then retries the latest decoded owner.
    func endLocalTextEditing(_ editing: LocalTextEditing) {
        guard localTextEditing == editing else { return }
        localTextEditing = nil
        focusOwnerState.publish(localTextEditing: nil)
        applyDecodedOwner()
        scheduleDeferredReclaim()
    }

    /// Retries after the native field editor has finished its end-editing notification.
    func nativeTextEditingDidEnd() {
        scheduleDeferredReclaim()
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
            applyDecodedOwner()
            return
        }

        detach()
        attachedWindow = window
        applyDecodedOwner()
        firstResponderTask = Task { @MainActor [weak self, weak window] in
            guard let window else { return }
            for await _ in window.publisher(for: \.firstResponder, options: [.new]).values {
                guard let self else { return }
                self.recordFirstResponderEvent()
                self.windowFirstResponderDidChange()
            }
        }
        windowUpdateTask = Task { @MainActor [weak self, weak window] in
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didUpdateNotification, object: window) {
                guard let self else { return }
                self.applyDecodedOwner()
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
        attachedWindow?.initialFirstResponder = nil
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

    /// Records native state when the first render frame reaches the application.
    func firstFrameDidRender() {
        recordFocusDiagnostic(point: "first-frame")
    }

    /// Reclaims the decoded owner after the attached window becomes key.
    func windowDidBecomeKey() {
        recordFocusDiagnostic(point: "window-did-become-key")
        applyDecodedOwner()
        reconcileRequestedPresentationFocus()
        scheduleDeferredReclaim()
    }

    /// Reapplies the decoded owner when a pointer interaction returns to the editor.
    func pointerReturnedToEditor() {
        applyDecodedOwner()
    }

    /// Reclaims the decoded owner after AppKit completes a file-drop interaction.
    func fileDropDidComplete() {
        scheduleDeferredReclaim()
    }

    /// Suspends owner application while an AppKit sheet or modal panel owns focus.
    func beginNativeModal() {
        nativeModalDepth += 1
        deferredReclaimTask?.cancel()
        deferredReclaimTask = nil
    }

    /// Ends one native modal scope and restores the named responder when the last scope closes.
    func endNativeModalAndRestore() {
        nativeModalDepth = max(0, nativeModalDepth - 1)
        guard nativeModalDepth == 0 else { return }
        restoreAfterNativeModal()
    }

    /// Brings the window forward and restores the decoded owner after a native modal closes.
    func restoreAfterNativeModal() {
        guard let window = attachedWindow else { return }
        window.makeKeyAndOrderFront(nil)
        applyDecodedOwner()
    }

    /// Updates overlay key routing and reapplies the decoded owner.
    func agentOverlayVisibilityDidChange(_ visible: Bool) {
        guard agentOverlayVisible != visible else { return }
        agentOverlayVisible = visible
        reconcileAgentKeyMonitor()
        applyDecodedOwner()
        if !visible {
            scheduleDeferredReclaim()
        }
    }

    /// Returns true while AppKit's native field editor owns text input or IME composition.
    func nativeTextEditingIsActive() -> Bool {
        guard let window = attachedWindow else { return false }
        return window.firstResponder is NSText
    }

    /// Activates the window without overriding the owner named by the BEAM.
    func requestAccessibilityFocus() -> Bool {
        guard let window = attachedWindow else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        applyDecodedOwner()
        return NSApp.isActive && window.isKeyWindow && decodedResponderHasFocus()
    }

    /// Activates the app and returns whether the requested editor focus postcondition now holds.
    func requestPresentationFocus() -> Bool {
        recordFocusDiagnostic(point: "presentation-focus-request")
        guard nativeModalDepth == 0 else {
            recordFocusDiagnostic(point: "presentation-focus-result", requestResult: false)
            return false
        }
        guard let window = attachedWindow,
              editorView?.window === window
        else {
            recordFocusDiagnostic(point: "presentation-focus-result", requestResult: false)
            return false
        }
        presentationFocusRequested = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        applyDecodedOwner()
        reconcileRequestedPresentationFocus()
        let result = presentationFocusReady()
        recordFocusDiagnostic(point: "presentation-focus-result", requestResult: result)
        return result
    }

    /// Verifies the named responder postcondition required by a native open receipt.
    func presentationFocusReady() -> Bool {
        guard nativeModalDepth == 0, localTextEditing == nil,
              let window = attachedWindow,
              window.isVisible, !window.isMiniaturized,
              NSApp.isActive, window.isKeyWindow
        else { return false }
        applyDecodedOwner()
        return decodedResponderHasFocus()
    }

    /// Routes one overlay event through the editor's existing responder methods when policy permits.
    func routeAgentOverlayEvent(_ event: NSEvent) -> NSEvent? {
        guard nativeModalDepth == 0,
              agentOverlayVisible,
              let window = attachedWindow,
              let editorView = editorView as? EditorNSView,
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
            guard !Task.isCancelled, let self else { return }
            self.applyDecodedOwner()
        }
    }

    private func applicationDidBecomeActive() {
        recordFocusDiagnostic(point: "application-did-become-active")
        reconcileRequestedPresentationFocus()
        applyDecodedOwner()
    }

    private func recordFirstResponderEvent() {
        if firstResponderEventCount < Self.maximumLoggedFirstResponderEvents + 1 {
            firstResponderEventCount += 1
        }
        guard firstResponderEventCount <= Self.maximumLoggedFirstResponderEvents else { return }
        recordFocusDiagnostic(point: "first-responder-publisher-event")
    }

    private func recordFocusDiagnostic(point: String, requestResult: Bool? = nil) {
        focusDiagnosticLog.record(
            point: point,
            applicationIsActive: NSApp.isActive,
            window: attachedWindow,
            editorView: editorView,
            nativeModalDepth: nativeModalDepth,
            presentationFocusRequested: presentationFocusRequested,
            firstResponderEventCount: firstResponderEventCount,
            requestResult: requestResult
        )
    }

    private func windowFirstResponderDidChange() {
        if !applyingOwner { applyDecodedOwner() }
        guard presentationFocusRequested, presentationFocusReady(),
              let editorView = editorView as? EditorNSView else { return }
        presentationFocusRequested = false
        editorView.nativeApplicationFocusDidSettle()
    }

    private func reconcileRequestedPresentationFocus() {
        guard presentationFocusRequested,
              presentationFocusReady(),
              let editorView = editorView as? EditorNSView
        else { return }
        presentationFocusRequested = false
        editorView.nativeApplicationFocusDidSettle()
    }

    private func responder(for kind: Wire.FocusOwner.Responder) -> NSResponder? {
        switch kind {
        case .editorView: return editorView
        case .pickerQuery: return pickerQuery
        case .searchQuery: return searchQuery
        case .inlineEdit: return inlineEdit
        }
    }

    private func responderForDecodedOwner() -> NSResponder? {
        guard let kind = decodedOwner?.responderKind else { return nil }
        return responder(for: kind)
    }

    private func hasFocus(_ responder: NSResponder, in window: NSWindow) -> Bool {
        if window.firstResponder === responder { return true }
        guard let field = responder as? NSTextField, let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    private func decodedResponderHasFocus() -> Bool {
        guard let window = attachedWindow, let responder = responderForDecodedOwner() else { return false }
        return hasFocus(responder, in: window)
    }

    /// The only native first-responder writer. Missing fields and text/modal leases
    /// retain the latest owner until registration or a lifecycle retry can apply it.
    private func applyDecodedOwner() {
        guard !applyingOwner, decodedOwner != nil else { return }
        pendingOwnerApply = true
        guard nativeModalDepth == 0, localTextEditing == nil,
              let window = attachedWindow,
              let responder = responderForDecodedOwner(),
              let view = responder as? NSView, view.window === window
        else { return }
        guard (editorView as? EditorNSView)?.hasMarkedText() != true else { return }
        if hasFocus(responder, in: window) {
            pendingOwnerApply = false
            (responder as? any EditorFocusReceiving)?.editorFocusDidApply()
            return
        }
        guard !nativeTextEditingIsActive() else { return }
        applyingOwner = true
        window.initialFirstResponder = view
        let applied = window.makeFirstResponder(responder)
        if applied { (responder as? any EditorFocusReceiving)?.editorFocusDidApply() }
        applyingOwner = false
        pendingOwnerApply = !applied
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

@MainActor
private final class EditorFocusDiagnosticLog {
    private static let environmentKey = "MINGA_AX_FOCUS_LOG"
    private static let maximumRecords = 64

    private let outputURL: URL?
    private var records: [Record] = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["MINGA_AX_ISOLATED_RUN"] == "1",
              let path = environment[Self.environmentKey],
              path.hasPrefix("/")
        else {
            outputURL = nil
            return
        }
        outputURL = URL(fileURLWithPath: path)
    }

    func record(
        point: String,
        applicationIsActive: Bool,
        window: NSWindow?,
        editorView: NSView?,
        nativeModalDepth: Int,
        presentationFocusRequested: Bool,
        firstResponderEventCount: Int,
        requestResult: Bool?
    ) {
        guard let outputURL, records.count < Self.maximumRecords else { return }
        let responder = window?.firstResponder
        records.append(
            Record(
                sequence: records.count + 1,
                point: point,
                applicationIsActive: applicationIsActive,
                windowAttached: window != nil,
                windowMatchesEditor: editorView?.window === window,
                windowIsVisible: window?.isVisible,
                windowIsMiniaturized: window?.isMiniaturized,
                windowIsKey: window?.isKeyWindow,
                responderType: responder.map { String(reflecting: type(of: $0)) },
                responderIdentity: responder.map { String(describing: ObjectIdentifier($0)) },
                editorIdentity: editorView.map { String(describing: ObjectIdentifier($0)) },
                responderIsEditor: responder === editorView,
                responderIsNativeText: responder is NSText,
                nativeModalDepth: nativeModalDepth,
                presentationFocusRequested: presentationFocusRequested,
                firstResponderEventCount: firstResponderEventCount,
                requestResult: requestResult
            )
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: outputURL, options: .atomic)
        } catch {
            NSLog("Accessibility focus diagnostic write failed: %@", String(describing: error))
        }
    }

    private struct Record: Encodable {
        let sequence: Int
        let point: String
        let applicationIsActive: Bool
        let windowAttached: Bool
        let windowMatchesEditor: Bool
        let windowIsVisible: Bool?
        let windowIsMiniaturized: Bool?
        let windowIsKey: Bool?
        let responderType: String?
        let responderIdentity: String?
        let editorIdentity: String?
        let responderIsEditor: Bool
        let responderIsNativeText: Bool
        let nativeModalDepth: Int
        let presentationFocusRequested: Bool
        let firstResponderEventCount: Int
        let requestResult: Bool?
    }
}
