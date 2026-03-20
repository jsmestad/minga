/// Container for all GUI chrome sub-states.
///
/// Holds every `@Observable` state object that SwiftUI chrome views need.
/// Injected once into `CommandDispatcher` and `ContentView`, eliminating
/// the 9 optional property wiring that previously required individual
/// assignment in `AppDelegate`.
///
/// All sub-states are initialized at creation time; no optional nil-checks
/// needed in dispatch handlers.
@MainActor
final class GUIState {
    /// Theme colors for SwiftUI chrome views.
    let themeColors = ThemeColors()

    /// Tab bar state.
    let tabBarState = TabBarState()

    /// File tree sidebar state.
    let fileTreeState = FileTreeState()

    /// Completion popup state.
    let completionState = CompletionState()

    /// Which-key popup state.
    let whichKeyState = WhichKeyState()

    /// Breadcrumb path bar state.
    let breadcrumbState = BreadcrumbState()

    /// Status bar state.
    let statusBarState = StatusBarState()

    /// Picker (command palette) state.
    let pickerState = PickerState()

    /// Agent chat state.
    let agentChatState = AgentChatState()

    /// Bottom panel container state.
    let bottomPanelState = BottomPanelState()

    /// Semantic window content from gui_window_content (0x80).
    /// Keyed by windowId. Cleared each frame before dispatch.
    var windowContents: [UInt16: GUIWindowContent] = [:]

    /// Clears per-frame state that must be rebuilt from incoming commands.
    /// Called at the start of each frame before dispatching commands.
    func beginFrame() {
        windowContents.removeAll(keepingCapacity: true)
    }
}
