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

    static func create(at root: URL, runtimeParent: URL) throws -> AccessibilityTestFixture {
        let project = root.appendingPathComponent("fixture-project", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let configDirectory = root.appendingPathComponent("xdg-config/minga", isDirectory: true)
        for directory in [project, home, configDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let config = configDirectory.appendingPathComponent("config.exs")
        let alpha = project.appendingPathComponent("alpha_target.ex")
        let beta = project.appendingPathComponent("beta_target.ex")
        try write("", to: project.appendingPathComponent(".minga"))
        try write("use Minga.Config\n", to: config)
        try write("ALPHA PANE λ🙂\nsecond alpha line\n", to: alpha)
        try write("BETA PANE é🙂\nsecond beta line\n", to: beta)
        return AccessibilityTestFixture(
            home: home,
            runtimeParent: runtimeParent,
            config: config,
            debugLog: root.appendingPathComponent("minga-debug.log"),
            alpha: alpha
        )
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
