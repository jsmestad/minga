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
    private let maximumElements = 240
    private let pollInterval: TimeInterval = 0.05

    init(application: XCUIApplication) {
        self.application = application
    }

    func waitForNode(
        _ description: String,
        timeout: TimeInterval = 12,
        matching predicate: (AccessibilityNode) -> Bool
    ) throws -> AccessibilityNode {
        try wait(description, timeout: timeout) {
            try self.nodes().first(where: predicate)
        }
    }

    func waitForNodes(
        _ description: String,
        timeout: TimeInterval = 12,
        matching predicate: (AccessibilityNode) -> Bool,
        until accepted: ([AccessibilityNode]) -> Bool
    ) throws -> [AccessibilityNode] {
        try wait(description, timeout: timeout) {
            let matches = try self.nodes().filter(predicate)
            return accepted(matches) ? matches : nil
        }
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 12,
        predicate: () throws -> Bool
    ) throws {
        let _: Bool = try wait(description, timeout: timeout) {
            try predicate() ? true : nil
        }
    }

    func nodeExists(matching predicate: (AccessibilityNode) -> Bool) throws -> Bool {
        try nodes().contains(where: predicate)
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
            let snapshots = try nodes()
            let lines = snapshots.enumerated().map { index, node in
                [
                    "\(index): role=\(node.role)",
                    "id=\(node.identifier ?? "nil")",
                    "label=\(node.label ?? "nil")",
                    "value=\(bounded(node.value))",
                    "focused=\(String(describing: node.focused))"
                ].joined(separator: " ")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Unable to collect XCTest accessibility tree: \(error)"
        }
    }

    private func nodes() throws -> [AccessibilityNode] {
        let elements = application.descendants(matching: .any).allElementsBoundByIndex
        return try elements.prefix(maximumElements).map(snapshot)
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
        predicate: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = try? predicate() { return value }
            RunLoop.current.run(
                mode: .default,
                before: min(Date().addingTimeInterval(pollInterval), deadline)
            )
        } while Date() < deadline

        throw AccessibilityClientError.timeout(description, timeout)
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
