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

/// A file-opening request delivered by macOS Launch Services.
///
/// Regular file URLs retain the normal Finder/Open With path. The private
/// `minga://wait/...` URL is transport used by the bundled CLI shim so a
/// terminal process can wait for BEAM-owned editor completion semantics.
enum AppOpenRequest: Equatable {
    case file(URL)
    case wait(path: String, resultPath: String)

    /// Parses a Launch Services URL into an app-open request.
    static func parse(_ url: URL) -> AppOpenRequest? {
        if url.isFileURL {
            return .file(url.standardizedFileURL)
        }

        guard url.scheme == "minga", url.host == "wait" else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2,
              let resultPath = decodeBase64URL(components[0]),
              let path = decodeBase64URL(components[1]),
              !resultPath.isEmpty,
              !path.isEmpty
        else {
            return nil
        }

        let standardizedResultPath = URL(fileURLWithPath: resultPath).standardizedFileURL.path
        guard WaitResultFile.isAllowedResultPath(standardizedResultPath) else { return nil }

        return .wait(
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            resultPath: standardizedResultPath
        )
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Publishes an app-side failure only when the BEAM did not already complete a wait request.
enum WaitResultFile {
    static var allowedRootURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("minga-wait", isDirectory: true)
            .standardizedFileURL
    }

    static func isAllowedResultPath(_ resultPath: String) -> Bool {
        let resultURL = URL(fileURLWithPath: resultPath).standardizedFileURL
        let requestURL = resultURL.deletingLastPathComponent()
        let requestName = requestURL.lastPathComponent

        return resultURL.lastPathComponent == "result"
            && requestName.hasPrefix("request.")
            && requestName.count > "request.".count
            && requestURL.deletingLastPathComponent().standardizedFileURL.path == allowedRootURL.path
    }

    /// Atomically creates a non-zero result without overwriting a BEAM-owned completion.
    static func failIfPending(at resultPath: String, reason: String) -> Bool {
        guard isAllowedResultPath(resultPath) else { return false }

        let message = reason
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(500)
        let contents = Data("1\t\(message)\n".utf8)
        let resultURL = URL(fileURLWithPath: resultPath).standardizedFileURL
        let tempURL = resultURL
            .deletingLastPathComponent()
            .appendingPathComponent(".result-tmp-\(UUID().uuidString)")

        do {
            try contents.write(to: tempURL, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try FileManager.default.linkItem(at: tempURL, to: resultURL)
            return true
        } catch {
            return false
        }
    }
}

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

    /// Called on every BEAM exit so app-local transports can fail pending requests.
    var onTermination: (@MainActor (_ status: Int32) -> Void)?

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

    /// Selects the Minga CLI arguments that the embedded BEAM should receive.
    ///
    /// Only flags understood by `Minga.CLI` are forwarded, while positional targets are preserved in their original order. The generated OTP release launcher does not forward arguments after its `start` command, so `start()` transports this array through `MINGA_CLI_ARGS_B64` instead.
    static func forwardedCLIArguments(from appArguments: [String]) -> [String] {
        var cliArguments: [String] = []
        let valueFlags: Set<String> = ["--config", "--debug-log", "-D"]
        let booleanFlags: Set<String> = [
            "--editor", "--no-context", "--minimal", "--safe", "-Q"
        ]
        var expectsValue = false

        for arg in appArguments.dropFirst() {
            if expectsValue {
                cliArguments.append(arg)
                expectsValue = false
                continue
            }

            if valueFlags.contains(arg) {
                cliArguments.append(arg)
                expectsValue = true
            } else if booleanFlags.contains(arg) || !arg.hasPrefix("-") {
                cliArguments.append(arg)
            }
        }

        return cliArguments
    }

    /// Encodes CLI arguments for lossless transport through the release environment.
    static func encodedCLIArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            Data(argument.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ",")
    }

    /// Returns the working directory the embedded BEAM should start in.
    ///
    /// Finder, Spotlight, and Dock launches commonly inherit `/` as their cwd.
    /// That is a poor default project root, so bundle launches fall back to HOME
    /// when the inherited cwd is a launch-services placeholder rather than a user directory.
    static func defaultWorkingDirectoryURL(
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.bundleURL,
        fileExists: @escaping (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> URL {
        let currentURL = URL(fileURLWithPath: currentDirectoryPath).standardizedFileURL

        guard shouldUseHomeWorkingDirectory(currentDirectoryPath: currentDirectoryPath, environment: environment, bundleURL: bundleURL),
              let homePath = environment["HOME"],
              !homePath.isEmpty,
              fileExists(homePath)
        else {
            return currentURL
        }

        return URL(fileURLWithPath: homePath).standardizedFileURL
    }

    private static func shouldUseHomeWorkingDirectory(
        currentDirectoryPath: String,
        environment: [String: String],
        bundleURL: URL?
    ) -> Bool {
        let currentPath = URL(fileURLWithPath: currentDirectoryPath).standardizedFileURL.path

        if currentPath == "/" || currentPath == "/Applications" || currentPath == "/System/Applications" {
            return true
        }

        guard let bundleURL else { return false }

        let bundlePath = bundleURL.standardizedFileURL.path
        return currentPath == bundlePath || currentPath.hasPrefix(bundlePath + "/")
    }

    /// Spawns the BEAM release as a child process with piped stdin/stdout.
    func start() {
        guard let execURL = Self.beamExecutableURL() else {
            NSLog("BEAMProcessManager: no embedded BEAM release found")
            return
        }

        // Prevent App Nap / automatic + sudden termination while the BEAM lives.
        beginBackgroundActivityIfNeeded()

        let proc = Process()
        proc.executableURL = execURL

        let cliArguments = Self.forwardedCLIArguments(from: ProcessInfo.processInfo.arguments)
        proc.arguments = ["start"]

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
        env["MINGA_CLI_ARGS_B64"] = Self.encodedCLIArguments(cliArguments)

        let workingDirectoryURL = Self.defaultWorkingDirectoryURL(environment: env)
        proc.currentDirectoryURL = workingDirectoryURL
        env["PWD"] = workingDirectoryURL.path

        if cliArguments.contains("--safe") || cliArguments.contains("-Q") {
            env["MINGA_SAFE_MODE"] = "1"
        }

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
        isShuttingDown = false
        start()
    }

    /// Sends SIGTERM to the BEAM and waits briefly for clean shutdown.
    /// Used during Cmd+Q / applicationShouldTerminate.
    func shutdownGracefully(timeout: TimeInterval = 3.0) {
        guard let proc = process, proc.isRunning else { return }

        isShuttingDown = true

        // Real quit: release the App Nap / termination assertion so the GUI
        // process can exit normally once the BEAM has shut down.
        endBackgroundActivity()

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
        isShuttingDown: Bool,
        recentRestartCount: Int,
        maxRestarts: Int
    ) -> TerminationOutcome {
        if isShuttingDown { return .normalExit }
        if status == 0 { return .normalExit }
        if recentRestartCount >= maxRestarts { return .giveUp }

        let attempt = recentRestartCount + 1
        // Exponential backoff: 100ms, 200ms, 400ms
        let delay = 0.1 * pow(2.0, Double(attempt - 1))
        return .restart(delay: delay)
    }

    // MARK: - Private

    /// Handles BEAM exit. Kept non-`private` so the termination path can be
    /// exercised directly in tests that assert the main actor is not blocked.
    func handleTermination(status: Int32, reason: Process.TerminationReason) {
        NSLog("BEAMProcessManager: BEAM exited (status \(status), reason \(reason.rawValue))")

        self.process = nil
        self.readHandle = nil
        self.writeHandle = nil
        onTermination?(status)

        // Prune old timestamps outside the restart window.
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        restartTimestamps.removeAll { $0 < cutoff }

        let outcome = Self.terminationOutcome(
            status: status,
            isShuttingDown: isShuttingDown,
            recentRestartCount: restartTimestamps.count,
            maxRestarts: maxRestarts
        )

        switch outcome {
        case .normalExit:
            onNormalExit?()

        case .giveUp:
            NSLog("BEAMProcessManager: too many crashes (\(maxRestarts) in \(windowSeconds)s), giving up")
            // Recovery is presented by onCrash; it must not block the main actor.
            onCrash?()

        case let .restart(delay):
            restartTimestamps.append(now)
            NSLog("BEAMProcessManager: restarting in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.start()
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
