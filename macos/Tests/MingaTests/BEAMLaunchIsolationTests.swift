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
        let configuration = BEAMLaunchConfiguration.build(from: inputs(arguments: arguments))

        #expect(
            BEAMLaunchConfiguration.ipcRuntimeParentURL(from: arguments)
                == URL(fileURLWithPath: "/private/tmp/runtime", isDirectory: true)
        )
        #expect(configuration.environment["MINGA_CLI_ARGS_B64"] == "LS1lZGl0b3I,L3RtcC9maXh0dXJlLmV4")
        #expect(BEAMLaunchConfiguration.ipcRuntimeParentURL(from: [
            "Minga", "--minga-ipc-runtime-parent", "relative/path"
        ]) == nil)
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
            appPID: 1234,
            appEUID: 501,
            appInstanceID: "instance-123",
            launchNonce: nil,
            releaseCookie: "cookie-1"
        )
    }
}
