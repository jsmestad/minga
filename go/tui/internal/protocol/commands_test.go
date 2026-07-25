package protocol

import (
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestEncodeReadyReportsSemanticTUI(t *testing.T) {
	packet := EncodeReady(120, 40)
	// Capability format 2 carries 20 fields plus a u16 protocol-version tail.
	if len(packet) != 29 {
		t.Fatalf("ready packet length = %d, want 29", len(packet))
	}
	if packet[0] != generated.OPReady {
		t.Fatalf("opcode = 0x%02X, want ready", packet[0])
	}
	if packet[5] != 2 || packet[6] != 20 {
		t.Fatalf("capability header = {%d,%d}, want {2,20}", packet[5], packet[6])
	}
	if packet[7] != 0 || packet[13] != 1 || packet[14] != 1 {
		t.Fatalf("capabilities should report semantic TUI resource policy: %#v", packet[7:])
	}
	if got := binary.BigEndian.Uint32(packet[15:19]); got != 64*1024*1024 {
		t.Fatalf("max_frame_bytes = %d", got)
	}
	if got := binary.BigEndian.Uint32(packet[19:23]); got != 0 {
		t.Fatalf("max_frame_commands = %d, want unadvertised", got)
	}
	if got := binary.BigEndian.Uint32(packet[23:27]); got != 0 {
		t.Fatalf("max_window_rows = %d, want unadvertised", got)
	}
	version := uint16(packet[27])<<8 | uint16(packet[28])
	if version != generated.ProtocolVersion {
		t.Fatalf("protocol_version tail = %d, want %d", version, generated.ProtocolVersion)
	}
}

func TestEncodeInputEventLayouts(t *testing.T) {
	key := EncodeKeyPress('A', 0x03, 4242)
	if len(key) != 10 || key[0] != generated.OPKeyPress || binary.BigEndian.Uint32(key[6:10]) != 4242 {
		t.Fatalf("key_press layout = %v, want 10 bytes with sequence tail", key)
	}

	mouse := EncodeMouseEvent(-1, 5, 0, 0x02, MousePress, 1)
	if len(mouse) != 9 || mouse[0] != generated.OPMouseEvent || mouse[8] != 1 {
		t.Fatalf("mouse_event layout = %v, want 9 bytes with click count", mouse)
	}
}

func TestDecodeProtocolError(t *testing.T) {
	message := "protocol_version mismatch: frontend 1, beam 2"
	packet := []byte{generated.OPProtocolError, byte(len(message) >> 8), byte(len(message))}
	packet = append(packet, []byte(message)...)
	// A trailing commit_frame proves the len16 frame is bounded and does not swallow
	// the rest of the stream.
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Kind != CommandProtocolError {
		t.Fatalf("kind = %v, want protocol error", command.Kind)
	}
	if command.ProtocolError != message {
		t.Fatalf("message = %q, want %q", command.ProtocolError, message)
	}
	if command.Size != 3+len(message) {
		t.Fatalf("size = %d, want %d", command.Size, 3+len(message))
	}

	second, err := DecodeCommand(packet[command.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

func TestDecodeBeginFrame(t *testing.T) {
	// begin_frame (#2739): opcode + frame_seq:u32 + base_frame_seq:u32 + generation:u32.
	packet := []byte{generated.OPBeginFrame, 0, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0, 9}
	cmd, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if cmd.Kind != CommandBeginFrame {
		t.Fatalf("kind = %v, want begin frame", cmd.Kind)
	}
	if cmd.Size != 13 {
		t.Fatalf("size = %d, want 13", cmd.Size)
	}
	if cmd.FrameSeq != 7 || cmd.BaseFrameSeq != 3 || cmd.Generation != 9 {
		t.Fatalf("frame_seq/base/generation = %d/%d/%d, want 7/3/9", cmd.FrameSeq, cmd.BaseFrameSeq, cmd.Generation)
	}
}

func TestDecodeCommitFrameCarriesInputSeq(t *testing.T) {
	// commit_frame (#2219): opcode + frame_seq:u32 + input_seq:u32. input_seq is
	// the echoed input correlation sequence (ticket #2215).
	packet := []byte{generated.OPCommitFrame, 0, 0, 0, 7, 0, 0, 0x10, 0x92}
	cmd, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if cmd.Kind != CommandCommitFrame {
		t.Fatalf("kind = %v, want commit frame", cmd.Kind)
	}
	if cmd.Size != 9 {
		t.Fatalf("size = %d, want 9", cmd.Size)
	}
	if cmd.FrameSeq != 7 {
		t.Fatalf("frame_seq = %d, want 7", cmd.FrameSeq)
	}
	if cmd.InputSeq != 0x1092 {
		t.Fatalf("input_seq = %d, want %d", cmd.InputSeq, 0x1092)
	}
}

func TestDecodeProtocolErrorShortPayloads(t *testing.T) {
	if _, err := DecodeCommand([]byte{generated.OPProtocolError, 0}); err == nil {
		t.Fatalf("expected error for truncated protocol_error header")
	}
	if _, err := DecodeCommand([]byte{generated.OPProtocolError, 0, 5, 'h', 'i'}); err == nil {
		t.Fatalf("expected error for truncated protocol_error message")
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
	rowsPayload := append([]byte{0, 0, 0, 1}, row...)
	headerPayload := []byte{0, 7, 0x02, 0, 3, 0, 4, 1, 0, 0, 0, 0, 0, 11}
	packet := windowContentPacket(section32(0x01, headerPayload), section32(0x02, rowsPayload))

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
	if !command.Window.CursorVisible {
		t.Fatalf("full window header should decode cursor_visible from flags: %+v", command.Window)
	}
	if len(command.Window.Rows) != 1 || command.Window.Rows[0].Text != "hi" {
		t.Fatalf("rows decoded incorrectly: %+v", command.Window.Rows)
	}
	if got := command.Window.Rows[0].Spans[0].FG; got != 0xFFFFFF {
		t.Fatalf("span fg = 0x%06X, want 0xFFFFFF", got)
	}
}

func TestDecodeWindowContentRequiresOneHeaderAndRows(t *testing.T) {
	header := []byte{0, 7, 0x02, 0, 3, 0, 4, 1, 0, 0, 0, 0, 0, 11}
	rows := []byte{0, 0, 0, 0}

	tests := []struct {
		name   string
		packet []byte
	}{
		{name: "empty sections", packet: windowContentPacket()},
		{name: "missing rows", packet: windowContentPacket(section32(0x01, header))},
		{name: "missing header", packet: windowContentPacket(section32(0x02, rows))},
		{name: "duplicate header", packet: windowContentPacket(section32(0x01, header), section32(0x01, header), section32(0x02, rows))},
		{name: "duplicate rows", packet: windowContentPacket(section32(0x01, header), section32(0x02, rows), section32(0x02, rows))},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := DecodeCommand(tt.packet); err == nil {
				t.Fatal("DecodeCommand accepted an incomplete semantic window")
			}
		})
	}
}

func TestDecodeWindowContentScrollPresentation(t *testing.T) {
	headerPayload := []byte{0, 7, 0x02, 0, 3, 0, 4, 1, 0, 2, 0, 0, 0, 42}
	rowsPayload := []byte{0, 0, 0, 0}
	scrollPayload := []byte{0, 7, 0x01}
	scrollPayload = append(scrollPayload, u32Bytes(5)...)
	scrollPayload = append(scrollPayload, 0, 2)
	scrollPayload = append(scrollPayload, 0, 1)
	scrollPayload = append(scrollPayload, u32Bytes(5)...)
	scrollPayload = append(scrollPayload, u32Bytes(15)...)
	scrollPayload = append(scrollPayload, u32Bytes(4)...)
	scrollPayload = append(scrollPayload, u32Bytes(18)...)
	scrollPayload = append(scrollPayload, u32Bytes(42)...)
	scrollPayload = append(scrollPayload, u32Bytes(99)...)
	scrollPayload = append(scrollPayload, u32Bytes(3)...) // scroll_seq (#2661)

	packet := windowContentPacket(
		section32(0x01, headerPayload),
		section32(0x02, rowsPayload),
		section32(0x0A, scrollPayload),
	)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Kind != CommandWindowContent {
		t.Fatalf("kind = %v, want window content", command.Kind)
	}
	if !command.Window.ScrollSet {
		t.Fatalf("scroll presentation should be marked present: %+v", command.Window)
	}
	scroll := command.Window.Scroll
	if scroll.WindowID != 7 || !scroll.ResetRequired || scroll.AnchorTop != 5 || scroll.AnchorLeft != 2 || scroll.AnchorVisualRowOffset != 1 {
		t.Fatalf("scroll anchor decoded incorrectly: %+v", scroll)
	}
	if scroll.VisibleStartLine != 5 || scroll.VisibleEndLine != 15 || scroll.OverscanStartLine != 4 || scroll.OverscanEndLine != 18 {
		t.Fatalf("scroll ranges decoded incorrectly: %+v", scroll)
	}
	if scroll.ContentEpoch != 42 || scroll.LayoutGeneration != 99 {
		t.Fatalf("scroll identity decoded incorrectly: %+v", scroll)
	}
	if scroll.ScrollSeq != 3 {
		t.Fatalf("scroll_seq decoded incorrectly: %+v", scroll)
	}
}

func TestDecodeWindowContentDropsMismatchedScrollPresentation(t *testing.T) {
	headerPayload := []byte{0, 7, 0x02, 0, 3, 0, 4, 1, 0, 2, 0, 0, 0, 42}
	rowsPayload := []byte{0, 0, 0, 0}
	scrollPayload := []byte{0, 8, 0x01}
	scrollPayload = append(scrollPayload, u32Bytes(5)...)
	scrollPayload = append(scrollPayload, 0, 2)
	scrollPayload = append(scrollPayload, 0, 1)
	scrollPayload = append(scrollPayload, u32Bytes(5)...)
	scrollPayload = append(scrollPayload, u32Bytes(15)...)
	scrollPayload = append(scrollPayload, u32Bytes(4)...)
	scrollPayload = append(scrollPayload, u32Bytes(18)...)
	scrollPayload = append(scrollPayload, u32Bytes(42)...)
	scrollPayload = append(scrollPayload, u32Bytes(99)...)
	scrollPayload = append(scrollPayload, u32Bytes(3)...) // scroll_seq (#2661)

	packet := windowContentPacket(
		section32(0x01, headerPayload),
		section32(0x02, rowsPayload),
		section32(0x0A, scrollPayload),
	)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Window.ScrollSet {
		t.Fatalf("mismatched scroll presentation should be dropped: %+v", command.Window.Scroll)
	}
}

func TestDecodeWindowRowsAndViewportDeltasIncludeRowRefs(t *testing.T) {
	ref := []byte{
		0,
		0, 0, 0, 0, 0, 0, 0, 9,
		0, 0, 0, 5,
	}
	rowsPayload := append([]byte{0, 0, 0, 1}, ref...)
	tests := []struct {
		name              string
		opcode            byte
		header            []byte
		wantID            uint16
		wantEpoch         uint32
		wantRow           uint16
		wantCol           uint16
		wantShape         byte
		wantScroll        uint16
		wantCursorVisible bool
	}{
		{name: "rows", opcode: generated.OPGuiWindowRowsDelta, header: []byte{0, 7, 0x12, 0x34, 0x56, 0x78, 0xAA, 0, 9, 0, 11, 2, 0, 13}, wantID: 7, wantEpoch: 0x12345678, wantRow: 9, wantCol: 11, wantShape: 2, wantScroll: 13, wantCursorVisible: false},
		{name: "viewport", opcode: generated.OPGuiWindowViewportDelta, header: []byte{0, 8, 0x22, 0x33, 0x44, 0x55, 0xBB, 0, 10, 0, 12, 3, 0, 14}, wantID: 8, wantEpoch: 0x22334455, wantRow: 10, wantCol: 12, wantShape: 3, wantScroll: 14, wantCursorVisible: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			packet := append([]byte{tt.opcode, 2, 0x01, 0, 0, 0, byte(len(tt.header))}, tt.header...)
			packet = append(packet, 0x02, 0, 0, byte(len(rowsPayload)>>8), byte(len(rowsPayload)))
			packet = append(packet, rowsPayload...)
			packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

			command, err := DecodeCommand(packet)
			if err != nil {
				t.Fatalf("DecodeCommand returned error: %v", err)
			}
			if command.Kind != CommandWindowDelta {
				t.Fatalf("kind = %v, want window delta", command.Kind)
			}
			window := command.Window
			if !window.ScrollLeftSet {
				t.Fatalf("scroll left should be marked present in delta header: %+v", window)
			}
			if window.ID != tt.wantID || window.ContentEpoch != tt.wantEpoch || window.CursorRow != tt.wantRow || window.CursorCol != tt.wantCol || window.CursorShape != tt.wantShape || window.ScrollLeft != tt.wantScroll {
				t.Fatalf("header decoded incorrectly: %+v", window)
			}
			if window.CursorVisible != tt.wantCursorVisible {
				t.Fatalf("cursor_visible decoded incorrectly: got %v want %v in %+v", window.CursorVisible, tt.wantCursorVisible, window)
			}
			if len(window.Rows) != 1 || !window.Rows[0].Ref {
				t.Fatalf("row ref decoded incorrectly: %+v", window.Rows)
			}
			if window.Rows[0].ID != 9 || window.Rows[0].ContentHash != 5 {
				t.Fatalf("row ref identity decoded incorrectly: %+v", window.Rows[0])
			}

			second, err := DecodeCommand(packet[command.Size:])
			if err != nil {
				t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
			}
			if second.Kind != CommandCommitFrame {
				t.Fatalf("second kind = %v, want commit frame", second.Kind)
			}
		})
	}
}

func TestDecodeWindowSectionedDeltaRequiresHeaderAndRows(t *testing.T) {
	header := []byte{0, 7, 0x12, 0x34, 0x56, 0x78, 0xAA, 0, 9, 0, 11, 2, 0, 13}
	rowsPayload := []byte{0, 0, 0, 0}

	tests := []struct {
		name   string
		opcode byte
		packet []byte
	}{
		{
			name:   "rows delta missing header",
			opcode: generated.OPGuiWindowRowsDelta,
			packet: append([]byte{generated.OPGuiWindowRowsDelta, 1}, append([]byte{0x02, 0, byte(len(rowsPayload))}, rowsPayload...)...),
		},
		{
			name:   "rows delta missing rows",
			opcode: generated.OPGuiWindowRowsDelta,
			packet: append([]byte{generated.OPGuiWindowRowsDelta, 1}, append([]byte{0x01, 0, byte(len(header))}, header...)...),
		},
		{
			name:   "viewport delta missing header",
			opcode: generated.OPGuiWindowViewportDelta,
			packet: append([]byte{generated.OPGuiWindowViewportDelta, 1}, append([]byte{0x02, 0, byte(len(rowsPayload))}, rowsPayload...)...),
		},
		{
			name:   "viewport delta missing rows",
			opcode: generated.OPGuiWindowViewportDelta,
			packet: append([]byte{generated.OPGuiWindowViewportDelta, 1}, append([]byte{0x01, 0, byte(len(header))}, header...)...),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := DecodeCommand(tt.packet); err == nil {
				t.Fatalf("DecodeCommand(%s) unexpectedly succeeded", tt.name)
			}
		})
	}
}

func TestDecodeSkipsFontCommandsWithoutDroppingFollowingCommands(t *testing.T) {
	registerFont := []byte{generated.OPRegisterFont, 1, 0, 4, 'F', 'i', 'r', 'a'}
	commitFrame := []byte{generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0}
	packet := append(registerFont, commitFrame...)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand font returned error: %v", err)
	}
	if first.Size != len(registerFont) {
		t.Fatalf("font command size = %d, want %d", first.Size, len(registerFont))
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
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
	if len(command.Chrome.Tabs.Tabs) != 1 {
		t.Fatalf("tab count = %d, want 1", len(command.Chrome.Tabs.Tabs))
	}
	if got := command.Chrome.Tabs.Tabs[0]; !got.Active || got.ID != 9 || got.Label != "main" {
		t.Fatalf("tab decoded incorrectly: %+v", got)
	}
}

func TestDecodeMinibufferChrome(t *testing.T) {
	packet := append([]byte{generated.OPGuiMinibuffer, 1, 2, 0, 3, 1, ':'}, string16("w")...)
	packet = append(packet, string16("write file")...)
	packet = append(packet, 0, 0, 0, 0, 0, 0)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	mini := command.Chrome.Mini
	if !mini.Visible || mini.Prompt != ":" || mini.Input != "w" || mini.Context != "write file" {
		t.Fatalf("minibuffer decoded incorrectly: %+v", mini)
	}
	if command.Chrome.Summary != ":w write file" {
		t.Fatalf("summary = %q, want prompt/input/context", command.Chrome.Summary)
	}
}

func TestDecodeWorkspacesChromeDoesNotSwallowFollowingCommands(t *testing.T) {
	workspace := []byte{
		0, 7,
		1,
		2,
		0, 3,
		0x44, 0x55, 0x66,
		0, 4,
		0, 1,
		0, 2,
		0, 3,
	}
	workspace = append(workspace, string8("Agent")...)
	workspace = append(workspace, string8("A")...)
	tab := []byte{
		0, 0, 0, 9,
		0, 7,
		0,
		0, 0x21,
		0, 0, 0, 5,
	}
	tab = append(tab, string8("*")...)
	tab = append(tab, string16("main.ex")...)
	tab = append(tab, string16("/repo/main.ex")...)
	tab = append(tab, 0, 0, 0, 0)
	body := []byte{2, 0, 7, 1, 1, 1}
	body = append(body, workspace...)
	body = append(body, 0, 1)
	body = append(body, tab...)
	packet := []byte{generated.OPGuiWorkspaces, byte(len(body) >> 8), byte(len(body))}
	packet = append(packet, body...)
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Kind != CommandChrome {
		t.Fatalf("kind = %v, want chrome", first.Kind)
	}
	if first.Size != len(packet)-9 {
		t.Fatalf("workspace size = %d, want %d", first.Size, len(packet)-9)
	}
	spaces := first.Chrome.Spaces
	if spaces.ActiveID != 7 || len(spaces.Spaces) != 1 || len(spaces.Tabs) != 1 {
		t.Fatalf("workspaces decoded incorrectly: %+v", spaces)
	}
	if got := spaces.Spaces[0]; !got.Active || !got.Attention || !got.Closeable || got.Label != "Agent" || got.TabCount != 4 {
		t.Fatalf("workspace decoded incorrectly: %+v", got)
	}
	if got := spaces.Tabs[0]; got.Label != "main.ex" || got.Path != "/repo/main.ex" || got.WorkspaceID != 7 {
		t.Fatalf("workspace tab decoded incorrectly: %+v", got)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

func TestDecodeCompletionChromeDoesNotSwallowFollowingCommands(t *testing.T) {
	item := append([]byte{1}, string16("map")...)
	item = append(item, string16("Enum.map/2")...)
	packet := []byte{generated.OPGuiCompletion, 1, 0, 9, 0, 4, 0, 0, 0, 1}
	packet = append(packet, item...)
	// documentation string16 (selected item's doc preview) trails the item list.
	packet = append(packet, string16("Applies fun to each element.")...)
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-9 {
		t.Fatalf("completion size = %d, want %d", first.Size, len(packet)-9)
	}
	completion := first.Chrome.Complete
	if !completion.Visible || completion.Row != 9 || completion.Col != 4 || len(completion.Items) != 1 {
		t.Fatalf("completion decoded incorrectly: %+v", completion)
	}
	if got := completion.Items[0]; got.Kind != 1 || got.Label != "map" || got.Detail != "Enum.map/2" {
		t.Fatalf("completion item decoded incorrectly: %+v", got)
	}
	if completion.Documentation != "Applies fun to each element." {
		t.Fatalf("completion documentation = %q, want preview text", completion.Documentation)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

func TestDecodeWhichKeyChromeDoesNotSwallowFollowingCommands(t *testing.T) {
	binding := []byte{1}
	binding = append(binding, string8("f")...)
	binding = append(binding, string16("file")...)
	binding = append(binding, string8("*")...)
	packet := []byte{generated.OPGuiWhichKey, 1}
	packet = append(packet, string16("SPC")...)
	packet = append(packet, 0, 2, 0, 1)
	packet = append(packet, binding...)
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-9 {
		t.Fatalf("which-key size = %d, want %d", first.Size, len(packet)-9)
	}
	which := first.Chrome.Which
	if !which.Visible || which.Prefix != "SPC" || which.PageCount != 2 || len(which.Bindings) != 1 {
		t.Fatalf("which-key decoded incorrectly: %+v", which)
	}
	if got := which.Bindings[0]; got.Key != "f" || got.Description != "file" || got.Icon != "*" {
		t.Fatalf("which-key binding decoded incorrectly: %+v", got)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

func TestDecodePickerChromeDoesNotSwallowFollowingCommands(t *testing.T) {
	header := []byte{1, 0, 0, 0, 2, 0, 4, 1}
	header = append(header, string16("Files")...)
	header = append(header, 0, 1)
	query := string16("main")
	item := []byte{0xAA, 0xBB, 0xCC, 0x02}
	item = append(item, string16("main.ex")...)
	item = append(item, string16("lib/main.ex")...)
	item = append(item, string16("modified")...)
	item = append(item, 0)
	items := []byte{0, 1}
	items = append(items, item...)
	actions := []byte{1, 0, 1}
	actions = append(actions, string16("open")...)
	body := section(0x01, header)
	body = append(body, section(0x02, query)...)
	body = append(body, section(0x03, items)...)
	body = append(body, section(0x04, actions)...)
	body = append(body, section(0x05, string16("find"))...)
	body = append(body, section(0x06, []byte{0})...)
	packet := []byte{generated.OPGuiPicker, 6}
	packet = append(packet, body...)
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-9 {
		t.Fatalf("picker size = %d, want %d", first.Size, len(packet)-9)
	}
	picker := first.Chrome.Picker
	if !picker.Visible || picker.Title != "Files" || picker.Query != "main" || picker.Marked != 1 || len(picker.Items) != 1 {
		t.Fatalf("picker decoded incorrectly: %+v", picker)
	}
	if got := picker.Items[0]; !got.Marked || got.Label != "main.ex" || got.Description != "lib/main.ex" || got.Annotation != "modified" {
		t.Fatalf("picker item decoded incorrectly: %+v", got)
	}
	if len(picker.Actions) != 1 || picker.Actions[0] != "open" || picker.ModePrefix != "find" {
		t.Fatalf("picker extras decoded incorrectly: %+v", picker)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

// A peer that emits a header section ending right after has_preview (no
// title/marked_count tail) must decode through DecodeCommand to a UI-visible
// Picker whose optional tail degrades to its zero value, without reading the
// bytes of the following command into the header. This proves the section
// window bounds the generated decoder on the production path, not just in the
// generated-package unit tests.
func TestDecodePickerShortHeaderSectionStopsAtWindow(t *testing.T) {
	// visible(1) selected(2) filtered(2) total(2) has_preview(1) = 8 bytes,
	// the window ends before the optional title/marked_count tail.
	header := []byte{1, 0, 5, 0, 9, 0, 12, 1}
	body := section(0x01, header)
	packet := []byte{generated.OPGuiPicker, 1}
	packet = append(packet, body...)
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	// commit_frame is 9 bytes (opcode + frame_seq:u32 + input_seq:u32).
	if first.Size != len(packet)-9 {
		t.Fatalf("picker size = %d, want %d", first.Size, len(packet)-9)
	}
	picker := first.Chrome.Picker
	if !picker.Visible || picker.Selected != 5 || picker.Filtered != 9 || picker.Total != 12 || !picker.HasPreview {
		t.Fatalf("picker header decoded incorrectly: %+v", picker)
	}
	if picker.Title != "" || picker.Marked != 0 {
		t.Fatalf("omitted tail must be zero-valued, got title=%q marked=%d", picker.Title, picker.Marked)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand batch returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

func TestDecodePickerPreviewChromeDoesNotSwallowFollowingCommands(t *testing.T) {
	segment := []byte{0xCC, 0xDD, 0xEE, 1}
	segment = append(segment, string16("def main")...)
	packet := []byte{generated.OPGuiPickerPreview, 1, 0, 1, 1}
	packet = append(packet, segment...)
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-9 {
		t.Fatalf("picker preview size = %d, want %d", first.Size, len(packet)-9)
	}
	preview := first.Chrome.Preview
	if !preview.Visible || len(preview.Lines) != 1 || len(preview.Lines[0].Segments) != 1 {
		t.Fatalf("preview decoded incorrectly: %+v", preview)
	}
	got := preview.Lines[0].Segments[0]
	if got.Text != "def main" || got.FG != 0xCCDDEE || !got.Bold {
		t.Fatalf("preview segment decoded incorrectly: %+v", got)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand commit_frame returned error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

const (
	fileTreeVisibleFlag         byte = 0x01
	fileTreeFocusedFlag         byte = 0x02
	fileTreeLocalNavigationFlag byte = 0x20
	fileTreeReadyStatus         byte = 3
)

func TestDecodeFileTreeChromeRows(t *testing.T) {
	row := []byte{
		0, 0, 0, 1,
		0, 0x05,
		1,
		0,
		0, 0,
		0, 0,
		0, 0,
		0, 0,
		0,
	}
	row = append(row, string16("/repo/lib")...)
	row = append(row, string16("/repo/lib")...)
	row = append(row, string16("lib")...)
	row = append(row, string16("lib")...)
	row = append(row, 1, 'd')
	row = append(row, 0xFF)
	row = append(row, 0, 0)
	row = append(row, 0x6D, 0x80, 0x86) // icon color (R,G,B) follows editing payload
	row = append(row, 0xFF)             // heat level (0xFF = none) trails the row
	body := []byte{2, fileTreeVisibleFlag | fileTreeFocusedFlag | fileTreeLocalNavigationFlag, fileTreeReadyStatus}
	body = append(body, string16("/repo/lib")...)
	body = append(body, string16("/repo")...)
	body = append(body, 0, 30, 0, 1)
	body = append(body, 0, 0)
	body = append(body, row...)
	packet := append([]byte{generated.OPGuiFileTree, 0, 0, 0, byte(len(body))}, body...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	tree := command.Chrome.Tree
	if !tree.Visible || !tree.Focused || tree.Flags&fileTreeLocalNavigationFlag == 0 || tree.Status != fileTreeReadyStatus || tree.Root != "/repo" || len(tree.Rows) != 1 {
		t.Fatalf("file tree decoded incorrectly: %+v", tree)
	}
	if got := tree.Rows[0]; !got.Directory || !got.Selected || got.Name != "lib" || got.Depth != 1 || got.IconColor != 0x6D8086 {
		t.Fatalf("file tree row decoded incorrectly: %+v", got)
	}
}

func TestDecodeStatusChrome(t *testing.T) {
	identity := section(0x01, []byte{0, 2, 0})
	cursor := section(0x02, []byte{0, 0, 0, 12, 0, 0, 0, 8, 0, 0, 0, 90})
	file := append([]byte{1, '*', 0xAA, 0xBB, 0xCC}, string16("main.ex")...)
	file = append(file, 6, 'e', 'l', 'i', 'x', 'i', 'r')
	message := section(0x07, string16("saved"))
	packet := []byte{generated.OPGuiStatusBar, 4}
	packet = append(packet, identity...)
	packet = append(packet, cursor...)
	packet = append(packet, section(0x06, file)...)
	packet = append(packet, message...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	status := command.Chrome.Status
	if status.Filename != "main.ex" || status.Filetype != "elixir" || status.Line != 12 || status.Column != 8 || status.Message != "saved" {
		t.Fatalf("status decoded incorrectly: %+v", status)
	}
}

func TestDecodeStatusOperationUsesGeneratedMappingAndKeepsNoticeSeparate(t *testing.T) {
	operation := make([]byte, 8)
	binary.BigEndian.PutUint64(operation, 4_294_967_297)
	operation = append(operation,
		byte(generated.OperationKindLspRename),
		byte(generated.OperationStatusRunning),
		0x07,
	)
	operation = append(operation, string16("Renaming...")...)
	operation = append(operation, 0, 2, 0, 5)
	operation = append(operation, 0, 0, 0, 7, 0, 0, 0, 10)

	packet := []byte{generated.OPGuiStatusBar, 2}
	packet = append(packet, section(0x07, string16("ordinary notice"))...)
	packet = append(packet, section(0x0F, operation)...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	status := command.Chrome.Status
	if status.Message != "ordinary notice" {
		t.Fatalf("plain message was conflated with operation: %+v", status)
	}
	if status.Operation == nil {
		t.Fatal("structured operation was not decoded")
	}
	got := *status.Operation
	if got.OperationID != 4_294_967_297 || got.Kind != generated.OperationKindLspRename || got.Status != generated.OperationStatusRunning || got.Flags != 0x07 || got.Message != "Renaming..." {
		t.Fatalf("operation identity/semantic mapping = %+v", got)
	}
	if got.QueuePosition != 2 || got.QueueTotal != 5 || got.ProgressCurrent != 7 || got.ProgressTotal != 10 {
		t.Fatalf("operation metadata mapping = %+v", got)
	}
}

func TestDecodeStatusModelineSegments(t *testing.T) {
	left := []byte{2, 0, 1, 0, 1}
	left = append(left, string8("mode")...)
	left = append(left, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33, 1)
	left = append(left, string16(" NORMAL ")...)
	left = append(left, string16("set_mode")...)
	right := []byte{}
	right = append(right, string8("position")...)
	right = append(right, 0, 0, 0, 0, 0, 0, 0)
	right = append(right, string16("1:1 Top")...)
	right = append(right, string16("")...)
	packet := []byte{generated.OPGuiStatusBar, 1}
	packet = append(packet, section(0x0B, append(left, right...))...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	status := command.Chrome.Status
	if len(status.Left) != 1 || len(status.Right) != 1 || status.Left[0].Name != "mode" || status.Left[0].Text != " NORMAL " || status.Left[0].Command != "set_mode" || status.Right[0].Text != "1:1 Top" {
		t.Fatalf("modeline segments decoded incorrectly: %+v", status)
	}
}

func TestDecodeStatusPendingKeys(t *testing.T) {
	packet := []byte{generated.OPGuiStatusBar, 1}
	packet = append(packet, section(0x0E, string16("\"a2d"))...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Chrome.Status.PendingKeys != "\"a2d" {
		t.Fatalf("pending keys decoded incorrectly: %q", command.Chrome.Status.PendingKeys)
	}
}

func TestDecodeStatusPendingKeysAbsentSection(t *testing.T) {
	packet := []byte{generated.OPGuiStatusBar, 1}
	packet = append(packet, section(0x07, string16("ready"))...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Chrome.Status.PendingKeys != "" {
		t.Fatalf("absent pending-keys section should decode to empty, got %q", command.Chrome.Status.PendingKeys)
	}
}

func TestDecodeGutterChrome(t *testing.T) {
	window := section(0x01, []byte{0, 7, 0, 1, 0, 2, 0, 3, 1, 0, 80})
	config := section(0x02, []byte{0, 0, 0, 4, 0, 4, 2})
	entriesPayload := []byte{0, 2}
	entriesPayload = append(entriesPayload, 0, 0, 0, 4, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF)
	entriesPayload = append(entriesPayload, 0, 0, 0, 5, 3, 0, 0xFF, 0xFF, 0xFF, 0xFF)
	packet := []byte{generated.OPGuiGutter, 3}
	packet = append(packet, window...)
	packet = append(packet, config...)
	packet = append(packet, section(0x03, entriesPayload)...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	gutter := command.Chrome.WindowGutter
	if gutter.WindowID != 7 || gutter.ContentRow != 1 || gutter.ContentCol != 2 || gutter.CursorLine != 4 || gutter.LineNumberWidth != 4 || len(gutter.Entries) != 2 || gutter.Entries[1].DisplayType != 3 {
		t.Fatalf("gutter decoded incorrectly: %+v", gutter)
	}
}

func TestDecodeWindowOverlaySections(t *testing.T) {
	header := section32(0x01, []byte{0, 7, 3, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 9})
	rows := section32(0x02, []byte{0, 0, 0, 0})
	selection := section32(0x03, []byte{1, 0, 0, 0, 1, 0, 0, 0, 4})
	search := section32(0x04, []byte{0, 1, 0, 0, 0, 2, 0, 5, 1})
	diagnostics := section32(0x05, []byte{0, 1, 0, 0, 0, 2, 0, 0, 0, 5, 0})
	highlights := section32(0x06, []byte{0, 1, 0, 0, 0, 3, 0, 0, 0, 6, 2})
	annotationPayload := []byte{0, 1, 0, 0, 1, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33}
	annotationPayload = append(annotationPayload, string16("note")...)
	annotations := section32(0x07, annotationPayload)
	geometryPayload := make([]byte, 67)
	geometryPayload[1] = 7
	geometryPayload[63] = 3
	geometryPayload[65] = 2
	geometry := section32(0x08, geometryPayload)
	packet := windowContentPacket(header, rows, selection, search, diagnostics, highlights, annotations, geometry)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	window := command.Window
	if window.Selection.Type != 1 || len(window.SearchMatches) != 1 || len(window.Diagnostics) != 1 || len(window.Highlights) != 1 || len(window.Annotations) != 1 || !window.GeometrySet {
		t.Fatalf("overlay sections decoded incorrectly: %+v", window)
	}
	if window.Annotations[0].Text != "note" || window.Geometry.WindowID != 7 || window.Geometry.LineNumberWidth != 3 || window.Geometry.SignColWidth != 2 {
		t.Fatalf("annotation/geometry decoded incorrectly: %+v", window)
	}
}

func TestDecodeWindowOverlayGeometryFailureLeavesGeometryUnset(t *testing.T) {
	header := section32(0x01, []byte{0, 7, 3, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 9})
	rows := section32(0x02, []byte{0, 0, 0, 0})
	geometryPayload := make([]byte, 67)
	geometryPayload[1] = 7
	geometryPayload[63] = 3
	geometryPayload[65] = 2
	geometryPayload[66] = 1
	geometry := section32(0x08, geometryPayload)
	packet := windowContentPacket(header, rows, geometry)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Window.GeometrySet {
		t.Fatalf("malformed geometry should leave GeometrySet unset: %+v", command.Window)
	}
}

func TestDecodeWindowCursorlineSection(t *testing.T) {
	header := section32(0x01, []byte{0, 7, 3, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 9})
	rows := section32(0x02, []byte{0, 0, 0, 0})
	cursorline := section32(0x09, []byte{0, 1, 0x11, 0x22, 0x33})
	packet := windowContentPacket(header, rows, cursorline)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if !command.Window.Cursorline.Visible || command.Window.Cursorline.Row != 1 || command.Window.Cursorline.BG != 0x112233 {
		t.Fatalf("cursorline decoded incorrectly: %+v", command.Window.Cursorline)
	}
}

func TestDecodeRemainingSemanticChrome(t *testing.T) {
	cursorline := []byte{generated.OPGuiCursorline, 0, 4, 0x11, 0x22, 0x33}
	command, err := DecodeCommand(cursorline)
	if err != nil {
		t.Fatalf("DecodeCommand cursorline returned error: %v", err)
	}
	if !command.Chrome.CursorlineChrome.Visible || command.Chrome.CursorlineChrome.Row != 4 || command.Chrome.CursorlineChrome.BG != 0x112233 {
		t.Fatalf("cursorline decoded incorrectly: %+v", command.Chrome.CursorlineChrome)
	}

	indentPayload := []byte{0, 7, 2, 0xFF, 0xFF, 2, 0, 2, 0, 4, 0, 2, 1, 2}
	indent := append([]byte{generated.OPGuiIndentGuides, 0, byte(len(indentPayload))}, indentPayload...)
	command, err = DecodeCommand(indent)
	if err != nil {
		t.Fatalf("DecodeCommand indent guides returned error: %v", err)
	}
	if command.Chrome.IndentGuides.WindowID != 7 || len(command.Chrome.IndentGuides.GuideCols) != 2 || len(command.Chrome.IndentGuides.IndentLevels) != 2 {
		t.Fatalf("indent guides decoded incorrectly: %+v", command.Chrome.IndentGuides)
	}

	emptyIndentPayload := []byte{0, 7, 2, 0xFF, 0xFF, 0}
	emptyIndent := append([]byte{generated.OPGuiIndentGuides, 0, byte(len(emptyIndentPayload))}, emptyIndentPayload...)
	command, err = DecodeCommand(emptyIndent)
	if err != nil {
		t.Fatalf("DecodeCommand empty indent guides returned error: %v", err)
	}
	if command.Chrome.IndentGuides.WindowID != 7 || len(command.Chrome.IndentGuides.GuideCols) != 0 {
		t.Fatalf("empty indent guides decoded incorrectly: %+v", command.Chrome.IndentGuides)
	}

	selectionPayload := append([]byte{1}, string16("row-1")...)
	selection := append([]byte{generated.OPGuiFileTreeSelection, 0, byte(len(selectionPayload))}, selectionPayload...)
	command, err = DecodeCommand(selection)
	if err != nil {
		t.Fatalf("DecodeCommand file tree selection returned error: %v", err)
	}
	if !command.Chrome.FileTreeSelection.Focused || command.Chrome.FileTreeSelection.SelectedID != "row-1" {
		t.Fatalf("file tree selection decoded incorrectly: %+v", command.Chrome.FileTreeSelection)
	}

	lineSpacing := []byte{generated.OPGuiLineSpacing, 0, 2, 0, 120}
	command, err = DecodeCommand(lineSpacing)
	if err != nil {
		t.Fatalf("DecodeCommand line spacing returned error: %v", err)
	}
	if command.Chrome.LineSpacing.SpacingX100 != 120 {
		t.Fatalf("line spacing decoded incorrectly: %+v", command.Chrome.LineSpacing)
	}

	cursorAnimation := []byte{generated.OPGuiCursorAnimation, 0, 1, 1}
	command, err = DecodeCommand(cursorAnimation)
	if err != nil {
		t.Fatalf("DecodeCommand cursor animation returned error: %v", err)
	}
	if !command.Chrome.CursorAnimation.Enabled {
		t.Fatalf("cursor animation decoded incorrectly: %+v", command.Chrome.CursorAnimation)
	}

	configState := []byte{generated.OPGuiConfigState, 0, 0}
	command, err = DecodeCommand(configState)
	if err != nil {
		t.Fatalf("DecodeCommand config state returned error: %v", err)
	}
	if !command.Chrome.ConfigState.Present {
		t.Fatalf("config state decoded incorrectly: %+v", command.Chrome.ConfigState)
	}
}

func TestDecodeThemeAndEverydayChrome(t *testing.T) {
	packet := []byte{generated.OPGuiTheme, 2, 0x40, 0x11, 0x22, 0x33, 0x30, 0x44, 0x55, 0x66, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0}
	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand theme returned error: %v", err)
	}
	if first.Size != len(packet)-9 || first.Chrome.Theme.Colors[0x40] != 0x112233 {
		t.Fatalf("theme decoded incorrectly: size=%d theme=%+v", first.Size, first.Chrome.Theme)
	}

	breadcrumb := []byte{generated.OPGuiBreadcrumb, 2}
	breadcrumb = append(breadcrumb, string16("lib")...)
	breadcrumb = append(breadcrumb, string16("main.ex")...)
	command, err := DecodeCommand(breadcrumb)
	if err != nil {
		t.Fatalf("DecodeCommand breadcrumb returned error: %v", err)
	}
	if command.Chrome.Summary != "lib / main.ex" {
		t.Fatalf("breadcrumb summary = %q", command.Chrome.Summary)
	}

	git := []byte{generated.OPGuiGitStatus, 1, 0, 0, 2, 0, 1}
	git = append(git, string16("main")...)
	git = append(git, 0, 1, 0, 0, 0, 7, 1, 2)
	git = append(git, string16("lib/main.ex")...)
	git = append(git, 0)
	git = append(git, string16("/repo")...)
	git = append(git, string16("last commit")...)
	// Trailing commit_frame is a fixed:9 sentinel (opcode + frame_seq + echoed input_seq).
	git = append(git, 0, 3, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)
	command, err = DecodeCommand(git)
	if err != nil {
		t.Fatalf("DecodeCommand git returned error: %v", err)
	}
	if command.Size != len(git)-9 || command.Chrome.Git.Branch != "main" || command.Chrome.Git.Ahead != 2 || len(command.Chrome.Git.Entries) != 1 || command.Chrome.Git.StashCount != 3 {
		t.Fatalf("git decoded incorrectly: size=%d git=%+v", command.Size, command.Chrome.Git)
	}

	searchPayload := []byte{1, 0, 9, 0, 12, 0x03}
	search := append([]byte{generated.OPGuiSearchState, 0, byte(len(searchPayload))}, searchPayload...)
	command, err = DecodeCommand(search)
	if err != nil {
		t.Fatalf("DecodeCommand search returned error: %v", err)
	}
	if !command.Chrome.Search.Active || command.Chrome.Search.Count != 9 || command.Chrome.Search.CurrentIndex != 12 {
		t.Fatalf("search decoded incorrectly: %+v", command.Chrome.Search)
	}

}

func TestDecodeTransientOverlayChrome(t *testing.T) {
	segment := append([]byte{1}, string16("hover text")...)
	line := append([]byte{0, 0, 1}, segment...)
	hover := []byte{generated.OPGuiHoverPopup, 1, 0, 4, 0, 8, 1, 0, 0, 0, 1}
	hover = append(hover, line...)
	command, err := DecodeCommand(hover)
	if err != nil {
		t.Fatalf("DecodeCommand hover returned error: %v", err)
	}
	if !command.Chrome.Hover.Visible || command.Chrome.Hover.AnchorRow != 4 || len(command.Chrome.Hover.Lines) != 1 {
		t.Fatalf("hover decoded incorrectly: %+v", command.Chrome.Hover)
	}

	actionPayload := append([]byte{1}, string16("Open docs")...)
	action := append([]byte{generated.OPGuiHoverAction, 0, byte(len(actionPayload))}, actionPayload...)
	command, err = DecodeCommand(action)
	if err != nil {
		t.Fatalf("DecodeCommand hover action returned error: %v", err)
	}
	if !command.Chrome.HoverAction.Visible || command.Chrome.HoverAction.Name != "Open docs" {
		t.Fatalf("hover action decoded incorrectly: %+v", command.Chrome.HoverAction)
	}

	param := append(string16("arg"), string16("argument docs")...)
	sig := append(string16("fun(arg)"), string16("signature docs")...)
	sig = append(sig, 1)
	sig = append(sig, param...)
	signature := []byte{generated.OPGuiSignatureHelp, 1, 0, 2, 0, 3, 0, 0, 1}
	signature = append(signature, sig...)
	command, err = DecodeCommand(signature)
	if err != nil {
		t.Fatalf("DecodeCommand signature returned error: %v", err)
	}
	if !command.Chrome.Signature.Visible || len(command.Chrome.Signature.Signatures) != 1 || command.Chrome.Signature.Signatures[0].Label != "fun(arg)" {
		t.Fatalf("signature decoded incorrectly: %+v", command.Chrome.Signature)
	}

	float := []byte{generated.OPGuiFloatPopup, 1, 0, 20, 0, 5}
	float = append(float, string16("Menu")...)
	float = append(float, 0, 1)
	float = append(float, string16("one line")...)
	command, err = DecodeCommand(float)
	if err != nil {
		t.Fatalf("DecodeCommand float returned error: %v", err)
	}
	if !command.Chrome.Float.Visible || command.Chrome.Float.Title != "Menu" || len(command.Chrome.Float.Lines) != 1 {
		t.Fatalf("float decoded incorrectly: %+v", command.Chrome.Float)
	}
}

func TestDecodePanelAndSidebarChrome(t *testing.T) {
	note := string16("n1")
	note = append(note, 0, 1)
	note = append(note, make([]byte, 8)...)
	note = append(note, make([]byte, 8)...)
	note = append(note, 0, 0, 0, 10)
	note = append(note, string16("Build passed")...)
	note = append(note, string16("all checks green")...)
	note = append(note, string16("ci")...)
	note = append(note, 0)
	notesPayload := []byte{1, 0, 1}
	notesPayload = append(notesPayload, note...)
	packet := append([]byte{generated.OPGuiNotifications, byte(len(notesPayload) >> 8), byte(len(notesPayload))}, notesPayload...)
	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand notifications returned error: %v", err)
	}
	if !command.Chrome.Notifications.Visible || len(command.Chrome.Notifications.Items) != 1 || command.Chrome.Notifications.Items[0].Title != "Build passed" {
		t.Fatalf("notifications decoded incorrectly: %+v", command.Chrome.Notifications)
	}

	bottom := []byte{generated.OPGuiBottomPanel, 1, 0, 30, 0, 1, 2}
	bottom = append(bottom, string8("Messages")...)
	bottom = append(bottom, 0, 0, 0, 7, 0, 1, 0, 0, 0, 5, 1, 2, 0, 0, 0, 9)
	bottom = append(bottom, string16("lib/main.ex")...)
	bottom = append(bottom, string16("warning")...)
	command, err = DecodeCommand(bottom)
	if err != nil {
		t.Fatalf("DecodeCommand bottom panel returned error: %v", err)
	}
	if !command.Chrome.Bottom.Visible || command.Chrome.Bottom.StreamInstance != 7 || len(command.Chrome.Bottom.Tabs) != 1 || len(command.Chrome.Bottom.Messages) != 1 {
		t.Fatalf("bottom panel decoded incorrectly: %+v", command.Chrome.Bottom)
	}

	firstBottom := bottomPanelPacket(7, 1, "first")
	firstCommand, err := DecodeCommand(firstBottom)
	if err != nil {
		t.Fatalf("DecodeCommand first bottom panel returned error: %v", err)
	}
	secondBottom := bottomPanelPacket(8, 1, "second")
	secondCommand, err := DecodeCommand(secondBottom)
	if err != nil {
		t.Fatalf("DecodeCommand second bottom panel returned error: %v", err)
	}
	if firstCommand.Chrome.Bottom.StreamInstance == secondCommand.Chrome.Bottom.StreamInstance || firstCommand.Chrome.Bottom.Messages[0].ID != secondCommand.Chrome.Bottom.Messages[0].ID {
		t.Fatalf("bottom panel stream identity not preserved: first=%+v second=%+v", firstCommand.Chrome.Bottom, secondCommand.Chrome.Bottom)
	}

	sidebarEntry := string16("files")
	sidebarEntry = append(sidebarEntry, string16("Files")...)
	sidebarEntry = append(sidebarEntry, string16("file_tree")...)
	sidebarEntry = append(sidebarEntry, string16("*")...)
	sidebarEntry = append(sidebarEntry, 0, 1, 0x03, 0, 32, 0, 2)
	sidebarsPayload := []byte{1, 0, 1}
	sidebarsPayload = append(sidebarsPayload, string16("files")...)
	sidebarsPayload = append(sidebarsPayload, sidebarEntry...)
	sidebars := append([]byte{generated.OPGuiSidebars, 0, 0, 0, byte(len(sidebarsPayload))}, sidebarsPayload...)
	command, err = DecodeCommand(sidebars)
	if err != nil {
		t.Fatalf("DecodeCommand sidebars returned error: %v", err)
	}
	if command.Chrome.Name != "sidebars" || len(command.Chrome.Sidebars.Items) != 1 || !command.Chrome.Sidebars.Items[0].Focused {
		t.Fatalf("sidebars decoded incorrectly: name=%q sidebars=%+v", command.Chrome.Name, command.Chrome.Sidebars)
	}

	overlayEntry := string8("gitlens")
	overlayEntry = append(overlayEntry, string8("cursor")...)
	overlayEntry = append(overlayEntry, 0, 7, 0, 2, 0, 4, 2, 0xAA, 0xBB, 0xCC, 200)
	overlayEntry = append(overlayEntry, string16("branch")...)
	overlayPayload := append([]byte{1}, overlayEntry...)
	overlay := append([]byte{generated.OPGuiExtensionOverlay, byte(len(overlayPayload) >> 8), byte(len(overlayPayload))}, overlayPayload...)
	command, err = DecodeCommand(overlay)
	if err != nil {
		t.Fatalf("DecodeCommand extension overlay returned error: %v", err)
	}
	if len(command.Chrome.Overlay.Entries) != 1 || command.Chrome.Overlay.Entries[0].Content != "branch" {
		t.Fatalf("extension overlay decoded incorrectly: %+v", command.Chrome.Overlay)
	}

	panelEntry := string8("ext")
	panelEntry = append(panelEntry, string8("panel")...)
	panelEntry = append(panelEntry, string8("Panel")...)
	panelEntry = append(panelEntry, 0, 1, 12, 1, 1, 0)
	panelEntry = append(panelEntry, string16("hello")...)
	extPayload := append([]byte{1}, panelEntry...)
	extPanel := append([]byte{generated.OPGuiExtensionPanel, byte(len(extPayload) >> 8), byte(len(extPayload))}, extPayload...)
	command, err = DecodeCommand(extPanel)
	if err != nil {
		t.Fatalf("DecodeCommand extension panel returned error: %v", err)
	}
	if len(command.Chrome.Extensions.Panels) != 1 || command.Chrome.Extensions.Panels[0].Title != "Panel" || len(command.Chrome.Extensions.Panels[0].Blocks) != 1 {
		t.Fatalf("extension panel decoded incorrectly: %+v", command.Chrome.Extensions)
	}

	node := string8("<0.1.0>")
	node = append(node, string8("")...)
	node = append(node, string16("Editor")...)
	node = append(node, 4, 0, 0, 0, 0, 100, 0, 2, 0, 0, 0, 50)
	obsPayload := section(0x01, []byte{1, 0, 1})
	obsPayload = append(obsPayload, section(0x02, node)...)
	obs := append([]byte{generated.OPGuiObservatory, 0, 0, 0, byte(len(obsPayload))}, obsPayload...)
	command, err = DecodeCommand(obs)
	if err != nil {
		t.Fatalf("DecodeCommand observatory returned error: %v", err)
	}
	if !command.Chrome.Observatory.Visible || len(command.Chrome.Observatory.Nodes) != 1 || command.Chrome.Observatory.Nodes[0].Name != "Editor" {
		t.Fatalf("observatory decoded incorrectly: %+v", command.Chrome.Observatory)
	}
}

func TestDecodeAgentChatSkipsRetiredMessagesSection(t *testing.T) {
	chat := []byte{generated.OPGuiAgentChat, 5}
	prompt := string16("fix")
	prompt = append(prompt, 2, 0, 1, 0, 3, 1, 4)
	retired := []byte{0xFF, 1, 0, 1}
	messageBody := append([]byte{0x01}, u32Bytes(2)...)
	messageBody = append(messageBody, []byte("hi")...)
	retired = append(retired, u32Bytes(uint32(4+len(messageBody)))...)
	retired = append(retired, u32Bytes(1)...)
	retired = append(retired, messageBody...)
	chat = append(chat, section(0x01, []byte{1, 1})...)
	chat = append(chat, section(0x02, string16("gpt"))...)
	chat = append(chat, section(0x06, retired)...)
	chat = append(chat, section(0x03, prompt)...)
	chat = append(chat, section(0x09, []byte{1})...)
	command, err := DecodeCommand(chat)
	if err != nil {
		t.Fatalf("DecodeCommand chat returned error: %v", err)
	}
	if command.Size != len(chat) {
		t.Fatalf("consumed = %d, want %d", command.Size, len(chat))
	}
	got := command.Chrome.AgentChat
	if !got.Visible || got.Status != 1 || got.ModelName != "gpt" || got.Prompt != "fix" || got.PromptLineCount != 2 || got.PromptCursorLine != 1 || got.PromptCursorCol != 3 || got.PromptVimMode != 1 || got.PromptVisibleRows != 4 || !got.InputFocused || got.ThinkingLevel != "" || got.Pending != "" || len(got.Completion) != 0 {
		t.Fatalf("agent chat decoded incorrectly: %+v", got)
	}
	if command.Chrome.Summary != "gpt" {
		t.Fatalf("agent chat summary = %q, want %q", command.Chrome.Summary, "gpt")
	}
}

func TestDecodeAgentTimelineChrome(t *testing.T) {
	timelinePayload := []byte{1, 0xFF, 0xFF, 1, 3}
	timelinePayload = append(timelinePayload, string8("apply_patch")...)
	timelinePayload = append(timelinePayload, 0, 0, 0, 4)
	timeline := append([]byte{generated.OPGuiEditTimeline, byte(len(timelinePayload) >> 8), byte(len(timelinePayload))}, timelinePayload...)
	command, err := DecodeCommand(timeline)
	if err != nil {
		t.Fatalf("DecodeCommand timeline returned error: %v", err)
	}
	if !command.Chrome.Timeline.Visible || len(command.Chrome.Timeline.Entries) != 1 || command.Chrome.Timeline.Entries[0].ToolName != "apply_patch" {
		t.Fatalf("timeline decoded incorrectly: %+v", command.Chrome.Timeline)
	}
}

func u32Bytes(value uint32) []byte {
	out := make([]byte, 4)
	binary.BigEndian.PutUint32(out, value)
	return out
}

func section(id byte, payload []byte) []byte {
	out := []byte{id, byte(len(payload) >> 8), byte(len(payload))}
	return append(out, payload...)
}

func section32(id byte, payload []byte) []byte {
	out := []byte{id}
	out = append(out, u32Bytes(uint32(len(payload)))...)
	return append(out, payload...)
}

func windowContentPacket(sections ...[]byte) []byte {
	body := []byte{byte(len(sections))}
	for _, section := range sections {
		body = append(body, section...)
	}
	packet := []byte{generated.OPGuiWindowContent}
	packet = append(packet, u32Bytes(uint32(len(body)))...)
	return append(packet, body...)
}

func bottomPanelPacket(streamInstance uint32, id uint32, text string) []byte {
	bottom := []byte{generated.OPGuiBottomPanel, 1, 0, 30, 0, 1, 2}
	bottom = append(bottom, string8("Messages")...)
	bottom = append(bottom, u32Bytes(streamInstance)...)
	bottom = append(bottom, 0, 1)
	bottom = append(bottom, u32Bytes(id)...)
	bottom = append(bottom, 1, 0)
	bottom = append(bottom, u32Bytes(9)...)
	bottom = append(bottom, string16("lib/main.ex")...)
	bottom = append(bottom, string16(text)...)
	return bottom
}

func string16(value string) []byte {
	out := []byte{byte(len(value) >> 8), byte(len(value))}
	return append(out, []byte(value)...)
}

func string8(value string) []byte {
	out := []byte{byte(len(value))}
	return append(out, []byte(value)...)
}
