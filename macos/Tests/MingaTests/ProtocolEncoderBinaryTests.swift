/// Tests for ProtocolEncoder binary layout.
///
/// Verifies the exact bytes the encoder writes to the wire match the
/// protocol spec. Uses a pipe to capture output instead of stdout.
/// Each test creates a fresh encoder, calls one method, reads the
/// {:packet, 4} framed output, and asserts the payload bytes.

import Testing
import Foundation
import MingaUI

/// Helper to create a pipe-backed encoder and read the framed output.
private func captureFrame(_ action: (ProtocolEncoder) -> Void) -> Data {
    let pipe = Pipe()
    let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)
    action(encoder)
    #expect(encoder.waitForPendingWritesForTesting())
    // Close write end so read doesn't block
    pipe.fileHandleForWriting.closeFile()
    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    // Strip the 4-byte length prefix to get the payload
    guard raw.count >= 4 else { return Data() }
    let len = Int(raw[0]) << 24 | Int(raw[1]) << 16 | Int(raw[2]) << 8 | Int(raw[3])
    guard raw.count >= 4 + len else { return Data() }
    return raw.subdata(in: 4..<(4 + len))
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

    @Test("file_tree_click encodes index as UInt16")
    func fileTreeClickLayout() {
        let payload = captureFrame { $0.send(.fileTreeClick(index: 15)) }

        #expect(payload.count == 4)
        #expect(payload[1] == GUI_ACTION_FILE_TREE_CLICK)
        #expect(readU16(payload, 2) == 15)
    }

    @Test("file_tree_drop encodes stable target identity and sources")
    func fileTreeDropLayout() {
        let payload = captureFrame {
            $0.send(.fileTreeDrop(sourcePaths: ["/tmp/a.txt", "/tmp/b.txt"], targetIndex: 8, targetID: "/project/lib", targetPathHash: 0xAABBCCDD, targetPath: "/project/lib", targetIsDirectory: true, modifiers: 0x02))
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
        #expect(afterSourceB == payload.count)
    }

    @Test("file_tree_drop rejects overlong paths instead of truncating")
    func fileTreeDropRejectsOverlongPath() {
        let overlongPath = "/tmp/" + String(repeating: "a", count: Int(UInt16.max))
        var result: OutboundActionResult?
        let payload = captureFrame {
            result = $0.send(.fileTreeDrop(sourcePaths: [overlongPath], targetIndex: 8, targetID: "/project/lib", targetPathHash: 0xAABBCCDD, targetPath: "/project/lib", targetIsDirectory: true, modifiers: 0))
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
        let payload = captureFrame { $0.send(.foldToggleAtLine(windowID: 7, bufferLine: 42)) }

        #expect(payload.count == 8)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_FOLD_TOGGLE_AT_LINE)
        #expect(readU16(payload, 2) == 7)
        #expect(readU32(payload, 4) == 42)
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

    @Test("completion_select encodes stable item ID as string8")
    func completionSelectLayout() {
        let payload = captureFrame { $0.send(.completionSelect(itemID: "item-3")) }

        #expect(payload.count == 9)
        #expect(payload[1] == GUI_ACTION_COMPLETION_SELECT)
        #expect(payload[2] == 6)
        #expect(String(decoding: payload[3...], as: UTF8.self) == "item-3")
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

    @Test("panel_switch_tab encodes tab index")
    func panelSwitchTabLayout() {
        let payload = captureFrame { $0.send(.panelSwitchTab(index: 2)) }

        #expect(payload.count == 3)
        #expect(payload[1] == GUI_ACTION_PANEL_SWITCH_TAB)
        #expect(payload[2] == 2)
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

    @Test("git_commit encodes amend flag, length, and message")
    func gitCommitLayout() {
        let message = "feat: polish git panel"
        let payload = captureFrame { $0.send(.gitCommit(message: message)) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_GIT_COMMIT)
        #expect(payload[2] == 0)
        let messageLen = readU16(payload, 3)
        #expect(messageLen == UInt16(message.utf8.count))
        let decoded = String(data: payload[5..<(5 + Int(messageLen))], encoding: .utf8)
        #expect(decoded == message)
    }

    @Test("git_commit amend encodes amend flag, length, and message")
    func gitCommitAmendLayout() {
        let message = "fixup: previous subject"
        let payload = captureFrame { $0.send(.gitCommitAmend(message: message)) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_GIT_COMMIT)
        #expect(payload[2] == 1)
        let messageLen = readU16(payload, 3)
        #expect(messageLen == UInt16(message.utf8.count))
        let decoded = String(data: payload[5..<(5 + Int(messageLen))], encoding: .utf8)
        #expect(decoded == message)
    }

    @Test("git_open_diff encodes path and section")
    func gitOpenDiffLayout() {
        let path = "lib/editor.ex"
        let payload = captureFrame { $0.send(.gitOpenDiff(path: path, section: 2)) }

        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_GIT_OPEN_DIFF)
        let pathLen = readU16(payload, 2)
        #expect(pathLen == UInt16(path.utf8.count))
        let decoded = String(data: payload[4..<(4 + Int(pathLen))], encoding: .utf8)
        #expect(decoded == path)
        #expect(payload[4 + Int(pathLen)] == 2)
    }


    @Test("agent_tool_toggle encodes stable message ID")
    func agentToolToggleLayout() {
        let payload = captureFrame { $0.send(.agentToolToggle(messageID: 0x01020304)) }

        #expect(payload.count == 6)
        #expect(payload[0] == OP_GUI_ACTION)
        #expect(payload[1] == GUI_ACTION_AGENT_TOOL_TOGGLE)
        #expect(readU32(payload, 2) == 0x01020304)
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
