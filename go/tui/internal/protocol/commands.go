package protocol

import (
	"encoding/binary"
	"fmt"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

type CommandKind int

const (
	CommandNoop CommandKind = iota
	// CommandBeginFrame opens a frame transaction (#2219). The frontend opens a
	// staging buffer keyed by frame_seq/base_frame_seq and accumulates the
	// transaction's commands until commit_frame.
	CommandBeginFrame
	// CommandCommitFrame closes a frame transaction (#2219), carrying the echoed
	// input correlation sequence (input_seq). The frontend gates the frame and
	// resolves keystroke latency on it.
	CommandCommitFrame
	CommandSetCursorShape
	CommandSetTitle
	CommandSetWindowBg
	CommandWindowContent
	CommandWindowDelta
	CommandChrome
	CommandClipboardWrite
	CommandExtensionRuntime
	CommandProtocolError
	// CommandStreamError is a synthetic, in-band marker the reader injects when a
	// command in a batch cannot be sized or decoded (#2219). It carries no wire
	// payload; the model treats it as a transaction invalidation when a frame
	// transaction is open, so a partial/garbled frame triggers request_keyframe
	// instead of warn-and-continue swallowing the rest of the open transaction.
	CommandStreamError
)

type Command struct {
	Kind CommandKind
	Size int
	// FrameSeq is the strictly monotonic global frame sequence carried by both
	// begin_frame and commit_frame (#2219). The staging buffer matches a commit's
	// FrameSeq against the open begin's to validate the transaction.
	FrameSeq uint32
	// BaseFrameSeq is the frame a begin_frame transaction's deltas assume; 0 means
	// keyframe (#2219). A non-zero base must equal the last committed frame_seq or
	// the transaction is invalidated.
	BaseFrameSeq uint32
	// Generation is the BEAM-owned recovery generation echoed by frame status.
	Generation uint32
	// InputSeq is the echoed input correlation sequence carried by a
	// CommandCommitFrame (ticket #2215, wire field input_seq). 0 means "no correlation".
	InputSeq         uint32
	CursorShape      byte
	Title            string
	WindowBg         uint32
	Window           WindowContent
	Chrome           ChromePayload
	ClipboardText    string
	ExtensionRuntime ExtensionRuntimePayload
	// ProtocolError carries the UTF-8 reason from a protocol_error (0x18)
	// command. The BEAM emits it when a frontend's handshake protocol_version
	// does not match the BEAM's, so the frontend shows a blocking error instead
	// of decoding a stream it cannot parse (ticket #2237).
	ProtocolError string
}

type ExtensionRuntimePayload struct {
	ExtensionID string
	Channel     string
	Payload     []byte
	Bytes       int
}

type ChromePayload struct {
	Opcode            byte
	Name              string
	Summary           string
	Bytes             int
	Tabs              TabBar
	Spaces            WorkspaceBar
	Mini              Minibuffer
	Complete          Completion
	Which             WhichKey
	Picker            Picker
	Preview           PickerPreview
	Tree              FileTree
	Status            StatusBar
	Theme             Theme
	Breadcrumb        Breadcrumb
	Git               GitStatus
	Search            SearchState
	Hover             HoverPopup
	HoverAction       HoverAction
	Signature         SignatureHelp
	Float             FloatPopup
	Overlay           ExtensionOverlay
	Notifications     Notifications
	Bottom            BottomPanel
	Extensions        ExtensionPanel
	Sidebars          Sidebars
	Observatory       Observatory
	AgentContext      AgentContext
	AgentChat         AgentChat
	AgentTranscript   AgentTranscript
	Timeline          EditTimeline
	Gutter            GutterSeparator
	CursorlineChrome  CursorlineChrome
	WindowGutter      Gutter
	IndentGuides      IndentGuides
	LineSpacing       LineSpacing
	FileTreeSelection FileTreeSelection
	CursorAnimation   CursorAnimation
	ConfigState       ConfigState
	Splits            SplitSeparators
	EmptyState        EmptyState
	// Placements carries the authoritative per-frame surface layout from
	// gui_surface_layout (0xA4, #2268): the BEAM's one rect+z list that drives
	// compositing order (sort by Z) and is the same list BEAM mouse hit-testing
	// uses. Empty when the opcode is absent.
	Placements []generated.SurfacePlacement
}

type WindowContent struct {
	ID             uint16
	CursorRow      uint16
	CursorCol      uint16
	CursorShape    byte
	CursorVisible  bool
	ScrollLeft     uint16
	ScrollLeftSet  bool
	ContentEpoch   uint32
	Cursorline     Cursorline
	Selection      Selection
	SearchMatches  []SearchMatch
	Diagnostics    []DiagnosticRange
	Highlights     []DocumentHighlight
	Annotations    []LineAnnotation
	Geometry       PaneGeometry
	Scroll         ScrollPresentation
	Rows           []WindowRow
	BaseRowCount   uint32
	ResultRowCount uint32
	RowSplices     []WindowRowSplice
	RowSplicesSet  bool
	SelectionSet   bool
	SearchSet      bool
	DiagnosticsSet bool
	HighlightsSet  bool
	AnnotationsSet bool
	GeometrySet    bool
	ScrollSet      bool
}

type Cursorline struct {
	Visible bool
	Row     uint16
	BG      uint32
}

type WindowRowSplice struct {
	StartIndex  uint32
	DeleteCount uint32
	InsertRows  []WindowRow
}

type WindowRow struct {
	Ref         bool
	Kind        byte
	ID          uint64
	BufferLine  uint32
	ContentHash uint32
	Text        string
	Spans       []generated.Span
}

// Span is a type alias for the generated span structure.
type Span = generated.Span

func DecodeCommand(payload []byte) (Command, error) {
	if len(payload) == 0 {
		return Command{}, fmt.Errorf("empty command")
	}

	switch payload[0] {
	case generated.OPBeginFrame:
		// begin_frame (#2739): frame_seq:u32 + base_frame_seq:u32 + generation:u32.
		if len(payload) < 13 {
			return Command{}, fmt.Errorf("short begin_frame")
		}
		return Command{
			Kind:         CommandBeginFrame,
			Size:         13,
			FrameSeq:     binary.BigEndian.Uint32(payload[1:5]),
			BaseFrameSeq: binary.BigEndian.Uint32(payload[5:9]),
			Generation:   binary.BigEndian.Uint32(payload[9:13]),
		}, nil
	case generated.OPCommitFrame:
		// commit_frame closes a frame transaction (#2219): <opcode, frame_seq:u32,
		// input_seq:u32>. input_seq is the echoed input correlation sequence
		// (ticket #2215).
		if len(payload) < 9 {
			return Command{}, fmt.Errorf("short commit_frame")
		}
		return Command{
			Kind:     CommandCommitFrame,
			Size:     9,
			FrameSeq: binary.BigEndian.Uint32(payload[1:5]),
			InputSeq: binary.BigEndian.Uint32(payload[5:9]),
		}, nil
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
	case generated.OPSetFont:
		return skipString16(payload, 5, "set_font")
	case generated.OPRegisterFont:
		return skipString16(payload, 2, "register_font")
	case generated.OPSetFontFallback:
		return skipFontFallback(payload)
	case generated.OPMeasureText:
		return skipString16(payload, 5, "measure_text")
	case generated.OPProtocolError:
		return decodeProtocolError(payload)
	case generated.OPClipboardWrite:
		return decodeClipboardWrite(payload)
	case generated.OPGuiWindowContent, generated.OPGuiWindowViewportDelta, generated.OPGuiWindowRowsDelta:
		return decodeWindowContent(payload)
	case generated.OPGuiWindowOverlayDelta:
		return decodeOverlayDelta(payload)
	case generated.OPGuiExtensionRuntime:
		return decodeExtensionRuntime(payload)
	default:
		return decodeSkipOrChrome(payload)
	}
}

func decodeWindowContent(payload []byte) (Command, error) {
	if len(payload) < 2 {
		return Command{}, fmt.Errorf("short semantic window")
	}

	opcode := payload[0]
	sectionCount := 0
	offset := 0
	end := 0
	sectionLenBytes := 4

	if opcode == generated.OPGuiWindowContent {
		if len(payload) < 6 {
			return Command{}, fmt.Errorf("short semantic window")
		}
		payloadLen := int(u32(payload, 1))
		end = 5 + payloadLen
		if payloadLen < 1 || len(payload) < end {
			return Command{}, fmt.Errorf("short semantic window payload")
		}
		sectionCount = int(payload[5])
		offset = 6
		sectionLenBytes = 4
	} else {
		sectionCount = int(payload[1])
		offset = 2
		end = len(payload)
	}

	sawHeader := false
	sawRows := false
	sawRowSplices := false
	window := WindowContent{}

	for i := 0; i < sectionCount; i++ {
		if end < offset+1+sectionLenBytes {
			return Command{}, fmt.Errorf("short semantic section")
		}
		sectionID := payload[offset]
		sectionLen := int(u32(payload, offset+1))
		offset += 1 + sectionLenBytes
		if end < offset+sectionLen {
			return Command{}, fmt.Errorf("short semantic section payload")
		}
		section := payload[offset : offset+sectionLen]
		offset += sectionLen

		switch sectionID {
		case 0x01:
			if sawHeader || !decodeWindowHeader(opcode, section, &window) {
				return Command{}, fmt.Errorf("malformed semantic window header")
			}
			sawHeader = true
		case 0x02:
			if sawRows || sawRowSplices || !decodeRows(section, &window, opcode != generated.OPGuiWindowContent) {
				return Command{}, fmt.Errorf("malformed semantic window rows")
			}
			sawRows = true
		case 0x0B:
			if opcode != generated.OPGuiWindowRowsDelta || sawRows || sawRowSplices || !decodeRowSplices(section, &window) {
				return Command{}, fmt.Errorf("malformed semantic window row splices")
			}
			sawRowSplices = true
		case 0x03:
			decodeSelection(section, &window)
		case 0x04:
			decodeSearchMatches(section, &window)
		case 0x05:
			decodeDiagnosticRanges(section, &window)
		case 0x06:
			decodeDocumentHighlights(section, &window)
		case 0x07:
			decodeLineAnnotations(section, &window)
		case 0x08:
			decodePaneGeometry(section, &window)
		case 0x09:
			decodeCursorline(section, &window)
		case 0x0A:
			decodeScrollPresentation(section, &window)
		}
	}

	if !sawHeader {
		return Command{}, fmt.Errorf("missing required semantic window header")
	}
	if sawRows == sawRowSplices {
		return Command{}, fmt.Errorf("missing or ambiguous semantic window rows")
	}

	validateScrollPresentation(&window)

	kind := CommandWindowContent
	if opcode != generated.OPGuiWindowContent {
		kind = CommandWindowDelta
	}
	if opcode == generated.OPGuiWindowContent && offset != end {
		return Command{}, fmt.Errorf("trailing semantic window bytes")
	}
	return Command{Kind: kind, Size: offset, Window: window}, nil
}

func validateScrollPresentation(window *WindowContent) {
	if !window.ScrollSet {
		return
	}
	if window.Scroll.WindowID == window.ID && window.Scroll.ContentEpoch == window.ContentEpoch {
		return
	}
	window.Scroll = ScrollPresentation{}
	window.ScrollSet = false
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
		ID:            u16(payload, 1),
		ContentEpoch:  u32(payload, 3),
		CursorRow:     u16(payload, 8),
		CursorCol:     u16(payload, 10),
		CursorShape:   payload[12],
		CursorVisible: payload[7]&0x01 != 0,
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

func decodeWindowHeader(opcode byte, section []byte, window *WindowContent) bool {
	if opcode == generated.OPGuiWindowContent {
		hdr, _, err := generated.DecodeGuiWindowContentHeader(section, 0, len(section))
		if err != nil {
			return false
		}
		window.ID = hdr.WindowID
		window.CursorRow = hdr.CursorRow
		window.CursorCol = hdr.CursorCol
		window.CursorShape = hdr.CursorShape
		window.CursorVisible = hdr.Flags&0x02 != 0
		window.ScrollLeft = hdr.ScrollLeft
		window.ScrollLeftSet = true
		window.ContentEpoch = hdr.ContentEpoch
		return true
	}

	// Delta header has a different wire layout from the full header.
	if len(section) < 14 {
		return false
	}
	window.ID = u16(section, 0)
	window.ContentEpoch = u32(section, 2)
	window.CursorVisible = section[6]&0x01 != 0
	window.CursorRow = u16(section, 7)
	window.CursorCol = u16(section, 9)
	window.CursorShape = section[11]
	window.ScrollLeft = u16(section, 12)
	window.ScrollLeftSet = true
	return true
}

func decodeCursorline(section []byte, window *WindowContent) {
	cl, _, err := generated.DecodeGuiWindowContentCursorline(section, 0, len(section))
	if err != nil {
		return
	}
	window.Cursorline = Cursorline{Visible: true, Row: cl.Row, BG: cl.BG}
}

func decodeRowSplices(section []byte, window *WindowContent) bool {
	if len(section) < 12 {
		return false
	}
	baseCount := u32(section, 0)
	resultCount := u32(section, 4)
	spliceCount := int(u32(section, 8))
	offset := 12
	if spliceCount > (len(section)-offset)/12 {
		return false
	}
	splices := make([]WindowRowSplice, 0, spliceCount)
	var previousStart uint32
	var previousEnd uint64
	var havePrevious bool
	computed := int64(baseCount)
	for i := 0; i < spliceCount; i++ {
		if len(section) < offset+12 {
			return false
		}
		start := u32(section, offset)
		deleteCount := u32(section, offset+4)
		insertCount := int(u32(section, offset+8))
		offset += 12
		deleteEnd := uint64(start) + uint64(deleteCount)
		if deleteEnd > uint64(baseCount) || (havePrevious && start <= previousStart) ||
			uint64(start) < previousEnd || (deleteCount == 0 && insertCount == 0) ||
			insertCount > (len(section)-offset)/13 {
			return false
		}
		insertRows := make([]WindowRow, 0, insertCount)
		for j := 0; j < insertCount; j++ {
			row, next, ok := decodeDeltaRowEntry(section, offset)
			if !ok {
				return false
			}
			insertRows = append(insertRows, row)
			offset = next
		}
		splices = append(splices, WindowRowSplice{StartIndex: start, DeleteCount: deleteCount, InsertRows: insertRows})
		previousStart = start
		previousEnd = deleteEnd
		havePrevious = true
		computed = computed - int64(deleteCount) + int64(insertCount)
		if computed < 0 || computed > int64(^uint32(0)) {
			return false
		}
	}
	if offset != len(section) || computed != int64(resultCount) {
		return false
	}
	window.BaseRowCount = baseCount
	window.ResultRowCount = resultCount
	window.RowSplices = splices
	window.RowSplicesSet = true
	return true
}

func decodeRows(section []byte, window *WindowContent, delta bool) bool {
	if len(section) < 4 {
		return false
	}

	count := int(u32(section, 0))
	offset := 4
	minimumRowSize := 23
	if delta {
		minimumRowSize = 13
	}
	if count > (len(section)-offset)/minimumRowSize {
		return false
	}
	rows := make([]WindowRow, 0, count)

	for i := 0; i < count; i++ {
		if delta {
			row, next, ok := decodeDeltaRowEntry(section, offset)
			if !ok {
				return false
			}
			rows = append(rows, row)
			offset = next
			continue
		}

		row, next, ok := decodeRow(section, offset)
		if !ok {
			return false
		}
		rows = append(rows, row)
		offset = next
	}

	if offset != len(section) {
		return false
	}
	window.Rows = rows
	return true
}

func decodeDeltaRowEntry(section []byte, offset int) (WindowRow, int, bool) {
	if offset >= len(section) {
		return WindowRow{}, offset, false
	}
	switch section[offset] {
	case 0:
		if len(section) < offset+13 {
			return WindowRow{}, offset, false
		}
		return WindowRow{
			Ref:         true,
			ID:          binary.BigEndian.Uint64(section[offset+1 : offset+9]),
			ContentHash: u32(section, offset+9),
		}, offset + 13, true
	case 1:
		return decodeRow(section, offset+1)
	default:
		return WindowRow{}, offset, false
	}
}

func decodeRow(section []byte, offset int) (WindowRow, int, bool) {
	genRow, nextOffset, err := generated.DecodeRow(section, offset, len(section))
	if err != nil {
		return WindowRow{}, offset, false
	}
	return WindowRow{
		Kind:        genRow.RowType,
		ID:          genRow.RowID,
		BufferLine:  genRow.BufLine,
		ContentHash: genRow.ContentHash,
		Text:        genRow.Text,
		Spans:       genRow.Spans,
	}, nextOffset, true
}

// decodeProtocolError decodes a protocol_error (0x18) command. The BEAM emits it
// when a frontend's handshake protocol_version does not match the BEAM's; the
// frontend displays the UTF-8 reason as a blocking error instead of decoding a
// stream it cannot parse (ticket #2237). Wire format: opcode(1) + len(u16) +
// UTF-8 message.
func decodeProtocolError(payload []byte) (Command, error) {
	if len(payload) < 3 {
		return Command{}, fmt.Errorf("short protocol_error")
	}
	messageLen := int(u16(payload, 1))
	size := 3 + messageLen
	if len(payload) < size {
		return Command{}, fmt.Errorf("short protocol_error message")
	}
	return Command{Kind: CommandProtocolError, Size: size, ProtocolError: string(payload[3:size])}, nil
}

func decodeClipboardWrite(payload []byte) (Command, error) {
	if len(payload) < 10 {
		return Command{}, fmt.Errorf("short clipboard_write")
	}
	payloadLen := int(u32(payload, 1))
	size := 5 + payloadLen
	if len(payload) < size || payloadLen < 5 {
		return Command{}, fmt.Errorf("short clipboard_write payload")
	}
	textLen := int(u32(payload, 6))
	if 5+textLen != payloadLen {
		return Command{}, fmt.Errorf("inconsistent clipboard_write text length")
	}
	text := string(payload[10 : 10+textLen])
	return Command{Kind: CommandClipboardWrite, Size: size, ClipboardText: text}, nil
}

func decodeExtensionRuntime(payload []byte) (Command, error) {
	if len(payload) < 5 {
		return Command{}, fmt.Errorf("short extension runtime")
	}
	payloadLen := int(u32(payload, 1))
	end := 5 + payloadLen
	if len(payload) < end {
		return Command{}, fmt.Errorf("short extension runtime payload")
	}
	offset := 5
	extensionID, next, ok := readString16(payload, offset)
	if !ok || next > end {
		return Command{}, fmt.Errorf("malformed extension runtime extension id")
	}
	offset = next
	channel, next, ok := readString16(payload, offset)
	if !ok || next > end {
		return Command{}, fmt.Errorf("malformed extension runtime channel")
	}
	offset = next
	raw := append([]byte(nil), payload[offset:end]...)
	return Command{Kind: CommandExtensionRuntime, Size: end, ExtensionRuntime: ExtensionRuntimePayload{ExtensionID: extensionID, Channel: channel, Payload: raw, Bytes: end}}, nil
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
