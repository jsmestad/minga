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
        let runtimeParent = root.appendingPathComponent("ipc", isDirectory: true)
        let configDirectory = root.appendingPathComponent("xdg-config/minga", isDirectory: true)
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
        try write("use Minga.Config\n", to: config)
        try write("ALPHA PANE λ🙂\nsecond alpha line\n", to: alpha)
        try write("BETA PANE é🙂\nsecond beta line\n", to: beta)
        try runGit(["init", "--quiet", project.path])
        try runGit(["-C", project.path, "add", "--", alpha.lastPathComponent, beta.lastPathComponent])
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

    private static func runGit(_ arguments: [String]) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let error = String(data: errorData, encoding: .utf8) ?? "unknown Git error"
            throw WorkflowFailure.unmet("Fixture Git setup failed: \(error)")
        }
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
