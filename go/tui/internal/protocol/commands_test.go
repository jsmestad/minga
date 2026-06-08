package protocol

import (
	"encoding/binary"
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

func TestDecodeWindowRowsAndViewportDeltasIncludeRowRefs(t *testing.T) {
	ref := []byte{
		0,
		0, 0, 0, 0, 0, 0, 0, 9,
		0, 0, 0, 5,
	}
	rowsPayload := append([]byte{0, 1}, ref...)
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
			packet := append([]byte{tt.opcode, 2, 0x01, 0, byte(len(tt.header))}, tt.header...)
			packet = append(packet, 0x02, byte(len(rowsPayload)>>8), byte(len(rowsPayload)))
			packet = append(packet, rowsPayload...)
			packet = append(packet, generated.OPBatchEnd)

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
				t.Fatalf("DecodeCommand batch returned error: %v", err)
			}
			if second.Kind != CommandBatchEnd {
				t.Fatalf("second kind = %v, want batch end", second.Kind)
			}
		})
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
	packet = append(packet, generated.OPBatchEnd)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-1 {
		t.Fatalf("picker size = %d, want %d", first.Size, len(packet)-1)
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
		t.Fatalf("DecodeCommand batch returned error: %v", err)
	}
	if second.Kind != CommandBatchEnd {
		t.Fatalf("second kind = %v, want batch end", second.Kind)
	}
}

func TestDecodePickerPreviewChromeDoesNotSwallowFollowingCommands(t *testing.T) {
	segment := []byte{0xCC, 0xDD, 0xEE, 1}
	segment = append(segment, string16("def main")...)
	packet := []byte{generated.OPGuiPickerPreview, 1, 0, 1, 1}
	packet = append(packet, segment...)
	packet = append(packet, generated.OPBatchEnd)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Size != len(packet)-1 {
		t.Fatalf("picker preview size = %d, want %d", first.Size, len(packet)-1)
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
	header := section(0x01, []byte{0, 7, 3, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 9})
	rows := section(0x02, []byte{0, 0})
	selection := section(0x03, []byte{1, 0, 0, 0, 1, 0, 0, 0, 4})
	search := section(0x04, []byte{0, 1, 0, 0, 0, 2, 0, 5, 1})
	diagnostics := section(0x05, []byte{0, 1, 0, 0, 0, 2, 0, 0, 0, 5, 0})
	highlights := section(0x06, []byte{0, 1, 0, 0, 0, 3, 0, 0, 0, 6, 2})
	annotationPayload := []byte{0, 1, 0, 0, 1, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33}
	annotationPayload = append(annotationPayload, string16("note")...)
	annotations := section(0x07, annotationPayload)
	geometryPayload := make([]byte, 67)
	geometryPayload[1] = 7
	geometryPayload[63] = 3
	geometryPayload[65] = 2
	geometry := section(0x08, geometryPayload)
	packet := []byte{generated.OPGuiWindowContent, 8}
	packet = append(packet, header...)
	packet = append(packet, rows...)
	packet = append(packet, selection...)
	packet = append(packet, search...)
	packet = append(packet, diagnostics...)
	packet = append(packet, highlights...)
	packet = append(packet, annotations...)
	packet = append(packet, geometry...)

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
	header := section(0x01, []byte{0, 7, 3, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 9})
	rows := section(0x02, []byte{0, 0})
	geometryPayload := make([]byte, 67)
	geometryPayload[1] = 7
	geometryPayload[63] = 3
	geometryPayload[65] = 2
	geometryPayload[66] = 1
	geometry := section(0x08, geometryPayload)
	packet := []byte{generated.OPGuiWindowContent, 3}
	packet = append(packet, header...)
	packet = append(packet, rows...)
	packet = append(packet, geometry...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if command.Window.GeometrySet {
		t.Fatalf("malformed geometry should leave GeometrySet unset: %+v", command.Window)
	}
}

func TestDecodeWindowCursorlineSection(t *testing.T) {
	header := section(0x01, []byte{0, 7, 3, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 9})
	rows := section(0x02, []byte{0, 0})
	cursorline := section(0x09, []byte{0, 1, 0x11, 0x22, 0x33})
	packet := []byte{generated.OPGuiWindowContent, 3}
	packet = append(packet, header...)
	packet = append(packet, rows...)
	packet = append(packet, cursorline...)

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
	packet := []byte{generated.OPGuiTheme, 2, 0x40, 0x11, 0x22, 0x33, 0x30, 0x44, 0x55, 0x66, generated.OPBatchEnd}
	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand theme returned error: %v", err)
	}
	if first.Size != len(packet)-1 || first.Chrome.Theme.Colors[0x40] != 0x112233 {
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
	git = append(git, 0, 3, generated.OPBatchEnd)
	command, err = DecodeCommand(git)
	if err != nil {
		t.Fatalf("DecodeCommand git returned error: %v", err)
	}
	if command.Size != len(git)-1 || command.Chrome.Git.Branch != "main" || command.Chrome.Git.Ahead != 2 || len(command.Chrome.Git.Entries) != 1 || command.Chrome.Git.StashCount != 3 {
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

	change := []byte{generated.OPGuiChangeSummary, 1, 0, 0, 0, 1}
	change = append(change, string16("README.md")...)
	change = append(change, 1, 0, 0, 0, 5, 0, 0, 0, 1)
	command, err = DecodeCommand(change)
	if err != nil {
		t.Fatalf("DecodeCommand change returned error: %v", err)
	}
	if !command.Chrome.Change.Visible || len(command.Chrome.Change.Entries) != 1 || command.Chrome.Change.Entries[0].LinesAdded != 5 {
		t.Fatalf("change decoded incorrectly: %+v", command.Chrome.Change)
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
	bottom = append(bottom, 0, 1, 0, 0, 0, 5, 1, 2, 0, 0, 0, 9)
	bottom = append(bottom, string16("lib/main.ex")...)
	bottom = append(bottom, string16("warning")...)
	command, err = DecodeCommand(bottom)
	if err != nil {
		t.Fatalf("DecodeCommand bottom panel returned error: %v", err)
	}
	if !command.Chrome.Bottom.Visible || len(command.Chrome.Bottom.Tabs) != 1 || len(command.Chrome.Bottom.Messages) != 1 {
		t.Fatalf("bottom panel decoded incorrectly: %+v", command.Chrome.Bottom)
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

	tool := []byte{generated.OPGuiToolManager, 1, 0, 0, 0, 0, 1}
	tool = append(tool, string8("elixir-ls")...)
	tool = append(tool, string8("Elixir LS")...)
	tool = append(tool, string16("Language server")...)
	tool = append(tool, 0, 1, 0, 0)
	tool = append(tool, string8("")...)
	tool = append(tool, string16("")...)
	tool = append(tool, 0)
	tool = append(tool, string16("")...)
	tool = append(tool, generated.OPBatchEnd)
	command, err = DecodeCommand(tool)
	if err != nil {
		t.Fatalf("DecodeCommand tool manager returned error: %v", err)
	}
	if !command.Chrome.ToolManager.Visible || len(command.Chrome.ToolManager.Tools) != 1 || command.Chrome.ToolManager.Tools[0].Label != "Elixir LS" {
		t.Fatalf("tool manager decoded incorrectly: %+v", command.Chrome.ToolManager)
	}
	if command.Size != len(tool)-1 {
		t.Fatalf("tool manager size = %d, want %d", command.Size, len(tool)-1)
	}
	second, err := DecodeCommand(tool[command.Size:])
	if err != nil {
		t.Fatalf("DecodeCommand batch returned error: %v", err)
	}
	if second.Kind != CommandBatchEnd {
		t.Fatalf("second kind = %v, want batch end", second.Kind)
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

func TestDecodeAgentBoardTimelineChrome(t *testing.T) {
	messageBody := []byte{0, 0, 0, 42, 0x02}
	messageBody = append(messageBody, 0, 0, 0, 5, 'h', 'e', 'l', 'l', 'o')
	messages := []byte{0xFF, 1, 0, 1, byte(len(messageBody) >> 24), byte(len(messageBody) >> 16), byte(len(messageBody) >> 8), byte(len(messageBody))}
	messages = append(messages, messageBody...)
	chat := []byte{generated.OPGuiAgentChat, 3}
	chat = append(chat, section(0x01, []byte{1, 1})...)
	chat = append(chat, section(0x02, string16("gpt"))...)
	chat = append(chat, section(0x06, messages)...)
	command, err := DecodeCommand(chat)
	if err != nil {
		t.Fatalf("DecodeCommand chat returned error: %v", err)
	}
	if !command.Chrome.AgentChat.Visible || command.Chrome.AgentChat.ModelName != "gpt" || len(command.Chrome.AgentChat.Messages) != 1 || command.Chrome.AgentChat.Messages[0].Text != "hello" {
		t.Fatalf("agent chat decoded incorrectly: %+v", command.Chrome.AgentChat)
	}

	board := []byte{generated.OPGuiBoard, 1, 0, 0, 0, 7, 0, 1, 0}
	board = append(board, string16("")...)
	board = append(board, 0, 0, 0, 7, 1, 0x02)
	board = append(board, string16("Fix CI")...)
	board = append(board, string8("gpt")...)
	board = append(board, 0, 0, 0, 9, 0, 0)
	command, err = DecodeCommand(board)
	if err != nil {
		t.Fatalf("DecodeCommand board returned error: %v", err)
	}
	if !command.Chrome.Board.Visible || len(command.Chrome.Board.Cards) != 1 || command.Chrome.Board.Cards[0].Task != "Fix CI" {
		t.Fatalf("board decoded incorrectly: %+v", command.Chrome.Board)
	}

	timelinePayload := []byte{1, 0xFF, 0xFF, 1, 3}
	timelinePayload = append(timelinePayload, string8("apply_patch")...)
	timelinePayload = append(timelinePayload, 0, 0, 0, 4)
	timeline := append([]byte{generated.OPGuiEditTimeline, byte(len(timelinePayload) >> 8), byte(len(timelinePayload))}, timelinePayload...)
	command, err = DecodeCommand(timeline)
	if err != nil {
		t.Fatalf("DecodeCommand timeline returned error: %v", err)
	}
	if !command.Chrome.Timeline.Visible || len(command.Chrome.Timeline.Entries) != 1 || command.Chrome.Timeline.Entries[0].ToolName != "apply_patch" {
		t.Fatalf("timeline decoded incorrectly: %+v", command.Chrome.Timeline)
	}
}

func TestDecodeAgentChatPreservesStructuredMessageDetails(t *testing.T) {
	tool := append(u32Bytes(7), 0x04, 1, 0, 0)
	tool = append(tool, u32Bytes(42)...)
	tool = append(tool, string16("read_file")...)
	tool = append(tool, string16("lib/app.ex")...)
	tool = append(tool, u32Bytes(2)...)
	tool = append(tool, 'o', 'k', 1)

	approval := append(u32Bytes(8), 0x09, 0)
	approval = append(approval, string16("edit_file")...)
	approval = append(approval, string16("Update lib/app.ex")...)
	approval = append(approval, string16("tc-1")...)
	approval = append(approval, 1, 0, 1)
	approval = append(approval, string16("+hello")...)

	usage := append(u32Bytes(9), 0x06)
	usage = append(usage, u32Bytes(1200)...)
	usage = append(usage, u32Bytes(300)...)
	usage = append(usage, u32Bytes(40)...)
	usage = append(usage, u32Bytes(20)...)
	usage = append(usage, u32Bytes(12500)...)

	prompt := string16("fix it")
	prompt = append(prompt, 2, 0, 1, 0, 4, 1, 2)

	chat := []byte{generated.OPGuiAgentChat, 3}
	chat = append(chat, section(0x01, []byte{1, 2})...)
	chat = append(chat, section(0x03, prompt)...)
	chat = append(chat, section(0x06, agentMessages(tool, approval, usage))...)
	command, err := DecodeCommand(chat)
	if err != nil {
		t.Fatalf("DecodeCommand chat returned error: %v", err)
	}
	if command.Chrome.AgentChat.Prompt != "fix it" || command.Chrome.AgentChat.PromptLineCount != 2 || command.Chrome.AgentChat.PromptCursorLine != 1 || command.Chrome.AgentChat.PromptCursorCol != 4 || command.Chrome.AgentChat.PromptVimMode != 1 || command.Chrome.AgentChat.PromptVisibleRows != 2 {
		t.Fatalf("prompt metadata decoded incorrectly: %+v", command.Chrome.AgentChat)
	}
	messages := command.Chrome.AgentChat.Messages
	if len(messages) != 3 {
		t.Fatalf("message count = %d, want 3: %+v", len(messages), messages)
	}
	if got := messages[0]; got.Name != "read_file" || got.Summary != "lib/app.ex" || got.Result != "ok" || got.DurationMS != 42 || got.AutoApprovedScope != 1 {
		t.Fatalf("tool message decoded incorrectly: %+v", got)
	}
	if got := messages[1]; got.Name != "edit_file" || got.PreviewKind != 1 || len(got.PreviewLines) != 1 || got.PreviewLines[0] != "+hello" {
		t.Fatalf("approval message decoded incorrectly: %+v", got)
	}
	if got := messages[2].Usage; got.Input != 1200 || got.Output != 300 || got.CacheRead != 40 || got.CacheWrite != 20 || got.CostMicros != 12500 {
		t.Fatalf("usage decoded incorrectly: %+v", got)
	}
}

func agentMessages(messages ...[]byte) []byte {
	out := []byte{0xFF, 1, byte(len(messages) >> 8), byte(len(messages))}
	for _, message := range messages {
		out = append(out, u32Bytes(uint32(len(message)))...)
		out = append(out, message...)
	}
	return out
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

func string16(value string) []byte {
	out := []byte{byte(len(value) >> 8), byte(len(value))}
	return append(out, []byte(value)...)
}

func string8(value string) []byte {
	out := []byte{byte(len(value))}
	return append(out, []byte(value)...)
}
