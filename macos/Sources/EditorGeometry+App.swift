/// App-side builders that pull `EditorGeometry` / `WindowChrome` out of the
/// Metal-owning types (`EditorNSView`, `FrameState`, `CoreTextMetalRenderer`,
/// `AppState`) that cannot live in the `MingaUI` framework.

import MingaUI
import SwiftUI

extension EditorGeometry {
    /// Reads current editor metrics off the live `EditorNSView`, falling back to
    /// the same neutral defaults `ContentView` used before this decoupling when
    /// no editor surface exists yet.
    @MainActor
    init(editorNSView: EditorNSView?) {
        if let v = editorNSView {
            self.init(
                cellWidth: v.cellWidth,
                cellHeight: v.cellHeight,
                viewportWidth: v.bounds.width,
                gutterCol: Int(v.dispatcher.committedEditorSnapshot?.gutterCol ?? 0),
                gutterLeftMargin: CoreTextMetalRenderer.gutterLeftMarginPt,
                gutterRightGap: CoreTextMetalRenderer.gutterRightGapPt
            )
        } else {
            self.init(
                cellWidth: 8,
                cellHeight: 16,
                viewportWidth: 800,
                gutterCol: 0,
                gutterLeftMargin: 0,
                gutterRightGap: 0
            )
        }
    }
}

extension WindowChrome {
    /// Snapshots the window chrome metrics off the `@Observable` `AppState`.
    @MainActor
    init(appState: AppState) {
        self.init(
            isFullScreen: appState.isFullScreen,
            trafficLightMidY: appState.trafficLightMidY,
            title: appState.windowTitle,
            backgroundIsDark: appState.windowBgIsDark,
            hasReceivedFirstFrame: appState.hasReceivedFirstFrame
        )
    }
}
