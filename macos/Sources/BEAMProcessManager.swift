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

@MainActor
final class BEAMProcessManager {
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

    /// Set during graceful shutdown to prevent the termination handler
    /// from attempting a restart.
    private(set) var isShuttingDown = false

    /// Whether start() has been called at least once. Used to gate
    /// onBEAMReady so it only fires on restarts, not the initial start.
    private var hasStartedOnce = false

    /// URLs for files passed via Finder "Open With" before the BEAM is ready.
    /// Flushed to the BEAM once the protocol signals ready.
    private(set) var pendingFileURLs: [URL] = []

    /// Resolves the BEAM release executable inside the app bundle.
    /// Returns nil if not running as a bundled app.
    static func beamExecutableURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let releaseURL = resourceURL
            .appendingPathComponent("release")
            .appendingPathComponent("bin")
            .appendingPathComponent("minga_macos")

        guard FileManager.default.fileExists(atPath: releaseURL.path) else { return nil }
        return releaseURL
    }

    /// Whether the app is running as a bundle with an embedded BEAM release.
    static var isBundleMode: Bool {
        beamExecutableURL() != nil
    }

    /// Spawns the BEAM release as a child process with piped stdin/stdout.
    func start() {
        guard let execURL = Self.beamExecutableURL() else {
            NSLog("BEAMProcessManager: no embedded BEAM release found")
            return
        }

        let proc = Process()
        proc.executableURL = execURL

        // Forward CLI flags (--editor, --no-context, --config) to the BEAM.
        // The CLI launcher script passes these via `open --args`, which puts
        // them in ProcessInfo.processInfo.arguments. We forward all arguments
        // that look like Minga CLI flags to the BEAM release's `start` command.
        var beamArgs = ["start"]
        let appArgs = ProcessInfo.processInfo.arguments.dropFirst() // skip argv[0]
        let mingaFlags: Set<String> = ["--editor", "--no-context", "--config"]
        var skipNext = false
        for arg in appArgs {
            if skipNext {
                beamArgs.append(arg)
                skipNext = false
                continue
            }
            if mingaFlags.contains(arg) {
                beamArgs.append(arg)
                if arg == "--config" { skipNext = true }
            }
        }
        proc.arguments = beamArgs

        // Set up pipes for the port protocol.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe

        // Pass stderr through to the app's stderr for logging.
        // The BEAM writes log messages to stderr; they'll appear in
        // Console.app and Xcode's debug output.
        proc.standardError = FileHandle.standardError

        // Tell the BEAM to use connected mode (don't spawn a GUI).
        var env = ProcessInfo.processInfo.environment
        env["MINGA_PORT_MODE"] = "connected"

        // Set RELEASE_NODE to prevent the BEAM from trying to connect
        // to other BEAM nodes (which would fail in a sandboxed app).
        env["RELEASE_DISTRIBUTION"] = "none"

        proc.environment = env

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

    /// Sends SIGTERM to the BEAM and waits briefly for clean shutdown.
    /// Used during Cmd+Q / applicationShouldTerminate.
    func shutdownGracefully(timeout: TimeInterval = 3.0) {
        guard let proc = process, proc.isRunning else { return }

        isShuttingDown = true

        // SIGTERM triggers orderly OTP shutdown in the BEAM.
        proc.terminate()

        // Wait on a background thread to avoid blocking the main thread.
        DispatchQueue.global().async {
            proc.waitUntilExit()
        }

        // Safety timeout: if the BEAM hasn't exited after `timeout` seconds,
        // force kill it. Uses global queue so it fires even if main thread is blocked.
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            // Check if the process is still alive via kill(pid, 0).
            if kill(pid, 0) == 0 {
                NSLog("BEAMProcessManager: BEAM did not exit in \(timeout)s, sending SIGKILL")
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Private

    private func handleTermination(status: Int32, reason: Process.TerminationReason) {
        NSLog("BEAMProcessManager: BEAM exited (status \(status), reason \(reason.rawValue))")

        self.process = nil
        self.readHandle = nil
        self.writeHandle = nil

        // Graceful shutdown in progress (Cmd+Q): don't restart.
        guard !isShuttingDown else {
            onNormalExit?()
            return
        }

        // Normal exit (user quit): don't restart.
        guard status != 0 else {
            onNormalExit?()
            return
        }

        // Prune old timestamps outside the restart window.
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        restartTimestamps.removeAll { $0 < cutoff }

        if restartTimestamps.count >= maxRestarts {
            NSLog("BEAMProcessManager: too many crashes (\(maxRestarts) in \(windowSeconds)s), giving up")
            onCrash?()
            return
        }

        restartTimestamps.append(now)

        // Exponential backoff: 100ms, 200ms, 400ms
        let delay = 0.1 * pow(2.0, Double(restartTimestamps.count - 1))
        NSLog("BEAMProcessManager: restarting in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.start()
        }
    }
}
