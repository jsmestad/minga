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
            "--safe",
            "-Q",
            "--editor",
            "--no-context",
            "--minimal",
            "--config", "/tmp/minga.exs", "one.ex",
            "--debug-log", "/tmp/minga.log", "two.ex",
            "-D", "/tmp/minga-short.log", "three.ex",
            "--minga-launch-nonce", "nonce-123",
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
        validHomeDirectoryURL: URL? = URL(fileURLWithPath: "/Users/alice"),
        launchNonce: String? = nil,
        releaseCookie: String = "cookie-1"
    ) -> BEAMLaunchConfiguration {
        BEAMLaunchConfiguration.build(from: BEAMLaunchInputs(
            executableURL: URL(fileURLWithPath: "/Applications/Minga.app/Contents/Resources/release/bin/minga_macos"),
            appArguments: appArguments,
            inheritedEnvironment: inheritedEnvironment,
            currentDirectoryURL: currentDirectoryURL,
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            validHomeDirectoryURL: validHomeDirectoryURL,
            ipcRuntimeParentURL: URL(fileURLWithPath: "/private/tmp/user"),
            appPID: 1234,
            appEUID: 501,
            appInstanceID: "instance-123",
            launchNonce: launchNonce,
            releaseCookie: releaseCookie
        ))
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
