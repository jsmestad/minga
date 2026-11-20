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
    private var pendingStartupRetry: StartupRetry?

    private struct StartupRetry {
        let deadline: DispatchTime
        let onFailure: (StartupFailure) -> Void
    }

    /// Called when the BEAM exits unexpectedly and restart limits are exceeded.
    var onCrash: (@MainActor () -> Void)?

    /// Lets application termination claim a process exit before automatic restart policy runs.
    var onTermination: (@MainActor (_ status: Int32) -> Bool)?

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
        case startupFailed
        case appShutdown
    }

    private(set) var exitIntent: ExitIntent = .running
    var isShuttingDown: Bool { exitIntent == .appShutdown }

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

    /// Whether the app is responsible for launching its editor core.
    static var isBundleMode: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MingaEmbeddedCore") as? Bool == true
            || BEAMLaunchInputAcquirer.embeddedExecutableURL() != nil
    }

    enum StartupFailure: Equatable {
        case missingRelease
        case missingDevelopmentProfile
        case launch(String)
        case previousCoreStopTimedOut
    }

    /// Acquires current bundle inputs and spawns the owned BEAM child.
    func start(onStartupFailure: ((StartupFailure) -> Void)? = nil) {
        guard exitIntent != .appShutdown, process == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let configuration = launchConfiguration(environment: environment) else {
            NSLog("BEAMProcessManager: no embedded BEAM release found")
            onStartupFailure?(.missingRelease)
            return
        }
        guard EmbeddedCoreProfile.permitsLaunch(environment) else {
            NSLog("BEAMProcessManager: Debug embedded core requires a private development profile")
            onStartupFailure?(.missingDevelopmentProfile)
            return
        }
        start(configuration: configuration, onStartupFailure: onStartupFailure)
    }

    /// Spawns a child from complete launch inputs and observes its termination.
    func start(configuration: BEAMLaunchConfiguration, onStartupFailure: ((StartupFailure) -> Void)? = nil) {
        guard exitIntent != .appShutdown, process == nil else { return }
        exitIntent = .running

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
            MainRunLoopAction {
                guard let self, self.process === process else { return }
                self.handleTermination(
                    status: process.terminationStatus,
                    reason: process.terminationReason
                )
            }.enqueue()
        }

        do {
            try proc.run()
        } catch {
            NSLog("BEAMProcessManager: failed to start BEAM: \(error)")
            for handle in [stdinPipe.fileHandleForReading, stdinPipe.fileHandleForWriting,
                           stdoutPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting] {
                closeLaunchHandle(handle)
            }
            endBackgroundActivity()
            if let onStartupFailure {
                onStartupFailure(.launch(error.localizedDescription))
            } else {
                onCrash?()
            }
            return
        }

        self.process = proc
        self.readHandle = stdoutPipe.fileHandleForReading
        self.writeHandle = stdinPipe.fileHandleForWriting

        NSLog("BEAMProcessManager: BEAM started (pid \(proc.processIdentifier))")

        onBEAMReady?(stdoutPipe.fileHandleForReading, stdinPipe.fileHandleForWriting)
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

    /// Keeps a failed startup's child owned without allowing its exit to launch another core automatically.
    func suppressStartupRestart() {
        guard exitIntent != .appShutdown else { return }
        exitIntent = .startupFailed
    }

    /// Stops a child that never received a protocol connection, while preserving explicit Retry.
    func stopUnconnectedStartup() {
        suppressStartupRestart()
        closeLaunchPipes()
        if let process, process.isRunning { process.terminate() }
    }

    /// Replaces the startup core only after its termination callback. A slow stop never starts a second child.
    func retryStartup(stopTimeout: TimeInterval = 3, onFailure: @escaping (StartupFailure) -> Void) {
        guard exitIntent != .appShutdown, pendingStartupRetry == nil else { return }
        restartTimestamps.removeAll()
        guard let stopping = process else {
            start(onStartupFailure: onFailure)
            return
        }

        exitIntent = .startupFailed
        let deadline = DispatchTime.now() + stopTimeout
        pendingStartupRetry = StartupRetry(deadline: deadline, onFailure: onFailure)
        if stopping.isRunning { stopping.terminate() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { [weak self] in
            MainRunLoopAction {
                guard let self, self.process === stopping, let retry = self.pendingStartupRetry else { return }
                self.pendingStartupRetry = nil
                retry.onFailure(.previousCoreStopTimedOut)
            }.enqueue()
        }
    }

    func beginAppShutdown() {
        exitIntent = .appShutdown
        pendingStartupRetry = nil
    }

    /// Hands the launch pipes to a successfully constructed ProtocolConnection without closing them.
    func transferPipeOwnership() {
        readHandle = nil
        writeHandle = nil
    }

    /// Aborts an owned launch without blocking the main actor or scheduling a restart.
    func abortStartup() {
        beginAppShutdown()
        if let process, process.isRunning {
            process.terminate()
        }
        closeLaunchPipes()
        if process == nil {
            endBackgroundActivity()
        }
    }

    private func closeLaunchPipes() {
        let handles = [writeHandle, readHandle].compactMap { $0 }
        writeHandle = nil
        readHandle = nil
        for handle in handles {
            closeLaunchHandle(handle)
        }
    }

    private func closeLaunchHandle(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            NSLog("BEAMProcessManager: failed to close launch pipe: \(error)")
        }
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
        case .appShutdown, .startupFailed:
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
        if exitIntent == .appShutdown || exitIntent == .startupFailed { return .normalExit }
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
    private func launchConfiguration(environment: [String: String]) -> BEAMLaunchConfiguration? {
        guard let inputs = BEAMLaunchInputAcquirer.current(
            appInstanceID: appInstanceID,
            launchNonce: launchNonce,
            environment: environment
        ) else { return nil }

        return BEAMLaunchConfiguration.build(from: inputs)
    }

    /// Handles BEAM exit. Kept non-`private` so the termination path can be
    /// exercised directly in tests that assert the main actor is not blocked.
    func handleTermination(status: Int32, reason: Process.TerminationReason) {
        NSLog("BEAMProcessManager: BEAM exited (status \(status), reason \(reason.rawValue))")

        self.process = nil
        closeLaunchPipes()
        endBackgroundActivity()

        if let retry = pendingStartupRetry {
            pendingStartupRetry = nil
            if DispatchTime.now() < retry.deadline {
                start(onStartupFailure: retry.onFailure)
            } else {
                retry.onFailure(.previousCoreStopTimedOut)
            }
            return
        }

        if onTermination?(status) == true { return }
        if exitIntent == .startupFailed { return }

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
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                MainRunLoopAction {
                    guard let self, self.exitIntent == .restartScheduled else { return }
                    self.start()
                }.enqueue()
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
