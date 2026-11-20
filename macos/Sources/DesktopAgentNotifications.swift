import AppKit
import MingaUI
import UserNotifications

/// Posts under Minga's bundle identity. The editor remains the owner of approvals and errors.
@MainActor
final class DesktopAgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let openEditor: @MainActor () -> Void
    private var approvals: [UUID: Task<Void, Never>] = [:]
    private var outcomes: [OutcomeKey: Task<Void, Never>] = [:]

    private struct OutcomeKey: Hashable {
        let session: UUID
        let outcome: AgentDesktopNotification.Outcome
    }

    init(openEditor: @escaping @MainActor () -> Void) {
        self.openEditor = openEditor
        super.init()
        center.delegate = self
    }

    func receive(_ notification: AgentDesktopNotification) {
        switch notification {
        case .approvalCleared(let id):
            approvals.removeValue(forKey: id)?.cancel()
            withdrawApprovals([approvalIdentifier(id)])
        case .approval(let id):
            postApproval(id)
        case .outcome(let outcome, let session, let debounceMs):
            postOutcome(outcome, session: session, debounceMs: debounceMs)
        }
    }

    func retireConnection() {
        guard !approvals.isEmpty || !outcomes.isEmpty else { return }
        for task in approvals.values { task.cancel() }
        withdrawApprovals(approvals.keys.map(approvalIdentifier))
        approvals.removeAll()
        for task in outcomes.values { task.cancel() }
        outcomes.removeAll()
    }

    private func postApproval(_ id: UUID) {
        guard !NSApp.isActive, approvals[id] == nil else { return }
        approvals[id] = Task {
            let delivered = await deliver(
                id: approvalIdentifier(id), title: "Tool Approval Needed",
                body: "The agent is waiting for you to review a tool request."
            )
            if Task.isCancelled {
                // Retirement can race an add already in progress.
                withdrawApprovals([approvalIdentifier(id)])
            } else if !delivered {
                approvals[id] = nil
            }
        }
    }

    private func postOutcome(_ outcome: AgentDesktopNotification.Outcome, session: UUID, debounceMs: UInt32) {
        let key = OutcomeKey(session: session, outcome: outcome)
        guard !NSApp.isActive, outcomes[key] == nil else { return }
        outcomes[key] = Task {
            defer { if !Task.isCancelled { outcomes[key] = nil } }
            let copy = switch outcome {
            case .complete: (title: "Agent Finished", body: "Your response is ready to review.")
            case .failed: (title: "Agent Needs Attention", body: "Open the conversation for details.")
            }
            guard await deliver(id: UUID().uuidString, title: copy.title, body: copy.body) else { return }
            // Cooldown starts after a successful post, not when a foreground event occurs.
            try? await Task.sleep(for: .milliseconds(debounceMs))
        }
    }

    private func deliver(id: String, title: String, body: String) async -> Bool {
        guard !Task.isCancelled, !NSApp.isActive else { return false }
        do {
            // macOS prompts only on the first request. Later calls respect the user's choice.
            guard try await center.requestAuthorization(options: [.alert]),
                  !Task.isCancelled, !NSApp.isActive else { return false }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = "agent"
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            PortLogger.warn("Could not deliver an agent notification", privateDetail: error.localizedDescription)
            return false
        }
    }

    private func approvalIdentifier(_ id: UUID) -> String { "agent-approval-\(id.uuidString)" }

    private func withdrawApprovals(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await openEditor()
    }
}
