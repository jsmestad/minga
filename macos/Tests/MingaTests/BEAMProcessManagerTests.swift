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
}
