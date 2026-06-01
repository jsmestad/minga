package protocol

import (
	"encoding/binary"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

type CommandKind int

const (
	CommandNoop CommandKind = iota
	CommandClear
	CommandBatchEnd
	CommandDrawText
	CommandSetCursor
	CommandSetCursorShape
	CommandSetTitle
	CommandSetWindowBg
	CommandWindowContent
	CommandWindowDelta
	CommandChrome
)

type Command struct {
	Kind        CommandKind
	Size        int
	Draw        DrawText
	CursorRow   uint16
	CursorCol   uint16
	CursorShape byte
	Title       string
	WindowBg    uint32
	Window      WindowContent
	Chrome      ChromePayload
}

type DrawText struct {
	Row   uint16
	Col   uint16
	FG    uint32
	BG    uint32
	Attrs uint16
	Text  string
}

type ChromePayload struct {
	Opcode  byte
	Name    string
	Summary string
	Bytes   int
	Tabs    TabBar
	Spaces  WorkspaceBar
	Mini    Minibuffer
	Tree    FileTree
	Status  StatusBar
}

type TabBar struct {
	ActiveIndex byte
	Tabs        []Tab
}

type Tab struct {
	Flags       byte
	ID          uint32
	GroupID     uint16
	Icon        string
	Label       string
	Tint        uint32
	Active      bool
	Dirty       bool
	Agent       bool
	Attention   bool
	Pinned      bool
	AgentStatus byte
}

type WorkspaceBar struct {
	Version  byte
	ActiveID uint16
	Mode     byte
	Flags    byte
	Spaces   []Workspace
	Tabs     []WorkspaceTab
}

type Workspace struct {
	ID              uint16
	Kind            byte
	Status          byte
	Flags           uint16
	Color           uint32
	TabCount        uint16
	DraftCount      uint16
	ConflictCount   uint16
	BackgroundCount uint16
	Label           string
	Icon            string
	Active          bool
	Attention       bool
	Closeable       bool
}

type WorkspaceTab struct {
	ID          uint32
	WorkspaceID uint16
	Kind        byte
	Flags       uint16
	PathHash    uint32
	Icon        string
	Label       string
	Path        string
	Tint        uint32
}

type Minibuffer struct {
	Visible       bool
	Mode          byte
	CursorPos     uint16
	Prompt        string
	Input         string
	Context       string
	SelectedIndex uint16
	Candidates    uint16
	Total         uint16
}

type FileTree struct {
	Visible  bool
	Focused  bool
	Status   byte
	Selected string
	Root     string
	Width    uint16
	Error    string
	Rows     []FileTreeRow
}

type FileTreeRow struct {
	ID        string
	Path      string
	Name      string
	Icon      string
	Depth     byte
	Flags     uint16
	Directory bool
	Expanded  bool
	Selected  bool
	Focused   bool
	Active    bool
	Dirty     bool
}

type StatusBar struct {
	ContentKind byte
	Mode        byte
	Flags       byte
	Line        uint32
	Column      uint32
	LineCount   uint32
	Icon        string
	Filename    string
	Filetype    string
	Message     string
}

type WindowContent struct {
	ID           uint16
	CursorRow    uint16
	CursorCol    uint16
	CursorShape  byte
	ScrollLeft   uint16
	ContentEpoch uint32
	Rows         []WindowRow
}

type WindowRow struct {
	Kind        byte
	ID          uint64
	BufferLine  uint32
	ContentHash uint32
	Text        string
	Spans       []Span
}

type Span struct {
	StartCol   uint16
	EndCol     uint16
	FG         uint32
	BG         uint32
	Attrs      byte
	FontWeight byte
	FontID     byte
}

func DecodeCommand(payload []byte) (Command, error) {
	if len(payload) == 0 {
		return Command{}, fmt.Errorf("empty command")
	}

	switch payload[0] {
	case generated.OPClear:
		return Command{Kind: CommandClear, Size: 1}, nil
	case generated.OPBatchEnd:
		return Command{Kind: CommandBatchEnd, Size: 1}, nil
	case generated.OPDrawText:
		return decodeDrawText(payload)
	case generated.OPDrawStyledText:
		return decodeDrawStyledText(payload)
	case generated.OPSetCursor:
		if len(payload) < 5 {
			return Command{}, fmt.Errorf("short set_cursor")
		}
		return Command{Kind: CommandSetCursor, Size: 5, CursorRow: u16(payload, 1), CursorCol: u16(payload, 3)}, nil
	case generated.OPSetCursorShape:
		if len(payload) < 2 {
			return Command{}, fmt.Errorf("short set_cursor_shape")
		}
		return Command{Kind: CommandSetCursorShape, Size: 2, CursorShape: payload[1]}, nil
	case generated.OPSetTitle:
		if len(payload) < 3 {
			return Command{}, fmt.Errorf("short set_title")
		}
		textLen := int(u16(payload, 1))
		if len(payload) < 3+textLen {
			return Command{}, fmt.Errorf("short set_title text")
		}
		return Command{Kind: CommandSetTitle, Size: 3 + textLen, Title: string(payload[3 : 3+textLen])}, nil
	case generated.OPSetWindowBg:
		if len(payload) < 4 {
			return Command{}, fmt.Errorf("short set_window_bg")
		}
		return Command{Kind: CommandSetWindowBg, Size: 4, WindowBg: u24(payload, 1)}, nil
	case generated.OPDefineRegion:
		return fixedNoop(payload, 15, "define_region")
	case generated.OPClearRegion, generated.OPDestroyRegion, generated.OPSetActiveRegion:
		return fixedNoop(payload, 3, "region_id")
	case generated.OPScrollRegion:
		return fixedNoop(payload, 7, "scroll_region")
	case generated.OPSetFont:
		return skipString16(payload, 5, "set_font")
	case generated.OPRegisterFont:
		return skipString16(payload, 2, "register_font")
	case generated.OPSetFontFallback:
		return skipFontFallback(payload)
	case generated.OPMeasureText:
		return skipString16(payload, 5, "measure_text")
	case generated.OPGuiWindowContent, generated.OPGuiWindowViewportDelta, generated.OPGuiWindowRowsDelta:
		return decodeWindowContent(payload)
	case generated.OPGuiWindowOverlayDelta:
		return decodeOverlayDelta(payload)
	default:
		return decodeSkipOrChrome(payload)
	}
}

func decodeDrawText(payload []byte) (Command, error) {
	if len(payload) < 14 {
		return Command{}, fmt.Errorf("short draw_text")
	}

	textLen := int(u16(payload, 12))
	if len(payload) < 14+textLen {
		return Command{}, fmt.Errorf("short draw_text text")
	}

	return Command{
		Kind: CommandDrawText,
		Size: 14 + textLen,
		Draw: DrawText{
			Row:   u16(payload, 1),
			Col:   u16(payload, 3),
			FG:    u24(payload, 5),
			BG:    u24(payload, 8),
			Attrs: uint16(payload[11]),
			Text:  string(payload[14 : 14+textLen]),
		},
	}, nil
}

func decodeDrawStyledText(payload []byte) (Command, error) {
	if len(payload) < 21 {
		return Command{}, fmt.Errorf("short draw_styled_text")
	}

	textLen := int(u16(payload, 19))
	if len(payload) < 21+textLen {
		return Command{}, fmt.Errorf("short draw_styled_text text")
	}

	return Command{
		Kind: CommandDrawText,
		Size: 21 + textLen,
		Draw: DrawText{
			Row:   u16(payload, 1),
			Col:   u16(payload, 3),
			FG:    u24(payload, 5),
			BG:    u24(payload, 8),
			Attrs: u16(payload, 11),
			Text:  string(payload[21 : 21+textLen]),
		},
	}, nil
}

func decodeWindowContent(payload []byte) (Command, error) {
	if len(payload) < 2 {
		return Command{}, fmt.Errorf("short semantic window")
	}

	opcode := payload[0]
	sectionCount := int(payload[1])
	offset := 2
	window := WindowContent{}

	for i := 0; i < sectionCount; i++ {
		if len(payload) < offset+3 {
			return Command{}, fmt.Errorf("short semantic section")
		}
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		if len(payload) < offset+sectionLen {
			return Command{}, fmt.Errorf("short semantic section payload")
		}
		section := payload[offset : offset+sectionLen]
		offset += sectionLen

		switch sectionID {
		case 0x01:
			decodeWindowHeader(opcode, section, &window)
		case 0x02:
			decodeRows(section, &window, opcode != generated.OPGuiWindowContent)
		}
	}

	return Command{Kind: CommandWindowContent, Size: offset, Window: window}, nil
}

func decodeOverlayDelta(payload []byte) (Command, error) {
	if len(payload) < 12 {
		return Command{}, fmt.Errorf("short overlay delta")
	}

	window := WindowContent{
		ID:           u16(payload, 1),
		ContentEpoch: u32(payload, 3),
		CursorRow:    u16(payload, 8),
		CursorCol:    u16(payload, 10),
	}
	if len(payload) >= 13 {
		window.CursorShape = payload[12]
	}

	return Command{Kind: CommandWindowDelta, Size: len(payload), Window: window}, nil
}

func decodeWindowHeader(opcode byte, section []byte, window *WindowContent) {
	if opcode == generated.OPGuiWindowContent {
		if len(section) < 14 {
			return
		}
		window.ID = u16(section, 0)
		window.CursorRow = u16(section, 3)
		window.CursorCol = u16(section, 5)
		window.CursorShape = section[7]
		window.ScrollLeft = u16(section, 8)
		window.ContentEpoch = u32(section, 10)
		return
	}

	if len(section) < 15 {
		return
	}
	window.ID = u16(section, 0)
	window.ContentEpoch = u32(section, 2)
	window.CursorRow = u16(section, 7)
	window.CursorCol = u16(section, 9)
	window.CursorShape = section[11]
	window.ScrollLeft = u16(section, 12)
}

func decodeRows(section []byte, window *WindowContent, delta bool) {
	if len(section) < 2 {
		return
	}

	count := int(u16(section, 0))
	offset := 2
	rows := make([]WindowRow, 0, count)

	for i := 0; i < count && offset < len(section); i++ {
		if delta && section[offset] == 0 && len(section) >= offset+13 {
			offset += 13
			continue
		}
		if delta && section[offset] == 1 {
			offset++
		}

		row, next, ok := decodeRow(section, offset)
		if !ok {
			break
		}
		rows = append(rows, row)
		offset = next
	}

	window.Rows = rows
}

func decodeRow(section []byte, offset int) (WindowRow, int, bool) {
	if len(section) < offset+21 {
		return WindowRow{}, offset, false
	}

	row := WindowRow{
		Kind:        section[offset],
		ID:          binary.BigEndian.Uint64(section[offset+1 : offset+9]),
		BufferLine:  u32(section, offset+9),
		ContentHash: u32(section, offset+13),
	}
	textLen := int(u32(section, offset+17))
	offset += 21
	if len(section) < offset+textLen+2 || !utf8.Valid(section[offset:offset+textLen]) {
		return WindowRow{}, offset, false
	}
	row.Text = string(section[offset : offset+textLen])
	offset += textLen

	spanCount := int(u16(section, offset))
	offset += 2
	row.Spans = make([]Span, 0, spanCount)
	for i := 0; i < spanCount && len(section) >= offset+13; i++ {
		row.Spans = append(row.Spans, Span{
			StartCol:   u16(section, offset),
			EndCol:     u16(section, offset+2),
			FG:         u24(section, offset+4),
			BG:         u24(section, offset+7),
			Attrs:      section[offset+10],
			FontWeight: section[offset+11],
			FontID:     section[offset+12],
		})
		offset += 13
	}

	return row, offset, true
}

func decodeSkipOrChrome(payload []byte) (Command, error) {
	opcode := payload[0]
	if opcode >= 0x70 {
		chrome := decodeChrome(payload)
		return Command{Kind: CommandChrome, Size: chrome.Bytes, Chrome: chrome}, nil
	}

	return Command{Kind: CommandNoop, Size: len(payload)}, nil
}

func decodeChrome(payload []byte) ChromePayload {
	opcode := payload[0]
	chrome := ChromePayload{Opcode: opcode, Name: opcodeName(opcode), Bytes: len(payload)}

	switch opcode {
	case generated.OPGuiTabBar:
		chrome.Tabs, chrome.Summary, chrome.Bytes = decodeTabBar(payload)
	case generated.OPGuiWorkspaces:
		chrome.Spaces, chrome.Summary, chrome.Bytes = decodeWorkspaces(payload)
	case generated.OPGuiMinibuffer:
		chrome.Mini, chrome.Summary, chrome.Bytes = decodeMinibuffer(payload)
	case generated.OPGuiFileTree:
		chrome.Tree, chrome.Summary, chrome.Bytes = decodeFileTree(payload)
	case generated.OPGuiStatusBar:
		chrome.Status, chrome.Summary, chrome.Bytes = decodeStatus(payload)
	default:
		if size := sectionedSize(payload); size > 0 {
			chrome.Bytes = size
		}
	}

	return chrome
}

func decodeTabBar(payload []byte) (TabBar, string, int) {
	if len(payload) < 3 {
		return TabBar{}, "", len(payload)
	}

	tabBar := TabBar{ActiveIndex: payload[1]}
	count := int(payload[2])
	offset := 3
	labels := make([]string, 0, count)
	tabBar.Tabs = make([]Tab, 0, count)

	for i := 0; i < count && len(payload) >= offset+8; i++ {
		flags := payload[offset]
		id := u32(payload, offset+1)
		groupID := u16(payload, offset+5)
		offset += 1 + 4 + 2
		icon, next, ok := readString8(payload, offset)
		if !ok {
			break
		}
		offset = next
		label, next, ok := readString16(payload, offset)
		if !ok || len(payload) < next+4 {
			break
		}
		tint := u32(payload, next)
		offset = next + 4
		tab := Tab{
			Flags:       flags,
			ID:          id,
			GroupID:     groupID,
			Icon:        icon,
			Label:       label,
			Tint:        tint,
			Active:      flags&0x01 != 0,
			Dirty:       flags&0x02 != 0,
			Agent:       flags&0x04 != 0,
			Attention:   flags&0x08 != 0,
			AgentStatus: (flags >> 4) & 0x07,
			Pinned:      flags&0x80 != 0,
		}
		tabBar.Tabs = append(tabBar.Tabs, tab)
		prefix := " "
		if byte(i) == tabBar.ActiveIndex || tab.Active {
			prefix = "*"
		}
		labels = append(labels, prefix+icon+" "+label)
	}

	return tabBar, stringsJoin(labels, "  "), offset
}

func decodeWorkspaces(payload []byte) (WorkspaceBar, string, int) {
	if len(payload) < 3 {
		return WorkspaceBar{}, "", len(payload)
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size {
		return WorkspaceBar{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 6 {
		return WorkspaceBar{}, "", size
	}

	bar := WorkspaceBar{
		Version:  body[0],
		ActiveID: u16(body, 1),
		Mode:     body[3],
		Flags:    body[4],
	}
	offset := 6
	count := int(body[5])
	labels := make([]string, 0, count)
	bar.Spaces = make([]Workspace, 0, count)
	for i := 0; i < count && len(body) >= offset+19; i++ {
		space := Workspace{
			ID:              u16(body, offset),
			Kind:            body[offset+2],
			Status:          body[offset+3],
			Flags:           u16(body, offset+4),
			Color:           u24(body, offset+6),
			TabCount:        u16(body, offset+9),
			DraftCount:      u16(body, offset+11),
			ConflictCount:   u16(body, offset+13),
			BackgroundCount: u16(body, offset+15),
		}
		offset += 17
		label, next, ok := readString8(body, offset)
		if !ok {
			break
		}
		space.Label = label
		icon, next, ok := readString8(body, next)
		if !ok {
			break
		}
		offset = next
		space.Icon = icon
		space.Active = space.ID == bar.ActiveID
		space.Attention = space.Flags&0x01 != 0
		space.Closeable = space.Flags&0x02 != 0
		bar.Spaces = append(bar.Spaces, space)
		prefix := " "
		if space.Active {
			prefix = "*"
		}
		labels = append(labels, fmt.Sprintf("%s%s %s", prefix, space.Icon, space.Label))
	}
	if len(body) < offset+2 {
		return bar, stringsJoin(labels, "  "), size
	}
	tabCount := int(u16(body, offset))
	offset += 2
	bar.Tabs = make([]WorkspaceTab, 0, tabCount)
	for i := 0; i < tabCount && len(body) >= offset+18; i++ {
		tab := WorkspaceTab{
			ID:          u32(body, offset),
			WorkspaceID: u16(body, offset+4),
			Kind:        body[offset+6],
			Flags:       u16(body, offset+7),
			PathHash:    u32(body, offset+9),
		}
		offset += 13
		var ok bool
		tab.Icon, offset, ok = readString8(body, offset)
		if !ok {
			break
		}
		tab.Label, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		tab.Path, offset, ok = readString16(body, offset)
		if !ok || len(body) < offset+4 {
			break
		}
		tab.Tint = u32(body, offset)
		offset += 4
		bar.Tabs = append(bar.Tabs, tab)
	}
	return bar, stringsJoin(labels, "  "), size
}

func decodeMinibuffer(payload []byte) (Minibuffer, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return Minibuffer{}, "", min(len(payload), 2)
	}
	if len(payload) < 6 {
		return Minibuffer{Visible: true}, "", len(payload)
	}

	mini := Minibuffer{
		Visible:   true,
		Mode:      payload[2],
		CursorPos: u16(payload, 3),
	}
	offset := 5
	prompt, next, ok := readString8(payload, offset)
	if !ok {
		return mini, "", len(payload)
	}
	mini.Prompt = prompt
	input, next, ok := readString16(payload, next)
	if !ok {
		return mini, "", len(payload)
	}
	mini.Input = input
	context, next, ok := readString16(payload, next)
	if !ok || len(payload) < next+6 {
		return mini, "", len(payload)
	}
	mini.Context = context
	mini.SelectedIndex = u16(payload, next)
	mini.Candidates = u16(payload, next+2)
	mini.Total = u16(payload, next+4)
	return mini, strings.TrimSpace(prompt + input + " " + context), len(payload)
}

func decodeFileTree(payload []byte) (FileTree, string, int) {
	if len(payload) < 5 {
		return FileTree{}, "", len(payload)
	}

	size := 5 + int(u32(payload, 1))
	if len(payload) < size {
		return FileTree{}, "", len(payload)
	}
	body := payload[5:size]
	if len(body) < 3 {
		return FileTree{}, "", size
	}

	flags := body[1]
	status := body[2]
	tree := FileTree{Visible: flags&0x01 != 0, Focused: flags&0x02 != 0, Status: status}
	offset := 3
	selected, next, ok := readString16(body, offset)
	if !ok {
		return tree, "", size
	}
	tree.Selected = selected
	root, next, ok := readString16(body, next)
	if !ok || len(body) < next+4 {
		return tree, "", size
	}
	tree.Root = root
	tree.Width = u16(body, next)
	rowCount := int(u16(body, next+2))
	next += 4
	errorReason, next, ok := readString16(body, next)
	if ok {
		tree.Error = errorReason
		tree.Rows = decodeFileTreeRows(body, next, rowCount)
	}
	statusText := map[byte]string{0: "hidden", 1: "loading", 2: "empty", 3: "ready", 4: "error"}[status]
	if selected != "" {
		return tree, fmt.Sprintf("%s %s (%d)", statusText, selected, rowCount), size
	}
	return tree, fmt.Sprintf("%s %s (%d)", statusText, root, rowCount), size
}

func decodeFileTreeRows(body []byte, offset int, count int) []FileTreeRow {
	rows := make([]FileTreeRow, 0, count)
	for i := 0; i < count && len(body) >= offset+17; i++ {
		flags := u16(body, offset+4)
		row := FileTreeRow{
			Flags:     flags,
			Depth:     body[offset+6],
			Directory: flags&0x01 != 0,
			Expanded:  flags&0x02 != 0,
			Selected:  flags&0x04 != 0,
			Focused:   flags&0x08 != 0,
			Active:    flags&0x10 != 0,
			Dirty:     flags&0x20 != 0,
		}
		offset += 17
		if len(body) < offset {
			break
		}
		guideCount := int(body[offset-1])
		offset += guideCount
		var ok bool
		row.ID, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		row.Path, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		_, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		row.Name, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		row.Icon, offset, ok = readString8(body, offset)
		if !ok || len(body) < offset+1 {
			break
		}
		offset++
		_, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		rows = append(rows, row)
	}
	return rows
}

func decodeStatus(payload []byte) (StatusBar, string, int) {
	size := sectionedSize(payload)
	if size == 0 {
		return StatusBar{}, "", len(payload)
	}

	status := StatusBar{}
	parts := make([]string, 0, 4)
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		section := payload[offset : offset+sectionLen]
		offset += sectionLen

		switch sectionID {
		case 0x01:
			if len(section) >= 3 {
				status.ContentKind = section[0]
				status.Mode = section[1]
				status.Flags = section[2]
			}
		case 0x02:
			if len(section) >= 12 {
				status.Line = u32(section, 0)
				status.Column = u32(section, 4)
				status.LineCount = u32(section, 8)
				parts = append(parts, fmt.Sprintf("%d:%d", status.Line, status.Column))
			}
		case 0x06:
			icon, filename, filetype, ok := statusFile(section)
			if ok {
				status.Icon = icon
				status.Filename = filename
				status.Filetype = filetype
				parts = append(parts, filename)
			}
		case 0x07:
			if message, _, ok := readString16(section, 0); ok && message != "" {
				status.Message = message
				parts = append(parts, message)
			}
		}
	}

	return status, stringsJoin(parts, "  "), size
}

func statusFile(section []byte) (string, string, string, bool) {
	if len(section) < 1 {
		return "", "", "", false
	}
	icon, offset, ok := readString8(section, 0)
	if !ok || len(section) < offset+3 {
		return "", "", "", false
	}
	offset += 3
	filename, offset, ok := readString16(section, offset)
	if !ok {
		return "", "", "", false
	}
	filetype, _, ok := readString8(section, offset)
	return icon, filename, filetype, ok
}

func fixedNoop(payload []byte, size int, name string) (Command, error) {
	if len(payload) < size {
		return Command{}, fmt.Errorf("short %s", name)
	}
	return Command{Kind: CommandNoop, Size: size}, nil
}

func skipString16(payload []byte, lengthOffset int, name string) (Command, error) {
	if len(payload) < lengthOffset+2 {
		return Command{}, fmt.Errorf("short %s", name)
	}
	size := lengthOffset + 2 + int(u16(payload, lengthOffset))
	if len(payload) < size {
		return Command{}, fmt.Errorf("short %s payload", name)
	}
	return Command{Kind: CommandNoop, Size: size}, nil
}

func skipFontFallback(payload []byte) (Command, error) {
	if len(payload) < 2 {
		return Command{}, fmt.Errorf("short set_font_fallback")
	}

	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		if len(payload) < offset+2 {
			return Command{}, fmt.Errorf("short set_font_fallback entry")
		}
		offset += 2 + int(u16(payload, offset))
		if len(payload) < offset {
			return Command{}, fmt.Errorf("short set_font_fallback name")
		}
	}
	return Command{Kind: CommandNoop, Size: offset}, nil
}

func sectionedSize(payload []byte) int {
	if len(payload) < 2 {
		return 0
	}

	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		if len(payload) < offset+3 {
			return 0
		}
		offset += 3 + int(u16(payload, offset+1))
		if len(payload) < offset {
			return 0
		}
	}
	return offset
}

func opcodeName(opcode byte) string {
	switch opcode {
	case generated.OPGuiTabBar:
		return "tabs"
	case generated.OPGuiWorkspaces:
		return "workspaces"
	case generated.OPGuiSidebars, generated.OPGuiFileTree:
		return "file tree"
	case generated.OPGuiPicker:
		return "picker"
	case generated.OPGuiMinibuffer:
		return "minibuffer"
	case generated.OPGuiCompletion:
		return "completion"
	case generated.OPGuiStatusBar:
		return "status"
	case generated.OPGuiWhichKey:
		return "which-key"
	case generated.OPGuiBottomPanel:
		return "panel"
	case generated.OPGuiExtensionPanel:
		return "extension"
	case generated.OPGuiNotifications:
		return "notifications"
	default:
		return fmt.Sprintf("0x%02X", opcode)
	}
}

func u16(data []byte, offset int) uint16 {
	return binary.BigEndian.Uint16(data[offset : offset+2])
}

func u24(data []byte, offset int) uint32 {
	return uint32(data[offset])<<16 | uint32(data[offset+1])<<8 | uint32(data[offset+2])
}

func u32(data []byte, offset int) uint32 {
	return binary.BigEndian.Uint32(data[offset : offset+4])
}

func readString8(data []byte, offset int) (string, int, bool) {
	if len(data) < offset+1 {
		return "", offset, false
	}
	size := int(data[offset])
	offset++
	if len(data) < offset+size {
		return "", offset, false
	}
	return string(data[offset : offset+size]), offset + size, true
}

func readString16(data []byte, offset int) (string, int, bool) {
	if len(data) < offset+2 {
		return "", offset, false
	}
	size := int(u16(data, offset))
	offset += 2
	if len(data) < offset+size {
		return "", offset, false
	}
	return string(data[offset : offset+size]), offset + size, true
}

func stringsJoin(parts []string, sep string) string {
	compact := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			compact = append(compact, part)
		}
	}
	return strings.Join(compact, sep)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
