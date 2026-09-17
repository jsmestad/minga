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
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let config = configDirectory.appendingPathComponent("config.exs")
        let alpha = project.appendingPathComponent("alpha_target.ex")
        let beta = project.appendingPathComponent("beta_target.ex")
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
