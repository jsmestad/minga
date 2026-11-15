import AppKit
import MingaUI
import MingaProtocol
import SwiftUI
import Testing
import ViewInspector

@Suite("Edit timeline native activation")
struct EditTimelineViewTests {
    @Test("Review buttons distinguish duplicate basenames and preserve source order")
    @MainActor func reviewUsesFullOfferedPath() throws {
        let paths = ["z/日本語/duplicate.swift", "a/nested folder/duplicate.swift"]
        let state = EditTimelineState(
            visible: true,
            files: paths.map { file($0) },
            generation: 0x0102_0304
        )
        let spy = SpyEncoder()
        let sut = EditTimelineView(state: state, sendAction: { action in
            _ = spy.send(FrontendActionComposition.outbound(action))
        }).environment(\.themeColors, ThemeColors())
        let buttons = try sut.inspect().findAll(ViewType.Button.self)

        #expect(try buttons.map { try $0.accessibilityLabel().string() } == paths.map { "Review \($0)" })
        for button in buttons {
            try button.tap()
        }
        #expect(spy.actions == paths.map {
            .semanticItemActivate(surface: .timeline, intent: 2, generation: 0x0102_0304, itemID: Data($0.utf8))
        })
    }

    @Test("Retained Review sends its original generation and path, never the replacement file")
    @MainActor func retainedReviewPreservesOffer() throws {
        let path = "Sources/original.swift"
        let state = EditTimelineState(visible: true, files: [file(path)], generation: 41)
        let spy = SpyEncoder()
        let sut = EditTimelineView(state: state, sendAction: { action in
            _ = spy.send(FrontendActionComposition.outbound(action))
        }).environment(\.themeColors, ThemeColors())
        let retained = try #require(sut.inspect().findAll(ViewType.Button.self).first)

        state.generation = 42
        state.files = [file("Tests/replacement.swift")]
        state.entries = [.init(entryID: "latest-entry", index: 0, toolName: "edit", timestampDelta: 0)]
        try retained.tap()

        #expect(spy.actions == [
            .semanticItemActivate(surface: .timeline, intent: 2, generation: 41, itemID: Data(path.utf8))
        ])
    }

    @Test("Unavailable review offers are disabled", arguments: [false, true])
    @MainActor func unavailableReviewIsDisabled(missingHandler: Bool) throws {
        let recorder = LocalActionRecorder<EditTimelineView.Action>()
        let state = EditTimelineState(
            visible: true,
            files: [file("Sources/single.swift")],
            generation: missingHandler ? 41 : 0
        )
        let sut = EditTimelineView(state: state, sendAction: missingHandler ? nil : recorder.handler)
            .environment(\.themeColors, ThemeColors())
        let button = try #require(sut.inspect().findAll(ViewType.Button.self).first)

        #expect(try button.isDisabled())
        #expect(throws: (any Error).self) { try button.tap() }
        #expect(recorder.actions.isEmpty)
    }

    @Test("Historical edits are labelled native buttons retaining intent one and entry identity")
    @MainActor func historicalNavigationRemainsSeparate() throws {
        let state = EditTimelineState(
            visible: true,
            entries: [.init(entryID: "original-entry", index: 0, toolName: "edit_file", timestampDelta: 0)],
            generation: 53
        )
        let spy = SpyEncoder()
        let sut = EditTimelineView(state: state, sendAction: { action in
            _ = spy.send(FrontendActionComposition.outbound(action))
        }).environment(\.themeColors, ThemeColors())
        let retained = try #require(sut.inspect().findAll(ViewType.Button.self).first)
        #expect(try retained.accessibilityLabel().string() == "View edit_file edit 1 of 1")

        state.generation = 54
        state.entries = [.init(entryID: "replacement-entry", index: 0, toolName: "write_file", timestampDelta: 1)]
        try retained.tap()

        #expect(spy.actions == [
            .semanticItemActivate(surface: .timeline, intent: 1, generation: 53, itemID: Data("original-entry".utf8))
        ])
    }

    @Test("Mounted timeline keeps its footprint from zero through a burst of files")
    @MainActor func mountedHeightIsIndependentOfFileCount() throws {
        for count in [0, 1, 100] {
            let files: [EditTimelineState.TimelineFile] = (0..<count).map { file("Sources/\($0).swift") }
            let state = EditTimelineState(visible: true, files: files, generation: 1)
            let view = EditTimelineView(state: state, sendAction: nil)
                .environment(\.themeColors, ThemeColors())
            let host = NSHostingView(rootView: view.frame(width: 640))
            #expect(host.fittingSize.height == 24)
            if count == 0 {
                #expect(try view.inspect().findAll(ViewType.Button.self).isEmpty)
                #expect(try view.inspect().find(text: "No changed files").string() == "No changed files")
            }
        }
    }

    @MainActor private func file(_ path: String) -> EditTimelineState.TimelineFile {
        .init(path: path, entryCount: 2, linesAdded: 13, linesRemoved: 4, reviewStatus: 0)
    }
}
