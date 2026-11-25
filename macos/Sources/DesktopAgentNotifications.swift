import AppKit
import MingaUI
import UserNotifications

/// Posts the BEAM's "a task needs you" alerts under Minga's bundle identity, and removes them when the BEAM withdraws them.
///
/// The BEAM decides when to alert: only when a task starts needing you while Minga is in the background. This class never checks whether the app is active.
/// A click brings the editor forward and tells the BEAM which alert was clicked, so it opens the tasks drawer on that task.
@MainActor
final class DesktopAgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let identifierPrefix = "agent-needs-you-"

    /// What a response to one of the app's notifications asks for.
    enum Click: Equatable {
        /// A dismissal or an action this class does not offer.
        case ignore
        /// A click on a notification this class did not post: bring the editor forward.
        case openEditor
        /// A click on a "needs you" alert: bring the editor forward and open the drawer on its task.
        case openAlert(UUID)
    }

    private let center = UNUserNotificationCenter.current()
    private let openEditor: @MainActor () -> Void
    private let openAlert: @MainActor (UUID) -> Void
    private var alerts: [UUID: Task<Void, Never>] = [:]

    init(openEditor: @escaping @MainActor () -> Void, openAlert: @escaping @MainActor (UUID) -> Void) {
        self.openEditor = openEditor
        self.openAlert = openAlert
        super.init()
        center.delegate = self
    }

    func receive(_ notification: AgentDesktopNotification) {
        switch notification {
        case .withdrawn(let id):
            alerts.removeValue(forKey: id)?.cancel()
            withdraw([Self.identifier(id)])
            PortLogger.info("Agent notification withdrawn: \(Self.identifier(id))")
        case .needsYou(let id):
            post(id)
        }
    }

    func retireConnection() {
        guard !alerts.isEmpty else { return }
        for task in alerts.values { task.cancel() }
        withdraw(alerts.keys.map(Self.identifier))
        alerts.removeAll()
    }

    private func post(_ id: UUID) {
        guard alerts[id] == nil else { return }
        alerts[id] = Task {
            let delivered = await deliver(id: Self.identifier(id))
            if Task.isCancelled {
                // A withdrawal can race an add already in progress.
                withdraw([Self.identifier(id)])
            } else if !delivered {
                alerts[id] = nil
            } else {
                PortLogger.info("Agent notification posted: \(Self.identifier(id))")
            }
        }
    }

    private func deliver(id: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            // macOS prompts only on the first request. Later calls respect the user's choice.
            guard try await center.requestAuthorization(options: [.alert]), !Task.isCancelled else { return false }
            let content = UNMutableNotificationContent()
            content.title = "Minga needs you"
            content.body = "A task is waiting for your answer."
            content.threadIdentifier = "agent"
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            PortLogger.warn("Could not deliver an agent notification", privateDetail: error.localizedDescription)
            return false
        }
    }

    private func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// The notification identifier for an alert identity.
    nonisolated static func identifier(_ id: UUID) -> String { identifierPrefix + id.uuidString }

    /// The alert identity a notification identifier names, or nil for a notification this class did not post.
    nonisolated static func alert(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    /// What a response asks for: only the default action (a click on the notification) does anything, and only an alert
    /// this class posted names a task.
    nonisolated static func click(actionIdentifier: String, requestIdentifier: String) -> Click {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return .ignore }
        guard let alert = alert(fromIdentifier: requestIdentifier) else { return .openEditor }
        return .openAlert(alert)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let click = Self.click(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier
        )
        await MainActor.run { handle(click) }
    }

    /// Brings the editor forward and, for an alert, tells the BEAM which one was clicked. It never answers anything.
    func handle(_ click: Click) {
        switch click {
        case .ignore:
            return
        case .openEditor:
            openEditor()
        case .openAlert(let alert):
            PortLogger.info("Agent notification clicked: \(Self.identifier(alert))")
            openEditor()
            openAlert(alert)
        }
    }
}
