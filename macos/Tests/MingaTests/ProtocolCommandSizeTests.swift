/// Conformance for the schema-generated command_size sizing.
///
/// The generated `commandSize(_:)` is the authority a batch reader uses to
/// advance between concatenated commands. The gui_indent_guides (0x91) case is
/// the regression that desynced the Go renderer when an opcode was sized by
/// guesswork instead of its declared framing.

import Foundation
import Testing

struct ProtocolCommandSizeTests {
    @Test func sizesGenericFramings() {
        #expect(commandSize([OP_SET_CURSOR_SHAPE, 0]) == .sized(2))
        #expect(commandSize([OP_SET_WINDOW_BG, 0x28, 0x2C, 0x34]) == .sized(4))
        #expect(commandSize([OP_GUI_GUTTER_SEP, 0, 0, 0, 0, 0]) == .sized(6))
        // len16, the framing the Go reader previously mis-sized.
        #expect(commandSize([OP_GUI_INDENT_GUIDES, 0x00, 0x06, 1, 2, 3, 4, 5, 6]) == .sized(9))
        #expect(commandSize([OP_SET_TITLE, 0x00, 0x03, 0x61, 0x62, 0x63]) == .sized(6))
        // len32.
        #expect(commandSize([OP_GUI_FILE_TREE, 0, 0, 0, 2, 0xAA, 0xBB]) == .sized(7))
        // #2654 slice 1: the resident agent transcript is len32-framed, so a
        // frontend that does not yet consume it still sizes and skips it cleanly.
        #expect(commandSize([OP_GUI_AGENT_TRANSCRIPT, 0, 0, 0, 2, 0xAA, 0xBB]) == .sized(7))
    }

    @Test func sizesFrameTransactionMarkers() {
        // begin_frame/commit_frame (#2219 child A) are fixed:9 = opcode + two u32.
        #expect(commandSize([OP_BEGIN_FRAME, 0, 0, 0, 7, 0, 0, 0, 0]) == .sized(9))
        #expect(commandSize([OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 5]) == .sized(9))
        #expect(commandSize([OP_BEGIN_FRAME, 0, 0, 0]) == .incomplete)
    }

    @Test func customOpcodesDeferToDecoder() {
        #expect(commandSize([OP_GUI_GIT_STATUS, 0, 0, 0, 0]) == .custom)
    }

    @Test func unknownHighOpcodeFailsClosed() {
        #expect(commandSize([0xB7, 0x00, 0x02, 0xAA, 0xBB]) == .unknown)
    }

    @Test func reportsTruncatedPayload() {
        #expect(commandSize([OP_GUI_INDENT_GUIDES, 0x00]) == .incomplete)
        #expect(commandSize([]) == .incomplete)
    }

    @Test func decodeCommandsRejectsGeneratedSizedUnknownOpcode() {
        let payload = Data([0xB7, 0x00, 0x02, 0xAA, 0xBB, OP_COMMIT_FRAME, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: ProtocolDecodeError.self) {
            try decodeCommands(from: payload) { _ in }
        }
    }
}
