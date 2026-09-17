import ApplicationServices
import Foundation

struct AccessibilityNode {
    let element: AXUIElement
    let role: String
    let identifier: String?
    let label: String?
    let value: String?
    let selectedText: String?
    let selectedTextRange: NSRange?
    let focused: Bool?
    let actions: [String]
}

enum AccessibilityClientError: Error, CustomStringConvertible {
    case api(String, AXError)
    case condition(String)
    case timeout(String, TimeInterval)

    var description: String {
        switch self {
        case .api(let operation, let error):
            return "AX API failed during \(operation): \(error.rawValue)"
        case .condition(let message):
            return message
        case .timeout(let condition, let seconds):
            return "Timed out after \(String(format: "%.2f", seconds)) seconds waiting for \(condition)"
        }
    }
}

final class AccessibilityClient {
    private struct PendingElement {
        let element: AXUIElement
        let depth: Int
    }

    private let application: AXUIElement
    private let maximumDepth = 10
    private let maximumElements = 240
    private let pollInterval: TimeInterval = 0.05

    init(processIdentifier: pid_t) {
        application = AXUIElementCreateApplication(processIdentifier)
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
        guard node.actions.contains(kAXPressAction as String) else {
            throw AccessibilityClientError.condition(
                "Required AXPress action is missing from \(summary(node))"
            )
        }
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        guard result == .success else {
            throw AccessibilityClientError.api("AXPress on \(summary(node))", result)
        }
    }

    func focus(_ node: AccessibilityNode) throws {
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            node.element,
            kAXFocusedAttribute as CFString,
            &settable
        )
        guard settableResult == .success else {
            throw AccessibilityClientError.api(
                "checking AXFocused settable state on \(summary(node))",
                settableResult
            )
        }
        guard settable.boolValue else {
            throw AccessibilityClientError.condition(
                "AXFocused is not settable on \(summary(node))"
            )
        }

        let result = AXUIElementSetAttributeValue(
            node.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard result == .success else {
            throw AccessibilityClientError.api("setting AXFocused on \(summary(node))", result)
        }
    }

    func boundedTreeDump() -> String {
        do {
            let snapshots = try nodes()
            let lines = snapshots.enumerated().map { index, node in
                let range = node.selectedTextRange.map { "{\($0.location),\($0.length)}" } ?? "nil"
                return [
                    "\(index): role=\(node.role)",
                    "id=\(node.identifier ?? "nil")",
                    "label=\(node.label ?? "nil")",
                    "value=\(bounded(node.value))",
                    "focused=\(String(describing: node.focused))",
                    "selected=\(bounded(node.selectedText))",
                    "range=\(range)",
                    "actions=\(node.actions)"
                ].joined(separator: " ")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Unable to collect AX tree: \(error)"
        }
    }

    private func nodes() throws -> [AccessibilityNode] {
        var pending = [PendingElement(element: application, depth: 0)]
        var result: [AccessibilityNode] = []

        while let current = pending.first, result.count < maximumElements {
            pending.removeFirst()
            result.append(try snapshot(current.element))
            guard current.depth < maximumDepth else { continue }

            let children = try optionalAttribute(
                current.element,
                kAXChildrenAttribute as String
            ) as? [AXUIElement] ?? []
            pending.append(contentsOf: children.prefix(maximumElements - result.count).map {
                PendingElement(element: $0, depth: current.depth + 1)
            })
        }

        return result
    }

    private func snapshot(_ element: AXUIElement) throws -> AccessibilityNode {
        let role = try stringAttribute(element, kAXRoleAttribute as String) ?? "unknown"
        let title = try stringAttribute(element, kAXTitleAttribute as String)
        let description = try stringAttribute(element, kAXDescriptionAttribute as String)
        let identifier = try stringAttribute(element, kAXIdentifierAttribute as String)
        let value = try optionalAttribute(element, kAXValueAttribute as String)

        var actionNames: CFArray?
        let actionResult = AXUIElementCopyActionNames(element, &actionNames)
        let actions: [String]
        if actionResult == .success {
            actions = actionNames as? [String] ?? []
        } else if actionResult == .actionUnsupported || actionResult == .attributeUnsupported {
            actions = []
        } else {
            throw AccessibilityClientError.api("reading AX actions", actionResult)
        }

        return AccessibilityNode(
            element: element,
            role: role,
            identifier: identifier,
            label: description ?? title,
            value: describe(value),
            selectedText: try stringAttribute(element, kAXSelectedTextAttribute as String),
            selectedTextRange: try rangeAttribute(element, kAXSelectedTextRangeAttribute as String),
            focused: try boolAttribute(element, kAXFocusedAttribute as String),
            actions: actions
        )
    }

    private func wait<T>(
        _ description: String,
        timeout: TimeInterval,
        predicate: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            do {
                if let value = try predicate() { return value }
            } catch AccessibilityClientError.api(_, .cannotComplete) {
                // A live application's AX hierarchy can be momentarily unavailable while AppKit commits a frame.
            }
            RunLoop.current.run(
                mode: .default,
                before: min(Date().addingTimeInterval(pollInterval), deadline)
            )
        } while Date() < deadline

        throw AccessibilityClientError.timeout(description, timeout)
    }

    private func optionalAttribute(_ element: AXUIElement, _ attribute: String) throws -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch result {
        case .success:
            return value
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw AccessibilityClientError.api("reading \(attribute)", result)
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) throws -> String? {
        try optionalAttribute(element, attribute) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) throws -> Bool? {
        try optionalAttribute(element, attribute) as? Bool
    }

    private func rangeAttribute(_ element: AXUIElement, _ attribute: String) throws -> NSRange? {
        guard let value = try optionalAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
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
