package port

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// Regression for the gui_indent_guides (0x91) desync: an opcode the Go renderer
// does not explicitly decode must advance by its real framed length, not swallow
// the rest of the batch. Before the schema-driven CommandSize authority, 0x91 was
// mis-sized to 2 bytes and a stray byte consumed every following chrome command.
func TestDecodePacketDoesNotSwallowAfterIndentGuides(t *testing.T) {
	var batch []byte
	batch = append(batch, generated.OPSetCursor, 0, 0, 0, 0)                         // fixed:5
	batch = append(batch, generated.OPGuiIndentGuides, 0x00, 0x06, 1, 2, 3, 4, 5, 6) // len16, 9 bytes
	batch = append(batch, generated.OPGuiStatusBar, 1, 0x01, 0x00, 0x02, 0xAA, 0xBB) // sectioned, 7 bytes
	batch = append(batch, generated.OPBatchEnd)                                      // fixed:1

	var warnings []string
	cmds, err := decodePacket(batch, func(_ byte, text string) { warnings = append(warnings, text) })
	if err != nil {
		t.Fatalf("decodePacket error: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", warnings)
	}

	// All four commands must survive: cursor, indent-guides (chrome), status bar, batch_end.
	if len(cmds) != 4 {
		t.Fatalf("got %d commands, want 4: %+v", len(cmds), cmds)
	}
	if cmds[0].Kind != protocol.CommandSetCursor {
		t.Errorf("cmd[0] = %v, want SetCursor", cmds[0].Kind)
	}
	if cmds[len(cmds)-1].Kind != protocol.CommandBatchEnd {
		t.Errorf("last cmd = %v, want BatchEnd (frame not swallowed)", cmds[len(cmds)-1].Kind)
	}
}
