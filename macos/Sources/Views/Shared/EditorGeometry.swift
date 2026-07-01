/// Metal-free value types that carry app-only editor and window metrics into
/// the `MingaUI` framework.
///
/// `ContentView` used to read these directly off `AppState`, `EditorNSView`,
/// `FrameState`, and `CoreTextMetalRenderer` — all of which live in the Metal
/// app target and cannot be linked into the Metal-free `MingaUI` framework
/// (which must build SwiftUI canvas previews without the Metal toolchain).
/// The app builds these plain values and injects them, so `ContentView` renders
/// in Xcode's canvas.

import SwiftUI

/// Editor surface geometry the chrome needs to position overlays.
///
/// Deliberately has NO cursor fields: the cursor is dynamic per-frame state that
/// lives in `GUIState` (via `CompletionState` anchors, etc.). The app-only
/// `FrameState` cursor is intentionally not carried here.
public struct EditorGeometry: Equatable, Sendable {
    /// Width of one monospaced cell in points.
    public var cellWidth: CGFloat
    /// Height of one monospaced cell in points.
    public var cellHeight: CGFloat
    /// Width of the editor NSView's bounds in points.
    public var viewportWidth: CGFloat
    /// Column at which the gutter ends and text begins (0 when no gutter).
    public var gutterCol: Int
    /// Left margin inside the gutter, in points.
    public var gutterLeftMargin: CGFloat
    /// Gap between the gutter and the text column, in points.
    public var gutterRightGap: CGFloat

    public init(
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        viewportWidth: CGFloat,
        gutterCol: Int,
        gutterLeftMargin: CGFloat,
        gutterRightGap: CGFloat
    ) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.viewportWidth = viewportWidth
        self.gutterCol = gutterCol
        self.gutterLeftMargin = gutterLeftMargin
        self.gutterRightGap = gutterRightGap
    }

    /// Canvas-preview geometry with plausible metrics for a Metal-free preview.
    public static let preview = EditorGeometry(
        cellWidth: 8,
        cellHeight: 16,
        viewportWidth: 900,
        gutterCol: 5,
        gutterLeftMargin: 4,
        gutterRightGap: 6
    )
}

/// Window chrome metrics the shell needs to lay out the title bar and overlays.
///
/// Inputs are `@Observable` on `AppState`, so a plain value stays fresh: the app
/// rebuilds it whenever `ContentView`'s body re-evaluates.
public struct WindowChrome: Equatable, Sendable {
    /// Whether the window is in macOS full-screen mode.
    public var isFullScreen: Bool
    /// Vertical center of the traffic-light buttons, measured from the window top.
    public var trafficLightMidY: CGFloat
    /// Window title (drives `.navigationTitle`).
    public var title: String
    /// Whether the BEAM-selected background is dark (drives `.preferredColorScheme`).
    public var backgroundIsDark: Bool
    /// Whether the first commit_frame has arrived (dismisses the startup overlay).
    public var hasReceivedFirstFrame: Bool

    public init(
        isFullScreen: Bool,
        trafficLightMidY: CGFloat,
        title: String,
        backgroundIsDark: Bool,
        hasReceivedFirstFrame: Bool
    ) {
        self.isFullScreen = isFullScreen
        self.trafficLightMidY = trafficLightMidY
        self.title = title
        self.backgroundIsDark = backgroundIsDark
        self.hasReceivedFirstFrame = hasReceivedFirstFrame
    }

    /// Canvas-preview chrome: windowed, dark, first frame already received.
    public static let preview = WindowChrome(
        isFullScreen: false,
        trafficLightMidY: 20,
        title: "Minga",
        backgroundIsDark: true,
        hasReceivedFirstFrame: true
    )
}
