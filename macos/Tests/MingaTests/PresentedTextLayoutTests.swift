import AppKit
import CoreText
import MingaUI
import MingaProtocol
import Testing

@Suite("Displayed text targets")
@MainActor
struct PresentedTextLayoutTests {
    private func row(text: String, rank: UInt32 = 70_000, id: UInt64 = 88, y: CGFloat = 20, start: Int = 0) -> PresentedTextLayout.Row {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
        return PresentedTextLayout.Row(rowIndex: rank, rowID: id, presentationRow: 0, composedUTF16Start: start, composedUTF16End: start + text.utf16.count, line: CTLineCreateWithAttributedString(attributed), origin: CGPoint(x: 40, y: y), rect: CGRect(x: 40, y: y, width: 200, height: 20))
    }

    @Test("CoreText hit returns composed UTF16 and exact resident rank after accented text")
    func unicodeAndResidentRank() throws {
        let row = row(text: "ééé A界😀z")
        let layout = PresentedTextLayout(panes: [.init(windowID: 2, presentationID: 44, rect: CGRect(x: 40, y: 20, width: 200, height: 40), scrollOffset: .zero, rows: [row])])
        let hit = try #require(layout.hit(at: CGPoint(x: row.x(at: 4) + 0.01, y: 25)))
        #expect(hit.target == EditorTextTarget(windowID: 2, presentationID: 44, rowIndex: 70_000, rowID: 88, utf16Offset: 4))
        #expect(layout.hit(at: CGPoint(x: 239, y: 55))?.target.utf16Offset == 9)
    }

    @Test("clipped row retains its original composed offset")
    func horizontalSlice() {
        let row = row(text: "界abc", start: 12)
        #expect(row.utf16(at: row.x(at: 13) + 0.01) == 13)
        #expect(row.utf16(at: -10) == 12)
        #expect(row.utf16(at: 500) == 16)
    }

    @Test("drag stays in its origin pane and reports edge direction")
    func dragOrigin() throws {
        let first = row(text: "abc")
        let second = row(text: "xyz", rank: 8, id: 99, y: 80)
        let layout = PresentedTextLayout(panes: [
            .init(windowID: 1, presentationID: 10, rect: CGRect(x: 40, y: 20, width: 200, height: 40), scrollOffset: .zero, rows: [first]),
            .init(windowID: 2, presentationID: 11, rect: CGRect(x: 40, y: 80, width: 200, height: 40), scrollOffset: .zero, rows: [second])
        ])
        let point = CGPoint(x: 100, y: 90)
        #expect(layout.hit(at: point)?.target.windowID == 2)
        let drag = try #require(layout.hit(at: point, capturedWindowID: 1))
        #expect(drag.target.windowID == 1)
        #expect(drag.scrollY == 1)
        #expect(layout.hit(at: point, capturedWindowID: 3) == nil)
    }

    @Test("empty rows and captured scroll use the displayed geometry")
    func emptyAndScroll() throws {
        let empty = row(text: "", y: 7)
        let layout = PresentedTextLayout(panes: [.init(windowID: 1, presentationID: 1, rect: CGRect(x: 40, y: 5, width: 200, height: 40), scrollOffset: CGPoint(x: 3, y: 13), rows: [empty])])
        #expect(layout.hit(at: CGPoint(x: 60, y: 10))?.target.utf16Offset == 0)
        #expect(layout.cursor(windowID: 1, row: 0, utf16: 0) == CGPoint(x: 43, y: 20))
    }
}

@Suite("Text presentation lifetime")
@MainActor
struct TextPresentationLeasesTests {
    private func snapshot(_ id: UInt64) -> CommittedEditorSnapshot {
        var metadata = EditorSnapshotMetadata.empty
        metadata.textPresentations = [1: id]
        return CommittedEditorSnapshot(generation: 1, frameSeq: UInt32(id), frameState: FrameState(cols: 80, rows: 24), themeColors: nil, surfaces: [], activeWindowId: nil, metadata: metadata)
    }

    @Test("a visible frame survives commit and retirement waits for the last native attempt")
    func retainedVisibleAndAttempt() {
        let leases = TextPresentationLeases()
        var events: [String] = []
        leases.onState = { _, id, state in events.append("\(id):\(state.rawValue)") }
        leases.commit(snapshot(1))
        let firstAttempt = leases.beginAttempt(snapshot(1))
        leases.present(snapshot(1))
        leases.commit(snapshot(2))
        #expect(events == ["1:1"])
        leases.present(snapshot(2))
        #expect(events == ["1:1", "2:1"])
        leases.finishAttempt(firstAttempt)
        #expect(events == ["1:1", "2:1", "1:0"])
    }

    @Test("superseded unpresented candidates retire and duplicate redraws retain one active target")
    func discardedCandidates() {
        let leases = TextPresentationLeases()
        var events: [String] = []
        leases.onState = { _, id, state in events.append("\(id):\(state.rawValue)") }
        leases.commit(snapshot(1))
        leases.commit(snapshot(2))
        #expect(events == ["1:0"])
        let a = leases.beginAttempt(snapshot(2))
        let b = leases.beginAttempt(snapshot(2))
        leases.present(snapshot(2))
        leases.present(snapshot(2))
        leases.finishAttempt(a)
        leases.finishAttempt(b)
        #expect(events == ["1:0", "2:1"])
        leases.replaceConnection()
        #expect(events == ["1:0", "2:1"])
    }
}

@Suite("Displayed text protocol decoding")
struct DisplayedTextDecoderTests {
    @Test("presentation metadata decodes a full 64-bit identity")
    func presentation() throws {
        let bytes = Data([OP_GUI_TEXT_PRESENTATION, 2, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        let (command, size) = try decodeCommand(data: bytes, offset: 0)
        guard case .guiTextPresentation(let window, let identity) = command else {
            Issue.record("Expected text presentation metadata")
            return
        }
        #expect(size == 11)
        #expect(window == 512)
        #expect(identity == 0x0102030405060708)
        #expect(throws: ProtocolDecodeError.self) { try decodeCommand(data: Data(bytes.dropLast()), offset: 0) }
    }
}
