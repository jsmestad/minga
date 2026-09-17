import AppKit
import Foundation

struct OperationTiming: Codable {
    let operation: String
    let milliseconds: Double
}

enum WorkflowFailure: Error, CustomStringConvertible {
    case unmet(String)

    var description: String {
        switch self {
        case .unmet(let message): message
        }
    }
}

struct AccessibilityTestFixture {
    let home: URL
    let runtimeParent: URL
    let config: URL
    let debugLog: URL
    let alpha: URL

    static func create(at root: URL) throws -> AccessibilityTestFixture {
        let project = root.appendingPathComponent("fixture-project", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        // Darwin limits AF_UNIX socket paths to 103 bytes. Keep the isolated parent name short while remaining inside XCTest's writable temporary directory.
        let runtimeParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(UUID().uuidString.prefix(6)), isDirectory: true)
        let configDirectory = root.appendingPathComponent("xdg-config/minga", isDirectory: true)
        var keepRuntimeParent = false
        defer {
            if !keepRuntimeParent {
                try? FileManager.default.removeItem(at: runtimeParent)
            }
        }
        for directory in [project, home, runtimeParent, configDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtimeParent.path
        )
        let config = configDirectory.appendingPathComponent("config.exs")
        let alpha = project.appendingPathComponent("alpha_target.ex")
        let beta = project.appendingPathComponent("beta_target.ex")
        try write("", to: project.appendingPathComponent(".minga"))
        try write("use Minga.Config\n", to: config)
        try write("ALPHA PANE λ🙂\nsecond alpha line\n", to: alpha)
        try write("BETA PANE é🙂\nsecond beta line\n", to: beta)
        let fixture = AccessibilityTestFixture(
            home: home,
            runtimeParent: runtimeParent,
            config: config,
            debugLog: root.appendingPathComponent("minga-debug.log"),
            alpha: alpha
        )
        keepRuntimeParent = true
        return fixture
    }

    private static func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

}

@MainActor
enum RunningApplicationLocator {
    static func pid(bundleIdentifier: String, executableURL: URL, timeout: TimeInterval) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { process in
                    guard !process.isTerminated, let runningURL = process.executableURL else { return false }
                    return runningURL.resolvingSymlinksInPath().standardizedFileURL == executableURL
                }
            if matches.count > 1 {
                throw WorkflowFailure.unmet(
                    "Multiple isolated application processes matched \(bundleIdentifier) at \(executableURL.path)"
                )
            }
            if let process = matches.first { return process.processIdentifier }
            RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.05), deadline))
        } while Date() < deadline

        throw WorkflowFailure.unmet(
            "The isolated application process did not appear for \(bundleIdentifier) at \(executableURL.path)"
        )
    }
}
