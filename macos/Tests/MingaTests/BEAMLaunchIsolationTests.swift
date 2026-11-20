import Foundation
import Testing

@Suite("BEAM launch isolation")
struct BEAMLaunchIsolationTests {
    @Test("extracts an absolute isolated IPC parent without forwarding the internal flag")
    func extractsIsolatedIPCParent() {
        let arguments = [
            "Minga",
            "--editor",
            "--minga-ipc-runtime-parent", "/private/tmp/minga-ui-test/../runtime",
            "/tmp/fixture.ex"
        ]
        let explicitParent = BEAMLaunchConfiguration.ipcRuntimeParentURL(from: arguments)
        let configuration = BEAMLaunchConfiguration.build(from: inputs(arguments: arguments))

        #expect(
            explicitParent == URL(fileURLWithPath: "/private/tmp/runtime", isDirectory: true)
        )
        #expect(!BEAMLaunchConfiguration.usesDevelopmentIPC(explicitParent: explicitParent))
        #expect(configuration.environment["MINGA_CLI_ARGS_B64"] == "LS1lZGl0b3I,L3RtcC9maXh0dXJlLmV4")
        #expect(BEAMLaunchConfiguration.ipcRuntimeParentURL(from: [
            "Minga", "--minga-ipc-runtime-parent", "relative/path"
        ]) == nil)
    }

    @Test("Debug launches without an explicit IPC parent choose the developer namespace")
    func defaultsToDevelopmentIPC() {
#if DEBUG
        #expect(BEAMLaunchConfiguration.usesDevelopmentIPC(explicitParent: nil))
#else
        #expect(!BEAMLaunchConfiguration.usesDevelopmentIPC(explicitParent: nil))
#endif
    }

    @Test("Debug embedded startup rejects the installed environment; Release still accepts it")
    func embeddedCoreRequiresAnExplicitDebugProfile() {
        let installedEnvironment = ["HOME": "/Users/alice", "TMPDIR": "/private/var/folders/user/T"]
        #expect(!EmbeddedCoreProfile.permitsLaunch(installedEnvironment, required: true))
        #expect(EmbeddedCoreProfile.permitsLaunch(installedEnvironment, required: false))
        #expect(EmbeddedCoreProfile.permitsLaunch(installedEnvironment) == !EmbeddedCoreProfile.isRequired)
        #expect(BEAMLaunchConfiguration.build(from: inputs(arguments: ["Minga"])).environment["HOME"] == "/Users/alice")
    }

    @Test("Debug embedded startup requires distinct, private state roots from one profile")
    func embeddedCoreValidatesAllProfileRoots() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: attributes)
        defer { try? manager.removeItem(at: root) }

        let keys = ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "TMPDIR"]
        var profile = ["MINGA_DEV_PROFILE": root.path]
        for key in keys {
            let directory = root.appendingPathComponent(key, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: attributes)
            profile[key] = directory.path
        }
        #expect(EmbeddedCoreProfile.permitsLaunch(profile, required: true))

        let removedState = profile.removeValue(forKey: "XDG_STATE_HOME")
        let state = try #require(removedState)
        #expect(!EmbeddedCoreProfile.permitsLaunch(profile, required: true))
        profile["XDG_STATE_HOME"] = profile["HOME"]
        #expect(!EmbeddedCoreProfile.permitsLaunch(profile, required: true))

        profile["XDG_STATE_HOME"] = state
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: state)
        #expect(!EmbeddedCoreProfile.permitsLaunch(profile, required: true))
    }

    private func inputs(arguments: [String]) -> BEAMLaunchInputs {
        BEAMLaunchInputs(
            executableURL: URL(fileURLWithPath: "/Applications/Minga.app/Contents/Resources/release/bin/minga_macos"),
            appArguments: arguments,
            inheritedEnvironment: ["HOME": "/Users/alice"],
            currentDirectoryURL: URL(fileURLWithPath: "/Users/alice/code/minga"),
            bundleURL: URL(fileURLWithPath: "/Applications/Minga.app"),
            validHomeDirectoryURL: URL(fileURLWithPath: "/Users/alice"),
            ipcRuntimeParentURL: URL(fileURLWithPath: "/private/tmp/user"),
            usesDevelopmentIPC: false,
            appPID: 1234,
            appEUID: 501,
            appInstanceID: "instance-123",
            launchNonce: nil,
            releaseCookie: "cookie-1"
        )
    }
}
