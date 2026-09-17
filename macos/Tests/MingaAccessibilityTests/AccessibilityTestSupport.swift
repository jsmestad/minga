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

struct AccessibilityTestInputs {
    let home: URL
    let xdgConfigHome: URL
    let xdgDataHome: URL
    let xdgCacheHome: URL
    let runtimeParent: URL
    let config: URL
    let debugLog: URL
    let alpha: URL

    static func fromEnvironment(_ environment: [String: String]) throws -> AccessibilityTestInputs {
        AccessibilityTestInputs(
            home: try requiredAbsoluteURL(environment, key: "MINGA_AX_HOME", isDirectory: true),
            xdgConfigHome: try requiredAbsoluteURL(environment, key: "MINGA_AX_XDG_CONFIG_HOME", isDirectory: true),
            xdgDataHome: try requiredAbsoluteURL(environment, key: "MINGA_AX_XDG_DATA_HOME", isDirectory: true),
            xdgCacheHome: try requiredAbsoluteURL(environment, key: "MINGA_AX_XDG_CACHE_HOME", isDirectory: true),
            runtimeParent: try requiredAbsoluteURL(environment, key: "MINGA_AX_RUNTIME_PARENT", isDirectory: true),
            config: try requiredAbsoluteURL(environment, key: "MINGA_AX_CONFIG"),
            debugLog: try requiredAbsoluteURL(environment, key: "MINGA_AX_DEBUG_LOG"),
            alpha: try requiredAbsoluteURL(environment, key: "MINGA_AX_SOURCE")
        )
    }

    private static func requiredAbsoluteURL(
        _ environment: [String: String],
        key: String,
        isDirectory: Bool = false
    ) throws -> URL {
        guard let value = environment[key], value.hasPrefix("/") else {
            throw WorkflowFailure.unmet("INFRASTRUCTURE: \(key) must be an absolute path")
        }
        return URL(fileURLWithPath: value, isDirectory: isDirectory)
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
