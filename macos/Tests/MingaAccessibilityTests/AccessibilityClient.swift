import ApplicationServices
import Foundation
import XCTest

struct AccessibilityNode {
    let element: XCUIElement
    let role: XCUIElement.ElementType
    let identifier: String?
    let label: String?
    let value: String?
    let focused: Bool?
    let selectedTextRange: NSRange?
    let selectedText: String?
}

enum AccessibilityClientError: Error, CustomStringConvertible {
    case api(String, AXError)
    case condition(String)
    case timeout(String, TimeInterval)

    var description: String {
        switch self {
        case .api(let operation, let error):
            return "AX API failed during \(operation): AXError \(error.rawValue)"
        case .condition(let message):
            return message
        case .timeout(let condition, let seconds):
            return "Timed out after \(String(format: "%.2f", seconds)) seconds waiting for \(condition)"
        }
    }
}

@MainActor
final class AccessibilityClient {
    private let application: XCUIApplication
    private let accessibilityApplication: AXUIElement
    private let maximumFailureElements = 120
    private let pollInterval: TimeInterval = 0.25
    private var accessibilityElementsByIdentifier: [String: AXUIElement] = [:]

    init(application: XCUIApplication, processID: pid_t) {
        self.application = application
        accessibilityApplication = AXUIElementCreateApplication(processID)
    }

    func elements(
        ofType type: XCUIElement.ElementType,
        identifierPrefix: String? = nil,
        label: String? = nil,
        labelContains: String? = nil
    ) -> XCUIElementQuery {
        var predicates: [NSPredicate] = []
        if let identifierPrefix {
            predicates.append(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
        }
        if let label {
            predicates.append(NSPredicate(format: "label == %@", label))
        }
        if let labelContains {
            predicates.append(NSPredicate(format: "label CONTAINS %@", labelContains))
        }

        let query = application.descendants(matching: type)
        guard !predicates.isEmpty else { return query }
        return query.matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
    }

    func waitForNode(
        _ description: String,
        timeout: TimeInterval = 12,
        query: XCUIElementQuery,
        matching predicate: (AccessibilityNode) -> Bool
    ) throws -> AccessibilityNode {
        try waitForNode(
            description,
            timeout: timeout,
            query: query,
            includeTextSelection: false,
            matching: predicate
        )
    }

    func waitForEditorNode(
        _ description: String,
        timeout: TimeInterval = 12,
        query: XCUIElementQuery,
        matching predicate: (AccessibilityNode) -> Bool
    ) throws -> AccessibilityNode {
        try waitForNode(
            description,
            timeout: timeout,
            query: query,
            includeTextSelection: true,
            matching: predicate
        )
    }

    func requireRawAccessibilityAccess() throws {
        let trusted = AXIsProcessTrusted()
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            accessibilityApplication,
            kAXRoleAttribute as CFString,
            &role
        )
        guard trusted, result == .success else {
            throw AccessibilityClientError.condition(
                "INFRASTRUCTURE: launched text-range verification requires raw macOS Accessibility access; AXIsProcessTrusted=\(trusted), reading AXRole returned AXError \(result.rawValue)"
            )
        }
    }

    private func waitForNode(
        _ description: String,
        timeout: TimeInterval,
        query: XCUIElementQuery,
        includeTextSelection: Bool,
        matching predicate: (AccessibilityNode) -> Bool
    ) throws -> AccessibilityNode {
        let element = query.firstMatch
        var lastObservedNode: AccessibilityNode?

        do {
            return try wait(description, timeout: timeout, waitingFor: element) {
                guard element.exists else { return nil }
                let node = try self.snapshot(element, includeTextSelection: includeTextSelection)
                lastObservedNode = node
                return predicate(node) ? node : nil
            }
        } catch AccessibilityClientError.timeout(_, _) {
            guard let lastObservedNode else { throw AccessibilityClientError.timeout(description, timeout) }
            throw AccessibilityClientError.condition(
                "Timed out after \(String(format: "%.2f", timeout)) seconds waiting for \(description); last observed \(diagnosticSummary(lastObservedNode))"
            )
        }
    }

    func waitForNodes(
        _ description: String,
        timeout: TimeInterval = 12,
        query: XCUIElementQuery,
        until accepted: ([AccessibilityNode]) -> Bool
    ) throws -> [AccessibilityNode] {
        try wait(description, timeout: timeout, waitingFor: query.firstMatch) {
            guard query.firstMatch.exists else { return nil }
            let matches = try query.allElementsBoundByIndex.map { try self.snapshot($0) }
            return accepted(matches) ? matches : nil
        }
    }

    func waitForAbsence(
        _ description: String,
        timeout: TimeInterval = 12,
        query: XCUIElementQuery
    ) throws {
        let _: Bool = try wait(description, timeout: timeout, waitingFor: query.firstMatch) {
            query.firstMatch.exists ? nil : true
        }
    }

    func nodeExists(
        query: XCUIElementQuery,
        matching predicate: (AccessibilityNode) -> Bool
    ) throws -> Bool {
        let element = query.firstMatch
        guard element.exists else { return false }
        return predicate(try snapshot(element))
    }

    func performPress(on node: AccessibilityNode) throws {
        guard node.role == .button else {
            throw AccessibilityClientError.condition(
                "Required button action is missing from \(summary(node))"
            )
        }
        node.element.click()
    }

    func focus(_ node: AccessibilityNode) throws {
        guard node.role == .textView,
              let identifier = node.identifier,
              let element = try accessibilityElement(identifier: identifier)
        else {
            throw AccessibilityClientError.condition(
                "Required text-area focus action is missing from \(summary(node))"
            )
        }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard result == .success else {
            throw AccessibilityClientError.condition(
                "Text-area focus action failed with AXError \(result.rawValue) for \(summary(node))"
            )
        }
    }

    func boundedTreeDump() -> String {
        do {
            let elements = application.descendants(matching: .any).allElementsBoundByIndex
            let snapshots = try elements.prefix(maximumFailureElements).map { try snapshot($0) }
            let lines = snapshots.enumerated().map { index, node in
                [
                    "\(index): role=\(node.role)",
                    "id=\(node.identifier ?? "nil")",
                    "label=\(node.label ?? "nil")",
                    "value=\(bounded(node.value))",
                    "focused=\(String(describing: node.focused))",
                    "selectedTextRange=\(String(describing: node.selectedTextRange))",
                    "selectedText=\(bounded(node.selectedText))"
                ].joined(separator: " ")
            }
            let suffix = elements.count > maximumFailureElements
                ? "\n... truncated \(elements.count - maximumFailureElements) elements"
                : ""
            return lines.joined(separator: "\n") + suffix
        } catch {
            return "Unable to collect XCTest accessibility tree: \(error)"
        }
    }

    private func snapshot(
        _ element: XCUIElement,
        includeTextSelection: Bool = false
    ) throws -> AccessibilityNode {
        let snapshot = try element.snapshot()
        let representation = snapshot.dictionaryRepresentation
        let identifier = emptyAsNil(snapshot.identifier)
        let textSelection: (range: NSRange, text: String?)? = if includeTextSelection, let identifier {
            try editorTextSelection(identifier: identifier)
        } else {
            nil
        }
        return AccessibilityNode(
            element: element,
            role: snapshot.elementType,
            identifier: identifier,
            label: emptyAsNil(snapshot.label),
            value: describe(snapshot.value),
            focused: representation[.hasFocus] as? Bool,
            selectedTextRange: textSelection?.range,
            selectedText: textSelection?.text
        )
    }

    private func editorTextSelection(identifier: String) throws -> (range: NSRange, text: String?)? {
        guard identifier.hasPrefix("minga.editor."),
              let element = try accessibilityElement(identifier: identifier),
              let rawRangeValue = try attribute(kAXSelectedTextRangeAttribute as CFString, from: element),
              CFGetTypeID(rawRangeValue) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(rawRangeValue, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        let selectedText = try attribute(kAXSelectedTextAttribute as CFString, from: element) as? String
        return (NSRange(location: range.location, length: range.length), emptyAsNil(selectedText ?? ""))
    }

    private func accessibilityElement(identifier: String) throws -> AXUIElement? {
        if let cached = accessibilityElementsByIdentifier[identifier] { return cached }

        var pending = [accessibilityApplication]
        while let element = pending.popLast() {
            if try attribute(kAXIdentifierAttribute as CFString, from: element) as? String == identifier {
                accessibilityElementsByIdentifier[identifier] = element
                return element
            }
            if let children = try attribute(kAXChildrenAttribute as CFString, from: element) as? [AXUIElement] {
                pending.append(contentsOf: children)
            }
        }
        return nil
    }

    private func attribute(_ name: CFString, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name, &value)
        switch result {
        case .success:
            return value
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw AccessibilityClientError.api("reading \(name)", result)
        }
    }

    private func wait<T>(
        _ description: String,
        timeout: TimeInterval,
        waitingFor element: XCUIElement,
        predicate: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try throwIfConnectionFailed()
            do {
                if let value = try predicate() { return value }
            } catch AccessibilityClientError.api(_, .cannotComplete) {
                // A live application's AX hierarchy can be briefly unavailable while AppKit commits a frame.
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let interval = min(pollInterval, remaining)
            if element.exists {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(interval)
                )
            } else {
                _ = element.waitForExistence(timeout: interval)
            }
        } while Date() < deadline

        try throwIfConnectionFailed()
        throw AccessibilityClientError.timeout(description, timeout)
    }

    private func throwIfConnectionFailed() throws {
        for title in ["Editor Connection Failed", "Editor Core Stopped"] {
            let alert = application.alerts[title]
            guard alert.exists else { continue }
            let details = alert.descendants(matching: .staticText).allElementsBoundByIndex
                .map(\.label)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            throw AccessibilityClientError.condition(
                details.isEmpty ? "\(title) appeared" : "\(title): \(details)"
            )
        }

        let protocolError = elements(ofType: .any, identifierPrefix: "protocol-error-overlay").firstMatch
        if protocolError.exists {
            throw AccessibilityClientError.condition(
                "The protocol error overlay appeared before the editor became ready"
            )
        }
    }

    private func emptyAsNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func describe(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case nil:
            return nil
        default:
            return String(describing: value)
        }
    }

    private func summary(_ node: AccessibilityNode) -> String {
        "role=\(node.role) id=\(node.identifier ?? "nil") label=\(node.label ?? "nil")"
    }

    private func diagnosticSummary(_ node: AccessibilityNode) -> String {
        [
            summary(node),
            "value=\(bounded(node.value))",
            "focused=\(String(describing: node.focused))",
            "selectedTextRange=\(String(describing: node.selectedTextRange))",
            "selectedText=\(bounded(node.selectedText))"
        ].joined(separator: " ")
    }

    private func bounded(_ value: String?) -> String {
        guard let value else { return "nil" }
        let prefix = value.prefix(240)
        return String(reflecting: String(prefix)) + (value.count > prefix.count ? "…" : "")
    }
}
