import AppKit
import Darwin
import Foundation
import MingaProtocol
import MingaUI
import SwiftUI

/// Hosted Agent transcript view cost per committed transcript frame (#3572).
///
/// The replay hosts the shipping `AgentChatView` in an `NSHostingView` inside an offscreen window, seeds a resident transcript of a fixed size, focuses an unfinished composer draft, and then applies one transcript operation per frame through the production `prepareTranscript` and `publishTranscript` path. Each frame records main-thread CPU separately for store preparation, for publication plus the SwiftUI update that `layoutSubtreeIfNeeded()` forces, and for the window display pass. No provider, BEAM, or protocol decode is involved.
struct AgentTranscriptViewReplayMeasurement: Codable {
    let scenario: String
    let geometry: String
    let residentMessages: Int
    let warmupFrames: Int
    let measuredFrames: Int
    let processCPUMicroseconds: Int
    let prepareCPUSamplesMs: [Double]
    let updateCPUSamplesMs: [Double]
    let displayCPUSamplesMs: [Double]
    let firstFramePrepareCPUMs: Double
    let firstFrameUpdateCPUMs: Double
    let firstFrameDisplayCPUMs: Double
    let unobservedFrames: Int
    let enumeratedArrayBuildMs: Double
    let indexedIdentityPassMs: Double
    let revision: String
}

@MainActor
private final class RevisionObservations {
    var count = 0
}

/// Counts processed transcript revisions so each frame proves that SwiftUI ran the update transaction.
private struct TranscriptRevisionProbe: View {
    let state: AgentChatState
    let observations: RevisionObservations

    var body: some View {
        Color.clear.onChange(of: state.transcriptRevision) { _, _ in
            observations.count += 1
        }
    }
}

private func replayMessage(_ id: Int) -> Wire.ChatMessage {
    let beamId = UInt32(id + 1)
    switch id % 4 {
    case 0:
        return Wire.ChatMessage(beamId: beamId, content: .user(text: "Please update module \(id) so the parser keeps its spans."))
    case 2:
        return Wire.ChatMessage(beamId: beamId, content: .toolCall(
            name: "edit_file", summary: "lib/minga/module_\(id).ex", status: 1, isError: false,
            collapsed: true, autoApprovedScope: 0, durationMs: 12,
            result: "Updated lib/minga/module_\(id).ex", previewKind: 0, previewLines: []
        ))
    default:
        return Wire.ChatMessage(beamId: beamId, content: .assistant(text: "Updated module \(id). The parser now keeps highlight spans across edits."))
    }
}

private func streamingMessage(id: Int, words: Int) -> Wire.ChatMessage {
    var text = "Streaming reply"
    for word in 0..<words { text += " word\(word)" }
    return Wire.ChatMessage(beamId: UInt32(id + 1), content: .assistant(text: text))
}

private func cpuMilliseconds(_ start: UInt64) -> Double {
    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
}

private func processCPUMicroseconds() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Int(usage.ru_utime.tv_sec) * 1_000_000 + Int(usage.ru_utime.tv_usec)
    let system = Int(usage.ru_stime.tv_sec) * 1_000_000 + Int(usage.ru_stime.tv_usec)
    return user + system
}

@MainActor
private func applyPrepared(
    _ state: AgentChatState,
    trimFront: Int,
    baseCount: Int,
    messages: [Wire.ChatMessage]
) -> (AgentTranscriptSnapshot, Double) {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let result = AgentChatState.prepareTranscript(
        from: state.transcriptSnapshot, mode: 1, epoch: 1, truncated: false,
        trimFront: trimFront, baseCount: baseCount, messages: messages
    )
    let elapsed = cpuMilliseconds(start)
    switch result {
    case .success(let snapshot):
        return (snapshot, elapsed)
    case .failure(let failure):
        preconditionFailure("replay transcript operation rejected: \(failure)")
    }
}

/// Runs one scenario and writes its measurement.
@MainActor
func runAgentTranscriptViewReplay(
    outputURL: URL,
    residentMessages: Int,
    geometry: String,
    scenario: String,
    measuredFrames: Int,
    warmupFrames: Int
) throws {
    precondition(scenario == "file_change" || scenario == "stream", "scenario must be file_change or stream")
    let size: CGSize
    switch geometry {
    case "default": size = CGSize(width: 900, height: 820)
    case "narrow": size = CGSize(width: 420, height: 820)
    default: preconditionFailure("geometry must be default or narrow")
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let state = AgentChatState(visible: true, model: "test-model")
    var seed: [Wire.ChatMessage] = []
    seed.reserveCapacity(residentMessages + 1)
    for id in 0..<residentMessages { seed.append(replayMessage(id)) }
    var nextId = residentMessages
    if scenario == "stream" {
        seed.append(streamingMessage(id: nextId, words: 1))
    }
    precondition(state.applyTranscript(mode: 0, epoch: 1, baseCount: 0, messages: seed) == .appliedFullReplace)
    state.update(
        visible: true, status: .thinking, model: "test-model", thinkingLevel: "medium",
        prompt: "unfinished draft", promptLineCount: 1, promptCursorLine: 0, promptCursorCol: 16,
        promptMode: .insert, promptVisibleRows: 1, promptCompletion: nil
    )

    let observations = RevisionObservations()
    let root = AgentChatView(state: state, isInsertMode: true, sendAction: { _ in })
        .environment(\.themeColors, ThemeColors())
        .background(TranscriptRevisionProbe(state: state, observations: observations))
    let hostingView = NSHostingView(rootView: AnyView(root))
    hostingView.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let targetCount = max(residentMessages, 1)
    var words = 1
    var prepareSamples: [Double] = []
    var updateSamples: [Double] = []
    var displaySamples: [Double] = []
    var firstFrame: (Double, Double, Double)?
    var unobserved = 0
    var processStart = 0

    for frame in 0..<(warmupFrames + measuredFrames) {
        if frame == warmupFrames { processStart = processCPUMicroseconds() }
        let current = state.messages.count
        let prepared: (AgentTranscriptSnapshot, Double)
        if scenario == "stream" {
            words += 1
            prepared = applyPrepared(
                state, trimFront: 0, baseCount: current - 1,
                messages: [streamingMessage(id: residentMessages, words: words)]
            )
        } else {
            let trimFront = current >= targetCount ? 1 : 0
            prepared = applyPrepared(
                state, trimFront: trimFront, baseCount: current - trimFront,
                messages: [replayMessage(nextId)]
            )
            nextId += 1
        }
        let observedBefore = observations.count
        let updateStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        state.publishTranscript(prepared.0)
        hostingView.layoutSubtreeIfNeeded()
        let update = cpuMilliseconds(updateStart)
        let displayStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        window.displayIfNeeded()
        let display = cpuMilliseconds(displayStart)
        if observations.count == observedBefore { unobserved += 1 }
        if firstFrame == nil { firstFrame = (prepared.1, update, display) }
        guard frame >= warmupFrames else { continue }
        prepareSamples.append(prepared.1)
        updateSamples.append(update)
        displaySamples.append(display)
    }
    let processCPU = processCPUMicroseconds() - processStart

    // Reference costs on the final snapshot: the eager tuple array that the original view body builds, and one indexed identity read per resident entry.
    let messages = state.messages
    var start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let array = Array(messages.enumerated())
    let arrayMs = cpuMilliseconds(start)
    precondition(array.count == messages.count)
    start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    var identitySum = 0
    var index = messages.startIndex
    while index < messages.endIndex {
        identitySum &+= messages[index].id
        index = messages.index(after: index)
    }
    let identityMs = cpuMilliseconds(start)
    precondition(identitySum != -1)

    window.orderOut(nil)
    window.contentView = nil
    hostingView.rootView = AnyView(EmptyView())

    let first = firstFrame ?? (0, 0, 0)
    let measurement = AgentTranscriptViewReplayMeasurement(
        scenario: scenario,
        geometry: geometry,
        residentMessages: residentMessages,
        warmupFrames: warmupFrames,
        measuredFrames: measuredFrames,
        processCPUMicroseconds: processCPU,
        prepareCPUSamplesMs: prepareSamples,
        updateCPUSamplesMs: updateSamples,
        displayCPUSamplesMs: displaySamples,
        firstFramePrepareCPUMs: first.0,
        firstFrameUpdateCPUMs: first.1,
        firstFrameDisplayCPUMs: first.2,
        unobservedFrames: unobserved,
        enumeratedArrayBuildMs: arrayMs,
        indexedIdentityPassMs: identityMs,
        revision: ProcessInfo.processInfo.environment["MINGA_BENCHMARK_REVISION"] ?? "unknown"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(measurement).write(to: outputURL, options: .atomic)
    let updateSorted = updateSamples.sorted()
    let p50 = updateSorted.isEmpty ? 0 : updateSorted[updateSorted.count / 2]
    let summary = "scenario=\(scenario) geometry=\(geometry) messages=\(residentMessages) frames=\(measuredFrames) process_cpu_us=\(processCPU) update_p50_ms=\(p50) unobserved=\(unobserved) array_ms=\(arrayMs) identity_ms=\(identityMs)\n"
    FileHandle.standardOutput.write(Data(summary.utf8))
}
