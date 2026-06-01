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
	packet = append(packet, generated.OPBatchEnd)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Kind != CommandChrome {
		t.Fatalf("kind = %v, want chrome", first.Kind)
	}
	if first.Size != len(packet)-1 {
		t.Fatalf("workspace size = %d, want %d", first.Size, len(packet)-1)
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
		t.Fatalf("DecodeCommand batch returned error: %v", err)
	}
	if second.Kind != CommandBatchEnd {
		t.Fatalf("second kind = %v, want batch end", second.Kind)
	}
}

func TestDecodeCompletionChromeDoesNotSwallowFollowingCommands(t *testing.T) {
	item := append([]byte{1}, string16("map")...)
	item = append(item, string16("Enum.map/2")...)
	packet := []byte{generated.OPGuiCompletion, 1, 0, 9, 0, 4, 0, 0, 0, 1}
	packet = append(packet, item...)
	packet = append(packet, generated.OPBatchEnd)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-1 {
		t.Fatalf("completion size = %d, want %d", first.Size, len(packet)-1)
	}
	completion := first.Chrome.Complete
	if !completion.Visible || completion.Row != 9 || completion.Col != 4 || len(completion.Items) != 1 {
		t.Fatalf("completion decoded incorrectly: %+v", completion)
	}
	if got := completion.Items[0]; got.Kind != 1 || got.Label != "map" || got.Detail != "Enum.map/2" {
		t.Fatalf("completion item decoded incorrectly: %+v", got)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand batch returned error: %v", err)
	}
	if second.Kind != CommandBatchEnd {
		t.Fatalf("second kind = %v, want batch end", second.Kind)
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
	packet = append(packet, generated.OPBatchEnd)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-1 {
		t.Fatalf("which-key size = %d, want %d", first.Size, len(packet)-1)
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
		t.Fatalf("DecodeCommand batch returned error: %v", err)
	}
	if second.Kind != CommandBatchEnd {
		t.Fatalf("second kind = %v, want batch end", second.Kind)
	}
}

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
	row = append(row, 1, 'd', 0xFF)
	row = append(row, 0, 0)
	body := []byte{2, 1, 3}
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
	if !tree.Visible || tree.Status != 3 || tree.Root != "/repo" || len(tree.Rows) != 1 {
		t.Fatalf("file tree decoded incorrectly: %+v", tree)
	}
	if got := tree.Rows[0]; !got.Directory || !got.Selected || got.Name != "lib" || got.Depth != 1 {
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

func section(id byte, payload []byte) []byte {
	out := []byte{id, byte(len(payload) >> 8), byte(len(payload))}
	return append(out, payload...)
}

func string16(value string) []byte {
	out := []byte{byte(len(value) >> 8), byte(len(value))}
	return append(out, []byte(value)...)
}

func string8(value string) []byte {
	out := []byte{byte(len(value))}
	return append(out, []byte(value)...)
}
