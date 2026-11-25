/// Tests for ProtocolEncoder binary layout.
///
/// Verifies the exact bytes the encoder writes to the wire match the
/// protocol spec. Uses a pipe to capture output instead of stdout.
/// Each test creates a fresh encoder, calls one method, reads the
/// {:packet, 4} framed output, and asserts the payload bytes.

import Testing
import Foundation
import MingaUI

/// Captures every framed byte written by the encoder.
private func captureWire(_ action: (ProtocolEncoder) -> Void) -> Data {
    let pipe = Pipe()
    let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)
    action(encoder)
    #expect(encoder.waitForPendingWritesForTesting())
    // Close write end so read doesn't block
    pipe.fileHandleForWriting.closeFile()
    return pipe.fileHandleForReading.readDataToEndOfFile()
}

/// Helper to read the first payload from a pipe-backed encoder.
private func captureFrame(_ action: (ProtocolEncoder) -> Void) -> Data {
    let raw = captureWire(action)
    // Strip the 4-byte length prefix to get the payload
    guard raw.count >= 4 else { return Data() }
    let len = Int(raw[0]) << 24 | Int(raw[1]) << 16 | Int(raw[2]) << 8 | Int(raw[3])
    guard raw.count >= 4 + len else { return Data() }
    return raw.subdata(in: 4..<(4 + len))
}

@Suite("Encoder Binary: Scroll Batch")
struct EncoderScrollBatchTests {
    @Test("vertical scroll batches still use the six-byte input layout", arguments: [Int16(257), -257])
    func verticalBatch(delta: Int16) {
        let direction: UInt8 = delta > 0 ? 0 : 1
        let payload = captureFrame {
            $0.send(.scrollBatch(windowID: 0x1234, deltaLines: delta, direction: direction))
        }
        #expect(payload == Data(delta > 0
            ? [0x09, 0x12, 0x34, 0x01, 0x01, 0]
            : [0x09, 0x12, 0x34, 0xFE, 0xFF, 1]))
    }

    @Test("horizontal pan carries a signed column delta followed by its intent sequence", arguments: [Int16(257), -257])
    func horizontalPan(delta: Int16) {
        let payload = captureFrame {
            #expect($0.send(.horizontalPan(windowID: 0x1234, deltaColumns: delta, inputSeq: 0x12345678)).wasAccepted)
        }
        #expect(payload == Data(delta > 0
            ? [0x12, 0x12, 0x34, 0x01, 0x01, 0x12, 0x34, 0x56, 0x78]
            : [0x12, 0x12, 0x34, 0xFE, 0xFF, 0x12, 0x34, 0x56, 0x78]))
    }
}

// MARK: - Search session

@Suite("Encoder Binary: Search Session")
struct EncoderSearchSessionTests {
    @Test("search focus carries only the requested mode")
    func focusLayout() {
        let payload = captureFrame { $0.send(.searchFocus(replaceMode: true)) }

        #expect(payload == Data([OP_GUI_ACTION, GUI_ACTION_SEARCH_FOCUS, 1]))
    }

    @Test("search query carries session, sequence, Unicode query, and complete options")
    func queryLayout() {
        let payload = captureFrame {
            $0.send(.searchQuery(sessionID: 7, editSequence: 3, query: "café λ", flags: SearchFlags.caseSensitive | SearchFlags.regex))
        }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_SEARCH_QUERY)
        #expect(readU32(payload, 2) == 7)
        #expect(readU32(payload, 6) == 3)
        let (query, nextOffset) = readString16(payload, 10)
        #expect(query == "café λ")
        #expect(payload[nextOffset] == SearchFlags.caseSensitive | SearchFlags.regex)
        #expect(nextOffset + 1 == payload.count)
    }
}

/// Read a big-endian UInt16 from data at offset.
private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

/// Read a big-endian UInt32 from data at offset.
private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
    UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

/// Read a big-endian UInt64 from data at offset.
private func readU64(_ data: Data, _ offset: Int) -> UInt64 {
    (0..<8).reduce(0) { ($0 << 8) | UInt64(data[offset + $1]) }
}

/// Read a big-endian Int16 from data at offset.
private func readI16(_ data: Data, _ offset: Int) -> Int16 {
    Int16(bitPattern: readU16(data, offset))
}

/// Read a length-prefixed UTF-8 string and return the string plus the next offset.
private func readString16(_ data: Data, _ offset: Int) -> (String, Int) {
    let length = Int(readU16(data, offset))
    let start = offset + 2
    let end = start + length
    return (String(data: data.subdata(in: start..<end), encoding: .utf8) ?? "", end)
}

// MARK: - Application quit

@Suite("Encoder Binary: Application Quit")
struct EncoderApplicationQuitTests {
    @Test("application quit request carries its u32 correlation ID")
    func requestLayout() {
        let payload = captureFrame {
            _ = $0.send(.applicationQuitRequest(requestID: 0xA1B2_C3D4)).wasAccepted
        }

        #expect(payload.count == 5)
        #expect(payload[0] == OP_APPLICATION_QUIT_REQUEST)
        #expect(readU32(payload, 1) == 0xA1B2_C3D4)
    }

    @Test("application quit decision carries its correlation ID and decision")
    func decisionLayout() {
        let payload = captureFrame {
            _ = $0.send(.applicationQuitDecision(requestID: 42, decision: ApplicationQuitDecision.discard.rawValue)).wasAccepted
        }

        #expect(payload.count == 6)
        #expect(payload[0] == OP_APPLICATION_QUIT_DECISION)
        #expect(readU32(payload, 1) == 42)
        #expect(payload[5] == ApplicationQuitDecision.discard.rawValue)
    }
}

// MARK: - Native file dialogs

@Suite("Encoder Binary: Native File Dialog")
struct EncoderNativeFileDialogTests {
    @Test("multi-open result carries correlation and every selected path")
    func multiOpenLayout() {
        let payload = captureFrame {
            $0.send(.fileDialogResult(
                requestID: 0xA1B2_C3D4,
                outcome: 1,
                paths: ["/tmp/one.txt", "/tmp/two.txt"]
            ))
        }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_FILE_DIALOG_RESULT)
        #expect(readU32(payload, 2) == 0xA1B2_C3D4)
        #expect(payload[6] == 1)
        #expect(readU16(payload, 7) == 2)
        let (first, next) = readString16(payload, 9)
        let (second, end) = readString16(payload, next)
        #expect(first == "/tmp/one.txt")
        #expect(second == "/tmp/two.txt")
        #expect(end == payload.count)
    }

    @Test("cancel result carries no paths")
    func cancelLayout() {
        let payload = captureFrame {
            $0.send(.fileDialogResult(requestID: 7, outcome: 0, paths: []))
        }
        #expect(payload.count == 9)
        #expect(readU32(payload, 2) == 7)
        #expect(payload[6] == 0)
        #expect(readU16(payload, 7) == 0)
    }
}

// MARK: - Frontend foreground event

@Suite("Encoder Binary: Frontend foreground")
struct EncoderFrontendForegroundTests {
    @Test("the app's place is one byte after the opcode: 1 in the foreground, 0 in the background", arguments: [(true, UInt8(1)), (false, UInt8(0))])
    func layout(foreground: Bool, byte: UInt8) {
        let payload = captureFrame { $0.send(.frontendForeground(foreground)) }

        #expect(payload == Data([OP_FRONTEND_FOREGROUND, byte]))
        #expect(OP_FRONTEND_FOREGROUND == 0x13)
    }
}

// MARK: - Ready event

@Suite("Encoder Binary: Ready")
struct EncoderReadyTests {
    @Test("ready event has correct opcode and capabilities")
    func readyLayout() {
        let payload = captureFrame { $0.send(.ready(cols: 120, rows: 40)) }

        // Capability format 2 carries 20 fields plus a u16 protocol-version tail.
        #expect(payload.count == 29)
        #expect(payload[0] == OP_READY)
        #expect(readU16(payload, 1) == 120) // cols
        #expect(readU16(payload, 3) == 40)  // rows
        #expect(payload[5] == CAPS_VERSION)
        #expect(payload[6] == 20) // original fields plus resource-policy tail
        #expect(payload[7] == FRONTEND_NATIVE_GUI)
        #expect(payload[8] == COLOR_RGB)
        #expect(payload[9] == UNICODE_15)
        #expect(payload[10] == IMAGE_NATIVE)
        #expect(payload[11] == FLOAT_NATIVE)
        #expect(payload[12] == TEXT_PROPORTIONAL)
        #expect(payload[13] == SEMANTIC_UI_ENABLED)
        #expect(payload[14] == RESOURCE_POLICY_VERSION)
        #expect(readU32(payload, 15) == 64 * 1024 * 1024)
        #expect(readU32(payload, 19) == 0) // command admission is not enforced yet
        #expect(readU32(payload, 23) == 0) // per-window row admission is not enforced yet
        #expect(readU16(payload, 27) == PROTOCOL_VERSION) // protocol_version tail
    }
}

// MARK: - Request keyframe

@Suite("Encoder Binary: Request Keyframe")
struct EncoderRequestKeyframeTests {
    @Test("request_keyframe encodes opcode and last_good_frame_seq (#2219 child D)")
    func requestKeyframeLayout() {
        let payload = captureFrame { $0.send(.requestKeyframe(lastGoodFrameSequence: 0x0A0B_0C0D, generation: 7)) }

        #expect(payload.count == 9)
        #expect(payload[0] == OP_REQUEST_KEYFRAME)
        #expect(readU32(payload, 1) == 0x0A0B_0C0D)
        #expect(readU32(payload, 5) == 7)
    }

    @Test("request_keyframe carries a zero seq when the frontend has no good frame")
    func requestKeyframeZeroSeq() {
        let payload = captureFrame { $0.send(.requestKeyframe(lastGoodFrameSequence: 0, generation: 0)) }

        #expect(payload.count == 9)
        #expect(payload[0] == OP_REQUEST_KEYFRAME)
        #expect(readU32(payload, 1) == 0)
    }

    @Test("frame_applied encodes generation and frame")
    func frameAppliedLayout() {
        let payload = captureFrame { $0.send(.frameApplied(generation: 3, frameSequence: 9)) }
        #expect(payload.count == 9)
        #expect(payload[0] == OP_FRAME_APPLIED)
        #expect(readU32(payload, 1) == 3)
        #expect(readU32(payload, 5) == 9)
    }

    @Test("frame_rejected appends the protocol-v12 disposition byte")
    func frameRejectedLayout() {
        let payload = captureFrame {
            $0.send(.frameRejected(
                generation: 3,
                frameSequence: 9,
                lastAppliedFrameSequence: 7,
                reason: GeneratedProtocol.FrameRejectionReason.resourcePolicy.rawValue,
                disposition: GeneratedProtocol.FrameRejectionDisposition.terminalFrontendFailure.rawValue
            ))
        }
        #expect(payload.count == 15)
        #expect(payload[0] == OP_FRAME_REJECTED)
        #expect(readU32(payload, 1) == 3)
        #expect(readU32(payload, 5) == 9)
        #expect(readU32(payload, 9) == 7)
        #expect(payload[13] == GeneratedProtocol.FrameRejectionReason.resourcePolicy.rawValue)
        #expect(payload[14] == GeneratedProtocol.FrameRejectionDisposition.terminalFrontendFailure.rawValue)
    }

    @Test("resource-policy rejection defaults to terminal disposition")
    func frameRejectedResourcePolicyDefault() {
        let payload = captureFrame {
            $0.send(.frameRejected(
                generation: 4,
                frameSequence: 10,
                lastAppliedFrameSequence: 9,
                reason: GeneratedProtocol.FrameRejectionReason.resourcePolicy.rawValue,
                disposition: GeneratedProtocol.FrameRejectionDisposition.terminalFrontendFailure.rawValue
            ))
        }
        #expect(payload[14] == GeneratedProtocol.FrameRejectionDisposition.terminalFrontendFailure.rawValue)
    }

    @Test("window_ref_miss encodes the targeted window")
    func windowRefMissLayout() {
        let payload = captureFrame {
            $0.send(.windowReferenceMiss(generation: 3, frameSequence: 9, lastAppliedFrameSequence: 7, windowID: 12))
        }
        #expect(payload.count == 15)
        #expect(payload[0] == OP_WINDOW_REF_MISS)
        #expect(readU32(payload, 1) == 3)
        #expect(readU32(payload, 5) == 9)
        #expect(readU32(payload, 9) == 7)
        #expect(readU16(payload, 13) == 12)
    }
}

// MARK: - Key press

@Suite("Encoder Binary: Key Press")
struct EncoderKeyPressTests {
    @Test("key press encodes codepoint, modifiers, and zero correlation sequence")
    func keyPressLayout() {
        // The sequence-less encoder appends a zero correlation sequence (#2215).
        let payload = captureFrame { $0.send(.keyPress(codepoint: 27, modifiers: 0x02, sequence: 0)) }

        #expect(payload.count == 10)
        #expect(payload[0] == OP_KEY_PRESS)
        #expect(readU32(payload, 1) == 27)   // codepoint (Escape)
        #expect(payload[5] == 0x02)          // modifiers (Ctrl)
        #expect(readU32(payload, 6) == 0)    // correlation sequence
    }

    @Test("key press with large codepoint")
    func keyPressLargeCodepoint() {
        // Kitty arrow key codepoint
        let payload = captureFrame { $0.send(.keyPress(codepoint: 57350, modifiers: 0, sequence: 0)) }

        #expect(readU32(payload, 1) == 57350)
    }

    @Test("key press stamps the latency correlation sequence (#2215)")
    func keyPressCorrelationSequence() {
        let payload = captureFrame {
            $0.send(.keyPress(codepoint: 0x61, modifiers: 0, sequence: 0x0102_0304))
        }

        #expect(payload.count == 10)
        #expect(payload[0] == OP_KEY_PRESS)
        #expect(readU32(payload, 1) == 0x61)        // codepoint ('a')
        #expect(readU32(payload, 6) == 0x0102_0304) // correlation sequence
    }
}

// MARK: - Resize

@Suite("Encoder Binary: Resize")
struct EncoderResizeTests {
    @Test("resize encodes cols and rows")
    func resizeLayout() {
        let payload = captureFrame { $0.send(.resize(cols: 200, rows: 50)) }

        #expect(payload.count == 5)
        #expect(payload[0] == OP_RESIZE)
        #expect(readU16(payload, 1) == 200) // cols
        #expect(readU16(payload, 3) == 50)  // rows
    }
}

// MARK: - Mouse event

@Suite("Encoder Binary: Mouse Event")
struct EncoderMouseEventTests {
    @Test("mouse event encodes all fields including click count")
    func mouseEventLayout() {
        let payload = captureFrame {
            $0.send(.mouse(row: 10, column: -5, button: MOUSE_BUTTON_LEFT,
                           modifiers: 0x01, eventType: MOUSE_PRESS, clickCount: 3))
        }

        #expect(payload.count == 9)
        #expect(payload[0] == OP_MOUSE_EVENT)
        #expect(readI16(payload, 1) == 10)   // row (signed)
        #expect(readI16(payload, 3) == -5)   // col (signed, negative for left of view)
        #expect(payload[5] == MOUSE_BUTTON_LEFT)
        #expect(payload[6] == 0x01)           // modifiers (Shift)
        #expect(payload[7] == MOUSE_PRESS)
        #expect(payload[8] == 3)              // clickCount (triple-click)
    }

    @Test("scroll event uses correct button constants")
    func scrollLayout() {
        let payload = captureFrame {
            $0.send(.mouse(row: 0, column: 0, button: MOUSE_SCROLL_DOWN,
                           modifiers: 0, eventType: MOUSE_PRESS, clickCount: 1))
        }

        #expect(payload[5] == MOUSE_SCROLL_DOWN)
    }
}

// MARK: - Paste event

@Suite("Encoder Binary: Paste Event")
struct EncoderPasteEventTests {
    @Test("paste event encodes text with length prefix")
    func pasteLayout() {
        let payload = captureFrame { $0.send(.paste("hello\nworld")) }

        #expect(payload[0] == OP_PASTE_EVENT)
        let textLen = readU16(payload, 1)
        #expect(textLen == 11) // "hello\nworld" = 11 bytes
        let text = String(data: payload[3..<(3 + Int(textLen))], encoding: .utf8)
        #expect(text == "hello\nworld")
    }

    @Test("paste event with unicode text")
    func pasteUnicode() {
        let payload = captureFrame { $0.send(.paste("日本語")) }

        let textLen = readU16(payload, 1)
        #expect(textLen == 9) // 3 CJK chars × 3 bytes each
        let text = String(data: payload[3..<(3 + Int(textLen))], encoding: .utf8)
        #expect(text == "日本語")
    }

    @Test("paste event with empty text")
    func pasteEmpty() {
        let payload = captureFrame { $0.send(.paste("")) }

        #expect(payload[0] == OP_PASTE_EVENT)
        #expect(readU16(payload, 1) == 0) // text_len = 0
        #expect(payload.count == 3) // opcode + len only
    }
}

// MARK: - Log message

@Suite("Encoder Binary: Log Message")
struct EncoderLogMessageTests {
    @Test("log message encodes level and text")
    func logLayout() {
        let payload = captureFrame { $0.send(.log(level: LOG_LEVEL_INFO, message: "test msg")) }

        #expect(payload[0] == OP_LOG_MESSAGE)
        #expect(payload[1] == LOG_LEVEL_INFO)
        let msgLen = readU16(payload, 2)
        #expect(msgLen == 8) // "test msg"
        let msg = String(data: payload[4..<(4 + Int(msgLen))], encoding: .utf8)
        #expect(msg == "test msg")
    }
}

// MARK: - GUI actions

@Suite("Encoder Binary: GUI Actions")
struct EncoderGUIActionTests {
    @Test("select_tab encodes action type and tab ID")
    func selectTabLayout() {
        let payload = captureFrame { $0.send(.selectTab(id: 42)) }

        #expect(payload.count == 6)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_SELECT_TAB)
        #expect(readU32(payload, 2) == 42)
    }

    @Test("close_tab encodes action type and tab ID")
    func closeTabLayout() {
        let payload = captureFrame { $0.send(.closeTab(id: 99)) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_CLOSE_TAB)
        #expect(readU32(payload, 2) == 99)
    }

    @Test("chat pin intents encode opcode and sub-opcode with no payload")
    func chatPinIntentLayout() {
        let awayPayload = captureFrame { $0.send(.chatScrolledAwayFromBottom) }
        #expect(awayPayload.count == 2)
        #expect(awayPayload[0] == OP_GUI_ACTION)
        #expect(awayPayload[1] == GUI_ACTION_CHAT_SCROLLED_AWAY_FROM_BOTTOM)

        let returnedPayload = captureFrame { $0.send(.chatReturnedToBottom) }
        #expect(returnedPayload.count == 2)
        #expect(returnedPayload[0] == OP_GUI_ACTION)
        #expect(returnedPayload[1] == GUI_ACTION_CHAT_RETURNED_TO_BOTTOM)
    }

    @Test("picker_query_changed encodes correlation and complete UTF-8 text")
    func pickerQueryChangedLayout() {
        let payload = captureFrame {
            $0.send(.pickerQueryChanged(generation: 7, editSequence: 11, text: "café"))
        }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_PICKER_QUERY_CHANGED)
        #expect(readU32(payload, 2) == 7)
        #expect(readU32(payload, 6) == 11)
        let (query, end) = readString16(payload, 10)
        #expect(query == "café")
        #expect(end == payload.count)
    }

    @Test("picker semantic activations encode the offered generation and identity")
    func pickerActivationLayouts() {
        let item = captureFrame { $0.send(.pickerItemActivate(generation: 17, activationID: 23)) }
        #expect(item.count == 10)
        #expect(item[0] == OP_GUI_ACTION)
        #expect(item[1] == GUI_ACTION_PICKER_ITEM_ACTIVATE)
        #expect(readU32(item, 2) == 17)
        #expect(readU32(item, 6) == 23)

        let action = captureFrame { $0.send(.pickerActionActivate(generation: 29, activationID: 31)) }
        #expect(action.count == 10)
        #expect(action[0] == OP_GUI_ACTION)
        #expect(action[1] == GUI_ACTION_PICKER_ACTION_ACTIVATE)
        #expect(readU32(action, 2) == 29)
        #expect(readU32(action, 6) == 31)
    }

    @Test("tab_reorder encodes action type, tab ID, and visible index")
    func tabReorderLayout() {
        let payload = captureFrame { $0.send(.tabReorder(id: 42, newIndex: 3)) }

        #expect(payload.count == 8)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_TAB_REORDER)
        #expect(readU32(payload, 2) == 42)
        #expect(readU16(payload, 6) == 3)
    }

    @Test("tab id-scoped actions encode action type and tab ID")
    func tabIdScopedActionLayouts() {
        let cases: [(Data, UInt8, UInt32)] = [
            (captureFrame { $0.send(.tabPin(id: 7)) }, GUI_ACTION_TAB_PIN, 7),
            (captureFrame { $0.send(.tabUnpin(id: 8)) }, GUI_ACTION_TAB_UNPIN, 8),
            (captureFrame { $0.send(.tabMoveLeft(id: 9)) }, GUI_ACTION_TAB_MOVE_LEFT, 9),
            (captureFrame { $0.send(.tabMoveRight(id: 10)) }, GUI_ACTION_TAB_MOVE_RIGHT, 10)
        ]

        for (payload, action, id) in cases {
            #expect(payload.count == 6)
            #expect(payload[0] == OP_GUI_ACTION)
            #expect(payload[1] == action)
            #expect(readU32(payload, 2) == id)
        }
    }

    @Test("file_tree_drop encodes stable target identity and sources")
    func fileTreeDropLayout() {
        let payload = captureFrame {
            $0.send(.fileTreeDrop(sourcePaths: ["/tmp/a.txt", "/tmp/b.txt"], targetIndex: 8, targetID: "/project/lib", targetPathHash: 0xAABBCCDD, targetPath: "/project/lib", targetIsDirectory: true, modifiers: 0x02, generation: 0x0102_0304))
        }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_FILE_TREE_DROP)
        #expect(readU16(payload, 2) == 8)
        #expect(readU32(payload, 4) == 0xAABBCCDD)
        #expect(payload[8] == 1)
        #expect(payload[9] == 0x02)

        let (targetId, afterTargetId) = readString16(payload, 10)
        let (targetPath, afterTargetPath) = readString16(payload, afterTargetId)
        let sourceCount = readU16(payload, afterTargetPath)
        let (sourceA, afterSourceA) = readString16(payload, afterTargetPath + 2)
        let (sourceB, afterSourceB) = readString16(payload, afterSourceA)

        #expect(targetId == "/project/lib")
        #expect(targetPath == "/project/lib")
        #expect(sourceCount == 2)
        #expect(sourceA == "/tmp/a.txt")
        #expect(sourceB == "/tmp/b.txt")
        #expect(readU32(payload, afterSourceB) == 0x0102_0304)
        #expect(afterSourceB + 4 == payload.count)
    }

    @Test("file_tree_drop rejects overlong paths instead of truncating")
    func fileTreeDropRejectsOverlongPath() {
        let overlongPath = "/tmp/" + String(repeating: "a", count: Int(UInt16.max))
        var result: OutboundActionResult?
        let payload = captureFrame {
            result = $0.send(.fileTreeDrop(sourcePaths: [overlongPath], targetIndex: 8, targetID: "/project/lib", targetPathHash: 0xAABBCCDD, targetPath: "/project/lib", targetIsDirectory: true, modifiers: 0, generation: 7))
        }

        guard case .rejected(.invalidPayload(let reason)) = result else {
            Issue.record("expected invalid-payload rejection")
            return
        }
        #expect(reason.contains("source path exceeds GUI protocol limit"))
        #expect(payload[0] == OP_LOG_MESSAGE)
        #expect(payload[1] == LOG_LEVEL_WARN)
        let messageLength = Int(readU16(payload, 2))
        let message = String(data: payload[4..<(4 + messageLength)], encoding: .utf8)
        #expect(message?.contains("source path exceeds GUI protocol limit") == true)
    }

    @Test("fold_toggle_at_line encodes window ID and buffer line")
    func foldToggleAtLineLayout() {
        let payload = captureFrame { $0.send(.foldToggleAtLine(windowID: 7, generation: 0x0102_0304_0506_0708, bufferLine: 42)) }

        #expect(payload.count == 16)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_FOLD_TOGGLE_AT_LINE)
        #expect(readU16(payload, 2) == 7)
        #expect(readU64(payload, 4) == 0x0102_0304_0506_0708)
        #expect(readU32(payload, 12) == 42)
    }

    @Test("scroll_to_line encodes the offered pane identity and destination")
    func scrollToLineLayout() {
        let payload = captureFrame { $0.send(.scrollToLine(windowID: 7, generation: 0x0102_0304_0506_0708, line: 99)) }
        #expect(payload.count == 16)
        #expect(payload[1] == GUI_ACTION_SCROLL_TO_LINE)
        #expect(readU16(payload, 2) == 7)
        #expect(readU64(payload, 4) == 0x0102_0304_0506_0708)
        #expect(readU32(payload, 12) == 99)
    }

    @Test("scroll_to_visual_rank carries the displayed presentation and a wide rank")
    func scrollToVisualRankLayout() {
        let payload = captureFrame {
            $0.send(.scrollToVisualRank(windowID: 513, presentationID: 0x0102_0304_0506_0708, rank: 70_001))
        }
        #expect(payload.count == 16)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_SCROLL_TO_VISUAL_RANK)
        #expect(readU16(payload, 2) == 513)
        #expect(readU64(payload, 4) == 0x0102_0304_0506_0708)
        #expect(readU32(payload, 12) == 70_001)
    }

    @Test("focus_window encodes the pane window ID and durable generation")
    func focusWindowLayout() {
        let payload = captureFrame { $0.send(.focusWindow(windowID: 513, generation: 0x0102_0304_0506_0708)) }

        #expect(payload.count == 12)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_FOCUS_WINDOW)
        #expect(readU16(payload, 2) == 513)
        #expect(readU64(payload, 4) == 0x0102_0304_0506_0708)
    }

    @Test("command completion, timeline and Review activation use semantic surfaces")
    func additionalSemanticSurfaces() {
        for surface in [SemanticItemSurface.commandCompletion, .timeline, .review] {
            let payload = captureFrame {
                $0.send(.semanticItemActivate(surface: surface, intent: 1, generation: 42, itemID: Data("stable-id".utf8)))
            }
            #expect(payload[1] == GUI_ACTION_SEMANTIC_ITEM_ACTIVATE)
            #expect(payload[2] == surface.rawValue)
            #expect(payload[3] == 1)
            #expect(readU32(payload, 4) == 42)
            let (id, end) = readString16(payload, 8)
            #expect(id == "stable-id")
            #expect(end == payload.count)
        }
    }

    @Test("Review Back and Refresh echo exact Unicode item IDs on surface six")
    func reviewActivationLayout() {
        for intent: UInt8 in [1, 2] {
            let payload = captureFrame {
                $0.send(.semanticItemActivate(surface: .review, intent: intent, generation: 0x0102_0304, itemID: Data("opaque:é/👩‍💻?old=7".utf8)))
            }
            #expect(payload[0] == OP_GUI_ACTION)
            #expect(payload[1] == GUI_ACTION_SEMANTIC_ITEM_ACTIVATE)
            #expect(payload[2] == 6)
            #expect(payload[3] == intent)
            #expect(readU32(payload, 4) == 0x0102_0304)
            let (itemID, end) = readString16(payload, 8)
            #expect(itemID == "opaque:é/👩‍💻?old=7")
            #expect(end == payload.count)
        }
    }

    @Test("semantic item activation encodes surface intent generation and opaque item ID")
    func semanticItemActivationLayout() {
        let payload = captureFrame {
            $0.send(.semanticItemActivate(surface: .fileTree, intent: 4, generation: 0x0102_0304, itemID: Data("row-7".utf8)))
        }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_SEMANTIC_ITEM_ACTIVATE)
        #expect(payload[2] == SemanticItemSurface.fileTree.rawValue)
        #expect(payload[3] == 4)
        #expect(readU32(payload, 4) == 0x0102_0304)
        let (itemID, end) = readString16(payload, 8)
        #expect(itemID == "row-7")
        #expect(end == payload.count)
    }


    @Test("toggle_panel encodes panel ID")
    func togglePanelLayout() {
        let payload = captureFrame { $0.send(.togglePanel(panel: 1)) }

        #expect(payload.count == 3)
        #expect(payload[1] == GUI_ACTION_TOGGLE_PANEL)
        #expect(payload[2] == 1)
    }

    @Test("sidebar_action encodes id kind and action")
    func sidebarActionLayout() {
        let payload = captureFrame { $0.send(.sidebarAction(sidebarID: "git_status", kind: "git_status", action: "toggle")) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_SIDEBAR_ACTION)
        let (id, kindOffset) = readString16(payload, 2)
        let (kind, actionOffset) = readString16(payload, kindOffset)
        let (action, endOffset) = readString16(payload, actionOffset)
        #expect(id == "git_status")
        #expect(kind == "git_status")
        #expect(action == "toggle")
        #expect(endOffset == payload.count)
    }

    @Test("new_tab is just opcode + action_type")
    func newTabLayout() {
        let payload = captureFrame { $0.send(.newTab) }

        #expect(payload.count == 2)
        #expect(payload[1] == GUI_ACTION_NEW_TAB)
    }

    @Test("system_will_sleep is just opcode + action_type")
    func systemWillSleepLayout() {
        let payload = captureFrame { $0.send(.systemWillSleep) }

        #expect(payload.count == 2)
        #expect(payload[1] == GUI_ACTION_SYSTEM_WILL_SLEEP)
    }

    @Test("system_did_wake is just opcode + action_type")
    func systemDidWakeLayout() {
        let payload = captureFrame { $0.send(.systemDidWake) }

        #expect(payload.count == 2)
        #expect(payload[1] == GUI_ACTION_SYSTEM_DID_WAKE)
    }

    @Test("power_thermal_state encodes low power and thermal bytes")
    func powerThermalStateLayout() {
        let payload = captureFrame { $0.send(.powerThermalState(lowPowerMode: true, thermalState: 2)) }

        #expect(payload.count == 4)
        #expect(payload[1] == GUI_ACTION_POWER_THERMAL_STATE)
        #expect(payload[2] == 1)
        #expect(payload[3] == 2)
    }

    @Test("power_thermal_state encodes false low power as zero")
    func powerThermalStateFalseLowPowerLayout() {
        let payload = captureFrame { $0.send(.powerThermalState(lowPowerMode: false, thermalState: 0)) }

        #expect(payload.count == 4)
        #expect(payload[1] == GUI_ACTION_POWER_THERMAL_STATE)
        #expect(payload[2] == 0)
        #expect(payload[3] == 0)
    }

    @Test("observatory_inspect encodes PID with length prefix")
    func observatoryInspectLayout() {
        let pid = "<0.123.0>"
        let payload = captureFrame { $0.send(.observatoryInspect(pid: pid)) }

        #expect(payload.count == 2 + 2 + pid.utf8.count)
        #expect(payload[1] == GUI_ACTION_OBSERVATORY_INSPECT)
        #expect(readU16(payload, 2) == UInt16(pid.utf8.count))
        #expect(String(data: payload[4..<payload.count], encoding: .utf8) == pid)
    }

    @Test("panel_resize encodes height percent")
    func panelResizeLayout() {
        let payload = captureFrame { $0.send(.panelResize(heightPercent: 40)) }

        #expect(payload.count == 3)
        #expect(payload[1] == GUI_ACTION_PANEL_RESIZE)
        #expect(payload[2] == 40)
    }

    @Test("open_file encodes path with length prefix")
    func openFileLayout() {
        let path = "/home/user/project/lib/editor.ex"
        let payload = captureFrame { $0.send(.openFile(path: path)) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_OPEN_FILE)
        let pathLen = readU16(payload, 2)
        #expect(pathLen == UInt16(path.utf8.count))
        let decoded = String(data: payload[4..<(4 + Int(pathLen))], encoding: .utf8)
        #expect(decoded == path)
    }

    @Test("bulk and remote Git actions encode exactly the displayed panel identity")
    func gitPanelActionLayout() {
        let panelID: UInt64 = 0x0102_0304_0506_0708
        let actions: [(OutboundAction, UInt8)] = [
            (.gitStageAll(panelID: panelID), 0x1B),
            (.gitUnstageAll(panelID: panelID), 0x1C),
            (.gitPush(panelID: panelID), 0x38),
            (.gitPull(panelID: panelID), 0x39),
            (.gitFetch(panelID: panelID), 0x3A),
        ]

        for (action, subtype) in actions {
            let payload = captureFrame { $0.send(action) }
            #expect(payload == Data([0x07, subtype, 1, 2, 3, 4, 5, 6, 7, 8]))
        }
    }

    @Test("commit and amend encode the draft's panel, amend flag, and exact UTF-8 message")
    func gitCommitLayout() {
        let panelID: UInt64 = 0x0102_0304_0506_0708
        let actions: [(OutboundAction, UInt8)] = [
            (.gitCommit(panelID: panelID, message: "café"), 0),
            (.gitCommitAmend(panelID: panelID, message: "café"), 1),
        ]

        for (action, amendFlag) in actions {
            let payload = captureFrame { $0.send(action) }
            let expected = Data([0x07, 0x1D, 1, 2, 3, 4, 5, 6, 7, 8, amendFlag, 0, 5, 0x63, 0x61, 0x66, 0xC3, 0xA9])
            #expect(payload == expected)
        }
    }

    @Test("Git panel actions with zero identity emit only the rejection log")
    func rejectsMissingGitPanelIdentity() {
        let actions: [OutboundAction] = [
            .gitStageAll(panelID: 0), .gitUnstageAll(panelID: 0),
            .gitPush(panelID: 0), .gitPull(panelID: 0), .gitFetch(panelID: 0),
            .gitCommit(panelID: 0, message: "test"), .gitCommitAmend(panelID: 0, message: "test"),
        ]

        for action in actions {
            let wire = captureWire { #expect(!$0.send(action).wasAccepted) }
            let payloadSize = wire.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            #expect(wire.count == 4 + payloadSize)
            #expect(wire.dropFirst(4).first == OP_LOG_MESSAGE)
        }
    }

    @Test("Git row actions encode the offered panel identity, path, and section")
    func gitRowActionLayout() {
        let target = GitStatusEntryTarget(panelID: 0x2_0000_002A, path: "lib/café.ex", section: 2)
        let actions: [(OutboundAction, UInt8)] = [
            (.gitOpenFile(target), GUI_ACTION_GIT_OPEN_FILE),
            (.gitOpenDiff(target), GUI_ACTION_GIT_OPEN_DIFF),
            (.gitStageFile(target), GUI_ACTION_GIT_STAGE_FILE),
            (.gitUnstageFile(target), GUI_ACTION_GIT_UNSTAGE_FILE),
            (.gitDiscardFile(target), GUI_ACTION_GIT_DISCARD_FILE),
        ]

        for (action, opcode) in actions {
            let payload = captureFrame { $0.send(action) }
            #expect(payload[0] == OP_GUI_ACTION)
            #expect(payload[1] == opcode)
            #expect(readU64(payload, 2) == target.panelID)
            let pathLen = Int(readU16(payload, 10))
            #expect(pathLen == target.path.utf8.count)
            #expect(payload.count == 13 + pathLen)
            let decoded = String(data: payload[12..<(12 + pathLen)], encoding: .utf8)
            #expect(decoded == target.path)
            #expect(payload[12 + pathLen] == target.section)
        }
    }


    @Test("agent_tool_toggle encodes stable message ID")
    func agentToolToggleLayout() {
        let payload = captureFrame { $0.send(.agentToolToggle(messageID: 0x01020304)) }

        #expect(payload.count == 6)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_AGENT_TOOL_TOGGLE)
        #expect(readU32(payload, 2) == 0x01020304)
    }

    @Test("retained output read echoes the committed offer and tool message")
    func agentReadRetainedOutputLayout() {
        let payload = captureFrame {
            $0.send(.agentReadRetainedOutput(
                messageID: 0x01020304,
                offer: .init(high: 0x05060708090A0B0C, low: 0x0D0E0F1011121314)
            ))
        }
        let expected: [UInt8] = [OP_GUI_ACTION, GUI_ACTION_AGENT_READ_RETAINED_OUTPUT] + Array(1...20)
        #expect(payload == Data(expected))
    }

    @Test("execute_command encodes command name with length prefix")
    func executeCommandLayout() {
        let payload = captureFrame { $0.send(.executeCommand(name: "buffer_prev")) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_EXECUTE_COMMAND)
        let nameLen = readU16(payload, 2)
        #expect(nameLen == 11) // "buffer_prev".count
        let name = String(data: payload[4..<(4 + Int(nameLen))], encoding: .utf8)
        #expect(name == "buffer_prev")
    }

    @Test("which_key_press encodes the panel path, the raw key and its modifiers")
    func whichKeyPressLayout() {
        let payload = captureFrame { $0.send(.whichKeyPress(path: "SPC a", codepoint: 0x71, modifiers: 2)) }

        #expect(payload == Data([OP_GUI_ACTION, GUI_ACTION_WHICH_KEY_PRESS, 0, 5] + Array("SPC a".utf8) + [0, 0, 0, 0x71, 2]))
    }

    @Test("which_key_back encodes the crumb path")
    func whichKeyBackLayout() {
        let payload = captureFrame { $0.send(.whichKeyBack(path: "SPC")) }

        #expect(payload == Data([OP_GUI_ACTION, GUI_ACTION_WHICH_KEY_BACK, 0, 3] + Array("SPC".utf8)))
    }

    @Test("workspace_rename encodes id and name with length prefix")
    func workspaceRenameLayout() {
        let payload = captureFrame { $0.send(.workspaceRename(id: 7, name: "Research Bot")) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_WORKSPACE_RENAME)
        #expect(readU16(payload, 2) == 7)
        let nameLen = readU16(payload, 4)
        #expect(payload.count == 6 + Int(nameLen))
        let (name, end) = readString16(payload, 4)
        #expect(name == "Research Bot")
        #expect(end == payload.count)
    }

    @Test("workspace_set_icon encodes id and icon with compact length prefix")
    func workspaceSetIconLayout() {
        let payload = captureFrame { $0.send(.workspaceSetIcon(id: 7, icon: "cpu")) }

        #expect(payload.count == 8)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_WORKSPACE_SET_ICON)
        #expect(readU16(payload, 2) == 7)
        #expect(payload[4] == 3)
        #expect(String(data: payload[5..<8], encoding: .utf8) == "cpu")
    }

    @Test("workspace_close encodes just action type and workspace id")
    func workspaceCloseLayout() {
        let payload = captureFrame { $0.send(.workspaceClose(id: 7)) }

        #expect(payload.count == 4)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_WORKSPACE_CLOSE)
        #expect(readU16(payload, 2) == 7)
    }

    @Test("notification dismiss encodes action type and notification id")
    func notificationDismissLayout() {
        let id = "build:test"
        let payload = captureFrame { $0.send(.notificationDismiss(id: id)) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_NOTIFICATION_DISMISS)
        let (decodedId, endOffset) = readString16(payload, 2)
        #expect(decodedId == id)
        #expect(endOffset == payload.count)
    }

    @Test("notification action encodes action type, notification id, and action id")
    func notificationActionLayout() {
        let id = "build:test"
        let action = "show_logs"
        let payload = captureFrame { $0.send(.notificationAction(id: id, actionID: action)) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_NOTIFICATION_ACTION)
        let (decodedId, nextOffset) = readString16(payload, 2)
        let (decodedAction, endOffset) = readString16(payload, nextOffset)
        #expect(decodedId == id)
        #expect(decodedAction == action)
        #expect(endOffset == payload.count)
    }
}

// MARK: - Settings

@Suite("Encoder Binary: Settings")
struct EncoderSettingsTests {
    @Test("config_query encodes action with no payload")
    func configQueryLayout() {
        let payload = captureFrame { $0.send(.configQuery) }

        #expect(payload.count == 2)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_CONFIG_QUERY)
    }

    @Test("config_update encodes typed atom payload")
    func configUpdateAtomLayout() {
        let payload = captureFrame { $0.send(.configUpdate(key: "theme", value: .atom("doom_one"))) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_CONFIG_UPDATE)
        #expect(payload[2] == 5)
        #expect(String(data: payload[3..<8], encoding: .utf8) == "theme")
        #expect(payload[8] == SETTING_VALUE_ATOM)
        #expect(readU16(payload, 9) == 8)
        #expect(String(data: payload[11..<19], encoding: .utf8) == "doom_one")
    }

    @Test("config_update encodes typed bool payload")
    func configUpdateBoolLayout() {
        let payload = captureFrame { $0.send(.configUpdate(key: "wrap", value: .bool(true))) }

        #expect(payload == Data([OP_GUI_ACTION, GUI_ACTION_CONFIG_UPDATE, 4, 0x77, 0x72, 0x61, 0x70, SETTING_VALUE_BOOL, 1]))
    }

    @Test("config_update encodes typed int payload")
    func configUpdateIntLayout() {
        let payload = captureFrame { $0.send(.configUpdate(key: "tab_width", value: .int(4))) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_CONFIG_UPDATE)
        #expect(payload[2] == 9)
        #expect(String(data: payload[3..<12], encoding: .utf8) == "tab_width")
        #expect(payload[12] == SETTING_VALUE_INT)
        #expect(readU32(payload, 13) == 4)
    }

    @Test("config_update encodes typed string payload")
    func configUpdateStringLayout() {
        let payload = captureFrame { $0.send(.configUpdate(key: "font_family", value: .string("Iosevka"))) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_CONFIG_UPDATE)
        #expect(payload[2] == 11)
        #expect(String(data: payload[3..<14], encoding: .utf8) == "font_family")
        #expect(payload[14] == SETTING_VALUE_STRING)
        #expect(readU16(payload, 15) == 7)
        #expect(String(data: payload[17..<24], encoding: .utf8) == "Iosevka")
    }
}

// MARK: - Frame header

@Suite("Encoder Binary: Frame Header")
struct EncoderFrameHeaderTests {
    @Test("frame has correct {:packet, 4} length prefix")
    func frameHeader() {
        let pipe = Pipe()
        let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)
        encoder.send(.resize(cols: 80, rows: 24))
        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()

        // {:packet, 4}: first 4 bytes are big-endian payload length
        let declaredLen = Int(raw[0]) << 24 | Int(raw[1]) << 16 | Int(raw[2]) << 8 | Int(raw[3])
        #expect(declaredLen == 5) // resize payload = 5 bytes
        #expect(raw.count == 4 + declaredLen)
    }
}

@Suite("Encoder Binary: Displayed Text")
struct EncoderDisplayedTextTests {
    @Test("text event preserves wide identities, UTF16 offset, modifiers and signed drag edges")
    func targetLayout() {
        let target = EditorTextTarget(windowID: 512, presentationID: 0x0102030405060708, rowIndex: 70_000, rowID: 0x1122334455667788, utf16Offset: 120_000)
        let payload = captureFrame {
            $0.send(.editorText(target: target, button: 2, modifiers: 7, eventType: 3, clickCount: 2, scrollX: -1, scrollY: 1))
        }
        #expect(payload.count == 33)
        #expect(payload[0] == OP_EDITOR_TEXT_EVENT)
        #expect(readU16(payload, 1) == target.windowID)
        #expect(readU64(payload, 3) == target.presentationID)
        #expect(readU32(payload, 11) == target.rowIndex)
        #expect(readU64(payload, 15) == target.rowID)
        #expect(readU32(payload, 23) == target.utf16Offset)
        #expect(Array(payload[27...]) == [2, 7, 3, 2, 255, 1])
    }

    @Test("presentation lifecycle has an ordered explicit state")
    func lifecycleLayout() {
        let payload = captureFrame { $0.send(.textPresentationState(windowID: 512, presentationID: 0x0102030405060708, state: .active)) }
        #expect(payload == Data([OP_TEXT_PRESENTATION_STATE, 2, 0, 1, 2, 3, 4, 5, 6, 7, 8, 1]))
    }
}

@Suite("Encoder Binary: agent notification open")
struct EncoderAgentNotificationOpenTests {
    @Test("a click on a needs-you alert names the alert by its 16-byte identity")
    func openLayout() throws {
        let id = try #require(UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10"))
        let payload = captureFrame { $0.send(.agentNotificationOpen(alert: id)) }
        #expect(payload == Data([OP_GUI_ACTION, 0x72] + Array(1...16)))
    }
}

@Suite("Encoder Binary: picker fit")
struct EncoderPickerFitTests {
    @Test("fit carries the picker generation and the rows its list shows")
    func fitLayout() {
        let payload = captureFrame { $0.send(.pickerFit(generation: 0x01020304, rows: 13)) }
        #expect(payload == Data([OP_GUI_ACTION, 0x70, 1, 2, 3, 4, 0, 13]))
    }

    @Test("a fit without rows or without a picker never enters the transport")
    func invalidFitIsRejected() throws {
        let pipe = Pipe()
        let encoder = try ProtocolEncoder(output: pipe.fileHandleForWriting)
        for action: OutboundAction in [.pickerFit(generation: 0, rows: 13), .pickerFit(generation: 7, rows: 0)] {
            guard case .rejected(.invalidPayload) = encoder.send(action) else {
                Issue.record("Invalid picker fit entered the transport")
                continue
            }
        }
        #expect(encoder.send(.pickerFit(generation: 7, rows: 1)) == .accepted)
        withExtendedLifetime(pipe) {
            #expect(encoder.waitForPendingWritesForTesting())
        }
    }
}

@Suite("Encoder Binary: canonical multiline agent prompt")
struct EncoderAgentPromptTests {
    @Test("fit preserves the entire source presentation generation and both physical dimensions")
    func fitLayout() {
        let payload = captureFrame {
            $0.send(.agentPromptFit(windowID: 65534, generation: 0x0102030405060708, columns: 93, maxRows: 17))
        }
        #expect(payload == Data([
            OP_GUI_ACTION, 0x66, 0xFF, 0xFE,
            1, 2, 3, 4, 5, 6, 7, 8, 0, 93, 0, 17
        ]))
    }

    @Test("scroll uses signed big-endian i32 in both directions", arguments: [Int32.min, -257, 0, 257, Int32.max])
    func scrollLayout(delta: Int32) {
        let payload = captureFrame {
            $0.send(.agentPromptScroll(windowID: 65534, generation: UInt64.max, deltaRows: delta))
        }
        #expect(payload.count == 16)
        #expect(payload[0] == OP_GUI_ACTION && payload[1] == 0x67)
        #expect(readU16(payload, 2) == 65534)
        #expect(readU64(payload, 4) == UInt64.max)
        #expect(Int32(bitPattern: readU32(payload, 12)) == delta)
    }

    @Test("invalid targets and zero fit dimensions are rejected before transport")
    func fitAdmission() throws {
        let pipe = Pipe()
        let encoder = try ProtocolEncoder(output: pipe.fileHandleForWriting)
        for action: OutboundAction in [
            .agentPromptFit(windowID: 1, generation: 3, columns: 80, maxRows: 8),
            .agentPromptFit(windowID: 65534, generation: 3, columns: 0, maxRows: 8),
            .agentPromptFit(windowID: 65534, generation: 3, columns: 80, maxRows: 0),
            .agentPromptScroll(windowID: 1, generation: 3, deltaRows: 1)
        ] {
            guard case .rejected(.invalidPayload) = encoder.send(action) else {
                Issue.record("Invalid prompt geometry entered the transport")
                continue
            }
        }
        #expect(encoder.send(.agentPromptFit(windowID: 65534, generation: 3, columns: 1, maxRows: 1)) == .accepted)
        withExtendedLifetime(pipe) {
            #expect(encoder.waitForPendingWritesForTesting())
        }
    }
}

@Suite("Encoder Binary: request-bound tool approval")
struct EncoderAgentToolApprovalTests {
    @Test("all decisions encode the immutable IDs in session request tool order")
    func approvalLayout() throws {
        let decisions: [(AgentApprovalDecision, UInt8)] = [
            (.approve, 1), (.approveSession, 2), (.approveTurn, 3), (.reject, 4)
        ]
        for (decision, rawValue) in decisions {
            let payload = captureFrame {
                #expect($0.send(.agentToolApproval(sessionId: "session-λ", requestId: "request-二", toolCallId: "tool-é", decision: decision)) == .accepted)
            }
            try #require(payload.count >= 9)
            #expect(payload[0] == 0x07)
            #expect(payload[1] == 0x68)
            let (sessionId, requestOffset) = readString16(payload, 2)
            let (requestId, toolOffset) = readString16(payload, requestOffset)
            let (toolCallId, decisionOffset) = readString16(payload, toolOffset)
            #expect(sessionId == "session-λ")
            #expect(requestId == "request-二")
            #expect(toolCallId == "tool-é")
            #expect(payload[decisionOffset] == rawValue)
            #expect(decisionOffset + 1 == payload.count)
        }
    }

    @Test("each oversized identity is rejected without clipping or emitting approval")
    func oversizedIdentity() {
        let oversized = String(repeating: "é", count: 32_768)
        for invalidIndex in 0..<3 {
            var identities = ["session-a", "request-a", "tool-a"]
            identities[invalidIndex] = oversized
            var result: OutboundActionResult?
            let payload = captureFrame {
                result = $0.send(.agentToolApproval(sessionId: identities[0], requestId: identities[1], toolCallId: identities[2], decision: .approve))
            }
            #expect(result == .rejected(.payloadTooLarge(limitBytes: 65_535, attemptedBytes: 65_536)))
            #expect(payload.isEmpty)
        }
    }

    @Test("missing identities are rejected and leave the encoder available")
    func emptyIdentity() throws {
        let pipe = Pipe()
        let encoder = try ProtocolEncoder(output: pipe.fileHandleForWriting)
        for invalidIndex in 0..<3 {
            var identities = ["session-a", "request-a", "tool-a"]
            identities[invalidIndex] = ""
            guard case .rejected(.invalidPayload) = encoder.send(.agentToolApproval(
                sessionId: identities[0], requestId: identities[1], toolCallId: identities[2], decision: .reject
            )) else {
                Issue.record("Identity-free approval entered the transport")
                continue
            }
        }
        #expect(encoder.send(.agentToolApproval(sessionId: "session-a", requestId: "request-a", toolCallId: "tool-a", decision: .reject)) == .accepted)
        #expect(encoder.waitForPendingWritesForTesting())
    }
}
