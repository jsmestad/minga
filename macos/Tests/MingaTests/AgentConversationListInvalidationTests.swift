import AppKit
import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing

@MainActor
private final class EvaluationCounter {
    var count = 0
}

/// Reports each processed composer caret change so the test knows SwiftUI has
/// run the update transaction for that composer frame.
@MainActor
private struct ComposerCaretObservationProbe: View {
    let state: AgentChatState
    let changed: AsyncStream<UInt16>.Continuation

    var body: some View {
        Color.clear.onChange(of: state.promptCursorCol) { _, column in
            changed.yield(column)
        }
    }
}

/// Reports each processed transcript replacement.
@MainActor
private struct TranscriptObservationProbe: View {
    let state: AgentChatState
    let changed: AsyncStream<Int>.Continuation

    var body: some View {
        Color.clear.onChange(of: state.messages.count) { _, count in
            changed.yield(count)
        }
    }
}

@Suite("Agent conversation list invalidation")
struct AgentConversationListInvalidationTests {
    @Test("Composer updates do not re-evaluate the conversation list", arguments: [0, 100, 10_000])
    @MainActor func composerUpdatesSkipConversationList(messageCount: Int) async throws {
        let state = AgentChatState(visible: true, model: "test-model")
        state.seed(messages: (0..<messageCount).map { .assistant(id: $0, text: "Reply \($0)") })
        let counter = EvaluationCounter()
        let caretValues = AsyncStream.makeStream(of: UInt16.self, bufferingPolicy: .bufferingNewest(64))
        var carets = caretValues.stream.makeAsyncIterator()
        defer { caretValues.continuation.finish() }
        let transcriptValues = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(8))
        var transcripts = transcriptValues.stream.makeAsyncIterator()
        defer { transcriptValues.continuation.finish() }

        let root = AgentChatView(state: state, isInsertMode: true, sendAction: { _ in })
            .environment(\.themeColors, ThemeColors())
            .environment(\.agentConversationListEvaluationProbe, AgentConversationListEvaluationProbe { counter.count += 1 })
            .background(ComposerCaretObservationProbe(state: state, changed: caretValues.continuation))
            .background(TranscriptObservationProbe(state: state, changed: transcriptValues.continuation))
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: 760, height: 600))
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        defer {
            window.orderOut(nil)
            window.contentView = nil
            hostingView.rootView = AnyView(EmptyView())
        }
        hostingView.layoutSubtreeIfNeeded()
        try #require(counter.count > 0, "The conversation list must render before composer updates")
        let baseline = counter.count

        let completion = Wire.PromptCompletion(
            type: 1, selected: 0, anchorLine: 0, anchorCol: 0,
            candidates: [(name: "help", description: "Show help"), (name: "model", description: "Pick a model")]
        )
        for step in 1...50 {
            // Typing, caret motion, the composer growing by a line, and the
            // completion popup opening and closing.
            let rows = UInt8(1 + step / 20)
            state.update(
                visible: true, status: .idle, model: "test-model", thinkingLevel: "medium",
                prompt: String(repeating: "x", count: step), promptLineCount: rows,
                promptCursorLine: UInt16(rows - 1), promptCursorCol: UInt16(step), promptMode: .insert,
                promptVisibleRows: rows, promptCompletion: step % 10 >= 5 ? completion : nil
            )
            let observed = await carets.next()
            try #require(observed == UInt16(step), "SwiftUI must process composer frame \(step)")
            hostingView.layoutSubtreeIfNeeded()
        }
        #expect(counter.count == baseline, "Composer frames re-evaluated the conversation list \(counter.count - baseline) times")

        // Control: a transcript change re-evaluates the list through the same probe.
        state.seed(messages: (0...messageCount).map { .assistant(id: $0, text: "Reply \($0)") })
        let replaced = await transcripts.next()
        try #require(replaced == messageCount + 1)
        hostingView.layoutSubtreeIfNeeded()
        #expect(counter.count > baseline)
    }
}

@Suite("Agent transcript file change with a 10,000-message history")
struct AgentTranscriptFileChangeTests {
    @Test("a file-change frame keeps the draft while SwiftUI processes it at default and narrow width", arguments: [900, 420])
    @MainActor func fileChangeKeepsDraft(width: Int) async throws {
        let state = AgentChatState(visible: true, model: "test-model")
        var history: [Wire.ChatMessage] = []
        history.reserveCapacity(10_000)
        for id in 1...10_000 {
            history.append(Wire.ChatMessage(beamId: UInt32(id), content: id.isMultiple(of: 2) ? .assistant(text: "Reply \(id)") : .user(text: "Question \(id)")))
        }
        #expect(state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: history) == .appliedFullReplace)
        state.update(
            visible: true, status: .executingTool, model: "test-model", thinkingLevel: "medium",
            prompt: "unfinished draft", promptLineCount: 1, promptCursorLine: 0, promptCursorCol: 16,
            promptMode: .insert, promptVisibleRows: 1, promptCompletion: nil
        )
        let transcriptValues = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(8))
        var transcripts = transcriptValues.stream.makeAsyncIterator()
        defer { transcriptValues.continuation.finish() }

        let root = AgentChatView(state: state, isInsertMode: true, sendAction: { _ in })
            .environment(\.themeColors, ThemeColors())
            .background(TranscriptObservationProbe(state: state, changed: transcriptValues.continuation))
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: CGFloat(width), height: 820))
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        defer {
            window.orderOut(nil)
            window.contentView = nil
            hostingView.rootView = AnyView(EmptyView())
        }
        hostingView.layoutSubtreeIfNeeded()

        let fileChange = Wire.ChatMessage(beamId: 10_001, content: .toolCall(
            name: "edit_file", summary: "lib/minga/changed.ex", status: 1, isError: false, collapsed: true,
            autoApprovedScope: 0, durationMs: 12, result: "Updated lib/minga/changed.ex", previewKind: 0, previewLines: []
        ))
        #expect(state.applyTranscript(mode: 1, epoch: 1, baseCount: 10_000, messages: [fileChange]) == .appliedAppend)
        let count = await transcripts.next()
        try #require(count == 10_001, "SwiftUI must process the file-change frame")
        hostingView.layoutSubtreeIfNeeded()

        #expect(state.prompt == "unfinished draft")
        #expect(state.promptCursorCol == 16)
        #expect(state.promptMode == .insert)
        let rows = AgentTranscriptRows(state.messages)
        #expect(rows.count == 10_001)
        #expect(rows[10_000] == AgentTranscriptRow(id: 10_001, offset: 10_000))
        #expect(rows[9_999] == AgentTranscriptRow(id: 10_000, offset: 9_999))
    }
}

@Suite("Agent transcript revision")
struct AgentTranscriptRevisionTests {
    @Test("The revision advances only when the stored transcript is replaced")
    @MainActor func revisionTracksTranscriptReplacement() {
        let state = AgentChatState()
        let initial = state.transcriptRevision

        state.update(
            visible: true, status: .thinking, model: "test-model", thinkingLevel: "high",
            prompt: "draft", promptLineCount: 2, promptCursorLine: 1, promptCursorCol: 3,
            promptMode: .insert, promptVisibleRows: 2, promptCompletion: nil
        )
        #expect(state.transcriptRevision == initial, "Chrome and composer updates must not advance the revision")

        #expect(state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: [Wire.ChatMessage(beamId: 1, content: .user(text: "hi"))]) == .appliedFullReplace)
        #expect(state.transcriptRevision == initial &+ 1)

        // Streaming growth keeps the count and still advances the revision.
        #expect(state.applyTranscript(mode: 1, epoch: 1, baseCount: 0, messages: [Wire.ChatMessage(beamId: 1, content: .user(text: "hi there"))]) == .appliedAppend)
        #expect(state.messages.count == 1)
        #expect(state.transcriptRevision == initial &+ 2)

        #expect(state.applyTranscript(mode: 1, epoch: 9, baseCount: 1, messages: []) == .droppedEpochMismatch)
        #expect(state.transcriptRevision == initial &+ 2, "A rejected frame keeps the last-good revision")

        state.hide()
        #expect(state.transcriptRevision == initial &+ 3)
        #expect(state.messages.isEmpty)

        state.seed(messages: [.user(id: 2, text: "seeded")])
        #expect(state.transcriptRevision == initial &+ 4)
    }
}
