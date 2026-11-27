import AppKit
@testable import MingaUI
import SwiftUI
import Testing

@MainActor
private final class FileTreeEvaluationCounter {
    var count = 0
}

/// Builds a tree with two expanded directories followed by `fileCount` files nested inside both.
@MainActor
private func nestedTreeEntries(fileCount: Int) -> [FileTreeEntry] {
    func entry(_ index: Int, name: String, isDir: Bool, depth: Int) -> FileTreeEntry {
        FileTreeEntry(
            id: name, pathHash: UInt32(index), index: index, isDir: isDir, isExpanded: isDir,
            isSelected: false, isFocused: false, isActive: false, isDirty: false, isEditing: false,
            isLastChild: false, depth: depth, gitStatus: 0, diagnosticErrorCount: 0,
            diagnosticWarningCount: 0, diagnosticInfoCount: 0, diagnosticHintCount: 0,
            guides: Array(repeating: false, count: depth), icon: "", iconColor: .gray,
            name: name, relPath: name, path: "/project/\(name)", editingType: 255, editingText: ""
        )
    }
    var entries = [entry(0, name: "lib", isDir: true, depth: 0), entry(1, name: "lib/minga", isDir: true, depth: 1)]
    for file in 0..<fileCount {
        entries.append(entry(entries.count, name: "lib/minga/file_\(file).ex", isDir: false, depth: 2))
    }
    return entries
}

@MainActor
private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for subview in view.subviews {
        if let found = firstScrollView(in: subview) { return found }
    }
    return nil
}

@Suite("File tree top row")
@MainActor
struct FileTreeTopRowTests {
    private let rowHeight: CGFloat = 22
    private let topPadding: CGFloat = Spacing.hairline

    @Test("The top row changes only when the scrolled distance crosses a row boundary")
    func topRowChangesOnlyAtRowBoundaries() {
        // Row n occupies [topPadding + n * rowHeight, topPadding + (n + 1) * rowHeight) in content space.
        var transitions: [(distance: CGFloat, row: Int)] = []
        var previous = FileTreeView.topRow(scrolledDistance: 0, topPadding: topPadding, rowHeight: rowHeight)
        for tenth in 1...1_000 {
            let distance = CGFloat(tenth) / 10
            let row = FileTreeView.topRow(scrolledDistance: distance, topPadding: topPadding, rowHeight: rowHeight)
            if row != previous {
                transitions.append((distance, row))
                previous = row
            }
        }
        #expect(transitions.map(\.row) == Array(1...4))
        #expect(transitions.map(\.distance) == [24, 46, 68, 90] as [CGFloat])
    }

    @Test("The top padding and resting or overscrolled positions resolve to row zero", arguments: [-40, -2, 0, 1.9, 2, 23.9] as [CGFloat])
    func topPaddingResolvesToRowZero(distance: CGFloat) {
        #expect(FileTreeView.topRow(scrolledDistance: distance, topPadding: topPadding, rowHeight: rowHeight) == 0)
    }

    @Test("The transform measures from the inset content top, so the sticky header height does not move row boundaries", arguments: [0, 45] as [CGFloat])
    func headerInsetDoesNotShiftRows(headerHeight: CGFloat) {
        // At rest a scroll view reports contentOffset.y == -contentInsets.top.
        let resting = FileTreeView.topRow(contentOffsetY: -headerHeight, contentInsetTop: headerHeight, topPadding: topPadding, rowHeight: rowHeight)
        let beforeRowOne = FileTreeView.topRow(contentOffsetY: -headerHeight + 23.9, contentInsetTop: headerHeight, topPadding: topPadding, rowHeight: rowHeight)
        let atRowOne = FileTreeView.topRow(contentOffsetY: -headerHeight + 24, contentInsetTop: headerHeight, topPadding: topPadding, rowHeight: rowHeight)
        #expect([resting, beforeRowOne, atRowOne] == [0, 0, 1] as [Int])
    }

    @Test("No sticky header shows at the top of the tree")
    @MainActor func noHeaderAtTop() {
        let entries = nestedTreeEntries(fileCount: 4)
        #expect(FileTreeView.stickyParents(in: entries, topRow: 0).isEmpty)
        #expect(FileTreeView.stickyParents(in: [], topRow: 3).isEmpty)
    }

    @Test("A nested top row pins its scrolled-off parents, shallowest first")
    @MainActor func nestedTopRowPinsParents() {
        let entries = nestedTreeEntries(fileCount: 4)
        #expect(FileTreeView.stickyParents(in: entries, topRow: 1).map(\.id) == ["lib"])
        #expect(FileTreeView.stickyParents(in: entries, topRow: 4).map(\.id) == ["lib", "lib/minga"])
        #expect(FileTreeView.stickyParents(in: entries, topRow: 99).map(\.id) == ["lib", "lib/minga"], "A row past the end clamps to the last entry")
    }
}

@Suite("File tree scroll invalidation")
@MainActor
struct FileTreeScrollInvalidationTests {
    @Test("Scrolling less than one row does not re-evaluate the tree; crossing a row boundary re-evaluates it once")
    @MainActor func subRowScrollSkipsTreeEvaluation() throws {
        let state = FileTreeState(entries: nestedTreeEntries(fileCount: 200), visible: true, treeState: .ready)
        let counter = FileTreeEvaluationCounter()
        let root = FileTreeView(fileTreeState: state, sendAction: nil)
            .environment(\.themeColors, ThemeColors())
            .environment(\.fileTreeEvaluationProbe, FileTreeEvaluationProbe { counter.count += 1 })
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: 280, height: 400))
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            hostingView.rootView = AnyView(EmptyView())
        }
        let rendered = waitForLayout(in: hostingView) {
            counter.count > 0 && firstScrollView(in: hostingView) != nil
        }
        try #require(rendered, "The tree must render before scrolling")
        let scrollView = try #require(firstScrollView(in: hostingView), "The file tree must host an NSScrollView")
        let clipView = scrollView.contentView

        let rowHeight: CGFloat = 22
        let separatorHeight: CGFloat = 1

        func scrolledDistance() -> CGFloat {
            clipView.bounds.origin.y + scrollView.contentInsets.top
        }

        func scroll(toRow row: Int, plus offset: CGFloat) throws {
            // Row n's top edge sits at topPadding + n * rowHeight below the inset content top.
            let distance = Spacing.hairline + CGFloat(row) * rowHeight + offset
            let delta = Int32((distance - scrolledDistance()).rounded())
            try #require(delta != 0, "The wheel event must actually move the clip view")
            let cgEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0
            ))
            let event = try #require(NSEvent(cgEvent: cgEvent))
            scrollView.scrollWheel(with: event)

            let reachedPosition = waitForLayout(in: hostingView) {
                abs(scrolledDistance() - distance) <= 0.5
            }
            try #require(reachedPosition, "Wheel did not reach distance \(distance) at row \(row); clip is at \(scrolledDistance())")
        }

        let initial = counter.count
        #expect(scrollView.contentInsets.top == 0, "No sticky header shows at the top of the tree")

        // A real move within row zero must leave the header and tree unchanged.
        try scroll(toRow: 0, plus: 2)
        #expect(scrollView.contentInsets.top == 0)
        #expect(counter.count == initial, "Scrolling within row zero re-evaluated the tree")

        // Scroll deep enough that the header pins both parents, so later row crossings do not resize it.
        try scroll(toRow: 20, plus: 1)
        let headerHeight = 2 * rowHeight + separatorHeight
        let headerRendered = waitForLayout(in: hostingView) {
            scrollView.contentInsets.top == headerHeight
        }
        try #require(headerRendered, "Clip reached row 20 but the sticky header inset is \(scrollView.contentInsets.top), not \(headerHeight)")
        let baseline = counter.count
        try #require(baseline > initial, "SwiftUI must observe the scroll to row 20")

        for offset in stride(from: CGFloat(2), through: 20, by: 2) {
            try scroll(toRow: 20, plus: offset)
        }
        #expect(counter.count == baseline, "Sub-row scrolling re-evaluated the tree \(counter.count - baseline) times")

        try scroll(toRow: 21, plus: 1)
        let nextRowObserved = waitForLayout(in: hostingView) { counter.count > baseline }
        try #require(nextRowObserved, "SwiftUI did not observe the wheel crossing into row 21")

        // Observe more layout turns at distinct positions before counting. A delayed duplicate
        // from the boundary, or an evaluation inside row 21, both violate the same promise.
        for offset in [CGFloat(6), 12, 18] {
            try scroll(toRow: 21, plus: offset)
        }
        #expect(scrollView.contentInsets.top == headerHeight)
        #expect(counter.count == baseline + 1, "Crossing into row 21 and moving within it re-evaluated the tree \(counter.count - baseline) times")
    }

    private func waitForLayout(in hostingView: NSView, until condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
            hostingView.window?.displayIfNeeded()
            if condition() { return true }
        } while ContinuousClock.now < deadline
        return false
    }
}
