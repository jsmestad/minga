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
    /// Flipped once when the first complete frame (batch_end) arrives from the BEAM. The startup overlay fades out when this becomes true.
    var hasReceivedFirstFrame: Bool = false
    /// All GUI chrome sub-states in a single container.
    let gui = GUIState()
    /// Protocol encoder for sending gui_action events from SwiftUI chrome.
    var encoder: InputEncoder?
}
