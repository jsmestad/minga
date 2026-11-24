import Darwin
import Foundation
import Testing

@Suite("BEAM launch configuration")
struct BEAMLaunchConfigurationTests {
    struct WorkingDirectoryCase: Sendable {
        let currentDirectory: String
        let validHomeDirectory: String
        let expectedDirectory: String
    }

    @Test("builds one complete normal launch configuration")
    func buildsNormalConfiguration() {
        let configuration = makeConfiguration(
            appArguments: ["Minga", "--editor", "/tmp/path with space", "--ignored"],
            inheritedEnvironment: ["HOME": "/Users/alice", "LANG": "en_US.UTF-8"],
            currentDirectoryURL: URL(fileURLWithPath: "/Users/alice/code/minga"),
            validHomeDirectoryURL: URL(fileURLWithPath: "/Users/alice")
        )

        #expect(configuration == BEAMLaunchConfiguration(
            executableURL: URL(
                fileURLWithPath: "/Applications/Minga.app/Contents/Resources/release/bin/minga_macos"
            ),
            arguments: ["start"],
            environment: [
                "HOME": "/Users/alice",
                "LANG": "en_US.UTF-8",
                "MINGA_APP_EUID": "501",
                "MINGA_APP_INSTANCE_ID": "instance-123",
                "MINGA_APP_PID": "1234",
                "MINGA_BOOT_PROGRESS": "native",
                "MINGA_CLI_ARGS_B64": "LS1lZGl0b3I,L3RtcC9wYXRoIHdpdGggc3BhY2U",
                "MINGA_EXPECT_DISTRIBUTION": "0",
                "MINGA_IPC_RUNTIME_PARENT": "/private/tmp/user",
                "MINGA_PORT_MODE": "connected",
                "MINGA_RANDOM_RELEASE_COOKIE": "1",
                "PWD": "/Users/alice/code/minga",
                "RELEASE_COOKIE": "cookie-1",
                "RELEASE_DISTRIBUTION": "none"
            ],
            workingDirectoryURL: URL(fileURLWithPath: "/Users/alice/code/minga")
        ))
    }

    @Test("forwards safe mode, value flags, and positional targets while isolating the launch nonce")
    func buildsSafeConfiguration() {
        let arguments = [
            "Minga",
            "-NSTreatUnknownArgumentsAsOpen", "NO",
            "--safe",
            "-Q",
            "--editor",
            "--no-context",
            "--minimal",
            "--config", "/tmp/minga.exs", "one.ex",
            "--debug-log", "/tmp/minga.log", "two.ex",
            "-D", "/tmp/minga-short.log", "three.ex",
            "--minga-launch-nonce", "nonce-123",
            "--minga-ipc-runtime-parent", "/private/tmp/minga-ui-test",
            "--ignored"
        ]
        let configuration = makeConfiguration(appArguments: arguments, launchNonce: "nonce-123")

        #expect(BEAMLaunchConfiguration.launchNonce(from: arguments) == "nonce-123")
        #expect(configuration.environment["MINGA_CLI_ARGS_B64"] == encoded([
            "--safe", "-Q", "--editor", "--no-context", "--minimal",
            "--config", "/tmp/minga.exs", "one.ex",
            "--debug-log", "/tmp/minga.log", "two.ex",
            "-D", "/tmp/minga-short.log", "three.ex"
        ]))
        #expect(configuration.environment["MINGA_SAFE_MODE"] == "1")
        #expect(configuration.environment["MINGA_LAUNCH_NONCE"] == "nonce-123")
    }

    @Test("a safe-mode restart preserves the startup file, config argument, and launch nonce")
    func buildsForcedSafeConfiguration() {
        let configuration = makeConfiguration(
            appArguments: ["Minga", "--config", "/tmp/custom.exs", "/tmp/file.ex"],
            launchNonce: "nonce-123",
            forceSafeMode: true
        )

        #expect(configuration.environment["MINGA_CLI_ARGS_B64"] == encoded([
            "--safe", "--config", "/tmp/custom.exs", "/tmp/file.ex"
        ]))
        #expect(configuration.environment["MINGA_SAFE_MODE"] == "1")
        #expect(configuration.environment["MINGA_LAUNCH_NONCE"] == "nonce-123")
    }

    @Test("removes inherited distribution flags from the complete configuration")
    func sanitizesPreVMEnvironment() {
        let configuration = makeConfiguration(inheritedEnvironment: [
            "ERL_AFLAGS": "-sname inherited",
            "ERL_FLAGS": "-name inherited@example",
            "ERL_ZFLAGS": "-sname inherited_zflags",
            "ELIXIR_ERL_OPTIONS": "-sname inherited_elixir",
            "RELEASE_VM_ARGS": "/tmp/inherited.vm.args",
            "HOME": "/Users/alice"
        ])
        let environment = configuration.environment

        #expect(environment["ERL_AFLAGS"] == nil)
        #expect(environment["ERL_FLAGS"] == nil)
        #expect(environment["ERL_ZFLAGS"] == nil)
        #expect(environment["ELIXIR_ERL_OPTIONS"] == nil)
        #expect(environment["RELEASE_VM_ARGS"] == nil)
        #expect(environment["MINGA_EXPECT_DISTRIBUTION"] == "0")
        #expect(environment["RELEASE_DISTRIBUTION"] == "none")
        #expect(environment["HOME"] == "/Users/alice")
    }

    @Test("passes the native IPC namespace instead of inheriting a caller's selection")
    func resolvesIPCNamespace() {
        let development = makeConfiguration(usesDevelopmentIPC: true)
        let release = makeConfiguration(inheritedEnvironment: ["MINGA_IPC_DEVELOPMENT": "1"])

        #expect(development.environment["MINGA_IPC_DEVELOPMENT"] == "1")
        #expect(release.environment["MINGA_IPC_DEVELOPMENT"] == nil)
    }

    @Test("uses the confstr Darwin per-user temporary directory for native IPC")
    @MainActor func usesDarwinTemporaryDirectoryForIPC() throws {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        #expect(length > 1)
        var buffer = [CChar](repeating: 0, count: length)
        #expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length)

        let path = try #require(String(
            bytes: buffer.dropLast().map { UInt8(bitPattern: $0) },
            encoding: .utf8
        ))
        let expected = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        #expect(BEAMLaunchInputAcquirer.ipcRuntimeParentURL() == expected)
    }

    @Test("selects the working directory from resolved launch inputs", arguments: [
        WorkingDirectoryCase(
            currentDirectory: "/",
            validHomeDirectory: "/Users/alice",
            expectedDirectory: "/Users/alice"
        ),
        WorkingDirectoryCase(
            currentDirectory: "/Applications",
            validHomeDirectory: "/Users/alice",
            expectedDirectory: "/Users/alice"
        ),
        WorkingDirectoryCase(
            currentDirectory: "/System/Applications",
            validHomeDirectory: "/Users/alice",
            expectedDirectory: "/Users/alice"
        ),
        WorkingDirectoryCase(
            currentDirectory: "/Applications/Minga.app/Contents/MacOS",
            validHomeDirectory: "/Users/alice",
            expectedDirectory: "/Users/alice"
        ),
        WorkingDirectoryCase(
            currentDirectory: "/Users/alice/code/minga",
            validHomeDirectory: "/Users/alice",
            expectedDirectory: "/Users/alice/code/minga"
        )
    ])
    func selectsWorkingDirectory(testCase: WorkingDirectoryCase) {
        let configuration = makeConfiguration(
            currentDirectoryURL: URL(fileURLWithPath: testCase.currentDirectory),
            validHomeDirectoryURL: URL(fileURLWithPath: testCase.validHomeDirectory)
        )

        #expect(configuration.workingDirectoryURL.path == testCase.expectedDirectory)
        #expect(configuration.environment["PWD"] == testCase.expectedDirectory)
    }

    @Test("keeps a placeholder cwd when no valid HOME directory was acquired")
    func keepsCurrentDirectoryWithoutValidHome() {
        let configuration = makeConfiguration(
            inheritedEnvironment: ["HOME": "/Users/alice"],
            currentDirectoryURL: URL(fileURLWithPath: "/Applications"),
            validHomeDirectoryURL: nil
        )

        #expect(configuration.workingDirectoryURL.path == "/Applications")
        #expect(configuration.environment["PWD"] == "/Applications")
    }

    @Test("fresh launch inputs change runtime values while identity and nonce remain stable")
    func rebuildsConfigurationForRestart() {
        let first = makeConfiguration(
            inheritedEnvironment: ["HOME": "/Users/alice", "CURRENT_INPUT": "first"],
            currentDirectoryURL: URL(fileURLWithPath: "/Users/alice/first"),
            launchNonce: "stable-nonce",
            releaseCookie: "cookie-1"
        )
        let restarted = makeConfiguration(
            inheritedEnvironment: ["HOME": "/Users/alice", "CURRENT_INPUT": "second"],
            currentDirectoryURL: URL(fileURLWithPath: "/Users/alice/second"),
            launchNonce: "stable-nonce",
            releaseCookie: "cookie-2"
        )

        #expect(first.environment["CURRENT_INPUT"] == "first")
        #expect(restarted.environment["CURRENT_INPUT"] == "second")
        #expect(first.environment["RELEASE_COOKIE"] == "cookie-1")
        #expect(restarted.environment["RELEASE_COOKIE"] == "cookie-2")
        #expect(first.environment["RELEASE_COOKIE"] != restarted.environment["RELEASE_COOKIE"])
        #expect(first.environment["MINGA_APP_INSTANCE_ID"] == restarted.environment["MINGA_APP_INSTANCE_ID"])
        #expect(first.environment["MINGA_LAUNCH_NONCE"] == restarted.environment["MINGA_LAUNCH_NONCE"])
        #expect(first.workingDirectoryURL != restarted.workingDirectoryURL)
    }

    private func makeConfiguration(
        appArguments: [String] = ["Minga"],
        inheritedEnvironment: [String: String] = ["HOME": "/Users/alice"],
        currentDirectoryURL: URL = URL(fileURLWithPath: "/Users/alice/code/minga"),
        usesDevelopmentIPC: Bool = false,
        validHomeDirectoryURL: URL? = URL(fileURLWithPath: "/Users/alice"),
        launchNonce: String? = nil,
        releaseCookie: String = "cookie-1",
        forceSafeMode: Bool = false
    ) -> BEAMLaunchConfiguration {
        BEAMLaunchConfiguration.build(from: BEAMLaunchInputs(
            executableURL: URL(fileURLWithPath: "/Applications/Minga.app/Contents/Resources/release/bin/minga_macos"),
            appArguments: appArguments,
            inheritedEnvironment: inheritedEnvironment,
            currentDirectoryURL: currentDirectoryURL,
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            validHomeDirectoryURL: validHomeDirectoryURL,
            ipcRuntimeParentURL: URL(fileURLWithPath: "/private/tmp/user"),
            usesDevelopmentIPC: usesDevelopmentIPC,
            appPID: 1234,
            appEUID: 501,
            appInstanceID: "instance-123",
            launchNonce: launchNonce,
            releaseCookie: releaseCookie
        ), forceSafeMode: forceSafeMode)
    }

    private func encoded(_ arguments: [String]) -> String {
        arguments.map { argument in
            Data(argument.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ",")
    }
}

@Suite("Startup compile progress")
struct StartupCompileRecordsTests {
    @Test("fragmented progress survives ordinary and oversized stderr lines")
    func readsOnlyCompleteProgressRecords() {
        var decoder = StartupCompileRecords()
        var received: [String?] = []
        let deliver: (String?) -> Void = { received.append($0) }
        decoder.consume(Data("diagnostic\nMINGA_STARTUP_COMP".utf8), deliver: deliver)
        #expect(received.isEmpty)
        decoder.consume(Data("ILE\t{\"name\":\"local_extension\"}\n".utf8), deliver: deliver)
        decoder.consume(Data(("MINGA_STARTUP_COMPILE\t" + String(repeating: "x", count: 2048) + "\n").utf8), deliver: deliver)
        decoder.consume(Data("MINGA_STARTUP_COMPILE\t{\"name\":null}\n".utf8), deliver: deliver)
        #expect(received == ["local_extension", nil])
    }
}

@Suite("BEAMProcessManager Termination Handling")
struct BEAMProcessManagerTerminationTests {
    struct TransportRestartCase: Sendable {
        let managedProcessPresent: Bool
        let processIsRunning: Bool
        let exitIntent: BEAMProcessManager.ExitIntent
        let expected: BEAMProcessManager.TransportRestartDisposition
    }

    // MARK: - Pure decision function

    @Test("graceful shutdown resolves to a normal exit")
    func gracefulShutdownIsNormalExit() {
        let outcome = BEAMProcessManager.terminationOutcome(
            status: 0, exitIntent: .appShutdown, recentRestartCount: 0, maxRestarts: 3
        )
        #expect(outcome == .normalExit)
    }

    @Test("clean exit code resolves to a normal exit")
    func cleanExitIsNormalExit() {
        let outcome = BEAMProcessManager.terminationOutcome(
            status: 0, exitIntent: .running, recentRestartCount: 2, maxRestarts: 3
        )
        #expect(outcome == .normalExit)
    }

    @Test("crash within budget schedules a backoff restart")
    func crashWithinBudgetRestarts() {
        #expect(
            BEAMProcessManager.terminationOutcome(
                status: 1, exitIntent: .running, recentRestartCount: 0, maxRestarts: 3
            ) == .restart(delay: 0.1)
        )
        #expect(
            BEAMProcessManager.terminationOutcome(
                status: 1, exitIntent: .running, recentRestartCount: 1, maxRestarts: 3
            ) == .restart(delay: 0.2)
        )
        #expect(
            BEAMProcessManager.terminationOutcome(
                status: 1, exitIntent: .running, recentRestartCount: 2, maxRestarts: 3
            ) == .restart(delay: 0.4)
        )
    }

    @Test("crash past the budget resolves to give up (recovery surface)")
    func crashPastBudgetGivesUp() {
        let outcome = BEAMProcessManager.terminationOutcome(
            status: 1, exitIntent: .running, recentRestartCount: 3, maxRestarts: 3
        )
        #expect(outcome == .giveUp)
    }

    @Test("transport recovery disposition follows process and restart state", arguments: [
        TransportRestartCase(
            managedProcessPresent: true,
            processIsRunning: true,
            exitIntent: .running,
            expected: .terminateForRestart
        ),
        TransportRestartCase(
            managedProcessPresent: true,
            processIsRunning: false,
            exitIntent: .running,
            expected: .awaitProcessTermination
        ),
        TransportRestartCase(
            managedProcessPresent: false,
            processIsRunning: false,
            exitIntent: .running,
            expected: .startImmediately
        ),
        TransportRestartCase(
            managedProcessPresent: false,
            processIsRunning: false,
            exitIntent: .restartScheduled,
            expected: .awaitScheduledRestart
        ),
        TransportRestartCase(
            managedProcessPresent: true,
            processIsRunning: true,
            exitIntent: .restartScheduled,
            expected: .awaitScheduledRestart
        ),
        TransportRestartCase(
            managedProcessPresent: true,
            processIsRunning: false,
            exitIntent: .transportRestart,
            expected: .awaitScheduledRestart
        ),
        TransportRestartCase(
            managedProcessPresent: true,
            processIsRunning: true,
            exitIntent: .appShutdown,
            expected: .rejectDuringShutdown
        )
    ])
    func transportRecoveryDisposition(testCase: TransportRestartCase) {
        let disposition = BEAMProcessManager.transportRestartDisposition(
            managedProcessPresent: testCase.managedProcessPresent,
            processIsRunning: testCase.processIsRunning,
            exitIntent: testCase.exitIntent
        )
        #expect(disposition == testCase.expected)
    }

    @Test("user-confirmed transport restart replaces pipes even when termination exits zero")
    func transportRestartIntentOverridesExitStatus() {
        #expect(
            BEAMProcessManager.terminationOutcome(
                status: 0,
                exitIntent: .transportRestart,
                recentRestartCount: 3,
                maxRestarts: 3
            ) == .restart(delay: 0)
        )
    }

    @Test("approved quit claims nonzero process death before automatic restart")
    @MainActor func approvedNonzeroExitDoesNotRestart() {
        let manager = BEAMProcessManager()
        var replies: [Bool] = []
        var recoveryPresented = false
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )
        manager.onTermination = { _ in
            let disposition = coordinator.coreDidExit()
            #expect(disposition == .approvedTermination)
            manager.beginAppShutdown()
            return true
        }
        manager.onCrash = { recoveryPresented = true }
        #expect(coordinator.begin() == .pending)
        coordinator.receive(ApplicationQuitResponse(requestID: 1, outcome: .proceeding, dirtyCount: 0, bufferName: "", detail: ""))
        coordinator.transportDidDisconnect()

        manager.handleTermination(status: 1, reason: .exit)

        #expect(replies == [true])
        #expect(manager.exitIntent == .appShutdown)
        #expect(!recoveryPresented)
    }

    @Test("pending quit claims early nonzero exit until final approval is drained")
    @MainActor func earlyNonzeroExitWaitsForApproval() {
        let manager = BEAMProcessManager()
        var replies: [Bool] = []
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )
        manager.onTermination = { _ in coordinator.coreDidExit() != .noPendingQuit }
        #expect(coordinator.begin() == .pending)
        manager.handleTermination(status: 1, reason: .exit)
        #expect(manager.exitIntent != .restartScheduled)
        #expect(replies.isEmpty)
        #expect(coordinator.receive(ApplicationQuitResponse(requestID: 1, outcome: .proceeding, dirtyCount: 0, bufferName: "", detail: "")) == .approvedTermination)
        #expect(replies == [true])
    }

    // MARK: - Main-actor is never blocked by the termination path (#2698 defect B)

    @Test("give-up path invokes recovery without blocking the main actor")
    @MainActor func giveUpDoesNotBlockMainActor() {
        let manager = BEAMProcessManager()
        var recoveryPresented = false
        var normalExited = false
        manager.onCrash = { recoveryPresented = true }
        manager.onNormalExit = { normalExited = true }

        // Seed the crash history to the restart limit so the next crash gives up.
        manager.primeRestartHistoryForTesting(count: 3)

        let start = Date()
        manager.handleTermination(status: 1, reason: .exit)
        let elapsed = Date().timeIntervalSince(start)

        #expect(recoveryPresented == true)
        #expect(normalExited == false)
        // The handler must return effectively instantly; a synchronous restart
        // wait or a terminate wedge would take far longer than this budget.
        #expect(elapsed < 0.1)
        #expect(manager.hasLiveProcess == false)
    }

    @Test("restart path returns immediately and defers the respawn")
    @MainActor func restartPathDoesNotBlockMainActor() {
        let manager = BEAMProcessManager()
        var recoveryPresented = false
        var normalExited = false
        manager.onCrash = { recoveryPresented = true }
        manager.onNormalExit = { normalExited = true }

        let start = Date()
        manager.handleTermination(status: 1, reason: .exit)
        let elapsed = Date().timeIntervalSince(start)

        // First crash: neither give up nor normal exit; the respawn is deferred
        // to a later main-actor turn, so nothing runs synchronously here.
        #expect(recoveryPresented == false)
        #expect(normalExited == false)
        #expect(elapsed < 0.1)
        #expect(manager.exitIntent == .restartScheduled)
    }

    @Test("clean exit routes to normal exit, not recovery")
    @MainActor func cleanExitRoutesToNormalExit() {
        let manager = BEAMProcessManager()
        var recoveryPresented = false
        var normalExited = false
        manager.onCrash = { recoveryPresented = true }
        manager.onNormalExit = { normalExited = true }

        manager.handleTermination(status: 0, reason: .exit)

        #expect(normalExited == true)
        #expect(recoveryPresented == false)
    }
}

/// Startup stop watchdog, restart delay, and termination identity, driven by a manual clock.
/// Children are real short-lived processes; only elapsed time is simulated.
@Suite("BEAMProcessManager shutdown watchdog", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct BEAMProcessManagerWatchdogTests {
    /// A core that ignores SIGTERM and exits only after a line arrives on stdin.
    private struct UnresponsiveCore {
        let input: FileHandle

        /// Lets the core exit normally, whatever state the manager is in.
        func release() throws {
            try input.write(contentsOf: Data("\n".utf8))
        }
    }

    private func catConfiguration() -> BEAMLaunchConfiguration {
        BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            environment: [:], workingDirectoryURL: URL(fileURLWithPath: "/private/tmp")
        )
    }

    /// Starts a core that has installed its TERM trap before this returns.
    private func startUnresponsiveCore(_ manager: BEAMProcessManager) throws -> UnresponsiveCore {
        manager.start(configuration: BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf x; IFS= read -r line"],
            environment: [:],
            workingDirectoryURL: FileManager.default.temporaryDirectory
        ))
        let input = try #require(manager.writeHandle)
        let output = try #require(manager.readHandle)
        try #require(output.read(upToCount: 1) == Data([120]))
        return UnresponsiveCore(input: input)
    }

    /// Runs a process to completion so its termination status can be read.
    private func finishedProcess() async throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let (exits, exit) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            exit.yield()
            exit.finish()
        }
        try process.run()
        var iterator = exits.makeAsyncIterator()
        _ = await iterator.next()
        return process
    }

    @Test("a genuinely unresponsive core times out exactly at the deadline and stays owned")
    func unresponsiveCoreTimesOut() async throws {
        let clock = ManualClock()
        let manager = BEAMProcessManager(clock: clock)
        let (exits, exit) = AsyncStream<Int32>.makeStream()
        manager.onTermination = { status in exit.yield(status); return false }
        let core = try startUnresponsiveCore(manager)
        let original = try #require(manager.process)
        let (failures, report) = AsyncStream<BEAMProcessManager.StartupFailure>.makeStream()
        var reported: [BEAMProcessManager.StartupFailure] = []

        // The retry returns at once: waiting for exit never blocks the main actor.
        manager.retryStartup(stopTimeout: 3) { reported.append($0); report.yield($0) }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(2_999))
        #expect(clock.sleeperCount == 1)
        #expect(reported.isEmpty)

        clock.advance(by: .milliseconds(1))
        var results = failures.makeAsyncIterator()
        #expect(await results.next() == .previousCoreStopTimedOut)
        #expect(manager.process === original)
        #expect(manager.hasLiveProcess)
        #expect(manager.writeHandle === core.input)

        try core.release()
        var observedExits = exits.makeAsyncIterator()
        #expect(await observedExits.next() == 0)
        #expect(manager.process == nil)
        #expect(manager.exitIntent == .startupFailed)
        #expect(reported == [.previousCoreStopTimedOut])
    }

    @Test("a core that exits before the stop timeout is replaced and its watchdog is cancelled")
    func exitBeforeTimeoutCancelsWatchdog() async throws {
        try #require(!BEAMProcessManager.isBundleMode)
        let clock = ManualClock()
        let manager = BEAMProcessManager(clock: clock)
        defer { manager.abortStartup() }
        let core = try startUnresponsiveCore(manager)
        let (failures, report) = AsyncStream<BEAMProcessManager.StartupFailure>.makeStream()
        var reported: [BEAMProcessManager.StartupFailure] = []

        manager.retryStartup(stopTimeout: 3) { reported.append($0); report.yield($0) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        try core.release()

        // The test host has no embedded release, so the replacement launch reports a missing release.
        var results = failures.makeAsyncIterator()
        #expect(await results.next() == .missingRelease)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(10))
        #expect(clock.sleeperCount == 0)
        #expect(reported == [.missingRelease])
        #expect(manager.process == nil)
    }

    @Test("a core restarted before the old stop deadline is never treated as the stopping core")
    func restartBeforeTimeoutKeepsReplacement() async throws {
        try #require(!BEAMProcessManager.isBundleMode)
        let clock = ManualClock()
        let manager = BEAMProcessManager(clock: clock)
        defer { manager.abortStartup() }
        let core = try startUnresponsiveCore(manager)
        let (failures, report) = AsyncStream<BEAMProcessManager.StartupFailure>.makeStream()
        var reported: [BEAMProcessManager.StartupFailure] = []

        manager.retryStartup(stopTimeout: 3) { reported.append($0); report.yield($0) }
        await clock.waitForSleepers(1)
        try core.release()
        var results = failures.makeAsyncIterator()
        #expect(await results.next() == .missingRelease)

        manager.start(configuration: catConfiguration())
        let replacement = try #require(manager.process)
        let replacementInput = try #require(manager.writeHandle)
        clock.advance(by: .seconds(10))

        #expect(clock.sleeperCount == 0)
        #expect(manager.process === replacement)
        #expect(manager.hasLiveProcess)
        #expect(manager.writeHandle === replacementInput)
        #expect(manager.exitIntent == .running)
        #expect(reported == [.missingRelease])
    }

    @Test("a new start before the crash restart delay elapses cancels the delayed restart")
    func newStartCancelsRestartDelay() async throws {
        let clock = ManualClock()
        let manager = BEAMProcessManager(clock: clock)
        defer { manager.abortStartup() }

        manager.handleTermination(status: 1, reason: .exit)
        #expect(manager.exitIntent == .restartScheduled)
        await clock.waitForSleepers(1)

        manager.start(configuration: catConfiguration())
        let replacement = try #require(manager.process)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(1))
        #expect(manager.process === replacement)
        #expect(manager.exitIntent == .running)
    }

    @Test("app shutdown cancels a parked watchdog before its deadline", arguments: [false, true])
    func shutdownCancelsWatchdog(abort: Bool) async throws {
        let clock = ManualClock()
        let manager = BEAMProcessManager(clock: clock)
        let (exits, exit) = AsyncStream<Int32>.makeStream()
        manager.onTermination = { status in exit.yield(status); return false }
        let core = try startUnresponsiveCore(manager)
        var reported: [BEAMProcessManager.StartupFailure] = []

        manager.retryStartup(stopTimeout: 3) { reported.append($0) }
        await clock.waitForSleepers(1)
        if abort {
            manager.abortStartup()
        } else {
            manager.beginAppShutdown()
        }
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(10))
        #expect(reported.isEmpty)
        #expect(manager.exitIntent == .appShutdown)

        if !abort { try core.release() }
        var observedExits = exits.makeAsyncIterator()
        #expect(await observedExits.next() != nil)
        #expect(manager.process == nil)
        #expect(reported.isEmpty)
    }

    @Test("an exit handled after the deadline but before the watchdog runs reports one timeout")
    func exitAfterDeadlineBeforeWatchdogRuns() async throws {
        let clock = ManualClock()
        let manager = BEAMProcessManager(clock: clock)
        defer { manager.abortStartup() }
        // Handling the exit below closes the core's stdin, which lets it exit.
        _ = try startUnresponsiveCore(manager)
        var reported: [BEAMProcessManager.StartupFailure] = []

        manager.retryStartup(stopTimeout: 3) { reported.append($0) }
        await clock.waitForSleepers(1)
        let watchdog = try #require(manager.shutdownWatchdogTaskForTesting)
        // Wake the watchdog, then handle the exit in the same main-actor turn, before the watchdog runs.
        clock.advance(by: .seconds(3))
        manager.handleTermination(status: 0, reason: .exit)
        #expect(reported == [.previousCoreStopTimedOut])

        // The woken watchdog now runs, finds its core gone, and reports nothing more.
        await watchdog.value
        #expect(reported == [.previousCoreStopTimedOut])
        #expect(manager.process == nil)
        #expect(manager.exitIntent == .startupFailed)
    }

    @Test("a termination callback from an unrelated process leaves the current core untouched")
    func unrelatedCallbackIsIgnored() async throws {
        let manager = BEAMProcessManager(clock: ManualClock())
        defer { manager.abortStartup() }
        var terminations: [Int32] = []
        manager.onTermination = { status in terminations.append(status); return false }
        manager.start(configuration: catConfiguration())
        let current = try #require(manager.process)
        let input = try #require(manager.writeHandle)
        let output = try #require(manager.readHandle)

        manager.processDidTerminate(try await finishedProcess())

        #expect(manager.process === current)
        #expect(manager.hasLiveProcess)
        #expect(manager.writeHandle === input)
        #expect(manager.readHandle === output)
        #expect(manager.exitIntent == .running)
        #expect(terminations.isEmpty)
    }

    @Test("a late callback from a replaced core cannot clear its replacement")
    func lateCallbackFromReplacedCoreIsIgnored() async throws {
        let clock = ManualClock()
        let manager = BEAMProcessManager(clock: clock)
        defer { manager.abortStartup() }
        let (exits, exit) = AsyncStream<Int32>.makeStream()
        manager.onTermination = { status in exit.yield(status); return false }
        manager.start(configuration: catConfiguration())
        let original = try #require(manager.process)

        original.terminate()
        var observedExits = exits.makeAsyncIterator()
        #expect(await observedExits.next() == SIGTERM)
        #expect(manager.exitIntent == .restartScheduled)

        manager.start(configuration: catConfiguration())
        let replacement = try #require(manager.process)
        let input = try #require(manager.writeHandle)
        manager.processDidTerminate(original)

        #expect(manager.process === replacement)
        #expect(manager.hasLiveProcess)
        #expect(manager.writeHandle === input)
        #expect(manager.exitIntent == .running)
        #expect(clock.sleeperCount == 0)
    }
}
