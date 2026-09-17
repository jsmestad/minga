import Foundation
import XCTest

struct AccessibilityNode {
    let element: XCUIElement
    let role: XCUIElement.ElementType
    let identifier: String?
    let label: String?
    let value: String?
    let focused: Bool?
}

enum AccessibilityClientError: Error, CustomStringConvertible {
    case condition(String)
    case timeout(String, TimeInterval)

    var description: String {
        switch self {
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
    private let maximumFailureElements = 120
    private let pollInterval: TimeInterval = 0.25

    init(application: XCUIApplication) {
        self.application = application
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
        let element = query.firstMatch
        return try wait(description, timeout: timeout, waitingFor: element) {
            guard element.exists, let node = try? self.snapshot(element), predicate(node) else { return nil }
            return node
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
            let matches = try query.allElementsBoundByIndex.map(self.snapshot)
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
        guard node.role == .textView else {
            throw AccessibilityClientError.condition(
                "Required text-area focus action is missing from \(summary(node))"
            )
        }
        node.element.click()
    }

    func boundedTreeDump() -> String {
        do {
            let elements = application.descendants(matching: .any).allElementsBoundByIndex
            let snapshots = try elements.prefix(maximumFailureElements).map(snapshot)
            let lines = snapshots.enumerated().map { index, node in
                [
                    "\(index): role=\(node.role)",
                    "id=\(node.identifier ?? "nil")",
                    "label=\(node.label ?? "nil")",
                    "value=\(bounded(node.value))",
                    "focused=\(String(describing: node.focused))"
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

    private func snapshot(_ element: XCUIElement) throws -> AccessibilityNode {
        let snapshot = try element.snapshot()
        let representation = snapshot.dictionaryRepresentation
        return AccessibilityNode(
            element: element,
            role: snapshot.elementType,
            identifier: emptyAsNil(snapshot.identifier),
            label: emptyAsNil(snapshot.label),
            value: describe(snapshot.value),
            focused: representation[.hasFocus] as? Bool
        )
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
            if let value = try predicate() { return value }
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
            throw AccessibilityClientError.condition("The protocol error overlay appeared before the editor became ready")
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

    private func bounded(_ value: String?) -> String {
        guard let value else { return "nil" }
        let prefix = value.prefix(240)
        return String(reflecting: String(prefix)) + (value.count > prefix.count ? "…" : "")
    }
}
