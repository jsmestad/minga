import AppKit
import Foundation
import XCTest
@MainActor
final class MingaAccessibilityWorkflowTests: XCTestCase {
    private let timeout: TimeInterval = 15
    private var accessibilityClient: AccessibilityClient?
    private var launchedApplication: XCUIApplication?
    private var timings: [OperationTiming] = []

    func testRealApplicationAccessibilityNavigationAndFocus() throws {
        let environment = ProcessInfo.processInfo.environment
        let variant = environment["MINGA_AX_VARIANT"] ?? "unspecified"
        defer {
            launchedApplication?.terminate()
            launchedApplication = nil
        }

        do {
            let inputs = try AccessibilityTestInputs.fromEnvironment(environment)
            let application = configuredApplication(inputs: inputs)
            launchedApplication = application
            let client = try launch(
                application,
                environment: environment,
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
        try verifyInitialEditorFocus(app: app, client: client)
        try activateBetaThroughPicker(app: app, client: client)
        try dismissPickerAndVerifyBeta(app: app, client: client)
        try splitAndMoveFocus(app: app, client: client)
    }

    func verifyInitialEditorFocus(app: XCUIApplication, client: AccessibilityClient) throws {
        let alphaQuery = client.elements(
            ofType: .textView,
            identifierPrefix: "minga.editor.",
            labelContains: "alpha_target.ex"
        )
        let alpha = try timed("first-frame") {
            try client.waitForNode(
                "the first fixture editor pane",
                timeout: timeout,
                query: alphaQuery
            ) {
                $0.value?.contains("ALPHA PANE λ🙂") == true
            }
        }
        try require(
            alpha.identifier?.hasPrefix("minga.editor.") == true,
            "Alpha pane lacks its stable accessibility identity"
        )
        try require(alpha.focused == true, "Alpha pane is not the actual AX-focused editor after launch")
        app.typeText("v")
        app.typeKey(.escape, modifierFlags: [])
        _ = try timed("focus-after-mode-cycle") {
            try client.waitForNode(
                "alpha editor focus after entering and leaving visual mode",
                timeout: timeout,
                query: alphaQuery
            ) {
                $0.focused == true
            }
        }
    }

    func activateBetaThroughPicker(app: XCUIApplication, client: AccessibilityClient) throws {
        try openProjectPicker(app: app, client: client)
        app.typeText("target")

        let betaChoiceQuery = client.elements(
            ofType: .button,
            identifierPrefix: "picker-choice-",
            label: "beta_target.ex"
        )
        let betaChoice = try timed("picker-filter") {
            try client.waitForNode(
                "a nonselected beta_target.ex picker choice",
                timeout: timeout,
                query: betaChoiceQuery
            ) {
                $0.value?.hasPrefix("available") == true
            }
        }
        try require(betaChoice.identifier?.isEmpty == false, "The beta picker choice lacks semantic identity")

        try timed("picker-ax-activation") {
            try client.performPress(on: betaChoice)
            try client.waitForAbsence(
                "the picker to dismiss after accessibility activation",
                timeout: timeout,
                query: findFileChoicesQuery(client: client)
            )
        }

        _ = try client.waitForNode(
            "the activated beta_target.ex editor",
            timeout: timeout,
            query: editorPaneQuery(named: "beta_target.ex", client: client)
        ) {
            $0.value?.contains("BETA PANE é🙂") == true
                && $0.focused == true
        }
        try require(
            activeFileTabExists(named: "beta_target.ex", client: client),
            "AX activation did not make beta_target.ex the exact active file tab"
        )
    }

    func dismissPickerAndVerifyBeta(app: XCUIApplication, client: AccessibilityClient) throws {
        try openProjectPicker(app: app, client: client)
        app.typeText("alpha")
        _ = try client.waitForNode(
            "the filtered alpha_target.ex picker choice",
            timeout: timeout,
            query: client.elements(
                ofType: .button,
                identifierPrefix: "picker-choice-",
                label: "alpha_target.ex"
            )
        ) { _ in true }
        app.typeKey(.escape, modifierFlags: [])
        _ = try timed("picker-dismissal-focus-return") {
            try client.waitForNode(
                "beta editor focus after picker dismissal",
                timeout: timeout,
                query: editorPaneQuery(named: "beta_target.ex", client: client)
            ) {
                $0.value?.contains("BETA PANE é🙂") == true
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
                query: client.elements(ofType: .textView, identifierPrefix: "minga.editor."),
                until: { $0.count == 2 && Set($0.compactMap(\.identifier)).count == 2 }
            )
        }
        try require(
            splitPanes.allSatisfy { $0.label?.contains("beta_target.ex") == true },
            "The split did not expose the expected beta fixture in both panes"
        )

        let alphaTab = try client.waitForNode(
            "the inactive alpha_target.ex tab",
            timeout: timeout,
            query: fileTabQuery(named: "alpha_target.ex", client: client)
        ) {
            $0.value?.hasPrefix("inactive") == true
        }
        try timed("tab-ax-activation") { try client.performPress(on: alphaTab) }

        let distinctPanes = try distinctAlphaAndBetaPanes(client: client)
        let activeAlpha = try requireNode(
            distinctPanes.first { isEditorPane($0, named: "alpha_target.ex") && $0.focused == true },
            "Accessibility activation on the alpha tab did not expose alpha as the focused pane"
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
            query: client.elements(ofType: .textView, identifierPrefix: "minga.editor."),
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
            timeout: timeout,
            query: editorPaneQuery(named: "beta_target.ex", client: client)
        ) {
            $0.focused == true
        }
        try require(
            focusedBeta.value?.contains("BETA PANE é🙂") == true,
            "Focused beta pane exposes the wrong text"
        )
        try require(
            try client.nodeExists(
                query: editorPaneQuery(named: "alpha_target.ex", client: client)
            ) { $0.focused == false },
            "Alpha remained AX-focused after focusing the named beta pane"
        )
    }
}

private extension MingaAccessibilityWorkflowTests {
    func configuredApplication(inputs: AccessibilityTestInputs) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--editor",
            "--config", inputs.config.path,
            "--debug-log", inputs.debugLog.path,
            "--minga-ipc-runtime-parent", inputs.runtimeParent.path,
            inputs.alpha.path
        ]
        application.launchEnvironment = isolatedEnvironment(inputs: inputs)
        return application
    }

    func launch(
        _ application: XCUIApplication,
        environment: [String: String],
        variant: String
    ) throws -> AccessibilityClient {
        let bundleIdentifier = try requiredEnvironmentValue(environment, key: "MINGA_AX_APP_BUNDLE_ID")
        let executablePath = try requiredEnvironmentValue(environment, key: "MINGA_AX_APP_EXECUTABLE")
        let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
        try timed("launch-\(variant)") {
            application.launch()
            _ = try RunningApplicationLocator.pid(
                bundleIdentifier: bundleIdentifier,
                executableURL: executableURL,
                timeout: timeout
            )
        }
        return AccessibilityClient(application: application)
    }

    func openProjectPicker(app: XCUIApplication, client: AccessibilityClient) throws {
        app.typeText("  ")
        _ = try client.waitForNode(
            "the Find file choices container",
            timeout: timeout,
            query: findFileChoicesQuery(client: client)
        ) {
            $0.value?.contains("choices") == true
        }
        _ = try client.waitForNode(
            "the focused native picker query field",
            timeout: timeout,
            query: client.elements(ofType: .textField)
        ) {
            $0.focused == true
        }
    }

    func activeFileTabExists(named fileName: String, client: AccessibilityClient) throws -> Bool {
        try client.nodeExists(query: fileTabQuery(named: fileName, client: client)) {
            $0.value?.hasPrefix("active") == true
        }
    }

    func isEditorPane(_ node: AccessibilityNode, named fileName: String) -> Bool {
        node.role == .textView && node.label?.contains(fileName) == true
    }

    func editorPaneQuery(named fileName: String, client: AccessibilityClient) -> XCUIElementQuery {
        client.elements(
            ofType: .textView,
            identifierPrefix: "minga.editor.",
            labelContains: fileName
        )
    }

    func fileTabQuery(named fileName: String, client: AccessibilityClient) -> XCUIElementQuery {
        client.elements(ofType: .button, label: "File tab \(fileName)")
    }

    func findFileChoicesQuery(client: AccessibilityClient) -> XCUIElementQuery {
        client.elements(ofType: .any, label: "Find file choices")
    }

    func isolatedEnvironment(inputs: AccessibilityTestInputs) -> [String: String] {
        [
            "HOME": inputs.home.path,
            "CFFIXED_USER_HOME": inputs.home.path,
            "XDG_CONFIG_HOME": inputs.xdgConfigHome.path,
            "XDG_DATA_HOME": inputs.xdgDataHome.path,
            "XDG_CACHE_HOME": inputs.xdgCacheHome.path,
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
        }
        if let accessibilityClient {
            let tree = accessibilityClient.boundedTreeDump()
            attachText(tree, name: "Bounded accessibility tree")
        }
    }

    func writeTimings(variant: String, status: String) throws {
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
    }

    func attachText(_ contents: String, name: String) {
        let attachment = XCTAttachment(string: contents)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
