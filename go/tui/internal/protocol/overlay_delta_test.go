package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestDecodeOverlayDeltaConsumesMandatoryAccessibilityTrailer(t *testing.T) {
	for _, tc := range []struct {
		name       string
		flags      byte
		cursorline []byte
		cursor     []byte
	}{
		{"cursor", 1, nil, []byte{0, 0, 0, 4}},
		{"absent accessible cursor", 1, nil, []byte{0xFF, 0xFF, 0xFF, 0xFF}},
		{"cursorline", 3, []byte{0, 5, 0x11, 0x22, 0x33}, []byte{0, 0, 0, 4}},
		{"cursorline without accessible cursor", 3, []byte{0, 5, 0x11, 0x22, 0x33}, []byte{0xFF, 0xFF, 0xFF, 0xFF}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := []byte{generated.OPGuiWindowOverlayDelta, 0, 1, 0, 0, 0, 2, tc.flags, 0, 3, 0, 4, 1}
			payload = append(payload, tc.cursorline...)
			payload = append(payload, tc.cursor...)
			batch := append(append([]byte(nil), payload...), generated.OPCommitFrame, 0, 0, 0, 7, 0, 0, 0, 0)
			command, err := DecodeCommand(batch)
			if err != nil || command.Kind != CommandWindowDelta || command.Size != len(payload) {
				t.Fatalf("overlay framing: command=%+v error=%v, want size %d", command, err, len(payload))
			}
			if command.Window.ID != 1 || command.Window.CursorRow != 3 || command.Window.CursorCol != 4 {
				t.Fatalf("overlay payload changed: %+v", command.Window)
			}
			if command.Window.Cursorline.Visible != (tc.flags&2 != 0) {
				t.Fatalf("cursorline presence changed: %+v", command.Window.Cursorline)
			}
			next, err := DecodeCommand(batch[command.Size:])
			if err != nil || next.Kind != CommandCommitFrame || next.FrameSeq != 7 {
				t.Fatalf("accessibility trailer did not preserve following commit: %+v %v", next, err)
			}
			for size := range len(payload) {
				if _, err := DecodeCommand(payload[:size]); err == nil {
					t.Fatalf("accepted truncated overlay: %d of %d bytes", size, len(payload))
				}
			}
		})
	}
}
