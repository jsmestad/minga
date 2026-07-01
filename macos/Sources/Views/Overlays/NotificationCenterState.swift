/// Observable state for BEAM-owned editor notifications.

import Foundation
import SwiftUI
import MingaProtocol

/// Native view model for one notification action.
public struct EditorNotificationAction: Identifiable, Equatable {
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
    public let id: String
    public let label: String
}

/// Native view model for one editor notification.
public struct EditorNotification: Identifiable, Equatable {
    public init(id: String, level: NotificationLevel, dismissable: Bool, createdAt: Date, updatedAt: Date, title: String, body: String, source: String, actions: [EditorNotificationAction]) {
        self.id = id
        self.level = level
        self.dismissable = dismissable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.body = body
        self.source = source
        self.actions = actions
    }
    public let id: String
    public let level: NotificationLevel
    public let dismissable: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let title: String
    public let body: String
    public let source: String
    public let actions: [EditorNotificationAction]

    public var levelName: String { level.name }
}

/// Stores the current notification stack sent by the BEAM.
@MainActor
@Observable
public final class NotificationCenterState {
    public init(notifications: [EditorNotification] = []) {
        self.notifications = notifications
    }
    public var notifications: [EditorNotification] = []

    /// Applies a full notification snapshot from the protocol decoder.
    public func update(rawNotifications: [Wire.EditorNotification]) {
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
