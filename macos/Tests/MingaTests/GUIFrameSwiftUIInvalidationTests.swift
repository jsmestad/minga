import AppKit
import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing

@MainActor
private final class FrameProbeNSView: NSView {
    var publishedValue = ""
    var swiftUILocalIdentity = UUID()
    var nativeLocalValue = ""

    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class FrameProbeRecorder {
    struct Entry {
        weak var view: FrameProbeNSView?
        var updateCount: Int
        var stateObjectIDs: Set<ObjectIdentifier>
    }

    private var entries: [ContentViewFrameProbePoint: Entry] = [:]
    private let updates: AsyncStream<ContentViewFrameProbePoint>
    private let continuation: AsyncStream<ContentViewFrameProbePoint>.Continuation

    init() {
        let stream = AsyncStream.makeStream(
            of: ContentViewFrameProbePoint.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        updates = stream.stream
        continuation = stream.continuation
    }

    func record(
        point: ContentViewFrameProbePoint,
        stateObject: AnyObject,
        view: FrameProbeNSView
    ) {
        let prior = entries[point]
        var stateObjectIDs = prior?.stateObjectIDs ?? []
        stateObjectIDs.insert(ObjectIdentifier(stateObject))
        entries[point] = Entry(
            view: view,
            updateCount: (prior?.updateCount ?? 0) + 1,
            stateObjectIDs: stateObjectIDs
        )
        continuation.yield(point)
    }

    func view(for point: ContentViewFrameProbePoint) -> FrameProbeNSView? {
        entries[point]?.view
    }

    func updateCount(for point: ContentViewFrameProbePoint) -> Int {
        entries[point]?.updateCount ?? 0
    }

    func stateObjectIDs(for point: ContentViewFrameProbePoint) -> Set<ObjectIdentifier> {
        entries[point]?.stateObjectIDs ?? []
    }

    func waitForValue(_ value: String, point: ContentViewFrameProbePoint) async {
        if view(for: point)?.publishedValue == value {
            return
        }

        for await updatedPoint in updates where updatedPoint == point {
            if view(for: point)?.publishedValue == value {
                return
            }
        }
    }
}

private struct FrameProbeRepresentable: NSViewRepresentable {
    let point: ContentViewFrameProbePoint
    let value: String
    let stateObject: AnyObject
    let swiftUILocalIdentity: UUID
    let recorder: FrameProbeRecorder

    func makeNSView(context: Context) -> FrameProbeNSView {
        let view = FrameProbeNSView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ nsView: FrameProbeNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: FrameProbeNSView) {
        view.publishedValue = value
        view.swiftUILocalIdentity = swiftUILocalIdentity
        recorder.record(point: point, stateObject: stateObject, view: view)
    }
}

private struct ProductionFrameProbe: View {
    let point: ContentViewFrameProbePoint
    let gui: GUIState
    let stateObject: AnyObject
    let recorder: FrameProbeRecorder
    @Environment(\.guiFrameVersion) private var frameVersion
    @State private var localIdentity = UUID()

    var body: some View {
        let _ = frameVersion
        FrameProbeRepresentable(
            point: point,
            value: publishedValue,
            stateObject: stateObject,
            swiftUILocalIdentity: localIdentity,
            recorder: recorder
        )
    }

    private var publishedValue: String {
        switch point {
        case .shell:
            gui.tabBarState.displayTabs.map(\.label).joined(separator: ",")
        case .editor:
            gui.emptyStateState.sections.flatMap(\.items).map(\.label).joined(separator: ",")
        case .editorOverlay:
            gui.completionState.items.map(\.label).joined(separator: ",")
        case .extensionOverlay:
            gui.extensionOverlayState.entries.map(\.content).joined(separator: ",")
        case .windowOverlay:
            gui.pickerState.items.map(\.label).joined(separator: ",")
        }
    }
}

@Suite("Persistent SwiftUI GUI frame invalidation")
@MainActor
struct GUIFrameSwiftUIInvalidationTests {
    private typealias Labels = (
        shell: String,
        editor: String,
        editorOverlay: String,
        extensionOverlay: String,
        windowOverlay: String
    )

    private let points: [ContentViewFrameProbePoint] = [
        .shell,
        .editor,
        .editorOverlay,
        .extensionOverlay,
        .windowOverlay,
    ]

    @Test(
        "ContentView production hosts publish only committed or focused domain changes",
        .timeLimit(.minutes(1))
    )
    func contentViewProductionHostsFollowAtomicPublication() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let baseline: Labels = (
            "before.ex",
            "Before launchpad",
            "beforeCompletion",
            "beforeExtension",
            "beforePicker"
        )
        publishFrame(dispatcher, frameSeq: 1, baseFrameSeq: 0, labels: baseline)

        let recorder = FrameProbeRecorder()
        let root = ContentView(
            gui: gui,
            encoder: { nil },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in },
            frameProbe: ContentViewFrameProbe { point, stateObject in
                AnyView(ProductionFrameProbe(
                    point: point,
                    gui: gui,
                    stateObject: stateObject,
                    recorder: recorder
                ))
            }
        ) {
            Color.clear
        }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        defer { window.contentView = nil }
        hostingView.layoutSubtreeIfNeeded()

        await waitForValues(baseline, recorder: recorder)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        let shellInput = gui.shellInput
        let editorInput = gui.editorInput
        let editorOverlayInput = gui.editorOverlayInput
        let windowOverlayInput = gui.windowOverlayInput
        let expectedStateObjects: [ContentViewFrameProbePoint: AnyObject] = [
            .shell: gui.tabBarState,
            .editor: gui.emptyStateState,
            .editorOverlay: gui.completionState,
            .extensionOverlay: gui.extensionOverlayState,
            .windowOverlay: gui.pickerState,
        ]
        let originalViews = try Dictionary(uniqueKeysWithValues: points.map { point in
            (point, try #require(recorder.view(for: point)))
        })
        let originalSwiftUIIdentities = originalViews.mapValues(\.swiftUILocalIdentity)
        for (index, point) in points.enumerated() {
            originalViews[point]?.nativeLocalValue = "native-local-\(index)"
            let expectedStateObject = try #require(expectedStateObjects[point])
            #expect(recorder.stateObjectIDs(for: point) == [ObjectIdentifier(expectedStateObject)])
        }
        let shellView = try #require(originalViews[.shell])
        #expect(window.makeFirstResponder(shellView))

        let countsBeforeStaging = updateCounts(recorder)
        dispatcher.dispatch(.beginFrame(frameSeq: 2, baseFrameSeq: 1, generation: 1))
        stageDomainCommands(
            dispatcher,
            labels: (
                "staged.ex",
                "Staged launchpad",
                "stagedCompletion",
                "stagedExtension",
                "stagedPicker"
            )
        )
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectValues(baseline, recorder: recorder)
        expectUnchangedCounts(countsBeforeStaging, recorder: recorder)

        dispatcher.dispatch(.beginFrame(frameSeq: 3, baseFrameSeq: 1, generation: 1))
        stageDomainCommands(
            dispatcher,
            labels: (
                "rejected.ex",
                "Rejected launchpad",
                "rejectedCompletion",
                "rejectedExtension",
                "rejectedPicker"
            )
        )
        dispatcher.dispatch(.commitFrame(frameSeq: 99, seq: 0))
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectValues(baseline, recorder: recorder)
        expectUnchangedCounts(countsBeforeStaging, recorder: recorder)

        let committed: Labels = (
            "after.ex",
            "After launchpad",
            "afterCompletion",
            "afterExtension",
            "afterPicker"
        )
        publishFrame(dispatcher, frameSeq: 4, baseFrameSeq: 0, labels: committed)
        await waitForValues(committed, recorder: recorder)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        var counts = updateCounts(recorder)
        gui.frameStore.publishLocal(impact: .shell) {
            gui.tabBarState.update(activeIndex: 0, entries: [Self.tab(label: "local.ex")])
        }
        await recorder.waitForValue("local.ex", point: .shell)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectOnly([.shell], changedSince: counts, recorder: recorder)

        counts = updateCounts(recorder)
        gui.frameStore.publishLocal(impact: .editor) {
            Self.updateEmptyState(gui, label: "Local launchpad")
        }
        await recorder.waitForValue("Local launchpad", point: .editor)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectOnly([.editor], changedSince: counts, recorder: recorder)

        counts = updateCounts(recorder)
        gui.frameStore.publishLocal(impact: .editorOverlay) {
            Self.updateCompletion(gui, label: "localCompletion")
            gui.extensionOverlayState.update([Self.extensionOverlay(content: "localExtension")])
        }
        await recorder.waitForValue("localCompletion", point: .editorOverlay)
        await recorder.waitForValue("localExtension", point: .extensionOverlay)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectOnly([.editorOverlay, .extensionOverlay], changedSince: counts, recorder: recorder)

        counts = updateCounts(recorder)
        gui.frameStore.publishLocal(impact: .windowOverlay) {
            Self.updatePicker(gui, label: "localPicker")
        }
        await recorder.waitForValue("localPicker", point: .windowOverlay)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectOnly([.windowOverlay], changedSince: counts, recorder: recorder)

        #expect(gui.shellInput === shellInput)
        #expect(gui.editorInput === editorInput)
        #expect(gui.editorOverlayInput === editorOverlayInput)
        #expect(gui.windowOverlayInput === windowOverlayInput)
        for (index, point) in points.enumerated() {
            let updatedView = try #require(recorder.view(for: point))
            let expectedStateObject = try #require(expectedStateObjects[point])
            #expect(updatedView === originalViews[point])
            #expect(updatedView.swiftUILocalIdentity == originalSwiftUIIdentities[point])
            #expect(updatedView.nativeLocalValue == "native-local-\(index)")
            #expect(recorder.stateObjectIDs(for: point) == [ObjectIdentifier(expectedStateObject)])
        }
        #expect(window.firstResponder === shellView)
    }

    private func publishFrame(
        _ dispatcher: CommandDispatcher,
        frameSeq: UInt32,
        baseFrameSeq: UInt32,
        labels: Labels
    ) {
        dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: baseFrameSeq, generation: 1))
        if baseFrameSeq == 0 {
            dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        }
        stageDomainCommands(dispatcher, labels: labels)
        dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: 0))
    }

    private func stageDomainCommands(_ dispatcher: CommandDispatcher, labels: Labels) {
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: [Self.tab(label: labels.shell)]))
        dispatcher.dispatch(Self.emptyStateCommand(label: labels.editor))
        dispatcher.dispatch(.guiCompletion(
            visible: true,
            anchorRow: 0,
            anchorCol: 0,
            selectedIndex: 0,
            items: [Wire.CompletionItem(kind: 1, label: labels.editorOverlay, detail: "")],
            documentation: ""
        ))
        dispatcher.dispatch(.guiExtensionOverlay([
            Self.extensionOverlay(content: labels.extensionOverlay),
        ]))
        dispatcher.dispatch(Self.pickerCommand(label: labels.windowOverlay))
    }

    private func waitForValues(_ labels: Labels, recorder: FrameProbeRecorder) async {
        await recorder.waitForValue(labels.shell, point: .shell)
        await recorder.waitForValue(labels.editor, point: .editor)
        await recorder.waitForValue(labels.editorOverlay, point: .editorOverlay)
        await recorder.waitForValue(labels.extensionOverlay, point: .extensionOverlay)
        await recorder.waitForValue(labels.windowOverlay, point: .windowOverlay)
    }

    private func expectValues(_ labels: Labels, recorder: FrameProbeRecorder) {
        #expect(recorder.view(for: .shell)?.publishedValue == labels.shell)
        #expect(recorder.view(for: .editor)?.publishedValue == labels.editor)
        #expect(recorder.view(for: .editorOverlay)?.publishedValue == labels.editorOverlay)
        #expect(recorder.view(for: .extensionOverlay)?.publishedValue == labels.extensionOverlay)
        #expect(recorder.view(for: .windowOverlay)?.publishedValue == labels.windowOverlay)
    }

    private func updateCounts(
        _ recorder: FrameProbeRecorder
    ) -> [ContentViewFrameProbePoint: Int] {
        Dictionary(uniqueKeysWithValues: points.map { ($0, recorder.updateCount(for: $0)) })
    }

    private func expectUnchangedCounts(
        _ expected: [ContentViewFrameProbePoint: Int],
        recorder: FrameProbeRecorder
    ) {
        for point in points {
            #expect(recorder.updateCount(for: point) == expected[point])
        }
    }

    private func expectOnly(
        _ changed: Set<ContentViewFrameProbePoint>,
        changedSince prior: [ContentViewFrameProbePoint: Int],
        recorder: FrameProbeRecorder
    ) {
        for point in points {
            if changed.contains(point) {
                #expect(recorder.updateCount(for: point) > (prior[point] ?? 0))
            } else {
                #expect(recorder.updateCount(for: point) == prior[point])
            }
        }
    }

    private func completeThemeSlots() -> [(UInt8, UInt8, UInt8, UInt8)] {
        CommandDispatcher.requiredThemeSlots.map { slot in
            (slot, slot, slot, slot)
        }
    }

    private static func updateEmptyState(_ gui: GUIState, label: String) {
        gui.emptyStateState.update(
            crashed: false,
            version: "test",
            focusedId: "launchpad",
            sections: [emptyStateSection(label: label)]
        )
    }

    private static func updateCompletion(_ gui: GUIState, label: String) {
        gui.completionState.update(
            visible: true,
            anchorRow: 0,
            anchorCol: 0,
            selectedIndex: 0,
            rawItems: [Wire.CompletionItem(kind: 1, label: label, detail: "")],
            documentation: ""
        )
    }

    private static func updatePicker(_ gui: GUIState, label: String) {
        gui.pickerState.update(
            visible: true,
            selectedIndex: 0,
            filteredCount: 1,
            totalCount: 1,
            markedCount: 0,
            title: "Files",
            query: "",
            hasPreview: false,
            rawItems: [pickerItem(label: label)],
            actionMenu: nil,
            modePrefix: "",
            loadStatus: .ready
        )
    }

    private static func emptyStateCommand(label: String) -> RenderCommand {
        .guiEmptyState(
            visible: true,
            crashed: false,
            version: "test",
            focusedId: "launchpad",
            sections: [emptyStateSection(label: label)]
        )
    }

    private static func emptyStateSection(label: String) -> Wire.EmptyStateSection {
        Wire.EmptyStateSection(
            sectionId: 2,
            title: "Start",
            items: [Wire.EmptyStateItem(
                kind: 2,
                id: "launchpad",
                label: label,
                detail: "",
                jumpKey: "",
                chord: "",
                icon: "",
                iconColorRGB: 0
            )]
        )
    }

    private static func pickerCommand(label: String) -> RenderCommand {
        .guiPicker(
            visible: true,
            selectedIndex: 0,
            filteredCount: 1,
            totalCount: 1,
            markedCount: 0,
            title: "Files",
            query: "",
            hasPreview: false,
            items: [pickerItem(label: label)],
            actionMenu: nil,
            modePrefix: "",
            loadStatus: .ready
        )
    }

    private static func pickerItem(label: String) -> Wire.PickerItem {
        Wire.PickerItem(
            iconColor: 0,
            flags: 0,
            label: label,
            description: "",
            annotation: "",
            matchPositions: []
        )
    }

    private static func extensionOverlay(content: String) -> Wire.ExtensionOverlayEntry {
        Wire.ExtensionOverlayEntry(
            extensionName: "frame-test",
            overlayID: "cursor",
            windowID: 1,
            row: 0,
            col: 0,
            shape: 2,
            colorR: 200,
            colorG: 100,
            colorB: 50,
            opacity: 255,
            content: content
        )
    }

    private static func tab(label: String) -> Wire.TabEntry {
        Wire.TabEntry(
            id: 1,
            groupId: 0,
            isActive: true,
            isDirty: false,
            isAgent: false,
            hasAttention: false,
            agentStatus: 0,
            isPinned: false,
            tintColorRGB: 0,
            icon: "",
            label: label
        )
    }
}
