import ApplicationServices
import AppKit
import Foundation
import XCTest
@MainActor
final class MingaAccessibilityWorkflowTests: XCTestCase {
    private let timeout: TimeInterval = 15
    private var accessibilityClient: AccessibilityClient?
    private var artifactDirectory: URL?
    private var launchedApplication: XCUIApplication?
    private var timings: [OperationTiming] = []

    func testRealApplicationAccessibilityNavigationAndFocus() throws {
        let environment = ProcessInfo.processInfo.environment
        let variant = environment["MINGA_AX_VARIANT"] ?? "unspecified"
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("minga-accessibility-\(UUID().uuidString)", isDirectory: true)
        let artifacts = runRoot.appendingPathComponent("artifacts", isDirectory: true)
        artifactDirectory = artifacts
        defer {
            launchedApplication?.terminate()
            launchedApplication = nil
            try? FileManager.default.removeItem(at: runRoot)
        }

        do {
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try requireAccessibilityPermission(artifactDirectory: artifacts)

            let fixture = try AccessibilityTestFixture.create(at: runRoot)
            let application = configuredApplication(fixture: fixture)
            launchedApplication = application
            let client = try launch(
                application,
                environment: environment,
                runRoot: runRoot,
                variant: variant
            )
            accessibilityClient = client
            try runScenario(app: application, client: client)
            try writeTimings(variant: variant, status: "passed")
        } catch {
            try? writeTimings(variant: variant, status: "failed")
            captureFailure(message: String(describing: error))
            XCTFail(String(describing: error))
        }
    }
}
private extension MingaAccessibilityWorkflowTests {
    func runScenario(app: XCUIApplication, client: AccessibilityClient) throws {
        try verifyInitialSelection(app: app, client: client)
        try activateBetaThroughPicker(app: app, client: client)
        try dismissPickerAndVerifyBeta(app: app, client: client)
        try splitAndMoveFocus(app: app, client: client)
    }

    func verifyInitialSelection(app: XCUIApplication, client: AccessibilityClient) throws {
        let alpha = try timed("first-frame") {
            try client.waitForNode("the first fixture editor pane", timeout: timeout) {
                self.isEditorPane($0, named: "alpha_target.ex")
                    && $0.value?.contains("ALPHA PANE λ🙂") == true
            }
        }
        try require(
            alpha.identifier?.hasPrefix("minga.editor.") == true,
            "Alpha pane lacks its stable accessibility identity"
        )
        try require(alpha.focused == true, "Alpha pane is not the actual AX-focused editor after launch")
        try require(
            alpha.selectedText == nil || alpha.selectedText == "",
            "Alpha pane unexpectedly exposes selected text at launch"
        )
        try require(
            alpha.selectedTextRange == NSRange(location: 0, length: 0),
            "Alpha pane does not expose the initial insertion range {0,0}"
        )

        app.typeText("v")
        let selectedAlpha = try timed("selection-observation") {
            try client.waitForNode("the visual selection in alpha_target.ex", timeout: timeout) {
                self.isEditorPane($0, named: "alpha_target.ex")
                    && $0.selectedText == "A"
                    && $0.selectedTextRange == NSRange(location: 0, length: 1)
            }
        }
        try require(
            selectedAlpha.focused == true,
            "Alpha pane lost keyboard focus while exposing a visual selection"
        )

        app.typeKey(.escape, modifierFlags: [])
        _ = try timed("selection-dismissal") {
            try client.waitForNode("alpha insertion state after Escape", timeout: timeout) {
                self.isEditorPane($0, named: "alpha_target.ex")
                    && ($0.selectedText == nil || $0.selectedText == "")
                    && $0.selectedTextRange == NSRange(location: 0, length: 0)
                    && $0.focused == true
            }
        }
    }

    func activateBetaThroughPicker(app: XCUIApplication, client: AccessibilityClient) throws {
        try openProjectPicker(app: app, client: client)
        app.typeText("target")

        let betaChoice = try timed("picker-filter") {
            try client.waitForNode("a nonselected beta_target.ex picker choice", timeout: timeout) {
                $0.role == kAXButtonRole as String
                    && $0.identifier?.hasPrefix("picker-choice-") == true
                    && $0.label == "beta_target.ex"
                    && $0.value?.hasPrefix("available") == true
            }
        }
        try require(betaChoice.identifier?.isEmpty == false, "The beta picker choice lacks semantic identity")

        try timed("picker-ax-activation") {
            try client.performPress(on: betaChoice)
            try client.waitUntil("the picker to dismiss after AXPress", timeout: timeout) {
                try !client.nodeExists { $0.label == "Find file choices" }
            }
        }

        let beta = try client.waitForNode("the activated beta_target.ex editor", timeout: timeout) {
            self.isEditorPane($0, named: "beta_target.ex")
                && $0.value?.contains("BETA PANE é🙂") == true
                && $0.focused == true
        }
        try require(
            beta.selectedTextRange == NSRange(location: 0, length: 0),
            "Activated beta pane exposes the wrong insertion range"
        )
        try require(
            activeFileTabExists(named: "beta_target.ex", client: client),
            "AX activation did not make beta_target.ex the exact active file tab"
        )
    }

    func dismissPickerAndVerifyBeta(app: XCUIApplication, client: AccessibilityClient) throws {
        try openProjectPicker(app: app, client: client)
        app.typeText("alpha")
        _ = try client.waitForNode("the filtered alpha_target.ex picker choice", timeout: timeout) {
            $0.role == kAXButtonRole as String
                && $0.identifier?.hasPrefix("picker-choice-") == true
                && $0.label == "alpha_target.ex"
        }
        app.typeKey(.escape, modifierFlags: [])
        _ = try timed("picker-dismissal-focus-return") {
            try client.waitForNode("beta editor focus after picker dismissal", timeout: timeout) {
                self.isEditorPane($0, named: "beta_target.ex")
                    && $0.value?.contains("BETA PANE é🙂") == true
                    && $0.focused == true
            }
        }
        try require(
            activeFileTabExists(named: "beta_target.ex", client: client),
            "Picker dismissal activated a choice instead of returning to beta_target.ex"
        )
    }

    func splitAndMoveFocus(app: XCUIApplication, client: AccessibilityClient) throws {
        app.typeText(" wv")
        let splitPanes = try timed("split-discovery") {
            try client.waitForNodes(
                "two distinct editor panes",
                timeout: timeout,
                matching: { $0.role == kAXTextAreaRole as String },
                until: { $0.count == 2 && Set($0.compactMap(\.identifier)).count == 2 }
            )
        }
        try require(
            splitPanes.allSatisfy { $0.label?.contains("beta_target.ex") == true },
            "The split did not expose the expected beta fixture in both panes"
        )

        let alphaTab = try client.waitForNode("the inactive alpha_target.ex tab", timeout: timeout) {
            $0.role == kAXButtonRole as String
                && $0.label == "File tab alpha_target.ex"
                && $0.value?.hasPrefix("inactive") == true
        }
        try timed("tab-ax-activation") { try client.performPress(on: alphaTab) }

        let distinctPanes = try distinctAlphaAndBetaPanes(client: client)
        let activeAlpha = try requireNode(
            distinctPanes.first { isEditorPane($0, named: "alpha_target.ex") && $0.focused == true },
            "AXPress on the alpha tab did not expose alpha as the focused pane"
        )
        try require(
            activeAlpha.value?.contains("ALPHA PANE λ🙂") == true,
            "Focused alpha pane exposes the wrong text"
        )

        let inactiveBeta = try requireNode(
            distinctPanes.first { isEditorPane($0, named: "beta_target.ex") },
            "The beta pane disappeared after alpha tab activation"
        )
        try timed("pane-ax-focus") { try client.focus(inactiveBeta) }
        try verifyFocusedBeta(client: client)
    }

    func distinctAlphaAndBetaPanes(client: AccessibilityClient) throws -> [AccessibilityNode] {
        try client.waitForNodes(
            "alpha and beta in distinct panes",
            timeout: timeout,
            matching: { $0.role == kAXTextAreaRole as String },
            until: { panes in
                panes.count == 2
                    && panes.contains { self.isEditorPane($0, named: "alpha_target.ex") }
                    && panes.contains { self.isEditorPane($0, named: "beta_target.ex") }
            }
        )
    }

    func verifyFocusedBeta(client: AccessibilityClient) throws {
        let focusedBeta = try client.waitForNode(
            "beta_target.ex to own real keyboard focus",
            timeout: timeout
        ) {
            self.isEditorPane($0, named: "beta_target.ex") && $0.focused == true
        }
        try require(
            focusedBeta.value?.contains("BETA PANE é🙂") == true,
            "Focused beta pane exposes the wrong text"
        )
        try require(
            focusedBeta.selectedTextRange == NSRange(location: 0, length: 0),
            "Focused beta pane exposes the wrong insertion state"
        )
        try require(
            try client.nodeExists { self.isEditorPane($0, named: "alpha_target.ex") && $0.focused == false },
            "Alpha remained AX-focused after focusing the named beta pane"
        )
    }
}

private extension MingaAccessibilityWorkflowTests {
    func configuredApplication(fixture: AccessibilityTestFixture) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--editor",
            "--config", fixture.config.path,
            "--debug-log", fixture.debugLog.path,
            "--minga-ipc-runtime-parent", fixture.runtimeParent.path,
            fixture.alpha.path
        ]
        application.launchEnvironment = isolatedEnvironment(root: fixture.home)
        return application
    }

    func launch(
        _ application: XCUIApplication,
        environment: [String: String],
        runRoot: URL,
        variant: String
    ) throws -> AccessibilityClient {
        let bundleIdentifier = try requiredEnvironmentValue(environment, key: "MINGA_AX_APP_BUNDLE_ID")
        let executablePath = try requiredEnvironmentValue(environment, key: "MINGA_AX_APP_EXECUTABLE")
        let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
        try timed("launch-\(variant)") {
            application.launch()
            let pid = try RunningApplicationLocator.pid(
                bundleIdentifier: bundleIdentifier,
                executableURL: executableURL,
                timeout: timeout
            )
            try write("\(pid)\n", to: runRoot.appendingPathComponent("app.pid"))
        }
        let pid = try RunningApplicationLocator.pid(
            bundleIdentifier: bundleIdentifier,
            executableURL: executableURL,
            timeout: timeout
        )
        return AccessibilityClient(processIdentifier: pid)
    }

    func requireAccessibilityPermission(artifactDirectory: URL) throws {
        guard AXIsProcessTrusted() else {
            let message = [
                "The UI-test process does not have macOS Accessibility permission.",
                "Grant Accessibility access to Xcode (or the CI runner) and rerun scripts/test_macos_accessibility."
            ].joined(separator: " ")
            try write(message + "\n", to: artifactDirectory.appendingPathComponent("infrastructure-failure.txt"))
            throw WorkflowFailure.unmet("INFRASTRUCTURE: \(message)")
        }
    }

    func openProjectPicker(app: XCUIApplication, client: AccessibilityClient) throws {
        app.typeText("  ")
        _ = try client.waitForNode("the Find file choices container", timeout: timeout) {
            $0.label == "Find file choices" && $0.value?.contains("choices") == true
        }
        _ = try client.waitForNode("the focused native picker query field", timeout: timeout) {
            $0.role == kAXTextFieldRole as String && $0.focused == true
        }
    }

    func activeFileTabExists(named fileName: String, client: AccessibilityClient) throws -> Bool {
        try client.nodeExists {
            $0.role == kAXButtonRole as String
                && $0.label == "File tab \(fileName)"
                && $0.value?.hasPrefix("active") == true
        }
    }

    func isEditorPane(_ node: AccessibilityNode, named fileName: String) -> Bool {
        node.role == kAXTextAreaRole as String && node.label?.contains(fileName) == true
    }

    func isolatedEnvironment(root: URL) -> [String: String] {
        [
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("xdg-config", isDirectory: true).path,
            "XDG_DATA_HOME": root.appendingPathComponent("xdg-data", isDirectory: true).path,
            "XDG_CACHE_HOME": root.appendingPathComponent("xdg-cache", isDirectory: true).path,
            "MINGA_AX_ISOLATED_RUN": "1"
        ]
    }
}

private extension MingaAccessibilityWorkflowTests {
    func timed<T>(_ operation: String, body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let duration = start.duration(to: .now)
            let milliseconds = Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000
            timings.append(OperationTiming(operation: operation, milliseconds: milliseconds))
        }
        return try body()
    }

    func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw WorkflowFailure.unmet(message) }
    }

    func requireNode(_ node: AccessibilityNode?, _ message: String) throws -> AccessibilityNode {
        guard let node else { throw WorkflowFailure.unmet(message) }
        return node
    }

    func requiredEnvironmentValue(_ environment: [String: String], key: String) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw WorkflowFailure.unmet("INFRASTRUCTURE: \(key) is required")
        }
        return value
    }

    func captureFailure(message: String) {
        attachText(message, name: "Minga accessibility failure")
        if let launchedApplication, launchedApplication.exists {
            let screenshot = launchedApplication.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Minga accessibility failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let artifactDirectory {
                try? screenshot.pngRepresentation.write(
                    to: artifactDirectory.appendingPathComponent("failure.png"),
                    options: .atomic
                )
            }
        }
        guard let artifactDirectory else { return }
        try? write(message + "\n", to: artifactDirectory.appendingPathComponent("failure.txt"))
        if let accessibilityClient {
            let tree = accessibilityClient.boundedTreeDump()
            attachText(tree, name: "Bounded accessibility tree")
            try? write(
                tree + "\n",
                to: artifactDirectory.appendingPathComponent("accessibility-tree.txt")
            )
        }
    }

    func writeTimings(variant: String, status: String) throws {
        guard let artifactDirectory else { return }
        let payload: [String: Any] = [
            "variant": variant,
            "status": status,
            "operations": timings.map {
                ["operation": $0.operation, "milliseconds": $0.milliseconds]
            }
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Accessibility workflow timings"
        attachment.lifetime = .keepAlways
        add(attachment)
        try data.write(to: artifactDirectory.appendingPathComponent("timings.json"), options: .atomic)
    }

    func attachText(_ contents: String, name: String) {
        let attachment = XCTAttachment(string: contents)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}
