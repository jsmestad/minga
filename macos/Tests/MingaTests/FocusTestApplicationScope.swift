import AppKit
import Testing

/// Process-global presentation setup for tests that promise active-window AX identity.
/// Run these tests with exclusive presentation ownership; suite-local serialization does not exclude other suites.
@MainActor
final class FocusTestApplicationScope {
    private let label: String
    private let initialPolicy: NSApplication.ActivationPolicy
    private let previousFrontmost: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?
    private let initiallyActive: Bool
    private let initiallyFinishedLaunching: Bool
    private var notifications: [String] = []
    private var observationTasks: [Task<Void, Never>] = []

    init(_ label: String) async throws {
        let app = NSApplication.shared
        self.label = label
        initialPolicy = app.activationPolicy()
        previousFrontmost = NSWorkspace.shared.frontmostApplication
        previousKeyWindow = app.keyWindow
        initiallyActive = app.isActive
        initiallyFinishedLaunching = NSRunningApplication.current.isFinishedLaunching

        try #require(Bundle.main.bundleIdentifier == "com.minga.test-host", "Focus tests require MingaTestHost: \(diagnostics)")
        try #require(Bundle.main.bundleURL.lastPathComponent == "MingaTestHost.app", "Unexpected host bundle: \(diagnostics)")
        try #require(Bundle.main.executableURL?.lastPathComponent == "MingaTestHost", "Unexpected host executable: \(diagnostics)")
        // The host owns run() and launch completion; this scope only observes.
        for _ in 0..<100 {
            if app.isRunning && NSRunningApplication.current.isFinishedLaunching { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(app.isRunning, "Native host has no application event loop: \(diagnostics)")
        try #require(NSRunningApplication.current.isFinishedLaunching, "Native host has not finished launching: \(diagnostics)")
        try #require(app.activationPolicy() == .regular, "Native host must establish regular activation policy: \(diagnostics)")

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

        app.activate(ignoringOtherApps: true)
        print("[Focus application \(label)] startup \(diagnostics)")
    }

    deinit {
        for task in observationTasks { task.cancel() }
    }

    var diagnostics: String {
        "pid=\(ProcessInfo.processInfo.processIdentifier) host=\(Bundle.main.bundleIdentifier ?? "-") bundle=\(Bundle.main.bundleURL.path) executable=\(Bundle.main.executableURL?.path ?? "-") initialPolicy=\(initialPolicy.rawValue) policy=\(NSApp.activationPolicy().rawValue) initiallyActive=\(initiallyActive) active=\(NSApp.isActive) initiallyFinishedLaunching=\(initiallyFinishedLaunching) finishedLaunching=\(NSRunningApplication.current.isFinishedLaunching) isRunning=\(NSApp.isRunning) notifications=\(notifications)"
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
    /// Never restore arbitrary first responders or alter the host's launch lifecycle.
    func close() {
        print("[Focus application \(label)] teardown \(diagnostics)")
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll()
        if let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKeyAndOrderFront(nil)
        }
        if !initiallyActive, let previousFrontmost,
           previousFrontmost.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousFrontmost.activate(options: [])
        }
    }
}
