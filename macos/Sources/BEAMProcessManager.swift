/// Manages the BEAM child process when running in bundle mode.
///
/// When the user launches Minga.app from Finder, Spotlight, or the Dock,
/// this class discovers the embedded BEAM release inside the app bundle,
/// spawns it as a child process with piped stdin/stdout, and monitors
/// its lifecycle.
///
/// The BEAM receives `MINGA_PORT_MODE=connected` in its environment,
/// which tells Port.Manager to open `{:fd, 0, 1}` instead of spawning
/// a GUI process. The pipes connect the BEAM's stdin/stdout to our
/// ProtocolReader/ProtocolEncoder.
///
/// Crash recovery: if the BEAM exits unexpectedly, the manager attempts
/// automatic restart with exponential backoff (max 3 restarts in 5 seconds).
/// After the limit is exceeded, the onCrash callback fires so the app
/// can show an error UI.

import Foundation
import Darwin

@MainActor
final class BEAMProcessManager {
    /// Stable identity retained across BEAM child restarts in this app process.
    private let appInstanceID = UUID().uuidString.lowercased()

    /// Optional nonce supplied only by the launcher that created this app instance.
    private let launchNonce = BEAMLaunchConfiguration.launchNonce(
        from: ProcessInfo.processInfo.arguments
    )
    /// File handle for reading protocol messages from the BEAM (BEAM's stdout).
    private(set) var readHandle: FileHandle?

    /// File handle for writing protocol messages to the BEAM (BEAM's stdin).
    private(set) var writeHandle: FileHandle?

    /// The running BEAM child process.
    private var process: Process?

    /// Called when the BEAM exits unexpectedly and restart limits are exceeded.
    var onCrash: (@MainActor () -> Void)?

    /// Called when the BEAM exits normally (exit code 0).
    var onNormalExit: (@MainActor () -> Void)?

    /// Called each time the BEAM process starts (initial or restart).
    /// Provides the new read/write handles for protocol communication.
    var onBEAMReady: (@MainActor (_ readHandle: FileHandle, _ writeHandle: FileHandle) -> Void)?

    // Restart backoff tracking (OTP-style: max restarts in a time window).
    private var restartTimestamps: [Date] = []
    private let maxRestarts = 3
    private let windowSeconds: TimeInterval = 5.0

    enum ExitIntent: Equatable, Sendable {
        case running
        case transportRestart
        case restartScheduled
        case appShutdown
    }

    private(set) var exitIntent: ExitIntent = .running
    var isShuttingDown: Bool { exitIntent == .appShutdown }

    /// Whether start() has been called at least once. Used to gate
    /// onBEAMReady so it only fires on restarts, not the initial start.
    private var hasStartedOnce = false

    /// URLs for files passed via Finder "Open With" before the BEAM is ready.
    /// Flushed to the BEAM once the protocol signals ready.
    private(set) var pendingFileURLs: [URL] = []

    /// App Nap / termination assertion held for the lifetime of the BEAM child.
    ///
    /// Without this, macOS can App Nap (suspend) or automatically terminate the
    /// GUI process once it is fully occluded or hidden. A suspended GUI stops
    /// draining the BEAM's stdout pipe (render backpressure) and, if the process
    /// is reaped, drops the BEAM's stdin pipe. A dropped stdin pipe reaches the
    /// BEAM as EOF, which Frontend.Manager treats as "GUI exited" and answers
    /// with `System.stop(0)` — tearing down the whole editor node, buffers and
    /// undo included (#2698). Holding a `userInitiated` activity keeps the GUI
    /// scheduled and un-reaped while the editor core is alive; system sleep is
    /// still allowed (handled separately via the sleep/wake notifications).
    private var backgroundActivity: (any NSObjectProtocol)?

    /// Whether a BEAM child is currently running.
    var hasLiveProcess: Bool { process?.isRunning ?? false }

    /// Whether the app is running as a bundle with an embedded BEAM release.
    static var isBundleMode: Bool {
        BEAMLaunchInputAcquirer.embeddedExecutableURL() != nil
    }

    /// Spawns the BEAM release as a child process with piped stdin/stdout.
    func start() {
        guard exitIntent != .appShutdown else { return }
        guard process == nil else { return }
        if exitIntent == .restartScheduled {
            exitIntent = .running
        }
        guard let configuration = launchConfiguration() else {
            NSLog("BEAMProcessManager: no embedded BEAM release found")
            return
        }

        // Prevent App Nap / automatic + sudden termination while the BEAM lives.
        beginBackgroundActivityIfNeeded()

        let proc = Process()
        proc.executableURL = configuration.executableURL
        proc.arguments = configuration.arguments
        proc.environment = configuration.environment
        proc.currentDirectoryURL = configuration.workingDirectoryURL

        // Set up pipes for the port protocol.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe

        // Pass stderr through to the app's stderr for logging.
        // The BEAM writes log messages to stderr; they'll appear in
        // Console.app and Xcode's debug output.
        proc.standardError = FileHandle.standardError

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(
                    status: process.terminationStatus,
                    reason: process.terminationReason
                )
            }
        }

        do {
            try proc.run()
        } catch {
            NSLog("BEAMProcessManager: failed to start BEAM: \(error)")
            onCrash?()
            return
        }

        self.process = proc
        self.readHandle = stdoutPipe.fileHandleForReading
        self.writeHandle = stdinPipe.fileHandleForWriting

        NSLog("BEAMProcessManager: BEAM started (pid \(proc.processIdentifier))")

        // Only fire onBEAMReady on restarts, not the initial start.
        // The initial start is handled by AppDelegate.applicationDidFinishLaunching
        // which reads readHandle/writeHandle directly.
        if hasStartedOnce {
            onBEAMReady?(stdoutPipe.fileHandleForReading, stdinPipe.fileHandleForWriting)
        }
        hasStartedOnce = true
    }

    /// Buffers a file URL for opening once the BEAM is ready.
    func bufferFileURL(_ url: URL) {
        pendingFileURLs.append(url)
    }

    /// Returns and clears the pending file URLs.
    func flushPendingFileURLs() -> [URL] {
        let urls = pendingFileURLs
        pendingFileURLs = []
        return urls
    }

    /// Sends SIGUSR2 to the BEAM so the Watchdog restarts the editor core while preserving buffers.
    func sendRecoveryRestartSignal() {
        guard let proc = process, proc.isRunning else { return }
        kill(proc.processIdentifier, SIGUSR2)
    }

    /// Re-spawns the BEAM after the automatic restart budget was exhausted.
    ///
    /// Called from the recovery surface (user chose "Restart Editor"). Clears
    /// the crash-backoff history so the fresh process gets a clean budget.
    func restartAfterRecovery() {
        restartTimestamps.removeAll()
        exitIntent = .restartScheduled
        start()
    }

    func beginAppShutdown() {
        exitIntent = .appShutdown
    }

    enum TransportRestartDisposition: Equatable, Sendable {
        case terminateForRestart
        case startImmediately
        case awaitProcessTermination
        case awaitScheduledRestart
        case rejectDuringShutdown
    }

    nonisolated static func transportRestartDisposition(
        managedProcessPresent: Bool,
        processIsRunning: Bool,
        exitIntent: ExitIntent
    ) -> TransportRestartDisposition {
        switch exitIntent {
        case .appShutdown:
            return .rejectDuringShutdown
        case .restartScheduled, .transportRestart:
            return .awaitScheduledRestart
        case .running:
            guard managedProcessPresent else { return .startImmediately }
            return processIsRunning ? .terminateForRestart : .awaitProcessTermination
        }
    }

    /// Retires a terminally failed bundled transport and lets the normal crash path install fresh pipes.
    /// The user explicitly confirms this action after being warned that unsaved changes may be lost.
    @discardableResult
    func restartTransportAfterFailure() -> TransportRestartDisposition {
        let managedProcess = process
        let disposition = Self.transportRestartDisposition(
            managedProcessPresent: managedProcess != nil,
            processIsRunning: managedProcess?.isRunning ?? false,
            exitIntent: exitIntent
        )
        switch disposition {
        case .terminateForRestart:
            restartTimestamps.removeAll()
            exitIntent = .transportRestart
            managedProcess?.terminate()
        case .awaitProcessTermination:
            restartTimestamps.removeAll()
            exitIntent = .transportRestart
        case .startImmediately:
            restartTimestamps.removeAll()
            exitIntent = .restartScheduled
            start()
        case .awaitScheduledRestart, .rejectDuringShutdown:
            break
        }
        return disposition
    }

    // MARK: - Termination decision (pure, testable)

    /// What to do when the BEAM child process exits.
    enum TerminationOutcome: Equatable {
        /// Expected exit (graceful shutdown or user quit): let the app close.
        case normalExit
        /// Unexpected crash within the restart budget: respawn after `delay`.
        case restart(delay: TimeInterval)
        /// Unexpected crash past the restart budget: surface recovery to the user.
        case giveUp
    }

    /// Decides the termination outcome from inputs only. Pure and synchronous:
    /// it performs no I/O and never blocks, so the main actor stays free when
    /// the termination handler calls it (#2698 defect B).
    nonisolated static func terminationOutcome(
        status: Int32,
        exitIntent: ExitIntent,
        recentRestartCount: Int,
        maxRestarts: Int
    ) -> TerminationOutcome {
        if exitIntent == .appShutdown { return .normalExit }
        if exitIntent == .transportRestart { return .restart(delay: 0) }
        if status == 0 { return .normalExit }
        if recentRestartCount >= maxRestarts { return .giveUp }

        let attempt = recentRestartCount + 1
        // Exponential backoff: 100ms, 200ms, 400ms
        let delay = 0.1 * pow(2.0, Double(attempt - 1))
        return .restart(delay: delay)
    }

    // MARK: - Private

    /// Acquires current inputs for one start or restart, then applies launch policy in one pure build.
    private func launchConfiguration() -> BEAMLaunchConfiguration? {
        guard let inputs = BEAMLaunchInputAcquirer.current(
            appInstanceID: appInstanceID,
            launchNonce: launchNonce
        ) else { return nil }

        return BEAMLaunchConfiguration.build(from: inputs)
    }

    /// Handles BEAM exit. Kept non-`private` so the termination path can be
    /// exercised directly in tests that assert the main actor is not blocked.
    func handleTermination(status: Int32, reason: Process.TerminationReason) {
        NSLog("BEAMProcessManager: BEAM exited (status \(status), reason \(reason.rawValue))")

        self.process = nil
        self.readHandle = nil
        self.writeHandle = nil

        // Prune old timestamps outside the restart window.
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        restartTimestamps.removeAll { $0 < cutoff }

        let outcome = Self.terminationOutcome(
            status: status,
            exitIntent: exitIntent,
            recentRestartCount: restartTimestamps.count,
            maxRestarts: maxRestarts
        )
        switch outcome {
        case .normalExit:
            if exitIntent != .appShutdown {
                exitIntent = .running
            }
            onNormalExit?()

        case .giveUp:
            exitIntent = .running
            NSLog("BEAMProcessManager: too many crashes (\(maxRestarts) in \(windowSeconds)s), giving up")
            // Recovery is presented by onCrash; it must not block the main actor.
            onCrash?()

        case let .restart(delay):
            restartTimestamps.append(now)
            exitIntent = .restartScheduled
            NSLog("BEAMProcessManager: restarting in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.exitIntent == .restartScheduled else { return }
                self.start()
            }
        }
    }

    // MARK: - App Nap / termination assertion

    private func beginBackgroundActivityIfNeeded() {
        guard backgroundActivity == nil else { return }
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Minga editor core (BEAM) is running"
        )
    }

    private func endBackgroundActivity() {
        if let token = backgroundActivity {
            ProcessInfo.processInfo.endActivity(token)
            backgroundActivity = nil
        }
    }

    // MARK: - Test hooks

    /// Seeds the crash-backoff history so tests can drive the give-up path
    /// without spawning real processes.
    func primeRestartHistoryForTesting(count: Int) {
        let now = Date()
        restartTimestamps = Array(repeating: now, count: count)
    }
}
