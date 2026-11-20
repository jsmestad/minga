import AppKit
import Foundation
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
    let gui: GUIState
    /// Protocol encoder for sending gui_action events from SwiftUI chrome.
    var encoder: OutboundActionEncoding?

    /// Whether native restoration is isolated from the shared AppKit preference domain.
    let usesDevelopmentProfile: Bool
    let editorWindowFrame: ProfileEditorWindowFrame?

    init(applicationEnvironment: [String: String]? = nil) {
        let environment = applicationEnvironment ?? [:]
#if DEBUG
        let usesDevelopmentProfile = environment["MINGA_DEV_PROFILE"] != nil
#else
        let usesDevelopmentProfile = false
#endif
        self.usesDevelopmentProfile = usesDevelopmentProfile
        let stateDirectory: URL? = if usesDevelopmentProfile,
                                      let path = environment["XDG_STATE_HOME"], path.hasPrefix("/") {
            URL(fileURLWithPath: path, isDirectory: true)
        } else {
            nil
        }
        editorWindowFrame = stateDirectory.map(ProfileEditorWindowFrame.init(stateDirectory:))
        let storage: BottomPanelState.HeightStorage
        if let stateDirectory {
            storage = .file(stateDirectory.appendingPathComponent("macos-bottom-panel-height"))
        } else {
            storage = applicationEnvironment == nil || usesDevelopmentProfile ? .transient : .applicationPreferences
        }
        gui = GUIState(bottomPanelState: BottomPanelState(heightStorage: storage))
    }
}

/// Keeps window geometry in the launcher-owned state directory, never in AppKit defaults.
@MainActor
struct ProfileEditorWindowFrame {
    private let url: URL

    init(stateDirectory: URL) {
        url = stateDirectory.appendingPathComponent("macos-editor-window-frame")
    }

    func restore(_ window: NSWindow) {
        if let saved = try? String(contentsOf: url, encoding: .utf8) {
            window.setFrame(from: saved)
        }
    }

    func save(_ window: NSWindow) {
        do {
            try window.frameDescriptor.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            PortLogger.warn("Could not save editor window frame", privateDetail: error.localizedDescription)
        }
    }
}

enum StartupPresentation {
    case starting
    case waiting
    case slow(canRetry: Bool)
    case waitingLonger(canRetry: Bool)
    case retrying
    case failed(message: String, canRetry: Bool)
}
