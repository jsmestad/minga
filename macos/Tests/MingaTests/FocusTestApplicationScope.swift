import AppKit
import Testing

/// Process-global presentation setup for tests that promise active-window AX identity.
/// Run these tests with exclusive presentation ownership; suite-local serialization does not exclude other suites.
@MainActor
final class FocusTestApplicationScope {
    private static var launchCompletionRequested = false

    private let label: String
    private let previousPolicy: NSApplication.ActivationPolicy
    private let previousFrontmost: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?
    private let initiallyActive: Bool
    private let initiallyFinishedLaunching: Bool
    private var policyAccepted = false
    private var requestedLaunchCompletion = false
    private var notifications: [String] = []
    private var observationTasks: [Task<Void, Never>] = []

    init(_ label: String) throws {
        let app = NSApplication.shared
        self.label = label
        previousPolicy = app.activationPolicy()
        previousFrontmost = NSWorkspace.shared.frontmostApplication
        previousKeyWindow = app.keyWindow
        initiallyActive = app.isActive
        initiallyFinishedLaunching = NSRunningApplication.current.isFinishedLaunching

        let names: [Notification.Name] = [
            NSApplication.didFinishLaunchingNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ]
        // Async observation may begin after startup notifications have fired.
        // Scalar launch state, not notification presence, is the startup receipt.
        observationTasks = names.map { name in
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard !Task.isCancelled, let self else { return }
                    self.notifications.append(name.rawValue)
                }
            }
        }

        // MingaApp establishes this policy in applicationDidFinishLaunching.
        // Merely constructing NSApplication.shared in xctest does not do so.
        policyAccepted = app.setActivationPolicy(.regular)
        if !policyAccepted {
            close()
        }
        try #require(policyAccepted, "AppKit rejected regular activation policy: \(diagnostics)")
        if !NSRunningApplication.current.isFinishedLaunching && !Self.launchCompletionRequested {
            Self.launchCompletionRequested = true
            requestedLaunchCompletion = true
            app.finishLaunching()
        }
        // Launch completion is process-owned and irreversible.
        // In particular, isRunning describes an event loop, not whether launch has completed.
        app.activate(ignoringOtherApps: true)
        print("[Focus application \(label)] startup \(diagnostics)")
    }

    deinit {
        for task in observationTasks { task.cancel() }
    }

    var diagnostics: String {
        "pid=\(ProcessInfo.processInfo.processIdentifier) initialPolicy=\(previousPolicy.rawValue) policyAccepted=\(policyAccepted) policy=\(NSApp.activationPolicy().rawValue) initiallyActive=\(initiallyActive) active=\(NSApp.isActive) initiallyFinishedLaunching=\(initiallyFinishedLaunching) requestedLaunchCompletion=\(requestedLaunchCompletion) finishedLaunching=\(NSRunningApplication.current.isFinishedLaunching) isRunning=\(NSApp.isRunning) notifications=\(notifications)"
    }

    /// Observe activation only.
    /// Calling presentationFocusReady here would also apply focus policy and turn observation into a focus-repair mechanism.
    func waitUntilPresented(_ window: NSWindow) async throws {
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(NSApp.isActive, "Application did not activate: \(diagnostics)")
        try #require(window.isKeyWindow, "Window did not become key; visible=\(window.isVisible) canBecomeKey=\(window.canBecomeKey): \(diagnostics)")
    }

    /// Call after the test's consumer windows have detached and closed.
    /// Never restore an arbitrary first responder or pretend to undo finishLaunching.
    func close() {
        print("[Focus application \(label)] teardown \(diagnostics)")
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll()
        if let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.setActivationPolicy(previousPolicy)
        if !initiallyActive, let previousFrontmost,
           previousFrontmost.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousFrontmost.activate(options: [])
        }
    }
}
