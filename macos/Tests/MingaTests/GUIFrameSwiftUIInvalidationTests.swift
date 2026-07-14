import AppKit
import Foundation
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

    func installedTabAndTree() -> (tab: String, tree: String)? {
        guard let tab = view(for: .shell)?.publishedValue,
              let tree = view(for: .fileTree)?.publishedValue else {
            return nil
        }
        return (tab, tree)
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

private struct ProductionEditorSurface: View {
    let value: String
    let stateObject: AnyObject
    let recorder: FrameProbeRecorder
    @State private var localIdentity = UUID()

    var body: some View {
        FrameProbeRepresentable(
            point: .editor,
            value: value,
            stateObject: stateObject,
            swiftUILocalIdentity: localIdentity,
            recorder: recorder
        )
    }
}

private struct ProductionFrameProbe: View {
    let point: ContentViewFrameProbePoint
    let value: String
    let stateObject: AnyObject
    let recorder: FrameProbeRecorder
    @State private var localIdentity = UUID()

    var body: some View {
        FrameProbeRepresentable(
            point: point,
            value: value,
            stateObject: stateObject,
            swiftUILocalIdentity: localIdentity,
            recorder: recorder
        )
    }
}

private enum ObservationOwnerProbePoint: CaseIterable {
    case shellChrome
    case bottomPanel
    case sidebar
    case editorOverlay
    case windowOverlay
    case agent
    case extensionOverlay
    case extensionRuntime
    case gitStatus
    case messages
    case feedbackPending
    case feedbackSpinner
}

@MainActor
private final class ObservationOwnerProbeRecorder {
    private struct Entry {
        weak var view: FrameProbeNSView?
        var updateCount: Int
    }

    private var entries: [ObservationOwnerProbePoint: Entry] = [:]
    private let updates: AsyncStream<ObservationOwnerProbePoint>
    private let continuation: AsyncStream<ObservationOwnerProbePoint>.Continuation

    init() {
        let stream = AsyncStream.makeStream(
            of: ObservationOwnerProbePoint.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        updates = stream.stream
        continuation = stream.continuation
    }

    func record(point: ObservationOwnerProbePoint, value: String, view: FrameProbeNSView) {
        view.publishedValue = value
        entries[point] = Entry(
            view: view,
            updateCount: (entries[point]?.updateCount ?? 0) + 1
        )
        continuation.yield(point)
    }

    func value(for point: ObservationOwnerProbePoint) -> String? {
        entries[point]?.view?.publishedValue
    }

    func updateCounts() -> [ObservationOwnerProbePoint: Int] {
        Dictionary(uniqueKeysWithValues: ObservationOwnerProbePoint.allCases.map { point in
            (point, entries[point]?.updateCount ?? 0)
        })
    }

    func waitForValue(_ value: String, point: ObservationOwnerProbePoint) async {
        if self.value(for: point) == value {
            return
        }

        for await updatedPoint in updates where updatedPoint == point {
            if self.value(for: point) == value {
                return
            }
        }
    }
}

private struct ObservationOwnerProbeRepresentable: NSViewRepresentable {
    let point: ObservationOwnerProbePoint
    let value: String
    let recorder: ObservationOwnerProbeRecorder

    func makeNSView(context: Context) -> FrameProbeNSView {
        let view = FrameProbeNSView(frame: .zero)
        recorder.record(point: point, value: value, view: view)
        return view
    }

    func updateNSView(_ nsView: FrameProbeNSView, context: Context) {
        recorder.record(point: point, value: value, view: nsView)
    }
}

private struct ObservationOwnerProbe<Owner: AnyObject>: View {
    let point: ObservationOwnerProbePoint
    let owner: Owner
    let materialize: (Owner) -> String
    let recorder: ObservationOwnerProbeRecorder

    var body: some View {
        ObservationOwnerProbeRepresentable(
            point: point,
            value: materialize(owner),
            recorder: recorder
        )
    }
}

private struct ObservationOwnerProbeMatrix: View {
    let statusBar: StatusBarState
    let bottomPanel: BottomPanelState
    let sidebar: SidebarHostState
    let completion: CompletionState
    let picker: PickerState
    let agentContext: AgentContextBarState
    let extensionOverlay: ExtensionOverlayState
    let extensionRuntime: FrontendExtensionRuntimeRegistry
    let gitStatus: GitStatusState
    let messages: MessagesContentState
    let feedback: FeedbackState
    let recorder: ObservationOwnerProbeRecorder

    var body: some View {
        VStack {
            ObservationOwnerProbe(point: .shellChrome, owner: statusBar, materialize: { $0.message }, recorder: recorder)
            ObservationOwnerProbe(point: .bottomPanel, owner: bottomPanel, materialize: { "\($0.userHeight)" }, recorder: recorder)
            ObservationOwnerProbe(point: .sidebar, owner: sidebar, materialize: { $0.activeId }, recorder: recorder)
            ObservationOwnerProbe(point: .editorOverlay, owner: completion, materialize: { $0.items.first?.label ?? "" }, recorder: recorder)
            ObservationOwnerProbe(point: .windowOverlay, owner: picker, materialize: { $0.items.first?.label ?? "" }, recorder: recorder)
            ObservationOwnerProbe(point: .agent, owner: agentContext, materialize: { $0.task }, recorder: recorder)
            ObservationOwnerProbe(point: .extensionOverlay, owner: extensionOverlay, materialize: { $0.entries.first?.content ?? "" }, recorder: recorder)
            ObservationOwnerProbe(point: .extensionRuntime, owner: extensionRuntime, materialize: { $0.activeExtensionIDs.joined(separator: ",") }, recorder: recorder)
            ObservationOwnerProbe(point: .gitStatus, owner: gitStatus, materialize: { "\($0.branchName)|\($0.totalCount)" }, recorder: recorder)
            ObservationOwnerProbe(point: .messages, owner: messages, materialize: {
                "\($0.filteredEntries.last?.text ?? "")|\($0.isAutoScrolling)|\($0.hasNewEntries)"
            }, recorder: recorder)
            ObservationOwnerProbe(point: .feedbackPending, owner: feedback, materialize: { String($0.isPending) }, recorder: recorder)
            ObservationOwnerProbe(point: .feedbackSpinner, owner: feedback, materialize: { String($0.showingSpinner) }, recorder: recorder)
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
            frameProbe: ContentViewFrameProbe { point, value, stateObject in
                AnyView(ProductionFrameProbe(
                    point: point,
                    value: value,
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

        dispatcher.dispatch(.beginFrame(frameSeq: 4, baseFrameSeq: 0, generation: 1))
        stageDomainCommands(
            dispatcher,
            labels: (
                "resource-rejected.ex",
                "Resource-rejected launchpad",
                "resourceRejectedCompletion",
                "resourceRejectedExtension",
                "resourceRejectedPicker"
            )
        )
        dispatcher.resourcePolicyRejected()
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectValues(baseline, recorder: recorder)

        let committed: Labels = (
            "after.ex",
            "After launchpad",
            "afterCompletion",
            "afterExtension",
            "afterPicker"
        )
        publishFrame(dispatcher, frameSeq: 5, baseFrameSeq: 0, labels: committed)
        await waitForValues(committed, recorder: recorder)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        gui.frameStore.publishLocal(impact: .shell) {
            gui.tabBarState.update(activeIndex: 0, entries: [Self.tab(label: "local.ex")])
        }
        await recorder.waitForValue("local.ex", point: .shell)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectValues(
            ("local.ex", committed.editor, committed.editorOverlay, committed.extensionOverlay, committed.windowOverlay),
            recorder: recorder
        )

        gui.frameStore.publishLocal(impact: .editor) {
            Self.updateEmptyState(gui, label: "Local launchpad")
        }
        await recorder.waitForValue("Local launchpad", point: .editor)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectValues(
            ("local.ex", "Local launchpad", committed.editorOverlay, committed.extensionOverlay, committed.windowOverlay),
            recorder: recorder
        )

        gui.frameStore.publishLocal(impact: .editorOverlay) {
            Self.updateCompletion(gui, label: "localCompletion")
            gui.extensionOverlayState.update([Self.extensionOverlay(content: "localExtension")])
        }
        await recorder.waitForValue("localCompletion", point: .editorOverlay)
        await recorder.waitForValue("localExtension", point: .extensionOverlay)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectValues(
            ("local.ex", "Local launchpad", "localCompletion", "localExtension", committed.windowOverlay),
            recorder: recorder
        )

        gui.frameStore.publishLocal(impact: .windowOverlay) {
            Self.updatePicker(gui, label: "localPicker")
        }
        await recorder.waitForValue("localPicker", point: .windowOverlay)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        expectValues(
            ("local.ex", "Local launchpad", "localCompletion", "localExtension", "localPicker"),
            recorder: recorder
        )

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

    @Test(
        "direct Observation updates only the mutated tab or FileTree leaf",
        .timeLimit(.minutes(1))
    )
    func directObservationNarrowsLeafUpdates() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let tabs = [
            Self.workspaceTab(id: 1, label: "old.ex", path: "/tmp/old.ex"),
            Self.workspaceTab(id: 2, label: "new.ex", path: "/tmp/new.ex"),
        ]
        try publishCanonicalFrame(
            dispatcher,
            frameSeq: 1,
            baseFrameSeq: 0,
            tabs: tabs,
            activeIndex: 0,
            editorText: "resident editor",
            selectedFile: "old.ex"
        )

        let recorder = FrameProbeRecorder()
        let root = observationProofContentView(gui: gui, recorder: recorder)
        let (hostingView, window) = mount(root)
        defer { window.contentView = nil }
        hostingView.layoutSubtreeIfNeeded()
        await recorder.waitForValue("old.ex,new.ex", point: .shell)
        await recorder.waitForValue("old.ex", point: .fileTree)
        await recorder.waitForValue("editor-canary", point: .editor)

        let tabBaseline = recorder.updateCount(for: .shell)
        let treeBaseline = recorder.updateCount(for: .fileTree)
        let editorBaseline = recorder.updateCount(for: .editor)

        for iteration in 0..<100 {
            let label = "tab-\(iteration).ex"
            gui.tabBarState.updateWorkspaces(
                activeWorkspaceId: 0,
                mode: 0,
                flags: 0,
                entries: [],
                visibleTabs: [Self.workspaceTab(id: UInt32(iteration + 10), label: label, path: "/tmp/\(label)")]
            )
            await recorder.waitForValue(label, point: .shell)
        }

        #expect(recorder.updateCount(for: .shell) - tabBaseline == 100)
        #expect(recorder.updateCount(for: .fileTree) - treeBaseline == 0)
        #expect(recorder.updateCount(for: .editor) - editorBaseline == 0)

        let treePhaseTabBaseline = recorder.updateCount(for: .shell)
        let treePhaseTreeBaseline = recorder.updateCount(for: .fileTree)
        let treePhaseEditorBaseline = recorder.updateCount(for: .editor)
        for iteration in 0..<100 {
            let selected = iteration.isMultiple(of: 2) ? "new.ex" : "old.ex"
            gui.fileTreeState.updateSelection(selectedId: selected, focused: true)
            await recorder.waitForValue(selected, point: .fileTree)
        }

        #expect(recorder.updateCount(for: .fileTree) - treePhaseTreeBaseline == 100)
        #expect(recorder.updateCount(for: .shell) - treePhaseTabBaseline == 0)
        #expect(recorder.updateCount(for: .editor) - treePhaseEditorBaseline == 0)

        gui.fileTreeState.updateSelection(selectedId: "old.ex", focused: true)
        await recorder.waitForValue("old.ex", point: .fileTree)
        let previewTabBaseline = recorder.updateCount(for: .shell)
        let previewTreeBaseline = recorder.updateCount(for: .fileTree)
        let previewEditorBaseline = recorder.updateCount(for: .editor)
        let shellRevision = gui.frameStore.shell.value.revision

        #expect(dispatcher.previewFileTreeNavigation(codepoint: 106, modifiers: 0))
        await recorder.waitForValue("new.ex", point: .fileTree)

        #expect(recorder.updateCount(for: .fileTree) - previewTreeBaseline == 1)
        #expect(recorder.updateCount(for: .shell) - previewTabBaseline == 0)
        #expect(recorder.updateCount(for: .editor) - previewEditorBaseline == 0)
        #expect(gui.frameStore.shell.value.revision == shellRevision)
    }

    @Test(
        "direct owner updates render representative presentation leaves without frame publication",
        .timeLimit(.minutes(1))
    )
    func directObservationUpdatesPresentationOwnerMatrix() async throws {
        let bottomPanelHeightKey = "bottomPanelHeight"
        let persistedBottomPanelHeight = UserDefaults.standard.object(forKey: bottomPanelHeightKey)
        defer {
            if let persistedBottomPanelHeight {
                UserDefaults.standard.set(persistedBottomPanelHeight, forKey: bottomPanelHeightKey)
            } else {
                UserDefaults.standard.removeObject(forKey: bottomPanelHeightKey)
            }
        }

        let statusBar = StatusBarState()
        let bottomPanel = BottomPanelState()
        let sidebar = SidebarHostState()
        let completion = CompletionState()
        let picker = PickerState()
        let agentContext = AgentContextBarState()
        let extensionOverlay = ExtensionOverlayState()
        let extensionRuntime = FrontendExtensionRuntimeRegistry()
        let gitStatus = GitStatusState()
        let messages = MessagesContentState()
        let feedback = FeedbackState()
        defer { feedback.cancel() }

        let recorder = ObservationOwnerProbeRecorder()
        let root = ObservationOwnerProbeMatrix(
            statusBar: statusBar,
            bottomPanel: bottomPanel,
            sidebar: sidebar,
            completion: completion,
            picker: picker,
            agentContext: agentContext,
            extensionOverlay: extensionOverlay,
            extensionRuntime: extensionRuntime,
            gitStatus: gitStatus,
            messages: messages,
            feedback: feedback,
            recorder: recorder
        )
        let (hostingView, window) = mount(root)
        defer { window.contentView = nil }
        hostingView.layoutSubtreeIfNeeded()

        let initialValues: [ObservationOwnerProbePoint: String] = [
            .shellChrome: "",
            .bottomPanel: "\(bottomPanel.userHeight)",
            .sidebar: "file_tree",
            .editorOverlay: "",
            .windowOverlay: "",
            .agent: "",
            .extensionOverlay: "",
            .extensionRuntime: "",
            .gitStatus: "|0",
            .messages: "|true|false",
            .feedbackPending: "false",
            .feedbackSpinner: "false",
        ]
        for point in ObservationOwnerProbePoint.allCases {
            await recorder.waitForValue(try #require(initialValues[point]), point: point)
        }

        await expectOnlyOwnerProbeUpdate(.shellChrome, value: "Formatting…", recorder: recorder) {
            statusBar.update(from: Self.statusBarUpdate(message: "Formatting…"))
        }
        let nextBottomPanelHeight: CGFloat = bottomPanel.userHeight == 321 ? 322 : 321
        await expectOnlyOwnerProbeUpdate(.bottomPanel, value: "\(nextBottomPanelHeight)", recorder: recorder) {
            bottomPanel.userHeight = nextBottomPanelHeight
        }
        await expectOnlyOwnerProbeUpdate(.sidebar, value: "git_status", recorder: recorder) {
            sidebar.update(activeId: "git_status", sidebars: [Self.sidebarMetadata(id: "git_status", kind: "git_status")])
        }
        await expectOnlyOwnerProbeUpdate(.editorOverlay, value: "complete-me", recorder: recorder) {
            completion.update(
                visible: true,
                anchorRow: 0,
                anchorCol: 0,
                selectedIndex: 0,
                rawItems: [Wire.CompletionItem(kind: 1, label: "complete-me", detail: "")],
                documentation: ""
            )
        }
        await expectOnlyOwnerProbeUpdate(.windowOverlay, value: "pick-me", recorder: recorder) {
            picker.update(
                visible: true,
                selectedIndex: 0,
                filteredCount: 1,
                totalCount: 1,
                markedCount: 0,
                title: "Files",
                query: "",
                hasPreview: false,
                rawItems: [Self.pickerItem(label: "pick-me")],
                actionMenu: nil
            )
        }
        await expectOnlyOwnerProbeUpdate(.agent, value: "review the diff", recorder: recorder) {
            agentContext.update(
                visible: true,
                task: "review the diff",
                dispatchTimestamp: Date(),
                status: .idle,
                canApprove: false,
                progress: .init(activeAction: "", toolCount: 0, fileCount: 0, reviewHint: ""),
                todos: []
            )
        }
        await expectOnlyOwnerProbeUpdate(.extensionOverlay, value: "extension-content", recorder: recorder) {
            extensionOverlay.update([Self.extensionOverlay(content: "extension-content")])
        }
        await expectOnlyOwnerProbeUpdate(.extensionRuntime, value: "mounted-extension", recorder: recorder) {
            extensionRuntime.register(extensionID: "mounted-extension", decoder: { _ in }) { _ in
                AnyView(EmptyView())
            }
        }
        await expectOnlyOwnerProbeUpdate(.gitStatus, value: "feature/observation|1", recorder: recorder) {
            gitStatus.update(
                repoState: .normal,
                branchName: "feature/observation",
                ahead: 0,
                behind: 0,
                syncing: false,
                entries: [GitStatusEntry(pathHash: 1, section: .changed, status: .modified, path: "lib/minga.ex")],
                toast: nil,
                entryBasePath: "/repo",
                lastCommitMessage: "prior",
                stashCount: 0
            )
        }
        await expectOnlyOwnerProbeUpdate(.messages, value: "message-entry|false|true", recorder: recorder) {
            messages.scrolledUp()
            messages.appendEntries([
                Wire.MessageEntry(
                    streamInstance: 1,
                    id: 1,
                    level: 1,
                    subsystem: 0,
                    timestampSecs: 0,
                    filePath: "",
                    text: "message-entry"
                ),
            ])
        }
        let feedbackBaseline = recorder.updateCounts()
        feedback.update(message: "Formatting…")
        await recorder.waitForValue("true", point: .feedbackPending)
        await recorder.waitForValue("true", point: .feedbackSpinner)
        let feedbackCounts = recorder.updateCounts()
        #expect(feedbackCounts[.feedbackPending, default: 0] > feedbackBaseline[.feedbackPending, default: 0])
        #expect(feedbackCounts[.feedbackSpinner, default: 0] > feedbackBaseline[.feedbackSpinner, default: 0])
        for point in ObservationOwnerProbePoint.allCases where point != .feedbackPending && point != .feedbackSpinner {
            #expect(feedbackCounts[point, default: 0] == feedbackBaseline[point, default: 0])
        }
    }

    @Test(
        "1,000 dispatcher commits mount only coherent tab and FileTree pairs",
        .timeLimit(.minutes(2))
    )
    func persistentContentViewPublishesCanonicalPresentationCoherently() async throws {
        let gui = GUIState()
        let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
        let oldTabs = [Self.workspaceTab(id: 1, label: "old.ex", path: "/tmp/old.ex")]
        let newTabs = [Self.workspaceTab(id: 2, label: "new.ex", path: "/tmp/new.ex")]
        try publishCanonicalFrame(
            dispatcher,
            frameSeq: 1,
            baseFrameSeq: 0,
            tabs: oldTabs,
            activeIndex: 0,
            editorText: "resident editor",
            selectedFile: "old.ex",
            generation: 2
        )

        let recorder = FrameProbeRecorder()
        let root = observationProofContentView(gui: gui, recorder: recorder)
        let (hostingView, window) = mount(root)
        defer { window.contentView = nil }
        hostingView.layoutSubtreeIfNeeded()
        await recorder.waitForValue("old.ex", point: .shell)
        await recorder.waitForValue("old.ex", point: .fileTree)

        let baselineCounts = updateCounts(recorder)
        stageCanonicalShellFrame(
            dispatcher,
            frameSeq: 2,
            baseFrameSeq: 1,
            tabs: newTabs,
            selectedFile: "new.ex",
            generation: 2
        )
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(recorder.installedTabAndTree()?.tab == "old.ex")
        #expect(recorder.installedTabAndTree()?.tree == "old.ex")
        expectUnchangedCounts(baselineCounts, recorder: recorder)

        dispatcher.resourcePolicyRejected()
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(recorder.installedTabAndTree()?.tab == "old.ex")
        #expect(recorder.installedTabAndTree()?.tree == "old.ex")

        stageCanonicalShellFrame(
            dispatcher,
            frameSeq: 3,
            baseFrameSeq: 1,
            tabs: newTabs,
            selectedFile: "new.ex",
            generation: 2
        )
        dispatcher.dispatch(.commitFrame(frameSeq: 99, seq: 0))
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(recorder.installedTabAndTree()?.tab == "old.ex")
        #expect(recorder.installedTabAndTree()?.tree == "old.ex")

        stageCanonicalShellFrame(
            dispatcher,
            frameSeq: 4,
            baseFrameSeq: 1,
            tabs: newTabs,
            selectedFile: "new.ex",
            generation: 1
        )
        dispatcher.dispatch(.commitFrame(frameSeq: 4, seq: 0))
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(recorder.installedTabAndTree()?.tab == "old.ex")
        #expect(recorder.installedTabAndTree()?.tree == "old.ex")

        var priorFrameSeq: UInt32 = 1
        var frameSeq: UInt32 = 5
        var hybridPairs = 0
        for iteration in 0..<1_000 {
            let usesNew = iteration.isMultiple(of: 2)
            let expected = usesNew ? "new.ex" : "old.ex"
            stageCanonicalShellFrame(
                dispatcher,
                frameSeq: frameSeq,
                baseFrameSeq: priorFrameSeq,
                tabs: usesNew ? newTabs : oldTabs,
                selectedFile: expected,
                generation: 2
            )
            dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: 0))
            await recorder.waitForValue(expected, point: .shell)
            await recorder.waitForValue(expected, point: .fileTree)

            let pair = try #require(recorder.installedTabAndTree())
            if pair.tab != pair.tree {
                hybridPairs += 1
            }
            priorFrameSeq = frameSeq
            frameSeq += 1
        }

        #expect(hybridPairs == 0)
        #expect(recorder.view(for: .shell)?.nativeLocalValue == "")
        #expect(recorder.stateObjectIDs(for: .shell) == [ObjectIdentifier(gui.tabBarState)])
        #expect(recorder.stateObjectIDs(for: .fileTree) == [ObjectIdentifier(gui.fileTreeState)])
    }

    @Test("protocol presentation owner inventory uses Observation with only allowlisted infrastructure ignored")
    func observationLeafSourceGuard() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let owners: [(name: String, path: String, ignored: Set<String>)] = [
            ("AgentChatState", "Sources/Views/Agent/AgentChatState.swift", [
                "@ObservationIgnored private var hasTranscript: Bool = false",
            ]),
            ("AgentContextBarState", "Sources/Views/Agent/AgentContextBarState.swift", []),
            ("BottomPanelState", "Sources/Views/EditorChrome/BottomPanelState.swift", []),
            ("EmptyStateState", "Sources/Views/EditorChrome/EmptyStateState.swift", []),
            ("SearchState", "Sources/Views/EditorChrome/SearchState.swift", []),
            ("StatusBarState", "Sources/Views/EditorChrome/StatusBarState.swift", []),
            ("TabBarState", "Sources/Views/EditorChrome/TabBarState.swift", []),
            ("WorkspaceState", "Sources/Views/EditorChrome/WorkspaceState.swift", []),
            ("BreadcrumbState", "Sources/Views/EditorChrome/BreadcrumbBar.swift", []),
            ("FileTreeState", "Sources/Views/Sidebar/FileTreeState.swift", []),
            ("SidebarHostState", "Sources/Views/Sidebar/SidebarHostState.swift", [
                "@ObservationIgnored private var warnedUnknownKinds: Set<String> = []",
            ]),
            ("ObservatoryState", "Sources/Views/Sidebar/ObservatoryState.swift", []),
            ("ChangeSummaryState", "Sources/Views/Sidebar/ChangeSummaryState.swift", []),
            ("GitStatusState", "Sources/Views/Sidebar/GitStatusState.swift", []),
            ("EditTimelineState", "Sources/Views/Shared/EditTimelineState.swift", []),
            ("CompletionState", "Sources/Views/Overlays/CompletionState.swift", []),
            ("HoverPopupState", "Sources/Views/Overlays/HoverPopupState.swift", []),
            ("SignatureHelpState", "Sources/Views/Overlays/SignatureHelpState.swift", []),
            ("MinibufferState", "Sources/Views/Overlays/MinibufferState.swift", []),
            ("PickerState", "Sources/Views/Overlays/PickerState.swift", []),
            ("WhichKeyState", "Sources/Views/Overlays/WhichKeyState.swift", []),
            ("FloatPopupState", "Sources/Views/Overlays/FloatPopupState.swift", []),
            ("NotificationCenterState", "Sources/Views/Overlays/NotificationCenterState.swift", []),
            ("ProtocolErrorState", "Sources/Views/Overlays/ProtocolErrorState.swift", []),
            ("ResyncState", "Sources/Views/Overlays/ResyncState.swift", []),
            ("MessagesContentState", "Sources/Views/Overlays/MessagesContentState.swift", []),
            ("ToolManagerState", "Sources/Views/Extensions/ToolManagerState.swift", []),
            ("ExtensionOverlayState", "Sources/Views/Extensions/ExtensionOverlayState.swift", []),
            ("ExtensionPanelState", "Sources/Views/Extensions/ExtensionPanelState.swift", []),
            ("FeedbackState", "Sources/Views/EditorChrome/FeedbackState.swift", [
                "@ObservationIgnored private var showTask: Task<Void, Never>?",
                "@ObservationIgnored private var holdTask: Task<Void, Never>?",
                "@ObservationIgnored private var spinnerOnTime: ContinuousClock.Instant?",
                "@ObservationIgnored private var lastMessage = \"\"",
            ]),
            ("FrontendExtensionRuntimeRegistry", "Sources/Extensions/FrontendExtensionRuntime.swift", [
                "@ObservationIgnored private var decoders: [String: Decoder] = [:]",
                "@ObservationIgnored private var viewBuilders: [String: ViewBuilder] = [:]",
            ]),
        ]
        let ignoredReasons = [
            "@ObservationIgnored private var hasTranscript: Bool = false": "cache",
            "@ObservationIgnored private var warnedUnknownKinds: Set<String> = []": "cache",
            "@ObservationIgnored private var showTask: Task<Void, Never>?": "task",
            "@ObservationIgnored private var holdTask: Task<Void, Never>?": "task",
            "@ObservationIgnored private var spinnerOnTime: ContinuousClock.Instant?": "clock",
            "@ObservationIgnored private var lastMessage = \"\"": "cache",
            "@ObservationIgnored private var decoders: [String: Decoder] = [:]": "decoder",
            "@ObservationIgnored private var viewBuilders: [String: ViewBuilder] = [:]": "builder",
        ]
        let allowedIgnoredReasons: Set<String> = ["task", "callback", "clock", "cache", "decoder", "builder", "metrics"]
        #expect(Set(owners.flatMap(\.ignored)) == Set(ignoredReasons.keys))
        #expect(Set(ignoredReasons.values).isSubset(of: allowedIgnoredReasons))

        let sourcePaths = Set(owners.map(\.path)).union([
            "Sources/Views/EditorChrome/TabBarView.swift",
            "Sources/Views/Sidebar/FileTreeView.swift",
            "Sources/Views/Shared/GUIState.swift",
        ])
        let sources = try Dictionary(uniqueKeysWithValues: sourcePaths.map { path in
            (path, try String(contentsOf: macosRoot.appendingPathComponent(path), encoding: .utf8))
        })

        for owner in owners {
            let source = try #require(sources[owner.path])
            #expect(source.contains("@MainActor\n@Observable\npublic final class \(owner.name)"))
            let ignoredLines = Set(source.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.contains("@ObservationIgnored") ? trimmed : nil
            })
            #expect(ignoredLines == owner.ignored)
            #expect(!source.contains("ObservableObject"))
            #expect(!source.contains("objectWillChange"))
            #expect(!source.contains("ObservationRegistrar"))
        }

        let feedbackState = try #require(sources["Sources/Views/EditorChrome/FeedbackState.swift"])
        let guiState = try #require(sources["Sources/Views/Shared/GUIState.swift"])
        #expect(!feedbackState.contains("onPresentationChanged"))
        #expect(!feedbackState.contains("notifyPresentationChanged"))
        #expect(!guiState.contains("feedbackState.onPresentationChanged"))

        let tabState = try #require(sources["Sources/Views/EditorChrome/TabBarState.swift"])
        let tabView = try #require(sources["Sources/Views/EditorChrome/TabBarView.swift"])
        let treeState = try #require(sources["Sources/Views/Sidebar/FileTreeState.swift"])
        let treeView = try #require(sources["Sources/Views/Sidebar/FileTreeView.swift"])
        #expect(tabState.contains("@MainActor\n@Observable\npublic final class TabBarState"))
        #expect(treeState.contains("@MainActor\n@Observable\npublic final class FileTreeState"))
        for leafView in [tabView, treeView] {
            #expect(!leafView.contains("@Environment(\\.guiFrameVersion)"))
            #expect(!leafView.contains("let _ = frameVersion"))
        }
        #expect(!tabView.contains(".id(tabBarState"))
        #expect(!treeView.contains(".id(fileTreeState"))
    }

    private func observationProofContentView(gui: GUIState, recorder: FrameProbeRecorder) -> ContentView<ProductionEditorSurface> {
        ContentView(
            gui: gui,
            encoder: { nil },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in },
            frameProbe: ContentViewFrameProbe { point, value, stateObject in
                AnyView(ProductionFrameProbe(
                    point: point,
                    value: value,
                    stateObject: stateObject,
                    recorder: recorder
                ))
            }
        ) {
            ProductionEditorSurface(value: "editor-canary", stateObject: gui, recorder: recorder)
        }
    }

    private func mount<Root: View>(_ root: Root) -> (NSHostingView<Root>, NSWindow) {
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
        return (hostingView, window)
    }

    private func expectOnlyOwnerProbeUpdate(
        _ point: ObservationOwnerProbePoint,
        value: String,
        recorder: ObservationOwnerProbeRecorder,
        mutation: @MainActor () -> Void
    ) async {
        let baseline = recorder.updateCounts()
        mutation()
        await recorder.waitForValue(value, point: point)
        let updated = recorder.updateCounts()
        #expect(updated[point, default: 0] > baseline[point, default: 0])
        for unrelatedPoint in ObservationOwnerProbePoint.allCases where unrelatedPoint != point {
            #expect(updated[unrelatedPoint, default: 0] == baseline[unrelatedPoint, default: 0])
        }
    }

    private func stageCanonicalShellFrame(
        _ dispatcher: CommandDispatcher,
        frameSeq: UInt32,
        baseFrameSeq: UInt32,
        tabs: [Wire.WorkspaceTabEntry],
        selectedFile: String,
        generation: UInt32 = 1
    ) {
        dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: baseFrameSeq, generation: generation))
        dispatcher.dispatch(.guiTabBar(activeIndex: 0, tabs: []))
        dispatcher.dispatch(.guiWorkspaces(
            version: UInt8(clamping: frameSeq),
            activeWorkspaceId: 0,
            mode: 0,
            flags: 0,
            workspaces: [],
            visibleTabs: tabs
        ))
        dispatcher.dispatch(.guiFileTree(
            version: UInt8(clamping: frameSeq),
            treeFlags: 0x23,
            treeState: FileTreeVisibilityState.ready.rawValue,
            selectedId: selectedFile,
            treeWidth: 30,
            rootPath: "/tmp",
            errorReason: "",
            entries: tabs.enumerated().map { index, tab in
                Self.fileTreeEntry(
                    index: index,
                    id: tab.label,
                    path: tab.path,
                    selected: tab.label == selectedFile
                )
            }
        ))
    }

    private func publishCanonicalFrame(
        _ dispatcher: CommandDispatcher,
        frameSeq: UInt32,
        baseFrameSeq: UInt32,
        tabs: [Wire.WorkspaceTabEntry],
        activeIndex: UInt8,
        editorText: String,
        selectedFile: String,
        generation: UInt32 = 1
    ) throws {
        dispatcher.dispatch(.beginFrame(frameSeq: frameSeq, baseFrameSeq: baseFrameSeq, generation: generation))
        if baseFrameSeq == 0 {
            dispatcher.dispatch(.guiTheme(slots: completeThemeSlots()))
        }
        dispatcher.dispatch(.guiTabBar(activeIndex: activeIndex, tabs: []))
        dispatcher.dispatch(.guiWorkspaces(
            version: UInt8(clamping: frameSeq),
            activeWorkspaceId: 0,
            mode: 0,
            flags: 0,
            workspaces: [],
            visibleTabs: tabs
        ))
        dispatcher.dispatch(.guiSidebars(
            version: UInt8(clamping: frameSeq),
            activeId: "file_tree",
            sidebars: [Wire.SidebarMetadata(
                id: "file_tree",
                displayName: "File Tree",
                semanticKind: "file_tree",
                icon: "folder",
                order: 0,
                visible: true,
                focused: true,
                preferredWidth: 30,
                badgeCount: nil
            )]
        ))
        dispatcher.dispatch(.guiFileTree(
            version: UInt8(clamping: frameSeq),
            treeFlags: 0x23,
            treeState: FileTreeVisibilityState.ready.rawValue,
            selectedId: selectedFile,
            treeWidth: 30,
            rootPath: "/tmp",
            errorReason: "",
            entries: tabs.enumerated().map { index, tab in
                Self.fileTreeEntry(
                    index: index,
                    id: tab.label,
                    path: tab.path,
                    selected: tab.label == selectedFile
                )
            }
        ))
        dispatcher.dispatch(.guiWindowContent(data: try Self.windowContent(
            text: editorText,
            epoch: frameSeq
        )))
        dispatcher.dispatch(.commitFrame(frameSeq: frameSeq, seq: 0))
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

    private func completeThemeSlots() -> [(UInt8, UInt8, UInt8, UInt8)] {
        CommandDispatcher.requiredThemeSlots.map { slot in
            (slot, slot, slot, slot)
        }
    }

    private static func statusBarUpdate(message: String) -> StatusBarUpdate {
        StatusBarUpdate(
            contentKind: 0,
            mode: 0,
            cursorLine: 1,
            cursorCol: 1,
            lineCount: 1,
            flags: 0,
            lspStatus: 0,
            gitBranch: "",
            message: message,
            filetype: "",
            errorCount: 0,
            warningCount: 0,
            modelName: "",
            messageCount: 0,
            sessionStatus: 0,
            infoCount: 0,
            hintCount: 0,
            macroRecording: 0,
            parserStatus: 0,
            agentStatus: 0,
            gitAdded: 0,
            gitModified: 0,
            gitDeleted: 0,
            icon: "",
            iconColorR: 0,
            iconColorG: 0,
            iconColorB: 0,
            filename: "",
            diagnosticHint: "",
            backgroundSubagentCount: 0,
            backgroundSubagentLabel: ""
        )
    }

    private static func sidebarMetadata(id: String, kind: String) -> Wire.SidebarMetadata {
        Wire.SidebarMetadata(
            id: id,
            displayName: id,
            semanticKind: kind,
            icon: "",
            order: 0,
            visible: true,
            focused: true,
            preferredWidth: 30,
            badgeCount: nil
        )
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

    private static func workspaceTab(id: UInt32, label: String, path: String) -> Wire.WorkspaceTabEntry {
        Wire.WorkspaceTabEntry(
            id: id,
            workspaceId: 0,
            kind: 0,
            flags: 0,
            pathHash: id,
            tintColorRGB: 0,
            icon: "",
            label: label,
            path: path
        )
    }

    private static func fileTreeEntry(
        index: Int,
        id: String,
        path: String,
        selected: Bool
    ) -> Wire.FileTreeEntry {
        Wire.FileTreeEntry(
            pathHash: UInt32(index + 1),
            id: id,
            path: path,
            isDir: false,
            isExpanded: false,
            isSelected: selected,
            isFocused: selected,
            isActive: selected,
            isDirty: false,
            isEditing: false,
            isLastChild: index > 0,
            depth: 0,
            gitStatus: 0,
            diagnosticErrorCount: 0,
            diagnosticWarningCount: 0,
            diagnosticInfoCount: 0,
            diagnosticHintCount: 0,
            guides: [],
            icon: "",
            iconColorR: 0,
            iconColorG: 0,
            iconColorB: 0,
            name: id,
            relPath: id,
            editingType: 0xFF,
            editingText: ""
        )
    }

    private static func windowContent(text: String, epoch: UInt32) throws -> GUIWindowContent {
        let span = GUIHighlightSpan(
            startCol: 0,
            endCol: UInt16(clamping: text.count),
            fg: 0xFFFFFF,
            bg: 0,
            attrs: 0,
            fontWeight: 0,
            fontId: 0
        )
        let row = GUIVisualRow(
            rowType: .normal,
            rowId: UInt64(epoch),
            bufLine: 0,
            contentHash: epoch,
            text: text,
            spans: [span]
        )
        return try GUIWindowContent(
            windowId: 1,
            fullRefresh: true,
            contentEpoch: epoch,
            cursorRow: 0,
            cursorCol: 0,
            cursorShape: .block,
            rows: [row],
            selection: nil,
            searchMatches: [],
            diagnosticUnderlines: [],
            documentHighlights: []
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
