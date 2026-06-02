/// Tests for extension overlay/panel state routing and view rendering.
///
/// These cover the wiring added when `ExtensionOverlayView` and
/// `ExtensionPanelView` were mounted in `ContentView`: the state helpers
/// that the mount points read (`windowIDs`, `panels(forPosition:)`) and that
/// the views render populated content rather than silently showing nothing.

import Testing
import SwiftUI
import ViewInspector

// MARK: - Fixtures

private func overlayEntry(
    window: UInt16,
    id: String = "o",
    row: UInt16 = 0,
    col: UInt16 = 0,
    shape: UInt8 = 2,
    content: String = ""
) -> Wire.ExtensionOverlayEntry {
    Wire.ExtensionOverlayEntry(
        extensionName: "ext",
        overlayID: id,
        windowID: window,
        row: row,
        col: col,
        shape: shape,
        colorR: 200,
        colorG: 100,
        colorB: 50,
        opacity: 255,
        content: content
    )
}

private func panelEntry(
    id: String = "p",
    title: String = "",
    position: UInt8,
    visible: Bool = true,
    blocks: [Wire.PanelContentBlock] = []
) -> Wire.ExtensionPanelEntry {
    Wire.ExtensionPanelEntry(
        extensionName: "ext",
        panelID: id,
        title: title,
        position: position,
        sizeType: 0,
        sizeValue: 30,
        visible: visible,
        blocks: blocks
    )
}

// MARK: - ExtensionOverlayState

@Suite("ExtensionOverlayState")
@MainActor
struct ExtensionOverlayStateTests {
    @Test("windowIDs returns distinct window ids in first-seen order")
    func distinctWindowIDs() {
        let state = ExtensionOverlayState()
        state.update([
            overlayEntry(window: 2, id: "a"),
            overlayEntry(window: 1, id: "b"),
            overlayEntry(window: 2, id: "c"),
        ])

        #expect(state.windowIDs == [2, 1])
    }

    @Test("entries(forWindow:) filters to the requested window")
    func filtersByWindow() {
        let state = ExtensionOverlayState()
        state.update([
            overlayEntry(window: 1, id: "a"),
            overlayEntry(window: 2, id: "b"),
        ])

        #expect(state.entries(forWindow: 1).map(\.overlayID) == ["a"])
    }
}

// MARK: - ExtensionPanelState

@Suite("ExtensionPanelState")
@MainActor
struct ExtensionPanelStateTests {
    @Test("update drops invisible panels")
    func dropsInvisible() {
        let state = ExtensionPanelState()
        state.update([
            panelEntry(id: "a", position: 1, visible: true),
            panelEntry(id: "b", position: 1, visible: false),
        ])

        #expect(state.panels.map(\.panelID) == ["a"])
        #expect(state.hasVisiblePanels)
    }

    @Test("panels(forPosition:) routes by bottom/right/float")
    func routesByPosition() {
        let state = ExtensionPanelState()
        state.update([
            panelEntry(id: "bottom", position: 0),
            panelEntry(id: "right", position: 1),
            panelEntry(id: "float", position: 2),
        ])

        #expect(state.panels(forPosition: 0).map(\.panelID) == ["bottom"])
        #expect(state.panels(forPosition: 1).map(\.panelID) == ["right"])
        #expect(state.panels(forPosition: 2).map(\.panelID) == ["float"])
    }

    @Test("no visible panels reported when empty")
    func emptyHasNoPanels() {
        let state = ExtensionPanelState()
        #expect(!state.hasVisiblePanels)
    }
}

// MARK: - Overlay viewport visibility

@Suite("ExtensionOverlayState.isVisible")
@MainActor
struct OverlayVisibilityTests {
    private func entry(col: UInt16, row: UInt16) -> ExtensionOverlayState.OverlayEntry {
        ExtensionOverlayState.OverlayEntry(
            extensionName: "ext", overlayID: "o", windowID: 1,
            row: row, col: col, shape: 2,
            colorR: 0, colorG: 0, colorB: 0, opacity: 255, content: "x"
        )
    }

    @Test("entry inside the viewport is visible")
    func insideViewport() {
        #expect(ExtensionOverlayState.isVisible(
            entry(col: 12, row: 3), firstColumn: 10, columnCount: 40, rowCount: 20
        ))
    }

    @Test("entry scrolled left of the viewport is suppressed")
    func leftOfViewport() {
        #expect(!ExtensionOverlayState.isVisible(
            entry(col: 4, row: 3), firstColumn: 10, columnCount: 40, rowCount: 20
        ))
    }

    @Test("entry right of the viewport is suppressed")
    func rightOfViewport() {
        #expect(!ExtensionOverlayState.isVisible(
            entry(col: 60, row: 3), firstColumn: 10, columnCount: 40, rowCount: 20
        ))
    }

    @Test("entry below the pane is suppressed")
    func belowPane() {
        #expect(!ExtensionOverlayState.isVisible(
            entry(col: 12, row: 25), firstColumn: 10, columnCount: 40, rowCount: 20
        ))
    }

    @Test("unknown viewport size suppresses nothing")
    func unknownViewport() {
        #expect(ExtensionOverlayState.isVisible(
            entry(col: 999, row: 999), firstColumn: 0, columnCount: 0, rowCount: 0
        ))
    }
}

// MARK: - ExtensionOverlayView

@Suite("ExtensionOverlayView Structure")
struct ExtensionOverlayViewTests {
    @Test("label entry renders its content text")
    @MainActor func labelContentRenders() throws {
        let state = ExtensionOverlayState()
        state.update([overlayEntry(window: 1, shape: 2, content: "Alice")])

        let sut = ExtensionOverlayView(
            overlayState: state,
            windowID: 1,
            cellWidth: 8,
            cellHeight: 16,
            contentOrigin: .zero
        )

        let texts = try sut.inspect().findAll(ViewInspectorQuery.text)
        let strings = texts.compactMap { try? $0.string() }
        #expect(strings.contains("Alice"))
    }

    @Test("entries for other windows do not render")
    @MainActor func otherWindowHidden() throws {
        let state = ExtensionOverlayState()
        state.update([overlayEntry(window: 9, shape: 2, content: "Hidden")])

        let sut = ExtensionOverlayView(
            overlayState: state,
            windowID: 1,
            cellWidth: 8,
            cellHeight: 16,
            contentOrigin: .zero
        )

        let strings = try sut.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        #expect(!strings.contains("Hidden"))
    }
}

// MARK: - Overlay origin resolution

@Suite("ContentView.overlayContentOrigin")
struct OverlayContentOriginTests {
    @Test("origin offsets past the gutter text column")
    func gutterOffset() {
        let origin = ContentView.overlayContentOrigin(
            textCol: 5, textRow: 0, scrollLeft: 0,
            cellWidth: 8, cellHeight: 16, gutterPad: 14
        )
        // 5 * 8 + 14 = 54
        #expect(origin.x == 54)
        #expect(origin.y == 0)
    }

    @Test("split pane uses the pane's text rect row/col")
    func splitPaneOffset() {
        let origin = ContentView.overlayContentOrigin(
            textCol: 40, textRow: 20, scrollLeft: 0,
            cellWidth: 8, cellHeight: 16, gutterPad: 0
        )
        #expect(origin.x == 320)
        #expect(origin.y == 320)
    }

    @Test("horizontal scroll shifts the origin left")
    func horizontalScroll() {
        let origin = ContentView.overlayContentOrigin(
            textCol: 5, textRow: 0, scrollLeft: 3,
            cellWidth: 8, cellHeight: 16, gutterPad: 14
        )
        // 5*8 + 14 - 3*8 = 30
        #expect(origin.x == 30)
    }
}

// MARK: - Panel size resolution

@Suite("ContentView.panelCrossSize")
struct PanelCrossSizeTests {
    @Test("percent resolves against the basis")
    func percentOfBasis() {
        let size = ContentView.panelCrossSize(
            sizeType: 0, sizeValue: 30, cellExtent: 8, basis: 1000, minimum: 160
        )
        #expect(size == 300)
    }

    @Test("lines resolves against the cell extent")
    func linesByCellExtent() {
        let size = ContentView.panelCrossSize(
            sizeType: 1, sizeValue: 20, cellExtent: 8, basis: 1000, minimum: 160
        )
        #expect(size == 160)
    }

    @Test("tiny requests clamp up to the minimum")
    func clampsToMinimum() {
        let size = ContentView.panelCrossSize(
            sizeType: 0, sizeValue: 1, cellExtent: 8, basis: 1000, minimum: 160
        )
        #expect(size == 160)
    }

    @Test("oversized requests clamp to 80% of the basis")
    func clampsToBasisFraction() {
        let size = ContentView.panelCrossSize(
            sizeType: 0, sizeValue: 95, cellExtent: 8, basis: 1000, minimum: 160
        )
        #expect(size == 800)
    }
}

// MARK: - ExtensionPanelView

@Suite("ExtensionPanelView Structure")
struct ExtensionPanelViewTests {
    @Test("panel renders title and structured block content")
    @MainActor func rendersTitleAndBlocks() throws {
        let panel = panelEntry(
            title: "My Panel",
            position: 1,
            blocks: [
                .text("plain line"),
                .keyValue(pairs: [(key: "Status", value: "Ready")]),
            ]
        )

        let sut = ExtensionPanelView(panel: panel)

        let strings = try sut.inspect().findAll(ViewInspectorQuery.text).compactMap { try? $0.string() }
        #expect(strings.contains("My Panel"))
        #expect(strings.contains("plain line"))
        #expect(strings.contains("Status"))
        #expect(strings.contains("Ready"))
    }
}
