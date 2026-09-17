import AppKit
import Foundation
import Testing

@Suite("Singleton editor scene")
struct EditorSceneTests {
    private struct ProbeSnapshot: Codable {
        let editorWindowCount: Int
        let reusedExistingWindow: Bool
        let editorWindowIsVisible: Bool
    }

    private static let probeOutputPathEnvironmentKey = "MINGA_SINGLETON_EDITOR_WINDOW_PROBE_PATH"

    @Test("duplicate editor window requests reuse the existing window")
    @MainActor func duplicateRequestsReuseWindow() async throws {
        let productsDirectory = Bundle(for: EditorSceneTestBundleMarker.self).bundleURL.deletingLastPathComponent()
        let applicationURL = productsDirectory.appendingPathComponent("Minga.app")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("minga-editor-window-\(UUID().uuidString).json")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment.merging([
            Self.probeOutputPathEnvironmentKey: output.path,
        ]) { _, probeValue in probeValue }

        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        defer { application.terminate() }

        for _ in 0..<500 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            application.terminate()
            throw CocoaError(.fileReadNoSuchFile)
        }

        let data = try Data(contentsOf: output)
        try? FileManager.default.removeItem(at: output)
        let snapshot = try JSONDecoder().decode(ProbeSnapshot.self, from: data)

        #expect(snapshot.editorWindowCount == 1)
        #expect(snapshot.reusedExistingWindow)
        #expect(snapshot.editorWindowIsVisible)
    }

    @Test("production declares one stable editor scene and independent Settings")
    func productionSceneDeclaration() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: macosRoot.appendingPathComponent("Sources/MingaApp.swift"), encoding: .utf8)

        #expect(source.contains("Window(\"Minga\", id: EditorScene.id)"))
        #expect(!source.contains("WindowGroup {"))
        #expect(source.contains("Settings {"))
        #expect(source.contains("applicationShouldTerminateAfterLastWindowClosed"))
    }
}

private final class EditorSceneTestBundleMarker: NSObject {}
