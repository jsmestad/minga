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
	batch = append(batch, generated.OPSetCursorShape, 0)                             // fixed:2
	batch = append(batch, generated.OPGuiIndentGuides, 0x00, 0x06, 1, 2, 3, 4, 5, 6) // len16, 9 bytes
	batch = append(batch, generated.OPGuiStatusBar, 1, 0x01, 0x00, 0x02, 0xAA, 0xBB) // sectioned, 7 bytes
	batch = append(batch, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)           // fixed:9 (frame_seq + echoed input_seq)

	var warnings []string
	cmds := decodePacket(batch, func(_ byte, text string) { warnings = append(warnings, text) })
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", warnings)
	}

	// All four commands must survive: cursor, indent-guides (chrome), status bar, commit_frame.
	if len(cmds) != 4 {
		t.Fatalf("got %d commands, want 4: %+v", len(cmds), cmds)
	}
	if cmds[0].Kind != protocol.CommandSetCursorShape {
		t.Errorf("cmd[0] = %v, want SetCursorShape", cmds[0].Kind)
	}
	if cmds[len(cmds)-1].Kind != protocol.CommandCommitFrame {
		t.Errorf("last cmd = %v, want CommitFrame (frame not swallowed)", cmds[len(cmds)-1].Kind)
	}
}

// gui_window_overlay_delta (0xA0) is custom-framed: its decoder owns sizing.
// It must return a bounded size (13 bytes, or 18 with a cursorline) rather than
// len(payload); otherwise an overlay-only cursor update swallows commit_frame and
// any following chrome, the same blank/stale-frame failure this PR prevents.
func TestDecodePacketDoesNotSwallowAfterOverlayDelta(t *testing.T) {
	for _, tc := range []struct {
		name  string
		flags byte
		extra []byte
	}{
		{"no cursorline", 0x01, nil},
		{"with cursorline", 0x01 | 0x02, []byte{0, 5, 0x11, 0x22, 0x33}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var batch []byte
			// opcode + window_id(2) + content_epoch(4) + flags(1) + cursor_row(2) + cursor_col(2) + cursor_shape(1)
			batch = append(batch, generated.OPGuiWindowOverlayDelta, 0, 1, 0, 0, 0, 2, tc.flags, 0, 3, 0, 4, 1)
			batch = append(batch, tc.extra...)
			batch = append(batch, generated.OPGuiStatusBar, 1, 0x01, 0x00, 0x02, 0xAA, 0xBB) // sectioned
			batch = append(batch, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)           // fixed:9 (frame_seq + echoed input_seq)

			cmds := decodePacket(batch, func(_ byte, text string) { t.Fatalf("unexpected warning: %s", text) })
			if len(cmds) != 3 {
				t.Fatalf("got %d commands, want 3 (overlay delta did not swallow): %+v", len(cmds), cmds)
			}
			if cmds[0].Kind != protocol.CommandWindowDelta {
				t.Errorf("cmd[0] = %v, want WindowDelta", cmds[0].Kind)
			}
			if cmds[len(cmds)-1].Kind != protocol.CommandCommitFrame {
				t.Errorf("last cmd = %v, want CommitFrame", cmds[len(cmds)-1].Kind)
			}
		})
	}
}

// A sizing/decode failure mid-batch must surface a CommandStreamError marker
// at the failure point and stop, rather than silently swallowing the rest (#2219).
// The model uses the marker to abort an open frame transaction and resync.
func TestDecodePacketSurfacesStreamErrorOnUnknownOpcode(t *testing.T) {
	var batch []byte
	batch = append(batch, generated.OPBeginFrame, 0, 0, 0, 5, 0, 0, 0, 0) // open transaction (seq 5, base 0)
	batch = append(batch, generated.OPSetCursorShape, 0)                  // a valid command before the failure
	batch = append(batch, 0x6F)                                           // unknown opcode (below chrome range, no schema size)

	var warnings []string
	cmds := decodePacket(batch, func(_ byte, text string) { warnings = append(warnings, text) })

	if len(cmds) != 3 {
		t.Fatalf("got %d commands, want 3 (begin, cursor, stream error): %+v", len(cmds), cmds)
	}
	if cmds[len(cmds)-1].Kind != protocol.CommandStreamError {
		t.Fatalf("last command should be a stream error marker, got %v", cmds[len(cmds)-1].Kind)
	}
	if len(warnings) != 1 {
		t.Fatalf("a stream error should warn exactly once, got %v", warnings)
	}
}
