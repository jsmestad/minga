import Foundation
import Testing

@Suite("BEAMProcessManager Launch Arguments")
struct BEAMProcessManagerLaunchArgumentsTests {
    @Test("forwards safe mode and config flags to the BEAM child")
    @MainActor func forwardsSafeModeFlags() {
        let forwarded = BEAMProcessManager.forwardedLaunchArguments(
            from: [
                "/Applications/Minga.app/Contents/MacOS/Minga",
                "--safe",
                "-Q",
                "--config",
                "/tmp/minga.safe.exs",
                "--editor",
                "--no-context",
                "--ignored",
                "README.md"
            ]
        )

        #expect(forwarded == [
            "start",
            "--safe",
            "-Q",
            "--config",
            "/tmp/minga.safe.exs",
            "--editor",
            "--no-context"
        ])
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

    @Test("keeps /Applications for terminal launches")
    @MainActor func keepsApplicationsForTerminalLaunches() {
        let workingDirectory = BEAMProcessManager.defaultWorkingDirectoryURL(
            currentDirectoryPath: "/Applications",
            environment: ["HOME": "/Users/alice", "TERM": "xterm-256color"],
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app")
        )

        #expect(workingDirectory.path == "/Applications")
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
