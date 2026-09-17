import Foundation
import Darwin

/// Resolved inputs for one embedded BEAM launch.
///
/// Callers acquire filesystem, process, environment, and random values before
/// constructing this value. `BEAMLaunchConfiguration` then applies launch
/// policy without reading global state or performing I/O.
struct BEAMLaunchInputs: Sendable {
    let executableURL: URL
    let appArguments: [String]
    let inheritedEnvironment: [String: String]
    let currentDirectoryURL: URL
    let bundleURL: URL?
    let validHomeDirectoryURL: URL?
    let ipcRuntimeParentURL: URL
    let appPID: Int32
    let appEUID: UInt32
    let appInstanceID: String
    let launchNonce: String?
    let releaseCookie: String
}

/// Acquires the I/O-backed inputs needed to configure one embedded BEAM launch.
enum BEAMLaunchInputAcquirer {
    /// Resolves the BEAM release executable inside the app bundle.
    static func embeddedExecutableURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }

        let executableURL = resourceURL
            .appendingPathComponent("release")
            .appendingPathComponent("bin")
            .appendingPathComponent("minga_macos")
        guard FileManager.default.fileExists(atPath: executableURL.path) else { return nil }

        return executableURL
    }

    /// Reads all volatile inputs for one start or restart and generates a fresh cookie.
    static func current(appInstanceID: String, launchNonce: String?) -> BEAMLaunchInputs? {
        guard let executableURL = embeddedExecutableURL() else { return nil }

        let processInfo = ProcessInfo.processInfo
        let environment = processInfo.environment
        let runtimeParentURL = BEAMLaunchConfiguration.ipcRuntimeParentURL(
            from: processInfo.arguments
        ) ?? ipcRuntimeParentURL()
        return BEAMLaunchInputs(
            executableURL: executableURL,
            appArguments: processInfo.arguments,
            inheritedEnvironment: environment,
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            bundleURL: Bundle.main.bundleURL,
            validHomeDirectoryURL: validHomeDirectoryURL(environment: environment),
            ipcRuntimeParentURL: runtimeParentURL,
            appPID: getpid(),
            appEUID: geteuid(),
            appInstanceID: appInstanceID,
            launchNonce: launchNonce,
            releaseCookie: freshReleaseCookie()
        )
    }

    /// Darwin's private per-user temporary directory used as the validated IPC parent.
    static func ipcRuntimeParentURL() -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        precondition(length > 1, "Darwin per-user temporary directory is unavailable")

        var buffer = [CChar](repeating: 0, count: length)
        precondition(
            confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length,
            "Darwin per-user temporary directory changed while reading it"
        )

        guard let path = String(
            bytes: buffer.dropLast().map { UInt8(bitPattern: $0) },
            encoding: .utf8
        ) else {
            preconditionFailure("Darwin per-user temporary directory is not UTF-8")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
    }

    private static func validHomeDirectoryURL(environment: [String: String]) -> URL? {
        guard let homePath = environment["HOME"], !homePath.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: homePath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        return URL(fileURLWithPath: homePath, isDirectory: true)
    }

    private static func freshReleaseCookie() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

/// The complete immutable configuration applied to one embedded BEAM process.
struct BEAMLaunchConfiguration: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL

    /// Builds one complete launch configuration from resolved inputs.
    static func build(from inputs: BEAMLaunchInputs) -> BEAMLaunchConfiguration {
        let cliArguments = forwardedCLIArguments(from: inputs.appArguments)
        let workingDirectoryURL = workingDirectoryURL(
            currentDirectoryURL: inputs.currentDirectoryURL,
            bundleURL: inputs.bundleURL,
            validHomeDirectoryURL: inputs.validHomeDirectoryURL
        )
        var environment = sanitizedPreVMEnvironment(inputs.inheritedEnvironment)
        environment["MINGA_PORT_MODE"] = "connected"
        environment["MINGA_CLI_ARGS_B64"] = encodedCLIArguments(cliArguments)
        environment["MINGA_APP_INSTANCE_ID"] = inputs.appInstanceID
        environment["MINGA_APP_PID"] = String(inputs.appPID)
        environment["MINGA_APP_EUID"] = String(inputs.appEUID)
        environment["MINGA_IPC_RUNTIME_PARENT"] = inputs.ipcRuntimeParentURL.path
        environment["PWD"] = workingDirectoryURL.path
        environment["RELEASE_COOKIE"] = inputs.releaseCookie
        environment["MINGA_RANDOM_RELEASE_COOKIE"] = "1"

        if let launchNonce = inputs.launchNonce {
            environment["MINGA_LAUNCH_NONCE"] = launchNonce
        } else {
            environment.removeValue(forKey: "MINGA_LAUNCH_NONCE")
        }

        if cliArguments.contains("--safe") || cliArguments.contains("-Q") {
            environment["MINGA_SAFE_MODE"] = "1"
        }

        return BEAMLaunchConfiguration(
            executableURL: inputs.executableURL,
            arguments: ["start"],
            environment: environment,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    /// Extracts the launcher nonce without forwarding the internal flag to Minga.CLI.
    static func launchNonce(from appArguments: [String]) -> String? {
        let arguments = Array(appArguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--minga-launch-nonce"),
              arguments.indices.contains(index + 1)
        else { return nil }

        let value = arguments[index + 1]
        return value.isEmpty ? nil : value
    }

    /// Extracts an isolated native IPC parent supplied by a test launcher.
    ///
    /// The flag stays inside the app process and is never forwarded to the
    /// embedded CLI. The BEAM validates ownership and permissions before it
    /// creates any runtime entries below this directory.
    static func ipcRuntimeParentURL(from appArguments: [String]) -> URL? {
        let arguments = Array(appArguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--minga-ipc-runtime-parent"),
              arguments.indices.contains(index + 1)
        else { return nil }

        let path = arguments[index + 1]
        guard path.hasPrefix("/"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func forwardedCLIArguments(from appArguments: [String]) -> [String] {
        var cliArguments: [String] = []
        let valueFlags: Set<String> = ["--config", "--debug-log", "-D"]
        let booleanFlags: Set<String> = [
            "--editor", "--no-context", "--minimal", "--safe", "-Q"
        ]
        var expectsValue = false
        var skipsInternalValue = false

        for argument in appArguments.dropFirst() {
            if skipsInternalValue {
                skipsInternalValue = false
                continue
            }
            if argument == "--minga-launch-nonce"
                || argument == "--minga-ipc-runtime-parent"
                || argument == "-NSTreatUnknownArgumentsAsOpen" {
                skipsInternalValue = true
                continue
            }
            if expectsValue {
                cliArguments.append(argument)
                expectsValue = false
                continue
            }

            if valueFlags.contains(argument) {
                cliArguments.append(argument)
                expectsValue = true
            } else if booleanFlags.contains(argument) || !argument.hasPrefix("-") {
                cliArguments.append(argument)
            }
        }

        return cliArguments
    }

    private static func encodedCLIArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            Data(argument.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ",")
    }

    private static func sanitizedPreVMEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment.removeValue(forKey: "ERL_AFLAGS")
        environment.removeValue(forKey: "ERL_FLAGS")
        environment.removeValue(forKey: "ERL_ZFLAGS")
        environment.removeValue(forKey: "ELIXIR_ERL_OPTIONS")
        environment.removeValue(forKey: "RELEASE_VM_ARGS")
        environment["MINGA_EXPECT_DISTRIBUTION"] = "0"
        environment["RELEASE_DISTRIBUTION"] = "none"
        return environment
    }

    private static func workingDirectoryURL(
        currentDirectoryURL: URL,
        bundleURL: URL?,
        validHomeDirectoryURL: URL?
    ) -> URL {
        let currentURL = currentDirectoryURL.standardizedFileURL
        guard shouldUseHomeWorkingDirectory(currentURL: currentURL, bundleURL: bundleURL),
              let validHomeDirectoryURL
        else {
            return currentURL
        }

        return validHomeDirectoryURL.standardizedFileURL
    }

    private static func shouldUseHomeWorkingDirectory(currentURL: URL, bundleURL: URL?) -> Bool {
        let currentPath = currentURL.path
        if currentPath == "/" || currentPath == "/Applications" || currentPath == "/System/Applications" {
            return true
        }

        guard let bundleURL else { return false }

        let bundlePath = bundleURL.standardizedFileURL.path
        return currentPath == bundlePath || currentPath.hasPrefix(bundlePath + "/")
    }
}
