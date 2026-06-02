package protocol

import (
	"encoding/binary"
	"fmt"
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
	Opcode        byte
	Name          string
	Summary       string
	Bytes         int
	Tabs          TabBar
	Spaces        WorkspaceBar
	Mini          Minibuffer
	Complete      Completion
	Which         WhichKey
	Picker        Picker
	Preview       PickerPreview
	Tree          FileTree
	Status        StatusBar
	Theme         Theme
	Breadcrumb    Breadcrumb
	Git           GitStatus
	Search        SearchState
	Change        ChangeSummary
	Hover         HoverPopup
	HoverAction   HoverAction
	Signature     SignatureHelp
	Float         FloatPopup
	Overlay       ExtensionOverlay
	Notifications Notifications
	Bottom        BottomPanel
	Extensions    ExtensionPanel
	Sidebars      Sidebars
	Observatory   Observatory
	AgentContext  AgentContext
	AgentChat     AgentChat
	Board         Board
	Timeline      EditTimeline
	Gutter        GutterSeparator
	WindowGutter  Gutter
	Splits        SplitSeparators
}

type WindowContent struct {
	ID           uint16
	CursorRow    uint16
	CursorCol    uint16
	CursorShape  byte
	ScrollLeft   uint16
	ContentEpoch uint32
	Cursorline   Cursorline
	Rows         []WindowRow
}

type Cursorline struct {
	Visible bool
	Row     uint16
	BG      uint32
}

type WindowRow struct {
	Ref         bool
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
		case 0x09:
			decodeCursorline(section, &window)
		}
	}

	kind := CommandWindowContent
	if opcode != generated.OPGuiWindowContent {
		kind = CommandWindowDelta
	}
	return Command{Kind: kind, Size: offset, Window: window}, nil
}

// overlayDeltaCursorlineFlag marks a trailing cursorline section in an overlay
// delta (see WindowEncoder.encode_overlay_delta/1).
const overlayDeltaCursorlineFlag = 0x02

func decodeOverlayDelta(payload []byte) (Command, error) {
	// opcode(1) + window_id(2) + content_epoch(4) + flags(1) + cursor_row(2) +
	// cursor_col(2) + cursor_shape(1) = 13 bytes, plus a flat 5-byte cursorline
	// (row:2, r, g, b) when the flags cursorline bit is set. The size must be
	// bounded: returning len(payload) here would swallow the rest of the batch.
	const base = 13
	if len(payload) < base {
		return Command{}, fmt.Errorf("short overlay delta")
	}

	window := WindowContent{
		ID:           u16(payload, 1),
		ContentEpoch: u32(payload, 3),
		CursorRow:    u16(payload, 8),
		CursorCol:    u16(payload, 10),
		CursorShape:  payload[12],
	}

	size := base
	if payload[7]&overlayDeltaCursorlineFlag != 0 {
		size += 5
		if len(payload) < size {
			return Command{}, fmt.Errorf("short overlay delta cursorline")
		}
		window.Cursorline = Cursorline{Visible: true, Row: u16(payload, base), BG: u24(payload, base+2)}
	}

	return Command{Kind: CommandWindowDelta, Size: size, Window: window}, nil
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

func decodeCursorline(section []byte, window *WindowContent) {
	if len(section) < 5 {
		return
	}
	window.Cursorline = Cursorline{Visible: true, Row: u16(section, 0), BG: u24(section, 2)}
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
			rows = append(rows, WindowRow{
				Ref:         true,
				ID:          binary.BigEndian.Uint64(section[offset+1 : offset+9]),
				ContentHash: u32(section, offset+9),
			})
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

	// Unhandled low opcode: size it through the schema authority rather than
	// swallowing the rest of the batch.
	if size, status := generated.CommandSize(payload); status == generated.CommandSizeOK {
		return Command{Kind: CommandNoop, Size: size}, nil
	}
	return Command{}, fmt.Errorf("cannot size opcode 0x%02X", opcode)
}
