/// Protocol encode/decode round-trip tests.

import MingaUI
import Testing
import AppKit
import Foundation
import QuartzCore
import os
import MingaProtocol

private func appendConfigStateU16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendConfigStateU32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendConfigStateU64(_ data: inout Data, _ value: UInt64) {
    data.append(UInt8((value >> 56) & 0xFF))
    data.append(UInt8((value >> 48) & 0xFF))
    data.append(UInt8((value >> 40) & 0xFF))
    data.append(UInt8((value >> 32) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendConfigStateString8(_ data: inout Data, _ text: String) {
    let bytes = Array(text.utf8.prefix(Int(UInt8.max)))
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
}

private func appendConfigStateString16(_ data: inout Data, _ text: String) {
    let bytes = Array(text.utf8.prefix(Int(UInt16.max)))
    appendConfigStateU16(&data, UInt16(bytes.count))
    data.append(contentsOf: bytes)
}

private func appendWireU16(_ data: inout Data, _ value: UInt16) {
    appendConfigStateU16(&data, value)
}

private func appendWireU32(_ data: inout Data, _ value: UInt32) {
    appendConfigStateU32(&data, value)
}

private func appendWireU64(_ data: inout Data, _ value: UInt64) {
    appendConfigStateU64(&data, value)
}

private func appendWireString8(_ data: inout Data, _ text: String) {
    let bytes = Array(text.utf8.prefix(Int(UInt8.max)))
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
}

private func appendWireString16(_ data: inout Data, _ text: String) {
    appendConfigStateString16(&data, text)
}

private func appendConfigStateValue(_ data: inout Data, _ value: SettingValue) {
    switch value {
    case .bool(let enabled):
        data.append(SETTING_VALUE_BOOL)
        data.append(enabled ? 1 : 0)
    case .int(let number):
        data.append(SETTING_VALUE_INT)
        let unsigned = UInt32(bitPattern: Int32(clamping: number))
        data.append(UInt8((unsigned >> 24) & 0xFF))
        data.append(UInt8((unsigned >> 16) & 0xFF))
        data.append(UInt8((unsigned >> 8) & 0xFF))
        data.append(UInt8(unsigned & 0xFF))
    case .string(let text):
        data.append(SETTING_VALUE_STRING)
        appendConfigStateString16(&data, text)
    case .atom(let text):
        data.append(SETTING_VALUE_ATOM)
        appendConfigStateString16(&data, text)
    case .float(let number):
        data.append(SETTING_VALUE_FLOAT)
        let bits = number.bitPattern.bigEndian
        withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
    }
}

@Suite("Protocol Decoder")
struct ProtocolDecoderTests {
    @Test("Decode commit_frame command")
    func decodeCommitFrame() throws {
        // commit_frame (#2219): frame_seq:u32 + input_seq:u32. input_seq is the
        // echoed input correlation sequence (#2215, formerly carried by batch_end).
        let data = Data([OP_COMMIT_FRAME, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x10, 0x2A])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 9)
        guard case .commitFrame(let frameSeq, let seq) = cmd else {
            Issue.record("Expected .commitFrame, got \(String(describing: cmd))")
            return
        }
        #expect(frameSeq == 7)
        #expect(seq == 0x0000_102A)
    }

    @Test("Decode set_link_cursor active command (#2630)")
    func decodeSetLinkCursorActive() throws {
        let data = Data([OP_SET_LINK_CURSOR, 0x01])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)
        guard case .setLinkCursor(let active) = cmd else {
            Issue.record("Expected .setLinkCursor, got \(String(describing: cmd))")
            return
        }
        #expect(active == true)
    }

    @Test("Decode set_link_cursor inactive command (#2630)")
    func decodeSetLinkCursorInactive() throws {
        let data = Data([OP_SET_LINK_CURSOR, 0x00])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)
        guard case .setLinkCursor(let active) = cmd else {
            Issue.record("Expected .setLinkCursor, got \(String(describing: cmd))")
            return
        }
        #expect(active == false)
    }

    @Test("Decode begin_frame command")
    func decodeBeginFrame() throws {
        // begin_frame (#2739): frame_seq:u32 + base_frame_seq:u32 + generation:u32.
        let data = Data([OP_BEGIN_FRAME, 0, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0, 9])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 13)
        guard case .beginFrame(let frameSeq, let baseFrameSeq, let generation) = cmd else {
            Issue.record("Expected .beginFrame, got \(String(describing: cmd))")
            return
        }
        #expect(frameSeq == 7)
        #expect(baseFrameSeq == 3)
        #expect(generation == 9)
    }

    @Test("Decode framed gui_agent_context payload")
    func decodeFramedGuiAgentContext() throws {
        let dispatchTimestamp = Date(timeIntervalSince1970: 1_705_314_000)
        var body = Data([1])
        appendWireString16(&body, "Review diff")
        appendWireU64(&body, UInt64(dispatchTimestamp.timeIntervalSince1970))
        body.append(3)
        body.append(1)
        appendWireString16(&body, "Running shell")
        appendWireU16(&body, 2)
        appendWireU16(&body, 1)
        appendWireString16(&body, "Review: approve or reject changes")
        body.append(1)
        body.append(1)
        appendWireString16(&body, "Inspect files")

        var payload = Data()
        appendWireU16(&payload, UInt16(body.count))
        payload.append(body)

        var data = Data([OP_GUI_AGENT_CONTEXT])
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiAgentContext(let visible, let task, let decodedTimestamp, let status, let canApprove, let progress, let todos) = cmd else {
            Issue.record("Expected .guiAgentContext, got \(String(describing: cmd))")
            return
        }

        #expect(visible)
        #expect(task == "Review diff")
        #expect(decodedTimestamp == dispatchTimestamp)
        #expect(status == .needsYou)
        #expect(canApprove)
        #expect(progress.activeAction == "Running shell")
        #expect(progress.toolCount == 2)
        #expect(progress.fileCount == 1)
        #expect(progress.reviewHint == "Review: approve or reject changes")
        #expect(todos.count == 1)
        #expect(todos[0].status == 1)
        #expect(todos[0].description == "Inspect files")
    }

    @Test("Decode legacy gui_agent_context payload")
    func decodeLegacyGuiAgentContext() throws {
        let dispatchTimestamp = Date(timeIntervalSince1970: 1_705_314_100)
        var data = Data([OP_GUI_AGENT_CONTEXT, 1])
        appendWireString16(&data, "Legacy diff")
        appendWireU64(&data, UInt64(dispatchTimestamp.timeIntervalSince1970))
        data.append(4)
        data.append(1)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiAgentContext(let visible, let task, let decodedTimestamp, let status, let canApprove, _, let todos) = cmd else {
            Issue.record("Expected .guiAgentContext, got \(String(describing: cmd))")
            return
        }

        #expect(visible)
        #expect(task == "Legacy diff")
        #expect(decodedTimestamp == dispatchTimestamp)
        #expect(status == .done)
        #expect(canApprove)
        #expect(todos.isEmpty)
    }

    @Test("Decode visible gui_empty_state launchpad frame")
    func decodeGuiEmptyStateVisible() throws {
        var body = Data()
        body.append(1)          // visible
        body.append(0x01)       // flags: crashed
        appendWireString8(&body, "v0.9")
        appendWireString8(&body, "resume")   // focused_id

        body.append(2)          // section_count

        // Section 0: session (one resume card row)
        body.append(0)                          // section_id = session
        appendWireString8(&body, "Crashed session")
        body.append(1)                          // item_count
        body.append(0)                          // kind = resume
        appendWireString8(&body, "resume")      // id
        appendWireString16(&body, "restore session")
        appendWireString16(&body, "4 files")
        appendWireString8(&body, "r")           // jump_key
        appendWireString8(&body, "")            // chord
        appendWireString8(&body, "\u{f0453}")   // icon
        appendWireU32(&body, 0xFF8800)          // icon_color

        // Section 2: start (one action row with a chord)
        body.append(2)                          // section_id = start
        appendWireString8(&body, "Start")
        body.append(1)                          // item_count
        body.append(2)                          // kind = action
        appendWireString8(&body, "find_file")   // id
        appendWireString16(&body, "open file")
        appendWireString16(&body, "")
        appendWireString8(&body, "")            // jump_key
        appendWireString8(&body, "SPC f f")     // chord
        appendWireString8(&body, "\u{f0224}")   // icon
        appendWireU32(&body, 0)                 // icon_color = default

        var data = Data([OP_GUI_EMPTY_STATE])
        appendWireU16(&data, UInt16(body.count))
        data.append(body)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiEmptyState(let visible, let crashed, let version, let focusedId, let sections) = cmd else {
            Issue.record("Expected .guiEmptyState, got \(String(describing: cmd))")
            return
        }

        #expect(visible)
        #expect(crashed)
        #expect(version == "v0.9")
        #expect(focusedId == "resume")
        #expect(sections.count == 2)

        let session = sections[0]
        #expect(session.sectionId == 0)
        #expect(session.title == "Crashed session")
        #expect(session.items.count == 1)
        let resume = session.items[0]
        #expect(resume.kind == 0)
        #expect(resume.id == "resume")
        #expect(resume.label == "restore session")
        #expect(resume.detail == "4 files")
        #expect(resume.jumpKey == "r")
        #expect(resume.chord.isEmpty)
        #expect(resume.iconColorRGB == 0xFF8800)

        let start = sections[1]
        #expect(start.sectionId == 2)
        let action = start.items[0]
        #expect(action.kind == 2)
        #expect(action.id == "find_file")
        #expect(action.label == "open file")
        #expect(action.jumpKey.isEmpty)
        #expect(action.chord == "SPC f f")
        #expect(action.iconColorRGB == 0)
    }

    @Test("Decode hidden gui_empty_state single-byte payload")
    func decodeGuiEmptyStateHidden() throws {
        var data = Data([OP_GUI_EMPTY_STATE])
        appendWireU16(&data, 1)
        data.append(0)  // visible = 0

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiEmptyState(let visible, _, _, _, let sections) = cmd else {
            Issue.record("Expected .guiEmptyState, got \(String(describing: cmd))")
            return
        }
        #expect(!visible)
        #expect(sections.isEmpty)
    }

    @Test("Decode gui_edit_timeline file summaries")
    func decodeGuiEditTimelineFiles() throws {
        var payload = Data([1])
        appendWireU16(&payload, 0xFFFF)
        payload.append(1)
        payload.append(0)
        appendWireString8(&payload, "write_file")
        appendWireU32(&payload, 12)
        payload.append(1)
        appendWireString16(&payload, "lib/a.ex")
        payload.append(2)
        appendWireU32(&payload, 10)
        appendWireU32(&payload, 3)
        payload.append(1)

        var data = Data([OP_GUI_EDIT_TIMELINE])
        appendWireU16(&data, UInt16(payload.count))
        data.append(payload)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == data.count)
        guard case .guiEditTimeline(let visible, let viewingIndex, let entries, let files) = cmd else {
            Issue.record("Expected .guiEditTimeline, got \(String(describing: cmd))")
            return
        }

        #expect(visible)
        #expect(viewingIndex == 0xFFFF)
        #expect(entries.count == 1)
        #expect(entries[0].index == 0)
        #expect(entries[0].toolName == "write_file")
        #expect(entries[0].timestampDelta == 12)
        #expect(files.count == 1)
        #expect(files[0].path == "lib/a.ex")
        #expect(files[0].entryCount == 2)
        #expect(files[0].linesAdded == 10)
        #expect(files[0].linesRemoved == 3)
        #expect(files[0].reviewStatus == 1)
    }

    @Test("Skip known sized command without renderer handler")
    func skipKnownSizedCommandWithoutRendererHandler() throws {
        let data = Data([OP_GUI_SURFACE_LAYOUT, 0x01, 0x01, 0x00, 0x00, OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 0])

        let (ignored, size) = try decodeCommand(data: data, offset: 0)
        guard case nil = ignored else {
            Issue.record("Expected gui_surface_layout to be skipped, got \(String(describing: ignored))")
            return
        }
        #expect(size == 5)

        let (next, _) = try decodeCommand(data: data, offset: size)
        guard case .commitFrame(let frameSeq, _) = next else {
            Issue.record("Expected trailing .commitFrame, got \(String(describing: next))")
            return
        }
        #expect(frameSeq == 7)
    }

    // Per-frontend framing contract (generalized from PR #2347).
    //
    // Why this exists: three times in this project's history a hand-written framing
    // authority drifted from the generated schema and desynced a frontend's command
    // stream. PR #2347 was the third: this decoder's deleted fallback assumed unknown
    // 0x90+ opcodes were len16-prefixed, mis-sized the sectioned gui_surface_layout
    // (0xA4), corrupted the stream, and looped the loader. The generated commandSize
    // table is now the single framing authority. skipKnownSizedCommandWithoutRendererHandler
    // above covers ONE opcode; this test generalizes it across EVERY beam_to_frontend
    // opcode the live decodeCommand path frames so a fourth instance is impossible.
    //
    // What it asserts: for every framed opcode, a minimal payload followed by a
    // commit_frame sentinel must be consumed EXACTLY to the sentinel boundary by the
    // live decodeCommand, and the sentinel must decode as the next command. A sizer
    // that fell back to data.count on truncation would swallow the commit_frame and
    // fail (the #2322 sentinel guarantee).
    //
    // How opcodes are enumerated (self-updating on schema regen): the test parses the
    // generated opcode constants file (ProtocolOpcodes.generated.swift: `let OP_* :
    // UInt8 = 0x..`) for the full real opcode set, located relative to this source via
    // #filePath. There is no hand-maintained opcode list to rot; a new opcode added to
    // docs/protocol_schema.toml regenerates that file and enters this loop. Each opcode
    // is then classified through the live commandSize: .sized/.custom opcodes are framed
    // by the renderer path; .unknown opcodes are input/parser-response opcodes the
    // renderer never frames and are skipped.
    //
    // How minimal payloads are synthesized: a single zero-fill synthesizer, framing-kind
    // agnostic. For each framed opcode it searches the smallest zero-filled body
    // (opcode + N zero bytes) such that decodeCommand frames it to exactly its own length
    // and the appended commit_frame decodes intact. Zero bytes mean zero section/array
    // counts and zero-length strings, so the search converges on each opcode's true
    // minimal bounded frame for both generated-sized framings (fixed / len16 / len32 /
    // sectioned) and the custom decoders this file still owns (set_font, gui_git_status,
    // the parser commands, etc.). Opcodes whose decoder requires a nonzero length prefix
    // go in minimalBodyOverrides.
    //
    // FAILURE BY DEFAULT IS THE POINT: a new opcode that no zero-filled body within the
    // probe bound can frame (a new custom needing nonzero structure, or a real
    // mis-framing) fails this test loudly by name. Fix the framing or add an override;
    // do not silence it.
    @Test("Framing contract: every beam_to_frontend opcode is exactly framed")
    func framingContractEveryFramedOpcode() throws {
        let opcodes = try Self.loadGeneratedOpcodes()
        #expect(opcodes.count > 30, "opcode enumeration parsed too few constants; the generated format may have changed")

        var framed = 0
        for op in opcodes {
            // Classify each opcode by its framing kind on a minimal zero body. The two
            // framing layers have different authorities and so are asserted differently:
            //
            //   .sized  -> the generated commandSize table is the authority and frames
            //              the opcode from its length fields alone, no decoder needed.
            //              An all-zero body gives zero length fields, i.e. the minimal
            //              frame, for every fixed / len16 / len32 / sectioned opcode,
            //              including ones whose hand decoder rejects empty content (the
            //              decoder's content validation is orthogonal to framing). This
            //              is the exact #2347 class: a sized-but-unhandled opcode that
            //              must be skipped by its commandSize size, not a guessed one.
            //
            //   .custom -> the opcode uses bespoke framing; its live decoder owns sizing.
            //              Here the live decodeCommand IS the framing authority, so the
            //              contract drives it directly (zero-fill search, or an override
            //              for a content-strict custom).
            //
            //   .unknown -> input / parser-response opcode the renderer never frames.
            //   .incomplete -> only on a truncated probe; the probe is generously sized
            //                  so this means the opcode is not a real framed command.
            let probe = [op.value] + [UInt8](repeating: 0, count: Self.maxMinimalBodyProbe)
            switch commandSize(probe) {
            case .sized:
                framed += 1
                Self.assertSizedFramesToSentinel(op: op)
            case .custom:
                framed += 1
                guard let body = Self.minimalCustomBody(for: op.value) else {
                    Issue.record("custom opcode \(op.name) (0x\(String(op.value, radix: 16))) is framed by the renderer but no minimal zero-filled body within \(Self.maxMinimalBodyProbe) bytes yields an exact live frame; its decoder likely mis-frames or needs nonzero structure. Fix the framing or add an entry to minimalBodyOverrides.")
                    continue
                }
                Self.assertCustomFramesToSentinel(op: op, body: body)
            case .unknown, .incomplete:
                continue
            }
        }

        #expect(framed > 30, "discovered too few framed opcodes; classification silently broke")
    }

    // commit_frame is a complete fixed:9 command appended as the sentinel.
    static let commitFrameSentinel: [UInt8] = [OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 0]

    // Bounds the zero-fill search for custom opcodes. The largest known minimal bounded
    // custom frame is well under this; a failed search stays fast and unambiguous.
    static let maxMinimalBodyProbe = 64

    // Hand-built minimal bodies for CUSTOM opcodes whose live decoder rejects an all-zero
    // body and requires a nonzero inner length field. Keyed by opcode value. Empty today;
    // a new custom opcode that needs nonzero structure goes here, and until it does the
    // contract fails and names it.
    static let minimalBodyOverrides: [UInt8: [UInt8]] = [:]

    // assertSizedFramesToSentinel asserts the generated commandSize authority frames a
    // sized opcode exactly. The body is a zero-filled command of the authority's own
    // size (zero length fields = minimal). The trailing commit_frame must then size as
    // its own 9-byte command: a sizer that fell back to data.count on this minimal body
    // would consume the sentinel and fail (the #2322 sentinel guarantee).
    static func assertSizedFramesToSentinel(op: GeneratedOpcode) {
        let label = "\(op.name) (0x\(String(op.value, radix: 16)))"
        // Resolve the authority's size for a minimal zero body of this opcode.
        let probe = [op.value] + [UInt8](repeating: 0, count: maxMinimalBodyProbe)
        guard case .sized(let size) = commandSize(probe), size >= 1, size <= 1 + maxMinimalBodyProbe else {
            Issue.record("\(label): expected a sized framing on a minimal body")
            return
        }
        var body = [UInt8](repeating: 0, count: size)
        body[0] = op.value

        let framed = body + commitFrameSentinel
        guard case .sized(let framedFirst) = commandSize(framed), framedFirst == size else {
            Issue.record("\(label): commandSize re-framed the minimal body to a different size with the sentinel appended; the framing is not stable")
            return
        }
        // The sentinel must remain an intact, separately-sized commit_frame.
        let trailing = Array(framed[size...])
        guard case .sized(let sentinelSize) = commandSize(trailing), sentinelSize == commitFrameSentinel.count else {
            Issue.record("\(label): the trailing commit_frame did not size as a standalone 9-byte command (got \(commandSize(trailing))); the opcode frame over-read into the sentinel")
            return
        }

        // And the live decodeCommand must advance by exactly that size: a sized opcode
        // is either decoded or skipped, but never consumes past its commandSize bound.
        // A content-strict decoder may throw .malformed on this synthetic minimal body;
        // that is a content concern, not a framing one, so only a size mismatch fails.
        if let (_, liveSize) = try? decodeCommand(data: Data(framed), offset: 0) {
            if liveSize != size {
                Issue.record("\(label): live decodeCommand advanced \(liveSize) bytes, want \(size) (the commandSize authority); the live path disagrees with the framing table")
            }
        }
    }

    static func minimalCustomBody(for opcode: UInt8) -> [UInt8]? {
        if let override = minimalBodyOverrides[opcode] {
            return customFramesExactly(override) ? override : nil
        }
        for n in 0...maxMinimalBodyProbe {
            var candidate = [UInt8](repeating: 0, count: 1 + n)
            candidate[0] = opcode
            if customFramesExactly(candidate) {
                return candidate
            }
        }
        return nil
    }

    // customFramesExactly reports whether a custom body ++ commit_frame decodes through
    // the live path as exactly [body's command, commit_frame]: the first command consumes
    // exactly body.count and the trailing 9 bytes decode as commit_frame. A decoder that
    // throws on a too-short probe, or mis-sizes and swallows the sentinel, returns false
    // so the search continues; a length that genuinely frames converges.
    static func customFramesExactly(_ body: [UInt8]) -> Bool {
        let data = Data(body + commitFrameSentinel)
        guard let (_, size) = try? decodeCommand(data: data, offset: 0) else { return false }
        guard size == body.count else { return false }
        guard let (next, _) = try? decodeCommand(data: data, offset: size) else { return false }
        if case .commitFrame = next { return true }
        return false
    }

    static func assertCustomFramesToSentinel(op: GeneratedOpcode, body: [UInt8]) {
        let data = Data(body + commitFrameSentinel)
        let label = "\(op.name) (0x\(String(op.value, radix: 16)))"
        do {
            let (_, size) = try decodeCommand(data: data, offset: 0)
            guard size == body.count else {
                Issue.record("\(label): live decoder framed to \(size) bytes, want \(body.count); the custom opcode was mis-sized and swallowed or split the commit_frame sentinel")
                return
            }
            let (next, _) = try decodeCommand(data: data, offset: size)
            guard case .commitFrame = next else {
                Issue.record("\(label): trailing command is \(String(describing: next)), want .commitFrame; the custom frame did not stop at the sentinel boundary")
                return
            }
        } catch {
            Issue.record("\(label): live decode threw while framing a minimal custom payload: \(error)")
        }
    }

    struct GeneratedOpcode {
        let name: String
        let value: UInt8
    }

    // loadGeneratedOpcodes parses the generated opcode constants for the real opcode
    // set. The file is located relative to this test source (#filePath) so the list
    // tracks whatever `mix protocol.gen` last wrote.
    static func loadGeneratedOpcodes() throws -> [GeneratedOpcode] {
        // .../macos/Tests/MingaTests/ProtocolTests.swift -> .../macos/.generated/protocol/ProtocolOpcodes.generated.swift
        let testFile = URL(fileURLWithPath: #filePath)
        let generated = testFile
            .deletingLastPathComponent()  // MingaTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .appendingPathComponent(".generated/protocol/ProtocolOpcodes.generated.swift")

        let source = try String(contentsOf: generated, encoding: .utf8)

        // Matches: let OP_FOO: UInt8 = 0x1A   (only OP_-prefixed UInt8 wire opcodes;
        // GUI_ACTION_* sub-opcodes and PROTOCOL_VERSION are excluded by the pattern).
        let pattern = #"let\s+(OP_[A-Z0-9_]+)\s*:\s*UInt8\s*=\s*(0x[0-9A-Fa-f]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let full = NSRange(source.startIndex..<source.endIndex, in: source)

        var opcodes: [GeneratedOpcode] = []
        var seen = Set<UInt8>()
        regex.enumerateMatches(in: source, range: full) { match, _, _ in
            guard let match,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source),
                  let value = UInt8(String(source[valueRange]).dropFirst(2), radix: 16)
            else { return }
            if seen.insert(value).inserted {
                opcodes.append(GeneratedOpcode(name: String(source[nameRange]), value: value))
            }
        }
        return opcodes
    }

    @Test("Decode protocol_error command")
    func decodeProtocolError() throws {
        let message = "protocol_version mismatch: frontend 1, beam 2"
        let messageBytes = Array(message.utf8)
        var data = Data([OP_PROTOCOL_ERROR, UInt8(messageBytes.count >> 8), UInt8(messageBytes.count & 0xFF)])
        data.append(contentsOf: messageBytes)
        // A trailing commit_frame proves the len16 frame is bounded.
        data.append(contentsOf: [OP_COMMIT_FRAME, 0, 0, 0, 0, 0, 0, 0, 0])

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 3 + messageBytes.count)
        guard case .protocolError(let decoded) = cmd else {
            Issue.record("Expected .protocolError, got \(String(describing: cmd))")
            return
        }
        #expect(decoded == message)

        // The next command must still decode from the bounded offset.
        let (next, _) = try decodeCommand(data: data, offset: size)
        guard case .commitFrame = next else {
            Issue.record("Expected trailing .commitFrame, got \(String(describing: next))")
            return
        }
    }

    @Test("Decode protocol_error rejects truncated payloads")
    func decodeProtocolErrorTruncated() {
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: Data([OP_PROTOCOL_ERROR, 0x00]), offset: 0)
        }
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: Data([OP_PROTOCOL_ERROR, 0x00, 0x05, 0x68, 0x69]), offset: 0)
        }
    }

    @Test("Decode set_cursor_shape command")
    func decodeSetCursorShape() throws {
        let data = Data([OP_SET_CURSOR_SHAPE, CURSOR_BEAM])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 2)
        guard case .setCursorShape(let shape) = cmd else {
            Issue.record("Expected .setCursorShape, got \(String(describing: cmd))")
            return
        }
        #expect(shape == .beam)
    }

    @Test("Decode gui_cursor_animation command")
    func decodeGuiCursorAnimation() throws {
        let data = Data([OP_GUI_CURSOR_ANIMATION, 0x00, 0x01, 0x00])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 4)
        guard case .guiCursorAnimation(let enabled) = cmd else {
            Issue.record("Expected .guiCursorAnimation, got \(String(describing: cmd))")
            return
        }
        #expect(enabled == false)
    }

    @Test("Decode gui_sidebars command")
    func decodeGuiSidebars() throws {
        var payload = Data()
        payload.append(1)
        appendConfigStateU16(&payload, 2)
        appendConfigStateString16(&payload, "file_tree")

        appendConfigStateString16(&payload, "file_tree")
        appendConfigStateString16(&payload, "File Tree")
        appendConfigStateString16(&payload, "file_tree")
        appendConfigStateString16(&payload, "folder")
        appendConfigStateU16(&payload, 10)
        payload.append(0x03)
        appendConfigStateU16(&payload, 32)
        appendConfigStateU16(&payload, UInt16.max)

        appendConfigStateString16(&payload, "git_status")
        appendConfigStateString16(&payload, "Git Status")
        appendConfigStateString16(&payload, "git_status")
        appendConfigStateString16(&payload, "point.3.filled.connected.trianglepath.dotted")
        appendConfigStateU16(&payload, 20)
        payload.append(0x00)
        appendConfigStateU16(&payload, 30)
        appendConfigStateU16(&payload, 7)

        var encoded = Data([OP_GUI_SIDEBARS])
        appendConfigStateU32(&encoded, UInt32(payload.count))
        encoded.append(payload)

        let (cmd, size) = try decodeCommand(data: encoded, offset: 0)
        #expect(size == encoded.count)
        guard case .guiSidebars(let version, let activeId, let sidebars) = cmd else {
            Issue.record("Expected .guiSidebars, got \(String(describing: cmd))")
            return
        }
        #expect(version == 1)
        #expect(activeId == "file_tree")
        #expect(sidebars.count == 2)
        #expect(sidebars[0].id == "file_tree")
        #expect(sidebars[0].visible)
        #expect(sidebars[0].focused)
        #expect(sidebars[0].badgeCount == nil)
        #expect(sidebars[1].id == "git_status")
        #expect(sidebars[1].badgeCount == 7)
    }

    @Test("Decode gui_config_state command")
    func decodeGuiConfigState() throws {
        var payload = Data()
        appendConfigStateU16(&payload, 3)
        appendConfigStateString8(&payload, "theme")
        appendConfigStateValue(&payload, .atom("doom_one"))
        appendConfigStateString8(&payload, "font_size")
        appendConfigStateValue(&payload, .int(14))
        appendConfigStateString8(&payload, "cursor_blink")
        appendConfigStateValue(&payload, .bool(true))

        appendConfigStateU16(&payload, 1)
        appendConfigStateString8(&payload, "Doom One")
        appendConfigStateString8(&payload, "doom_one")
        payload.append(contentsOf: [0x28, 0x2C, 0x34, 0xBB, 0xC2, 0xCF, 0x51, 0xAF, 0xEF])

        appendConfigStateU16(&payload, 1)
        appendConfigStateString8(&payload, "normal")
        appendConfigStateString16(&payload, "SPC f f")
        appendConfigStateString16(&payload, "find_file")
        appendConfigStateString16(&payload, "Find file")

        var encoded = Data([OP_GUI_CONFIG_STATE])
        appendConfigStateU16(&encoded, UInt16(payload.count))
        encoded.append(payload)

        let (cmd, size) = try decodeCommand(data: encoded, offset: 0)
        #expect(size == encoded.count)
        guard case .guiConfigState(let state) = cmd else {
            Issue.record("Expected .guiConfigState, got \(String(describing: cmd))")
            return
        }

        #expect(state.options["theme"] == .atom("doom_one"))
        #expect(state.options["font_size"] == .int(14))
        #expect(state.options["cursor_blink"] == .bool(true))
        #expect(state.themePreviews.count == 1)
        #expect(state.keybindings.count == 1)
        #expect(state.themePreviews[0].name == "Doom One")
        #expect(state.keybindings[0].key == "SPC f f")
    }

    @Test("Decode gui_notifications command")
    func decodeGuiNotifications() throws {
        var payload = Data()
        payload.append(1)
        appendConfigStateU16(&payload, 1)
        appendConfigStateString16(&payload, "build:test")
        payload.append(2)
        payload.append(1)
        appendConfigStateU64(&payload, 1_715_000_000)
        appendConfigStateU64(&payload, 1_715_000_030)
        appendConfigStateU32(&payload, UInt32.max)
        appendConfigStateString16(&payload, "Build failed")
        appendConfigStateString16(&payload, "mix test exited with code 1")
        appendConfigStateString16(&payload, "Build")
        payload.append(1)
        appendConfigStateString16(&payload, "show_logs")
        appendConfigStateString16(&payload, "Show logs")

        var encoded = Data([OP_GUI_NOTIFICATIONS])
        appendConfigStateU16(&encoded, UInt16(payload.count))
        encoded.append(payload)

        let (cmd, size) = try decodeCommand(data: encoded, offset: 0)
        #expect(size == encoded.count)
        guard case .guiNotifications(let notifications) = cmd else {
            Issue.record("Expected .guiNotifications, got \(String(describing: cmd))")
            return
        }

        #expect(notifications.count == 1)
        #expect(notifications[0].id == "build:test")
        #expect(notifications[0].createdAt == 1_715_000_000)
        #expect(notifications[0].updatedAt == 1_715_000_030)
        #expect(notifications[0].title == "Build failed")
        #expect(notifications[0].dismissable)
        #expect(notifications[0].actions[0].label == "Show logs")
    }

    @Test("Decode multiple commands in one payload")
    func decodeMultipleCommands() throws {
        // Transport survivors only: set_cursor_shape(2) + set_window_bg(4) + commit_frame(9).
        var data = Data()
        data.append(OP_SET_CURSOR_SHAPE)
        data.append(CURSOR_BLOCK)
        data.append(OP_SET_WINDOW_BG)
        data.append(contentsOf: [0x28, 0x2C, 0x34])
        data.append(OP_COMMIT_FRAME)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // commit_frame frame_seq + echoed input_seq (fixed:9, #2219/#2215)

        var commands: [RenderCommand] = []
        try decodeCommands(from: data) { cmd in
            commands.append(cmd)
        }
        #expect(commands.count == 3)
    }

    @Test("Decode set_window_bg command")
    func decodeSetWindowBg() throws {
        let data = Data([OP_SET_WINDOW_BG, 0x28, 0x2C, 0x34])
        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 4)
        guard case .setWindowBg(let r, let g, let b) = cmd else {
            Issue.record("Expected .setWindowBg, got \(String(describing: cmd))")
            return
        }
        #expect(r == 0x28)
        #expect(g == 0x2C)
        #expect(b == 0x34)
    }

    @Test("Decode set_font command with ligatures enabled, regular weight")
    func decodeSetFont() throws {
        var data = Data()
        data.append(OP_SET_FONT)
        data.append(contentsOf: [0x00, 0x0E]) // size=14
        data.append(0x02) // weight=regular
        data.append(0x01) // ligatures=true
        let name = "JetBrains Mono"
        data.append(contentsOf: [UInt8(name.utf8.count >> 8), UInt8(name.utf8.count & 0xFF)])
        data.append(contentsOf: name.utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(size == 1 + 6 + name.utf8.count)
        guard case .setFont(let family, let fontSize, let ligatures, let weight) = cmd else {
            Issue.record("Expected .setFont, got \(String(describing: cmd))")
            return
        }
        #expect(family == "JetBrains Mono")
        #expect(fontSize == 14)
        #expect(weight == 2)
        #expect(ligatures == true)
    }

    @Test("Decode set_font command with ligatures disabled, bold weight")
    func decodeSetFontNoLigatures() throws {
        var data = Data()
        data.append(OP_SET_FONT)
        data.append(contentsOf: [0x00, 0x0D]) // size=13
        data.append(0x05) // weight=bold
        data.append(0x00) // ligatures=false
        let name = "Menlo"
        data.append(contentsOf: [0x00, UInt8(name.utf8.count)])
        data.append(contentsOf: name.utf8)

        let (cmd, _) = try decodeCommand(data: data, offset: 0)
        guard case .setFont(let family, let fontSize, let ligatures, let weight) = cmd else {
            Issue.record("Expected .setFont, got \(String(describing: cmd))")
            return
        }
        #expect(family == "Menlo")
        #expect(fontSize == 13)
        #expect(weight == 5)
        #expect(ligatures == false)
    }

    @Test("Skip highlight opcodes without error")
    func skipHighlightOpcodes() throws {
        // set_language with buffer_id=1 and name "elixir"
        var data = Data()
        data.append(OP_SET_LANGUAGE)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // buffer_id=1
        data.append(contentsOf: [0x00, 0x06]) // name_len=6
        data.append(contentsOf: "elixir".utf8)

        let (cmd, size) = try decodeCommand(data: data, offset: 0)
        #expect(cmd == nil) // Skipped
        #expect(size == 13) // 1 + 4 + 2 + 6
    }
}

@Suite("Protocol Encoder")
struct ProtocolEncoderTests {
    // Encoder writes to stdout, so we test the binary layout indirectly
    // by verifying the ready event structure.
    @Test("Ready event has correct size")
    func readyEventSize() {
        // The ready payload is 29 bytes in capability format 2:
        // opcode:1, cols:2, rows:2, caps_version:1, caps_len:1, fields:20, protocol:2
        // Total frame: 4 (length prefix) + 29 = 33 bytes.
        // We can't easily capture stdout in tests, but we verify the
        // constants are correct.
        #expect(CAPS_VERSION == 2)
        #expect(FRONTEND_NATIVE_GUI == 1)
        #expect(COLOR_RGB == 2)
        #expect(SEMANTIC_UI_ENABLED == 1)
    }

    @Test("Paste event opcode matches protocol constant")
    func pasteEventOpcode() {
        #expect(OP_PASTE_EVENT == 0x06)
    }
}

@Suite("Paste Event Encoder")
struct PasteEventEncoderTests {
    @Test("sendPasteEvent records call with correct text")
    func sendPasteBasic() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "hello\nworld\nline 3")
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == "hello\nworld\nline 3")
    }

    @Test("sendPasteEvent with empty text")
    func sendPasteEmpty() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "")
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == "")
    }

    @Test("sendPasteEvent with unicode text")
    func sendPasteUnicode() {
        let spy = SpyEncoder()
        let text = "こんにちは\n🎉 emoji\n中文"
        spy.sendPasteEvent(text: text)
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == text)
    }

    @Test("sendPasteEvent with single line")
    func sendPasteSingleLine() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "just one line")
        #expect(spy.pasteCalls.count == 1)
        #expect(spy.pasteCalls[0].text == "just one line")
    }

    @Test("multiple paste events accumulate correctly")
    func sendPasteMultiple() {
        let spy = SpyEncoder()
        spy.sendPasteEvent(text: "first paste\nwith lines")
        spy.sendPasteEvent(text: "second paste")
        #expect(spy.pasteCalls.count == 2)
        #expect(spy.pasteCalls[0].text == "first paste\nwith lines")
        #expect(spy.pasteCalls[1].text == "second paste")
    }
}

// MARK: - Spy encoder for testing resize behavior

/// Spy that records all InputEncoder calls for test assertions.
///
/// Uses OSAllocatedUnfairLock so it satisfies Sendable without @unchecked.
/// GUI action calls are recorded as GUIAction enum values, allowing tests
/// to verify that view interactions send the correct protocol events.
final class SpyEncoder: InputEncoder, Sendable {
    struct Resize: Sendable { let cols: UInt16; let rows: UInt16 }
    struct Ready: Sendable { let cols: UInt16; let rows: UInt16 }
    struct Log: Sendable { let level: UInt8; let message: String }
    struct Paste: Sendable { let text: String }
    struct KeyPress: Sendable { let codepoint: UInt32; let modifiers: UInt8 }
    struct PickerQuery: Sendable, Equatable { let generation: UInt32; let editSeq: UInt32; let text: String }
    struct MouseEvent: Sendable { let row: Int16; let col: Int16; let button: UInt8; let modifiers: UInt8; let eventType: UInt8; let clickCount: UInt8 }

    /// Recorded GUI action events. Each sendFoo() call appends one entry.
    enum GUIAction: Sendable, Equatable {
        case selectTab(id: UInt32)
        case closeTab(id: UInt32)
        case tabCopyPath(id: UInt32)
        case tabReorder(id: UInt32, newIndex: UInt16)
        case tabPin(id: UInt32)
        case tabUnpin(id: UInt32)
        case tabMoveLeft(id: UInt32)
        case tabMoveRight(id: UInt32)
        case hoverOpenAction
        case fileTreeClick(index: UInt16)
        case fileTreeToggle(index: UInt16)
        case fileTreeOpenInSplit(index: UInt16)
        case fileTreeNewFile(parentIndex: UInt16)
        case fileTreeNewFolder(parentIndex: UInt16)
        case fileTreeEditConfirm(text: String)
        case fileTreeEditCancel
        case fileTreeDelete(index: UInt16)
        case fileTreeRename(index: UInt16)
        case fileTreeDuplicate(index: UInt16)
        case fileTreeMove(sourceIndex: UInt16, targetDirIndex: UInt16)
        case fileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetId: String, targetPathHash: UInt32, targetPath: String, targetIsDir: Bool, modifiers: UInt8)
        case fileTreeCollapseAll
        case fileTreeRefresh
        case completionSelect(index: UInt16)
        case breadcrumbClick(index: UInt8)
        case togglePanel(panel: UInt8)
        case sidebarAction(sidebarId: String, kind: String, action: String)
        case newTab
        case systemWillSleep
        case systemDidWake
        case systemWillUnmount(volumePath: String)
        case cmdCopy
        case cmdCut
        case panelSwitchTab(index: UInt8)
        case panelDismiss
        case panelResize(heightPercent: UInt8)
        case openFile(path: String)
        case toolInstall(name: String)
        case toolUninstall(name: String)
        case toolUpdate(name: String)
        case toolDismiss
        case agentToolToggle(messageID: UInt32)
        case executeCommand(name: String)
        case minibufferSelect(index: UInt16)


        case gitStageFile(path: String)
        case gitUnstageFile(path: String)
        case gitDiscardFile(path: String)
        case gitStageAll
        case gitUnstageAll
        case gitCommit(message: String)
        case gitOpenFile(path: String)
        case gitOpenDiff(path: String, section: UInt8)
        case gitPush
        case gitPull
        case gitFetch
        case gitCommitAmend(message: String)
        case gitPullAndRetry
        case foldToggleAtLine(windowId: UInt16, bufferLine: UInt32)
        case observatoryInspect(pid: String)
        case chatScrolledAwayFromBottom
        case chatReturnedToBottom
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    struct State: Sendable {
        var resizeCalls: [Resize] = []
        var readyCalls: [Ready] = []
        var logCalls: [Log] = []
        var pasteCalls: [Paste] = []
        var keyPressCalls: [KeyPress] = []
        var pickerQueryCalls: [PickerQuery] = []
        var mouseEventCalls: [MouseEvent] = []
        var guiActions: [GUIAction] = []
    }

    var resizeCalls: [Resize] { state.withLock { $0.resizeCalls } }
    var readyCalls: [Ready] { state.withLock { $0.readyCalls } }
    var logCalls: [Log] { state.withLock { $0.logCalls } }
    var pasteCalls: [Paste] { state.withLock { $0.pasteCalls } }
    var keyPressCalls: [KeyPress] { state.withLock { $0.keyPressCalls } }
    var pickerQueryCalls: [PickerQuery] { state.withLock { $0.pickerQueryCalls } }
    var mouseEventCalls: [MouseEvent] { state.withLock { $0.mouseEventCalls } }
    var guiActions: [GUIAction] { state.withLock { $0.guiActions } }

    func sendReady(cols: UInt16, rows: UInt16) {
        state.withLock { $0.readyCalls.append(Ready(cols: cols, rows: rows)) }
    }
    func sendKeyPress(codepoint: UInt32, modifiers: UInt8) {
        state.withLock { $0.keyPressCalls.append(KeyPress(codepoint: codepoint, modifiers: modifiers)) }
    }
    func sendPickerQueryChanged(generation: UInt32, editSeq: UInt32, text: String) {
        state.withLock { $0.pickerQueryCalls.append(PickerQuery(generation: generation, editSeq: editSeq, text: text)) }
    }
    func sendResize(cols: UInt16, rows: UInt16) {
        state.withLock { $0.resizeCalls.append(Resize(cols: cols, rows: rows)) }
    }
    func sendMouseEvent(row: Int16, col: Int16, button: UInt8, modifiers: UInt8, eventType: UInt8, clickCount: UInt8 = 1) {
        state.withLock { $0.mouseEventCalls.append(MouseEvent(row: row, col: col, button: button, modifiers: modifiers, eventType: eventType, clickCount: clickCount)) }
    }
    func sendPasteEvent(text: String) {
        state.withLock { $0.pasteCalls.append(Paste(text: text)) }
    }
    func sendLog(level: UInt8, message: String) {
        state.withLock { $0.logCalls.append(Log(level: level, message: message)) }
    }

    // GUI actions: all recorded for test assertions
    func sendSelectTab(id: UInt32) { state.withLock { $0.guiActions.append(.selectTab(id: id)) } }
    func sendCloseTab(id: UInt32) { state.withLock { $0.guiActions.append(.closeTab(id: id)) } }
    func sendTabCopyPath(id: UInt32) { state.withLock { $0.guiActions.append(.tabCopyPath(id: id)) } }
    func sendTabReorder(id: UInt32, newIndex: UInt16) { state.withLock { $0.guiActions.append(.tabReorder(id: id, newIndex: newIndex)) } }
    func sendTabPin(id: UInt32) { state.withLock { $0.guiActions.append(.tabPin(id: id)) } }
    func sendTabUnpin(id: UInt32) { state.withLock { $0.guiActions.append(.tabUnpin(id: id)) } }
    func sendTabMoveLeft(id: UInt32) { state.withLock { $0.guiActions.append(.tabMoveLeft(id: id)) } }
    func sendTabMoveRight(id: UInt32) { state.withLock { $0.guiActions.append(.tabMoveRight(id: id)) } }
    func sendHoverOpenAction() { state.withLock { $0.guiActions.append(.hoverOpenAction) } }
    func sendFileTreeClick(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeClick(index: index)) } }
    func sendFileTreeToggle(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeToggle(index: index)) } }
    func sendFileTreeOpenInSplit(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeOpenInSplit(index: index)) } }
    func sendFileTreeNewFile(parentIndex: UInt16) { state.withLock { $0.guiActions.append(.fileTreeNewFile(parentIndex: parentIndex)) } }
    func sendFileTreeNewFolder(parentIndex: UInt16) { state.withLock { $0.guiActions.append(.fileTreeNewFolder(parentIndex: parentIndex)) } }
    func sendFileTreeEditConfirm(text: String) { state.withLock { $0.guiActions.append(.fileTreeEditConfirm(text: text)) } }
    func sendFileTreeEditCancel() { state.withLock { $0.guiActions.append(.fileTreeEditCancel) } }
    func sendFileTreeDelete(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeDelete(index: index)) } }
    func sendFileTreeRename(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeRename(index: index)) } }
    func sendFileTreeDuplicate(index: UInt16) { state.withLock { $0.guiActions.append(.fileTreeDuplicate(index: index)) } }
    func sendFileTreeMove(sourceIndex: UInt16, targetDirIndex: UInt16) { state.withLock { $0.guiActions.append(.fileTreeMove(sourceIndex: sourceIndex, targetDirIndex: targetDirIndex)) } }
    func sendFileTreeDrop(sourcePaths: [String], targetIndex: UInt16, targetId: String, targetPathHash: UInt32, targetPath: String, targetIsDir: Bool, modifiers: UInt8) { state.withLock { $0.guiActions.append(.fileTreeDrop(sourcePaths: sourcePaths, targetIndex: targetIndex, targetId: targetId, targetPathHash: targetPathHash, targetPath: targetPath, targetIsDir: targetIsDir, modifiers: modifiers)) } }
    func sendFileTreeCollapseAll() { state.withLock { $0.guiActions.append(.fileTreeCollapseAll) } }
    func sendFileTreeRefresh() { state.withLock { $0.guiActions.append(.fileTreeRefresh) } }
    func sendCompletionSelect(index: UInt16) { state.withLock { $0.guiActions.append(.completionSelect(index: index)) } }
    func sendBreadcrumbClick(index: UInt8) { state.withLock { $0.guiActions.append(.breadcrumbClick(index: index)) } }
    func sendTogglePanel(panel: UInt8) { state.withLock { $0.guiActions.append(.togglePanel(panel: panel)) } }
    func sendSidebarAction(sidebarId: String, kind: String, action: String) { state.withLock { $0.guiActions.append(.sidebarAction(sidebarId: sidebarId, kind: kind, action: action)) } }
    func sendNewTab() { state.withLock { $0.guiActions.append(.newTab) } }
    func sendSystemWillSleep() { state.withLock { $0.guiActions.append(.systemWillSleep) } }
    func sendSystemDidWake() { state.withLock { $0.guiActions.append(.systemDidWake) } }
    func sendSystemWillUnmount(volumePath: String) { state.withLock { $0.guiActions.append(.systemWillUnmount(volumePath: volumePath)) } }
    func sendCmdCopy() { state.withLock { $0.guiActions.append(.cmdCopy) } }
    func sendCmdCut() { state.withLock { $0.guiActions.append(.cmdCut) } }
    func sendPanelSwitchTab(index: UInt8) { state.withLock { $0.guiActions.append(.panelSwitchTab(index: index)) } }
    func sendPanelDismiss() { state.withLock { $0.guiActions.append(.panelDismiss) } }
    func sendPanelResize(heightPercent: UInt8) { state.withLock { $0.guiActions.append(.panelResize(heightPercent: heightPercent)) } }
    func sendOpenFile(path: String) { state.withLock { $0.guiActions.append(.openFile(path: path)) } }
    func sendToolInstall(name: String) { state.withLock { $0.guiActions.append(.toolInstall(name: name)) } }
    func sendToolUninstall(name: String) { state.withLock { $0.guiActions.append(.toolUninstall(name: name)) } }
    func sendToolUpdate(name: String) { state.withLock { $0.guiActions.append(.toolUpdate(name: name)) } }
    func sendToolDismiss() { state.withLock { $0.guiActions.append(.toolDismiss) } }
    func sendAgentToolToggle(messageID: UInt32) { state.withLock { $0.guiActions.append(.agentToolToggle(messageID: messageID)) } }
    func sendExecuteCommand(name: String) { state.withLock { $0.guiActions.append(.executeCommand(name: name)) } }
    func sendMinibufferSelect(index: UInt16) { state.withLock { $0.guiActions.append(.minibufferSelect(index: index)) } }


    func sendGitStageFile(path: String) { state.withLock { $0.guiActions.append(.gitStageFile(path: path)) } }
    func sendGitUnstageFile(path: String) { state.withLock { $0.guiActions.append(.gitUnstageFile(path: path)) } }
    func sendGitDiscardFile(path: String) { state.withLock { $0.guiActions.append(.gitDiscardFile(path: path)) } }
    func sendGitStageAll() { state.withLock { $0.guiActions.append(.gitStageAll) } }
    func sendGitUnstageAll() { state.withLock { $0.guiActions.append(.gitUnstageAll) } }
    func sendGitCommit(message: String) { state.withLock { $0.guiActions.append(.gitCommit(message: message)) } }
    func sendGitOpenFile(path: String) { state.withLock { $0.guiActions.append(.gitOpenFile(path: path)) } }
    func sendGitOpenDiff(path: String, section: UInt8) { state.withLock { $0.guiActions.append(.gitOpenDiff(path: path, section: section)) } }
    func sendGitPush() { state.withLock { $0.guiActions.append(.gitPush) } }
    func sendGitPull() { state.withLock { $0.guiActions.append(.gitPull) } }
    func sendGitFetch() { state.withLock { $0.guiActions.append(.gitFetch) } }
    func sendGitCommitAmend(message: String) { state.withLock { $0.guiActions.append(.gitCommitAmend(message: message)) } }
    func sendGitPullAndRetry() { state.withLock { $0.guiActions.append(.gitPullAndRetry) } }
    func sendWorkspaceRename(id: UInt16, name: String) { state.withLock { $0.guiActions.append(.gitOpenFile(path: "rename:\(id):\(name)")) } }
    func sendWorkspaceSetIcon(id: UInt16, icon: String) { state.withLock { $0.guiActions.append(.gitOpenFile(path: "icon:\(id):\(icon)")) } }
    func sendWorkspaceClose(id: UInt16) { state.withLock { $0.guiActions.append(.gitOpenFile(path: "close-ws:\(id)")) } }
    func sendSpaceLeaderChord(codepoint: UInt32, modifiers: UInt8) { /* no-op for tests */ }
    func sendSpaceLeaderRetract(codepoint: UInt32, modifiers: UInt8) { /* no-op for tests */ }
    func sendFindPasteboardSearch(text: String, direction: UInt8) { /* no-op for tests */ }
    func sendAgentApprove() { /* no-op for tests */ }
    func sendAgentRequestChanges() { /* no-op for tests */ }
    func sendAgentDismiss() { /* no-op for tests */ }
    func sendChangeSummaryClick(index: UInt32) { /* no-op for tests */ }
    func sendScrollToLine(line: UInt32) { /* no-op for tests */ }
    func sendFoldToggleAtLine(windowId: UInt16, bufferLine: UInt32) {
        state.withLock { $0.guiActions.append(.foldToggleAtLine(windowId: windowId, bufferLine: bufferLine)) }
    }
    func sendObservatoryInspect(pid: String) {
        state.withLock { $0.guiActions.append(.observatoryInspect(pid: pid)) }
    }
    func sendChatScrolledAwayFromBottom() { state.withLock { $0.guiActions.append(.chatScrolledAwayFromBottom) } }
    func sendChatReturnedToBottom() { state.withLock { $0.guiActions.append(.chatReturnedToBottom) } }
}

@Suite("EditorNSView Resize")
struct EditorNSViewResizeTests {
    /// Helper to create an EditorNSView with CoreText renderer.
    @MainActor private func makeView(spy: SpyEncoder, cols: UInt16 = 80, rows: UInt16 = 24, scale: CGFloat = 1.0) -> EditorNSView? {
        let face = FontFace(name: "Menlo", size: 13.0, scale: scale)
        let fm = FontManager(name: "Menlo", size: 13.0, scale: scale)
        let guiState = GUIState()
        let disp = CommandDispatcher(cols: cols, rows: rows, guiState: guiState)
        guard let ctRenderer = CoreTextMetalRenderer() else { return nil }
        ctRenderer.setupRenderers(fontManager: fm)
        return EditorNSView(encoder: spy, fontFace: face, dispatcher: disp,
                            coreTextRenderer: ctRenderer, fontManager: fm)
    }

    @Test("setFrameSize sends resize when cell dimensions change")
    @MainActor func setFrameSizeSendsResize() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }
        let face = view.fontFace

        let newWidth = CGFloat(face.cellWidth) * 100
        let newHeight = CGFloat(face.cellHeight) * 40
        view.setFrameSize(NSSize(width: newWidth, height: newHeight))

        #expect(spy.resizeCalls.count == 1)
        #expect(spy.resizeCalls[0].cols == 100)
        #expect(spy.resizeCalls[0].rows == 40)
        #expect(view.dispatcher.frameState.cols == 100)
        #expect(view.dispatcher.frameState.rows == 40)
    }

    @Test("setFrameSize does not send resize when dimensions unchanged")
    @MainActor func setFrameSizeNoResizeWhenSame() throws {
        let spy = SpyEncoder()
        let face = FontFace(name: "Menlo", size: 13.0, scale: 1.0)
        let cols = UInt16(800 / CGFloat(face.cellWidth))
        let rows = UInt16(600 / CGFloat(face.cellHeight))
        guard let view = makeView(spy: spy, cols: cols, rows: rows) else { return }

        view.setFrameSize(NSSize(width: CGFloat(cols) * CGFloat(face.cellWidth),
                                  height: CGFloat(rows) * CGFloat(face.cellHeight)))

        #expect(spy.resizeCalls.isEmpty)
    }

    @Test("setFrameSize clamps to minimum 1x1")
    @MainActor func setFrameSizeClampsMinimum() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy) else { return }

        view.setFrameSize(NSSize(width: 1, height: 1))

        #expect(spy.resizeCalls.count == 1)
        #expect(spy.resizeCalls[0].cols >= 1)
        #expect(spy.resizeCalls[0].rows >= 1)
        #expect(view.dispatcher.frameState.cols >= 1)
        #expect(view.dispatcher.frameState.rows >= 1)
    }

    @Test("viewDidMoveToWindow corrects initial scale mismatch without sending ready early")
    @MainActor func viewDidMoveToWindowCorrectsInitialScaleMismatch() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy, scale: 0.5) else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var callbackScale: CGFloat?
        view.onScaleFactorChanged = { newScale in
            callbackScale = newScale
        }

        window.contentView = view
        defer { window.contentView = nil }

        let expectedScale = window.backingScaleFactor
        #expect(callbackScale == expectedScale)
        #expect((view.layer as? CAMetalLayer)?.contentsScale == expectedScale)
        #expect(spy.readyCalls.isEmpty)
    }

    @Test("viewDidChangeBackingProperties calls scale callback when scale differs")
    @MainActor func backingPropertyChangeCallsScaleCallback() throws {
        let spy = SpyEncoder()
        guard let view = makeView(spy: spy, scale: 0.5) else { return }
        view.setFrameSize(NSSize(width: 400, height: 300))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.contentView = nil }

        var callbackScale: CGFloat?
        view.onScaleFactorChanged = { newScale in
            callbackScale = newScale
        }

        let expectedScale = window.backingScaleFactor
        view.viewDidChangeBackingProperties()

        #expect(callbackScale == expectedScale)
        #expect((view.layer as? CAMetalLayer)?.contentsScale == expectedScale)
    }
}

@Suite("PortLogger")
struct PortLoggerTests {
    @Test("log calls are forwarded to the encoder")
    func logForwarding() {
        let spy = SpyEncoder()
        PortLogger.setup(encoder: spy)

        PortLogger.info("hello from test")

        #expect(spy.logCalls.count == 1)
        #expect(spy.logCalls[0].level == LOG_LEVEL_INFO)
        #expect(spy.logCalls[0].message == "hello from test")
    }

    @Test("all log levels are sent with the correct level byte")
    func logLevels() {
        let spy = SpyEncoder()
        PortLogger.setup(encoder: spy)

        PortLogger.error("e")
        PortLogger.warn("w")
        PortLogger.info("i")
        PortLogger.debug("d")

        #expect(spy.logCalls.count == 4)
        #expect(spy.logCalls[0].level == LOG_LEVEL_ERR)
        #expect(spy.logCalls[1].level == LOG_LEVEL_WARN)
        #expect(spy.logCalls[2].level == LOG_LEVEL_INFO)
        #expect(spy.logCalls[3].level == LOG_LEVEL_DEBUG)
    }

    @Test("sendLog binary layout matches Zig encodeLogMessage")
    func logBinaryLayout() {
        // Verify the real ProtocolEncoder produces the right binary.
        // We can't capture stdout easily, but we can verify the
        // constants match the Zig protocol.
        #expect(OP_LOG_MESSAGE == 0x60)
        #expect(LOG_LEVEL_ERR == 0)
        #expect(LOG_LEVEL_WARN == 1)
        #expect(LOG_LEVEL_INFO == 2)
        #expect(LOG_LEVEL_DEBUG == 3)
    }
}
