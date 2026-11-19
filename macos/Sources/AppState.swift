import MingaUI
import SwiftUI

/// Observable state shared between the app delegate and views.
@MainActor
@Observable
final class AppState {
    var windowTitle: String = "Minga"
    var editorNSView: EditorNSView?
    /// Whether the theme is dark (luminance < 0.5). Drives traffic-light appearance.
    var windowBgIsDark: Bool = true
    /// Whether the window is currently in macOS full-screen mode.
    var isFullScreen: Bool = false
    /// Vertical center of the traffic light buttons, measured from the window top.
    var trafficLightMidY: CGFloat = 14
    /// Native startup presentation. A committed editor replaces it.
    var startup: StartupPresentation? = .starting
    var hasReceivedFirstFrame: Bool { startup == nil }
    /// All GUI chrome sub-states in a single container.
    let gui = GUIState()
    /// Protocol encoder for sending gui_action events from SwiftUI chrome.
    var encoder: OutboundActionEncoding?
}

enum StartupPresentation {
    case starting
    case waiting
    case slow(canRetry: Bool)
    case waitingLonger(canRetry: Bool)
    case retrying
    case failed(message: String, canRetry: Bool)
}
