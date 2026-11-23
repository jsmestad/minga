import AppKit
import Foundation
import Testing

@Suite("Singleton editor scene")
struct EditorSceneTests {
    private struct ProbeSnapshot: Codable {
        let editorWindowCount: Int
        let reusedExistingWindow: Bool
        let editorWindowIsVisible: Bool
        let reusedWindowForFileURLs: Bool
        let receivedFilePaths: [String]
        let fileURLError: String?
    }

    private static let probeOutputPathEnvironmentKey = "MINGA_SINGLETON_EDITOR_WINDOW_PROBE_PATH"

    @Test("window and native file-open requests reuse the existing editor window")
    @MainActor func windowAndFileOpenRequestsReuseWindow() async throws {
        let applicationPath = try #require(ProcessInfo.processInfo.environment["MINGA_TEST_PRODUCTION_APP_PATH"])
        let applicationURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
        try #require(applicationURL.lastPathComponent == "Minga.app", "Probe requires the separately built Minga app")
        let bundle = try #require(Bundle(url: applicationURL))
        let executable = try #require(bundle.executableURL)
        try #require(bundle.bundleIdentifier == "com.minga.editor.dev", "Debug app must not use installed Minga preferences")
        try #require(executable.lastPathComponent == "Minga" && FileManager.default.isExecutableFile(atPath: executable.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minga-editor-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURLs = ["first.txt", "second.txt"].map { directory.appendingPathComponent($0).standardizedFileURL }
        for url in fileURLs {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let output = directory.appendingPathComponent("probe.json")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment.merging([
            Self.probeOutputPathEnvironmentKey: output.path,
        ]) { _, probeValue in probeValue }

        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        defer { application.terminate() }

        let readyPath = output.path + ".ready"
        for (index, url) in fileURLs.enumerated() {
            let phase = String(index)
            for _ in 0..<1000 where (try? String(contentsOfFile: readyPath, encoding: .utf8)) != phase
                && !FileManager.default.fileExists(atPath: output.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            if FileManager.default.fileExists(atPath: output.path) { break }
            try #require(
                (try? String(contentsOfFile: readyPath, encoding: .utf8)) == phase,
                "Production window did not acknowledge file-open phase \(phase)"
            )
            try sendFileOpenEvent(url, to: application.processIdentifier)
        }

        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            application.terminate()
            throw CocoaError(.fileReadNoSuchFile)
        }

        let data = try Data(contentsOf: output)
        let snapshot = try JSONDecoder().decode(ProbeSnapshot.self, from: data)

        #expect(snapshot.editorWindowCount == 1)
        #expect(snapshot.reusedExistingWindow)
        #expect(snapshot.editorWindowIsVisible)
        #expect(snapshot.fileURLError == nil)
        #expect(snapshot.reusedWindowForFileURLs)
        #expect(snapshot.receivedFilePaths == fileURLs.map(\.path))
    }

    private struct InactiveLaunchSnapshot: Codable {
        let editorWindowCount: Int
        let editorWindowIsVisible: Bool
        let applicationIsActive: Bool
    }

    /// AppKit skips the launch window for an inactive app; the editor must still exist so the frontend can send `ready`.
    ///
    /// The BEAM executes the frontend directly rather than through LaunchServices, which is the launch path where AppKit applies that skip.
    @Test("an inactive direct launch creates the editor window without activating the app")
    @MainActor func inactiveLaunchCreatesEditorWindow() async throws {
        let executable = try #require(Bundle(url: productionApplicationURL())?.executableURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minga-inactive-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("probe.json")
        let process = Process()
        process.executableURL = executable
        let environment = ProcessInfo.processInfo.environment
        process.environment = [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "PATH": environment["PATH"] ?? "/usr/bin:/bin",
            "MINGA_INACTIVE_LAUNCH_WINDOW_PROBE_PATH": output.path,
        ]
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try JSONDecoder().decode(InactiveLaunchSnapshot.self, from: Data(contentsOf: output))

        #expect(!snapshot.applicationIsActive)
        #expect(snapshot.editorWindowCount == 1)
        #expect(snapshot.editorWindowIsVisible)
    }

    private func productionApplicationURL() throws -> URL {
        let applicationPath = try #require(ProcessInfo.processInfo.environment["MINGA_TEST_PRODUCTION_APP_PATH"])
        let applicationURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
        try #require(applicationURL.lastPathComponent == "Minga.app", "Probe requires the separately built Minga app")
        let bundle = try #require(Bundle(url: applicationURL))
        try #require(bundle.bundleIdentifier == "com.minga.editor.dev", "Debug app must not use installed Minga preferences")
        return applicationURL
    }

    /// Targets the launched process, not another concurrently running Minga app with the same bundle ID.
    private func sendFileOpenEvent(_ url: URL, to pid: pid_t) throws {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
        event.setParam(files, forKeyword: AEKeyword(keyDirectObject))
        _ = try event.sendEvent(options: .noReply, timeout: 2)
    }
}
