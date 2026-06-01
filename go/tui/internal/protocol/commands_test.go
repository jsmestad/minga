package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestEncodeReadyReportsSemanticTUI(t *testing.T) {
	packet := EncodeReady(120, 40)
	if len(packet) != 14 {
		t.Fatalf("ready packet length = %d, want 14", len(packet))
	}
	if packet[0] != generated.OPReady {
		t.Fatalf("opcode = 0x%02X, want ready", packet[0])
	}
	if packet[5] != 1 || packet[6] != 7 {
		t.Fatalf("capability header = {%d,%d}, want {1,7}", packet[5], packet[6])
	}
	if packet[7] != 0 || packet[13] != 1 {
		t.Fatalf("capabilities should report tui with semantic_ui=true: %#v", packet[7:])
	}
}

func TestDecodeWindowContentRows(t *testing.T) {
	row := []byte{
		0,
		0, 0, 0, 0, 0, 0, 0, 9,
		0, 0, 0, 4,
		0, 0, 0, 5,
		0, 0, 0, 2,
		'h', 'i',
		0, 1,
		0, 0, 0, 2,
		0xFF, 0xFF, 0xFF,
		0, 0, 0,
		1,
		2,
		0,
	}
	rowsPayload := append([]byte{0, 1}, row...)
	headerPayload := []byte{0, 7, 0x02, 0, 3, 0, 4, 1, 0, 0, 0, 0, 0, 11}
	packet := append([]byte{generated.OPGuiWindowContent, 2, 0x01, 0, byte(len(headerPayload))}, headerPayload...)
	packet = append(packet, 0x02, byte(len(rowsPayload)>>8), byte(len(rowsPayload)))
	packet = append(packet, rowsPayload...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Kind != CommandWindowContent {
		t.Fatalf("kind = %v, want window content", command.Kind)
	}
	if command.Window.ID != 7 || command.Window.CursorRow != 3 || command.Window.CursorCol != 4 {
		t.Fatalf("header decoded incorrectly: %+v", command.Window)
	}
	if len(command.Window.Rows) != 1 || command.Window.Rows[0].Text != "hi" {
		t.Fatalf("rows decoded incorrectly: %+v", command.Window.Rows)
	}
	if got := command.Window.Rows[0].Spans[0].FG; got != 0xFFFFFF {
		t.Fatalf("span fg = 0x%06X, want 0xFFFFFF", got)
	}
}

func TestDecodeSkipsFontCommandsWithoutDroppingFollowingCommands(t *testing.T) {
	registerFont := []byte{generated.OPRegisterFont, 1, 0, 4, 'F', 'i', 'r', 'a'}
	batchEnd := []byte{generated.OPBatchEnd}
	packet := append(registerFont, batchEnd...)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand font returned error: %v", err)
	}
	if first.Size != len(registerFont) {
		t.Fatalf("font command size = %d, want %d", first.Size, len(registerFont))
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand batch returned error: %v", err)
	}
	if second.Kind != CommandBatchEnd {
		t.Fatalf("second kind = %v, want batch end", second.Kind)
	}
}

func TestDecodeTabBarChromeSummary(t *testing.T) {
	tab := []byte{
		1,
		0, 0, 0, 9,
		0, 2,
		1, '*',
		0, 4, 'm', 'a', 'i', 'n',
		0, 0, 0, 0,
	}
	packet := append([]byte{generated.OPGuiTabBar, 0, 1}, tab...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Kind != CommandChrome {
		t.Fatalf("kind = %v, want chrome", command.Kind)
	}
	if command.Chrome.Summary != "** main" {
		t.Fatalf("summary = %q, want active tab label", command.Chrome.Summary)
	}
}
