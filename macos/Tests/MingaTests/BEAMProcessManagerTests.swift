import Darwin
import Foundation
import Testing

@Suite("BEAMProcessManager Launch Arguments")
struct BEAMProcessManagerLaunchArgumentsTests {
    @Test("forwards safe mode, editor, minimal, and positional targets")
    @MainActor func forwardsBooleanFlagsAndPositionals() {
        let forwarded = BEAMProcessManager.forwardedCLIArguments(
            from: [
                "/Applications/Minga.app/Contents/MacOS/Minga",
                "--safe",
                "-Q",
                "--editor",
                "--no-context",
                "--minimal",
                "--ignored",
                "README.md",
                "COMMIT_EDITMSG"
            ]
        )

        #expect(forwarded == [
            "--safe",
            "-Q",
            "--editor",
            "--no-context",
            "--minimal",
            "README.md",
            "COMMIT_EDITMSG"
        ])
    }

    @Test("forwards config and both debug log value flags with their values")
    @MainActor func forwardsValueFlags() {
        let forwarded = BEAMProcessManager.forwardedCLIArguments(
            from: [
                "/Applications/Minga.app/Contents/MacOS/Minga",
                "--config", "/tmp/minga.exs", "one.ex",
                "--debug-log", "/tmp/minga.log", "two.ex",
                "-D", "/tmp/minga-short.log", "three.ex"
            ]
        )

        #expect(forwarded == [
            "--config", "/tmp/minga.exs", "one.ex",
            "--debug-log", "/tmp/minga.log", "two.ex",
            "-D", "/tmp/minga-short.log", "three.ex"
        ])
    }

    @Test("encodes release CLI arguments without losing spaces")
    @MainActor func encodesCLIArguments() {
        #expect(
            BEAMProcessManager.encodedCLIArguments(["--editor", "/tmp/path with space"])
                == "LS1lZGl0b3I,L3RtcC9wYXRoIHdpdGggc3BhY2U"
        )
    }

    @Test("extracts but does not forward the internal launch nonce")
    @MainActor func isolatesLaunchNonce() {
        let arguments = ["Minga", "--minimal", "--minga-launch-nonce", "nonce-123", "README.md"]
        #expect(BEAMProcessManager.internalLaunchNonce(from: arguments) == "nonce-123")
        #expect(BEAMProcessManager.forwardedCLIArguments(from: arguments) == ["--minimal", "README.md"])
    }

    @Test("clears every inherited pre-VM option and requires local preboot distribution")
    @MainActor func sanitizesPreVMEnvironment() {
        let environment = BEAMProcessManager.sanitizedPreVMEnvironment([
            "ERL_AFLAGS": "-sname inherited",
            "ERL_FLAGS": "-name inherited@example",
            "ERL_ZFLAGS": "-sname inherited_zflags",
            "ELIXIR_ERL_OPTIONS": "-sname inherited_elixir",
            "RELEASE_VM_ARGS": "/tmp/inherited.vm.args",
            "HOME": "/Users/alice"
        ])

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
    @MainActor func usesDarwinTemporaryDirectoryForIPC() {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        #expect(length > 1)
        var buffer = [CChar](repeating: 0, count: length)
        #expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length)

        let expected = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .standardizedFileURL
        #expect(BEAMProcessManager.ipcRuntimeParentURL() == expected)
    }

    @Test("uses HOME when launch services provides root as cwd")
    @MainActor func usesHomeForRootWorkingDirectory() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/",
            environment: ["HOME": "/Users/alice"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            fileExists: { path in path == "/Users/alice" }
        )

        #expect(workingDirectory.path == "/Users/alice")
    }

    @Test("uses HOME when cwd is the Applications folder")
    @MainActor func usesHomeForApplicationsWorkingDirectory() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Applications",
            environment: ["HOME": "/Users/alice"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            fileExists: { path in path == "/Users/alice" }
        )

        #expect(workingDirectory.path == "/Users/alice")
    }

    @Test("uses HOME when cwd is System Applications")
    @MainActor func usesHomeForSystemApplicationsWorkingDirectory() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/System/Applications",
            environment: ["HOME": "/Users/alice"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            fileExists: { path in path == "/Users/alice" }
        )

        #expect(workingDirectory.path == "/Users/alice")
    }

    @Test("uses HOME when cwd is inside the app bundle")
    @MainActor func usesHomeForBundleWorkingDirectory() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Applications/Minga.app/Contents/MacOS",
            environment: ["HOME": "/Users/alice"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            fileExists: { path in path == "/Users/alice" }
        )

        #expect(workingDirectory.path == "/Users/alice")
    }

    @Test("keeps a real terminal cwd")
    @MainActor func keepsRealTerminalWorkingDirectory() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Users/alice/code/minga",
            environment: ["HOME": "/Users/alice"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app")
        )

        #expect(workingDirectory.path == "/Users/alice/code/minga")
    }

    @Test("uses HOME for /Applications even with TERM set")
    @MainActor func usesHomeForApplicationsEvenWithTerm() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Applications",
            environment: ["HOME": "/Users/alice", "TERM": "xterm-256color"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            fileExists: { path in path == "/Users/alice" }
        )

        #expect(workingDirectory.path == "/Users/alice")
    }

    @Test("keeps cwd when HOME is missing")
    @MainActor func keepsCurrentDirectoryWhenHomeIsMissing() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Applications",
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app")
        )

        #expect(workingDirectory.path == "/Applications")
    }

    @Test("keeps cwd when HOME is empty")
    @MainActor func keepsCurrentDirectoryWhenHomeIsEmpty() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Applications",
            environment: ["HOME": ""],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app")
        )

        #expect(workingDirectory.path == "/Applications")
    }

    @Test("keeps cwd when HOME is not an existing directory")
    @MainActor func keepsCurrentDirectoryWhenHomeIsInvalid() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Applications",
            environment: ["HOME": "/Users/alice"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            fileExists: { path in path == "/Applications" }
        )

        #expect(workingDirectory.path == "/Applications")
    }
}

@Suite("BEAMProcessManager Termination Handling")
struct BEAMProcessManagerTerminationTests {
    // MARK: - Pure decision function

    @Test("graceful shutdown resolves to a normal exit")
    func gracefulShutdownIsNormalExit() {
        let outcome = BEAMProcessManager.terminationOutcome(
            status: 0, isShuttingDown: true, recentRestartCount: 0, maxRestarts: 3
        )
        #expect(outcome == .normalExit)
    }

    @Test("clean exit code resolves to a normal exit")
    func cleanExitIsNormalExit() {
        let outcome = BEAMProcessManager.terminationOutcome(
            status: 0, isShuttingDown: false, recentRestartCount: 2, maxRestarts: 3
        )
        #expect(outcome == .normalExit)
    }

    @Test("crash within budget schedules a backoff restart")
    func crashWithinBudgetRestarts() {
        #expect(
            BEAMProcessManager.terminationOutcome(
                status: 1, isShuttingDown: false, recentRestartCount: 0, maxRestarts: 3
            ) == .restart(delay: 0.1)
        )
        #expect(
            BEAMProcessManager.terminationOutcome(
                status: 1, isShuttingDown: false, recentRestartCount: 1, maxRestarts: 3
            ) == .restart(delay: 0.2)
        )
        #expect(
            BEAMProcessManager.terminationOutcome(
                status: 1, isShuttingDown: false, recentRestartCount: 2, maxRestarts: 3
            ) == .restart(delay: 0.4)
        )
    }

    @Test("crash past the budget resolves to give up (recovery surface)")
    func crashPastBudgetGivesUp() {
        let outcome = BEAMProcessManager.terminationOutcome(
            status: 1, isShuttingDown: false, recentRestartCount: 3, maxRestarts: 3
        )
        #expect(outcome == .giveUp)
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
