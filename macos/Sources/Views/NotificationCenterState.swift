/// Observable state for BEAM-owned editor notifications.

import Foundation
import SwiftUI

/// Native view model for one notification action.
struct EditorNotificationAction: Identifiable, Equatable {
    let id: String
    let label: String
}

/// Native view model for one editor notification.
struct EditorNotification: Identifiable, Equatable {
    let id: String
    let level: NotificationLevel
    let dismissable: Bool
    let createdAt: Date
    let updatedAt: Date
    let title: String
    let body: String
    let source: String
    let actions: [EditorNotificationAction]

    var levelName: String { level.name }
}

/// Stores the current notification stack sent by the BEAM.
@MainActor
@Observable
final class NotificationCenterState {
    var notifications: [EditorNotification] = []

    /// Applies a full notification snapshot from the protocol decoder.
    func update(rawNotifications: [Wire.EditorNotification]) {
        notifications = rawNotifications.map { raw in
            EditorNotification(
                id: raw.id,
                level: raw.level,
                dismissable: raw.dismissable,
                createdAt: Date(timeIntervalSince1970: TimeInterval(raw.createdAt)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(raw.updatedAt)),
                title: raw.title,
                body: raw.body,
                source: raw.source,
                actions: raw.actions.map { EditorNotificationAction(id: $0.id, label: $0.label) }
            )
        }
    }
}
