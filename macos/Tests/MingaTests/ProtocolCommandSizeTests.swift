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
        #expect(commandSize([OP_CLEAR]) == .sized(1))
        #expect(commandSize([OP_SET_CURSOR, 0, 0, 0, 0]) == .sized(5))
        #expect(commandSize([OP_GUI_GUTTER_SEP, 0, 0, 0, 0, 0]) == .sized(6))
        // len16, the framing the Go reader previously mis-sized.
        #expect(commandSize([OP_GUI_INDENT_GUIDES, 0x00, 0x06, 1, 2, 3, 4, 5, 6]) == .sized(9))
        #expect(commandSize([OP_SET_TITLE, 0x00, 0x03, 0x61, 0x62, 0x63]) == .sized(6))
        // len32.
        #expect(commandSize([OP_GUI_FILE_TREE, 0, 0, 0, 2, 0xAA, 0xBB]) == .sized(7))
    }

    @Test func customOpcodesDeferToDecoder() {
        #expect(commandSize([OP_GUI_GIT_STATUS, 0, 0, 0, 0]) == .custom)
    }

    @Test func forwardCompatibleUnknownHighOpcode() {
        #expect(commandSize([0xB7, 0x00, 0x02, 0xAA, 0xBB]) == .sized(5))
    }

    @Test func reportsTruncatedPayload() {
        #expect(commandSize([OP_GUI_INDENT_GUIDES, 0x00]) == .incomplete)
        #expect(commandSize([]) == .incomplete)
    }

    @Test func decodeCommandsSkipsGeneratedSizedUnrenderedOpcode() throws {
        // batch_end is now fixed:5 (opcode + echoed correlation seq u32, #2215).
        let payload = Data([0xB7, 0x00, 0x02, 0xAA, 0xBB, OP_BATCH_END, 0, 0, 0, 0])
        var commands: [RenderCommand] = []

        try decodeCommands(from: payload) { command in
            commands.append(command)
        }

        #expect(commands.count == 1)
        guard case .batchEnd = commands.first else {
            Issue.record("Expected .batchEnd but got \(String(describing: commands.first))")
            return
        }
    }
}
