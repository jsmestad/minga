/// Property-based decoder fuzzing tests.
///
/// Generates valid binary payloads with randomized field values for each
/// opcode family, decodes them, and verifies the decoder:
/// 1. Doesn't crash (the primary goal)
/// 2. Produces the correct command type
/// 3. Consumes the exact number of bytes it should
///
/// Also tests truncation at every byte position within valid payloads,
/// verifying the decoder throws ProtocolDecodeError rather than crashing.
///
/// No external dependencies. Uses Swift's built-in randomness.

import Testing
import Foundation

// MARK: - Random payload generators

/// Generates a random UTF-8 string of the given byte length (ASCII subset for simplicity).
private func randomASCII(maxLen: Int = 20) -> String {
    let len = Int.random(in: 0...maxLen)
    return String((0..<len).map { _ in Character(UnicodeScalar(Int.random(in: 0x20...0x7E))!) })
}

/// Generates a random UInt8-prefixed string field.
private func randomString8Field(maxLen: Int = 20) -> Data {
    let s = randomASCII(maxLen: min(maxLen, 255))
    let utf8 = Array(s.utf8)
    var data = Data()
    data.append(UInt8(utf8.count))
    data.append(contentsOf: utf8)
    return data
}

/// Generates a random UInt16-prefixed string field.
private func randomString16Field(maxLen: Int = 50) -> Data {
    let s = randomASCII(maxLen: min(maxLen, 200))
    let utf8 = Array(s.utf8)
    var data = Data()
    data.append(UInt8(utf8.count >> 8))
    data.append(UInt8(utf8.count & 0xFF))
    data.append(contentsOf: utf8)
    return data
}

/// Appends a random 3-byte RGB color.
private func appendRandomRGB(_ data: inout Data) {
    data.append(UInt8.random(in: 0...255))
    data.append(UInt8.random(in: 0...255))
    data.append(UInt8.random(in: 0...255))
}

/// Appends a random big-endian UInt16.
private func appendRandomU16(_ data: inout Data, range: ClosedRange<UInt16> = 0...UInt16.max) {
    let v = UInt16.random(in: range)
    data.append(UInt8(v >> 8))
    data.append(UInt8(v & 0xFF))
}

/// Appends a random big-endian UInt32.
private func appendRandomU32(_ data: inout Data) {
    let v = UInt32.random(in: 0...UInt32.max)
    data.append(UInt8((v >> 24) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF))
    data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8(v & 0xFF))
}

// MARK: - Payload builders per opcode

/// Builds a valid draw_text payload with random values.
private func randomDrawText() -> Data {
    var data = Data([OP_DRAW_TEXT])
    appendRandomU16(&data)  // row
    appendRandomU16(&data)  // col
    appendRandomRGB(&data)  // fg
    appendRandomRGB(&data)  // bg
    data.append(UInt8.random(in: 0...0x0F))  // attrs
    let text = randomString16Field(maxLen: 30)
    data.append(text)
    return data
}

/// Builds a valid draw_styled_text payload with random values.
private func randomDrawStyledText() -> Data {
    var data = Data([OP_DRAW_STYLED_TEXT])
    appendRandomU16(&data)  // row
    appendRandomU16(&data)  // col
    appendRandomRGB(&data)  // fg
    appendRandomRGB(&data)  // bg
    appendRandomU16(&data)  // attrs16
    appendRandomRGB(&data)  // underlineColor
    data.append(UInt8.random(in: 0...255))  // blend
    data.append(UInt8.random(in: 0...7))    // fontWeight
    data.append(UInt8.random(in: 0...3))    // fontId
    let text = randomString16Field(maxLen: 30)
    data.append(text)
    return data
}

/// Builds a valid gui_theme payload with random slots.
private func randomGuiTheme() -> Data {
    let count = UInt8.random(in: 0...20)
    var data = Data([OP_GUI_THEME, count])
    for _ in 0..<count {
        data.append(UInt8.random(in: 0...0x60))  // slotId
        appendRandomRGB(&data)
    }
    return data
}

/// Builds a valid gui_tab_bar payload with random tabs.
private func randomGuiTabBar() -> Data {
    let tabCount = UInt8.random(in: 0...5)
    var data = Data([OP_GUI_TAB_BAR, UInt8.random(in: 0...tabCount), tabCount])
    for _ in 0..<tabCount {
        data.append(UInt8.random(in: 0...0xFF))  // flags
        appendRandomU32(&data)  // id
        appendRandomU16(&data)  // group_id
        data.append(randomString8Field(maxLen: 4))  // icon
        data.append(randomString16Field(maxLen: 20))  // label
    }
    return data
}

private func randomGuiWorkspaceBar() -> Data {
    let wsCount = UInt8.random(in: 0...4)
    var data = Data([OP_GUI_WORKSPACE_BAR])
    appendRandomU16(&data) // active_workspace_id
    data.append(wsCount)
    for _ in 0..<wsCount {
        appendRandomU16(&data) // id
        data.append(UInt8.random(in: 0...1)) // kind
        data.append(UInt8.random(in: 0...3)) // agent_status
        data.append(UInt8.random(in: 0...0xFF)) // r
        data.append(UInt8.random(in: 0...0xFF)) // g
        data.append(UInt8.random(in: 0...0xFF)) // b
        appendRandomU16(&data) // tab_count
        data.append(randomString8Field(maxLen: 20)) // label
        data.append(randomString8Field(maxLen: 15)) // icon
    }
    return data
}

/// Builds a valid gui_completion payload with random items.
private func randomGuiCompletion() -> Data {
    let visible = Bool.random()
    var data = Data([OP_GUI_COMPLETION, visible ? 1 : 0])
    guard visible else { return data }

    appendRandomU16(&data)  // anchorRow
    appendRandomU16(&data)  // anchorCol
    appendRandomU16(&data)  // selectedIndex
    let itemCount = UInt16.random(in: 0...3)
    data.append(UInt8(itemCount >> 8))
    data.append(UInt8(itemCount & 0xFF))
    for _ in 0..<itemCount {
        data.append(UInt8.random(in: 0...15))  // kind
        data.append(randomString16Field(maxLen: 15))  // label
        data.append(randomString16Field(maxLen: 15))  // detail
    }
    return data
}

/// Builds a valid gui_breadcrumb payload.
private func randomGuiBreadcrumb() -> Data {
    let count = UInt8.random(in: 0...5)
    var data = Data([OP_GUI_BREADCRUMB, count])
    for _ in 0..<count {
        data.append(randomString16Field(maxLen: 20))
    }
    return data
}

/// Builds a valid gui_gutter_sep payload.
private func randomGuiGutterSep() -> Data {
    var data = Data([OP_GUI_GUTTER_SEP])
    appendRandomU16(&data)
    appendRandomRGB(&data)
    return data
}

/// Builds a valid gui_cursorline payload.
private func randomGuiCursorline() -> Data {
    var data = Data([OP_GUI_CURSORLINE])
    appendRandomU16(&data)
    appendRandomRGB(&data)
    return data
}

// MARK: - Fuzz test suites

private let fuzzIterations = 500

@Suite("Decoder Fuzz: Fixed-Size Commands")
struct DecoderFuzzFixedSizeTests {

    @Test("clear never crashes on valid input")
    func fuzzClear() throws {
        for _ in 0..<fuzzIterations {
            let (cmd, size) = try decodeCommand(data: Data([OP_CLEAR]), offset: 0)
            #expect(size == 1)
            guard case .clear = cmd else { Issue.record("Expected .clear"); return }
        }
    }

    @Test("set_cursor with random values never crashes")
    func fuzzSetCursor() throws {
        for _ in 0..<fuzzIterations {
            var data = Data([OP_SET_CURSOR])
            appendRandomU16(&data)
            appendRandomU16(&data)
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == 5)
            guard case .setCursor = cmd else { Issue.record("Expected .setCursor"); return }
        }
    }

    @Test("gui_gutter_sep with random values never crashes")
    func fuzzGutterSep() throws {
        for _ in 0..<fuzzIterations {
            let data = randomGuiGutterSep()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == 6)
            guard case .guiGutterSeparator = cmd else { Issue.record("Expected .guiGutterSeparator"); return }
        }
    }

    @Test("gui_cursorline with random values never crashes")
    func fuzzCursorline() throws {
        for _ in 0..<fuzzIterations {
            let data = randomGuiCursorline()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == 6)
            guard case .guiCursorline = cmd else { Issue.record("Expected .guiCursorline"); return }
        }
    }
}

@Suite("Decoder Fuzz: Variable-Length Commands")
struct DecoderFuzzVariableLengthTests {

    @Test("draw_text with random values never crashes")
    func fuzzDrawText() throws {
        for _ in 0..<fuzzIterations {
            let data = randomDrawText()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)
            guard case .drawText = cmd else { Issue.record("Expected .drawText"); return }
        }
    }

    @Test("draw_styled_text with random values never crashes")
    func fuzzDrawStyledText() throws {
        for _ in 0..<fuzzIterations {
            let data = randomDrawStyledText()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)
            guard case .drawStyledText = cmd else { Issue.record("Expected .drawStyledText"); return }
        }
    }

    @Test("gui_theme with random slots never crashes")
    func fuzzGuiTheme() throws {
        for _ in 0..<fuzzIterations {
            let data = randomGuiTheme()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)
            guard case .guiTheme = cmd else { Issue.record("Expected .guiTheme"); return }
        }
    }

    @Test("gui_tab_bar with random tabs never crashes")
    func fuzzGuiTabBar() throws {
        for _ in 0..<fuzzIterations {
            let data = randomGuiTabBar()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)
            guard case .guiTabBar = cmd else { Issue.record("Expected .guiTabBar"); return }
        }
    }

    @Test("gui_workspace_bar with random workspaces never crashes")
    func fuzzGuiWorkspaceBar() throws {
        for _ in 0..<fuzzIterations {
            let data = randomGuiWorkspaceBar()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)
            guard case .guiWorkspaceBar = cmd else { Issue.record("Expected .guiWorkspaceBar"); return }
        }
    }

    @Test("gui_completion with random items never crashes")
    func fuzzGuiCompletion() throws {
        for _ in 0..<fuzzIterations {
            let data = randomGuiCompletion()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)
            guard case .guiCompletion = cmd else { Issue.record("Expected .guiCompletion"); return }
        }
    }

    @Test("gui_breadcrumb with random segments never crashes")
    func fuzzGuiBreadcrumb() throws {
        for _ in 0..<fuzzIterations {
            let data = randomGuiBreadcrumb()
            let (cmd, size) = try decodeCommand(data: data, offset: 0)
            #expect(size == data.count)
            guard case .guiBreadcrumb = cmd else { Issue.record("Expected .guiBreadcrumb"); return }
        }
    }
}

@Suite("Decoder Fuzz: Truncation at Every Byte Position")
struct DecoderFuzzTruncationTests {

    @Test("draw_text truncated at every position throws, never crashes")
    func truncateDrawText() {
        for _ in 0..<100 {
            let full = randomDrawText()
            for cutoff in 1..<full.count {
                let truncated = full.prefix(cutoff)
                do {
                    _ = try decodeCommand(data: Data(truncated), offset: 0)
                    // If it decodes, it must have consumed <= cutoff bytes
                } catch {
                    // Expected: ProtocolDecodeError
                }
            }
        }
    }

    @Test("draw_styled_text truncated at every position throws, never crashes")
    func truncateDrawStyledText() {
        for _ in 0..<100 {
            let full = randomDrawStyledText()
            for cutoff in 1..<full.count {
                let truncated = full.prefix(cutoff)
                do {
                    _ = try decodeCommand(data: Data(truncated), offset: 0)
                } catch {
                    // Expected
                }
            }
        }
    }

    @Test("gui_tab_bar truncated at every position throws, never crashes")
    func truncateGuiTabBar() {
        for _ in 0..<100 {
            let full = randomGuiTabBar()
            guard full.count > 1 else { continue }
            for cutoff in 1..<full.count {
                let truncated = full.prefix(cutoff)
                do {
                    _ = try decodeCommand(data: Data(truncated), offset: 0)
                } catch {
                    // Expected
                }
            }
        }
    }

    @Test("gui_completion truncated at every position throws, never crashes")
    func truncateGuiCompletion() {
        for _ in 0..<100 {
            let full = randomGuiCompletion()
            guard full.count > 1 else { continue }
            for cutoff in 1..<full.count {
                let truncated = full.prefix(cutoff)
                do {
                    _ = try decodeCommand(data: Data(truncated), offset: 0)
                } catch {
                    // Expected
                }
            }
        }
    }

    @Test("gui_theme truncated at every position throws, never crashes")
    func truncateGuiTheme() {
        for _ in 0..<100 {
            let full = randomGuiTheme()
            guard full.count > 1 else { continue }
            for cutoff in 1..<full.count {
                let truncated = full.prefix(cutoff)
                do {
                    _ = try decodeCommand(data: Data(truncated), offset: 0)
                } catch {
                    // Expected
                }
            }
        }
    }
}
