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
	Splits        SplitSeparators
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

type Completion struct {
	Visible  bool
	Row      uint16
	Col      uint16
	Selected uint16
	Items    []CompletionItem
}

type CompletionItem struct {
	Kind   byte
	Label  string
	Detail string
}

type WhichKey struct {
	Visible   bool
	Prefix    string
	Page      byte
	PageCount byte
	Bindings  []WhichKeyBinding
}

type WhichKeyBinding struct {
	Kind        byte
	Key         string
	Description string
	Icon        string
}

type Picker struct {
	Visible       bool
	Selected      uint16
	Filtered      uint16
	Total         uint16
	Marked        uint16
	HasPreview    bool
	Title         string
	Query         string
	ModePrefix    string
	LoadStatus    byte
	LoadError     string
	Actions       []string
	ActionIndex   byte
	ActionVisible bool
	Items         []PickerItem
}

type PickerItem struct {
	IconColor   uint32
	Flags       byte
	Label       string
	Description string
	Annotation  string
	TwoLine     bool
	Marked      bool
}

type PickerPreview struct {
	Visible bool
	Lines   []PreviewLine
}

type PreviewLine struct {
	Segments []PreviewSegment
}

type PreviewSegment struct {
	FG   uint32
	Bold bool
	Text string
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

type Theme struct {
	Colors map[byte]uint32
}

type Breadcrumb struct {
	Segments []string
}

type GitStatus struct {
	RepoState         byte
	Syncing           bool
	Ahead             uint16
	Behind            uint16
	Branch            string
	Entries           []GitStatusEntry
	Toast             GitToast
	EntryBasePath     string
	LastCommitMessage string
	StashCount        uint16
}

type GitStatusEntry struct {
	PathHash uint32
	Section  byte
	Status   byte
	Path     string
}

type GitToast struct {
	Visible bool
	Level   byte
	Action  byte
	Message string
}

type SearchState struct {
	Active       bool
	Count        uint16
	CurrentIndex uint16
	Flags        byte
}

type ChangeSummary struct {
	Visible       bool
	SelectedIndex uint16
	Entries       []ChangeEntry
}

type ChangeEntry struct {
	Path         string
	Action       byte
	LinesAdded   uint32
	LinesRemoved uint32
}

type HoverPopup struct {
	Visible      bool
	AnchorRow    uint16
	AnchorCol    uint16
	Focused      bool
	ScrollOffset uint16
	Lines        []RichLine
}

type HoverAction struct {
	Visible bool
	Name    string
}

type SignatureHelp struct {
	Visible         bool
	AnchorRow       uint16
	AnchorCol       uint16
	ActiveSignature byte
	ActiveParameter byte
	Signatures      []Signature
}

type Signature struct {
	Label      string
	Doc        string
	Parameters []SignatureParameter
}

type SignatureParameter struct {
	Label string
	Doc   string
}

type FloatPopup struct {
	Visible bool
	Width   uint16
	Height  uint16
	Title   string
	Lines   []string
}

type ExtensionOverlay struct {
	Entries []ExtensionOverlayEntry
}

type ExtensionOverlayEntry struct {
	Extension string
	ID        string
	WindowID  uint16
	Row       uint16
	Col       uint16
	Shape     byte
	FG        uint32
	Opacity   byte
	Content   string
}

type Notifications struct {
	Visible bool
	Items   []Notification
}

type Notification struct {
	ID            string
	Level         byte
	Dismissable   bool
	CreatedAt     uint64
	UpdatedAt     uint64
	AutoDismissMS uint32
	Title         string
	Body          string
	Source        string
	Actions       []NotificationAction
}

type NotificationAction struct {
	ID    string
	Label string
}

type BottomPanel struct {
	Visible       bool
	ActiveTab     byte
	HeightPercent byte
	Filter        byte
	Tabs          []PanelTab
	Messages      []PanelMessage
}

type PanelTab struct {
	Type byte
	Name string
}

type PanelMessage struct {
	ID        uint32
	Level     byte
	Subsystem byte
	Timestamp uint32
	Path      string
	Text      string
}

type ExtensionPanel struct {
	Panels []ExtensionPanelEntry
}

type ExtensionPanelEntry struct {
	Extension string
	ID        string
	Title     string
	Position  byte
	SizeType  byte
	SizeValue byte
	Visible   bool
	Blocks    []string
}

type Sidebars struct {
	Visible  bool
	ActiveID string
	Items    []Sidebar
}

type Sidebar struct {
	ID             string
	DisplayName    string
	SemanticKind   string
	Icon           string
	Order          uint16
	Flags          byte
	PreferredWidth uint16
	BadgeCount     uint16
	Visible        bool
	Focused        bool
}

type Observatory struct {
	Visible bool
	Count   uint16
	Nodes   []ObservatoryNode
}

type ObservatoryNode struct {
	PID             string
	ParentPID       string
	Name            string
	ProcessClass    byte
	Depth           byte
	Memory          uint32
	MessageQueueLen uint16
	Reductions      uint32
}

type AgentContext struct {
	Visible    bool
	Task       string
	Timestamp  uint64
	Status     byte
	CanApprove bool
}

type AgentChat struct {
	Visible       bool
	Status        byte
	ModelName     string
	Prompt        string
	ThinkingLevel string
	Messages      []AgentChatMessage
	Pending       string
	Completion    []string
}

type AgentChatMessage struct {
	ID   uint32
	Kind byte
	Text string
}

type Board struct {
	Visible       bool
	FocusedCardID uint32
	FilterMode    bool
	FilterText    string
	Cards         []BoardCard
}

type BoardCard struct {
	ID          uint32
	Status      byte
	Flags       byte
	Task        string
	Model       string
	Timestamp   uint32
	RecentFiles []string
}

type EditTimeline struct {
	Visible      bool
	ViewingIndex uint16
	Entries      []TimelineEntry
}

type TimelineEntry struct {
	Index          byte
	ToolName       string
	TimestampDelta uint32
}

type GutterSeparator struct {
	Col   uint16
	Color uint32
}

type SplitSeparators struct {
	Color       uint32
	Verticals   []VerticalSeparator
	Horizontals []HorizontalSeparator
}

type VerticalSeparator struct {
	Col      uint16
	StartRow uint16
	EndRow   uint16
}

type HorizontalSeparator struct {
	Row      uint16
	Col      uint16
	Width    uint16
	Filename string
}

type RichLine struct {
	Segments []RichSegment
}

type RichSegment struct {
	Style byte
	FG    uint32
	Flags byte
	Text  string
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
		}
	}

	kind := CommandWindowContent
	if opcode != generated.OPGuiWindowContent {
		kind = CommandWindowDelta
	}
	return Command{Kind: kind, Size: offset, Window: window}, nil
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
	case generated.OPGuiCompletion:
		chrome.Complete, chrome.Summary, chrome.Bytes = decodeCompletion(payload)
	case generated.OPGuiWhichKey:
		chrome.Which, chrome.Summary, chrome.Bytes = decodeWhichKey(payload)
	case generated.OPGuiPicker:
		chrome.Picker, chrome.Summary, chrome.Bytes = decodePicker(payload)
	case generated.OPGuiPickerPreview:
		chrome.Preview, chrome.Summary, chrome.Bytes = decodePickerPreview(payload)
	case generated.OPGuiFileTree:
		chrome.Tree, chrome.Summary, chrome.Bytes = decodeFileTree(payload)
	case generated.OPGuiStatusBar:
		chrome.Status, chrome.Summary, chrome.Bytes = decodeStatus(payload)
	case generated.OPGuiTheme:
		chrome.Theme, chrome.Summary, chrome.Bytes = decodeTheme(payload)
	case generated.OPGuiBreadcrumb:
		chrome.Breadcrumb, chrome.Summary, chrome.Bytes = decodeBreadcrumb(payload)
	case generated.OPGuiGitStatus:
		chrome.Git, chrome.Summary, chrome.Bytes = decodeGitStatus(payload)
	case generated.OPGuiSearchState:
		chrome.Search, chrome.Summary, chrome.Bytes = decodeSearchState(payload)
	case generated.OPGuiChangeSummary:
		chrome.Change, chrome.Summary, chrome.Bytes = decodeChangeSummary(payload)
	case generated.OPGuiHoverPopup:
		chrome.Hover, chrome.Summary, chrome.Bytes = decodeHoverPopup(payload)
	case generated.OPGuiHoverAction:
		chrome.HoverAction, chrome.Summary, chrome.Bytes = decodeHoverAction(payload)
	case generated.OPGuiSignatureHelp:
		chrome.Signature, chrome.Summary, chrome.Bytes = decodeSignatureHelp(payload)
	case generated.OPGuiFloatPopup:
		chrome.Float, chrome.Summary, chrome.Bytes = decodeFloatPopup(payload)
	case generated.OPGuiExtensionOverlay:
		chrome.Overlay, chrome.Summary, chrome.Bytes = decodeExtensionOverlay(payload)
	case generated.OPGuiNotifications:
		chrome.Notifications, chrome.Summary, chrome.Bytes = decodeNotifications(payload)
	case generated.OPGuiBottomPanel:
		chrome.Bottom, chrome.Summary, chrome.Bytes = decodeBottomPanel(payload)
	case generated.OPGuiExtensionPanel:
		chrome.Extensions, chrome.Summary, chrome.Bytes = decodeExtensionPanel(payload)
	case generated.OPGuiSidebars:
		chrome.Sidebars, chrome.Summary, chrome.Bytes = decodeSidebars(payload)
	case generated.OPGuiObservatory:
		chrome.Observatory, chrome.Summary, chrome.Bytes = decodeObservatory(payload)
	case generated.OPGuiAgentContext:
		chrome.AgentContext, chrome.Summary, chrome.Bytes = decodeAgentContext(payload)
	case generated.OPGuiAgentChat:
		chrome.AgentChat, chrome.Summary, chrome.Bytes = decodeAgentChat(payload)
	case generated.OPGuiBoard:
		chrome.Board, chrome.Summary, chrome.Bytes = decodeBoard(payload)
	case generated.OPGuiEditTimeline:
		chrome.Timeline, chrome.Summary, chrome.Bytes = decodeEditTimeline(payload)
	case generated.OPGuiGutterSep:
		chrome.Gutter, chrome.Summary, chrome.Bytes = decodeGutterSeparator(payload)
	case generated.OPGuiSplitSeparators:
		chrome.Splits, chrome.Summary, chrome.Bytes = decodeSplitSeparators(payload)
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

func decodeCompletion(payload []byte) (Completion, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return Completion{}, "", min(len(payload), 2)
	}
	if len(payload) < 10 {
		return Completion{Visible: true}, "", len(payload)
	}
	completion := Completion{
		Visible:  true,
		Row:      u16(payload, 2),
		Col:      u16(payload, 4),
		Selected: u16(payload, 6),
	}
	count := int(u16(payload, 8))
	completion.Items = make([]CompletionItem, 0, count)
	offset := 10
	labels := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+5; i++ {
		item := CompletionItem{Kind: payload[offset]}
		offset++
		var ok bool
		item.Label, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		item.Detail, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		completion.Items = append(completion.Items, item)
		labels = append(labels, item.Label)
	}
	return completion, stringsJoin(labels, "  "), offset
}

func decodeWhichKey(payload []byte) (WhichKey, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return WhichKey{}, "", min(len(payload), 2)
	}
	if len(payload) < 8 {
		return WhichKey{Visible: true}, "", len(payload)
	}
	prefix, offset, ok := readString16(payload, 2)
	if !ok || len(payload) < offset+4 {
		return WhichKey{Visible: true}, "", len(payload)
	}
	which := WhichKey{
		Visible:   true,
		Prefix:    prefix,
		Page:      payload[offset],
		PageCount: payload[offset+1],
	}
	count := int(u16(payload, offset+2))
	offset += 4
	which.Bindings = make([]WhichKeyBinding, 0, count)
	summary := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+6; i++ {
		binding := WhichKeyBinding{Kind: payload[offset]}
		offset++
		var ok bool
		binding.Key, offset, ok = readString8(payload, offset)
		if !ok {
			break
		}
		binding.Description, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		binding.Icon, offset, ok = readString8(payload, offset)
		if !ok {
			break
		}
		which.Bindings = append(which.Bindings, binding)
		summary = append(summary, binding.Key+" "+binding.Description)
	}
	return which, stringsJoin(summary, "  "), offset
}

func decodePicker(payload []byte) (Picker, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return Picker{}, "", min(len(payload), 2)
	}
	size := sectionedSize(payload)
	if size == 0 {
		return Picker{Visible: true}, "", len(payload)
	}
	picker := Picker{}
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		section := payload[offset : offset+sectionLen]
		offset += sectionLen
		switch sectionID {
		case 0x01:
			decodePickerHeader(section, &picker)
		case 0x02:
			if query, _, ok := readString16(section, 0); ok {
				picker.Query = query
			}
		case 0x03:
			picker.Items = decodePickerItems(section)
		case 0x04:
			decodePickerActions(section, &picker)
		case 0x05:
			if modePrefix, _, ok := readString16(section, 0); ok {
				picker.ModePrefix = modePrefix
			}
		case 0x06:
			decodePickerLoadStatus(section, &picker)
		}
	}
	summary := picker.Title
	if picker.Query != "" {
		summary = strings.TrimSpace(summary + " " + picker.Query)
	}
	return picker, summary, size
}

func decodePickerHeader(section []byte, picker *Picker) {
	if len(section) < 10 {
		return
	}
	picker.Visible = section[0] != 0
	picker.Selected = u16(section, 1)
	picker.Filtered = u16(section, 3)
	picker.Total = u16(section, 5)
	picker.HasPreview = section[7] != 0
	title, offset, ok := readString16(section, 8)
	if !ok {
		return
	}
	picker.Title = title
	if len(section) >= offset+2 {
		picker.Marked = u16(section, offset)
	}
}

func decodePickerItems(section []byte) []PickerItem {
	if len(section) < 2 {
		return nil
	}
	count := int(u16(section, 0))
	offset := 2
	items := make([]PickerItem, 0, count)
	for i := 0; i < count && len(section) >= offset+8; i++ {
		item := PickerItem{
			IconColor: u24(section, offset),
			Flags:     section[offset+3],
		}
		item.TwoLine = item.Flags&0x01 != 0
		item.Marked = item.Flags&0x02 != 0
		offset += 4
		var ok bool
		item.Label, offset, ok = readString16(section, offset)
		if !ok {
			break
		}
		item.Description, offset, ok = readString16(section, offset)
		if !ok {
			break
		}
		item.Annotation, offset, ok = readString16(section, offset)
		if !ok || len(section) < offset+1 {
			break
		}
		matchCount := int(section[offset])
		offset += 1 + matchCount*2
		if len(section) < offset {
			break
		}
		items = append(items, item)
	}
	return items
}

func decodePickerActions(section []byte, picker *Picker) {
	if len(section) < 1 {
		return
	}
	picker.ActionVisible = section[0] != 0
	if !picker.ActionVisible || len(section) < 3 {
		return
	}
	picker.ActionIndex = section[1]
	count := int(section[2])
	offset := 3
	picker.Actions = make([]string, 0, count)
	for i := 0; i < count; i++ {
		action, next, ok := readString16(section, offset)
		if !ok {
			break
		}
		picker.Actions = append(picker.Actions, action)
		offset = next
	}
}

func decodePickerLoadStatus(section []byte, picker *Picker) {
	if len(section) < 1 {
		return
	}
	picker.LoadStatus = section[0]
	if picker.LoadStatus == 2 {
		if err, _, ok := readString16(section, 1); ok {
			picker.LoadError = err
		}
	}
}

func decodePickerPreview(payload []byte) (PickerPreview, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return PickerPreview{}, "", min(len(payload), 2)
	}
	if len(payload) < 4 {
		return PickerPreview{Visible: true}, "", len(payload)
	}
	count := int(u16(payload, 2))
	offset := 4
	preview := PickerPreview{Visible: true, Lines: make([]PreviewLine, 0, count)}
	summary := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+1; i++ {
		segmentCount := int(payload[offset])
		offset++
		line := PreviewLine{Segments: make([]PreviewSegment, 0, segmentCount)}
		var text strings.Builder
		for j := 0; j < segmentCount && len(payload) >= offset+6; j++ {
			segment := PreviewSegment{
				FG:   u24(payload, offset),
				Bold: payload[offset+3]&0x01 != 0,
			}
			offset += 4
			value, next, ok := readString16(payload, offset)
			if !ok {
				return preview, stringsJoin(summary, "  "), len(payload)
			}
			segment.Text = value
			offset = next
			line.Segments = append(line.Segments, segment)
			text.WriteString(value)
		}
		preview.Lines = append(preview.Lines, line)
		summary = append(summary, text.String())
	}
	return preview, stringsJoin(summary, "  "), offset
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

func decodeTheme(payload []byte) (Theme, string, int) {
	if len(payload) < 2 {
		return Theme{}, "", len(payload)
	}
	count := int(payload[1])
	offset := 2
	theme := Theme{Colors: map[byte]uint32{}}
	for i := 0; i < count && len(payload) >= offset+4; i++ {
		theme.Colors[payload[offset]] = u24(payload, offset+1)
		offset += 4
	}
	return theme, fmt.Sprintf("%d colors", len(theme.Colors)), offset
}

func decodeBreadcrumb(payload []byte) (Breadcrumb, string, int) {
	if len(payload) < 2 {
		return Breadcrumb{}, "", len(payload)
	}
	count := int(payload[1])
	offset := 2
	crumb := Breadcrumb{Segments: make([]string, 0, count)}
	for i := 0; i < count; i++ {
		segment, next, ok := readString16(payload, offset)
		if !ok {
			break
		}
		crumb.Segments = append(crumb.Segments, segment)
		offset = next
	}
	return crumb, stringsJoin(crumb.Segments, " / "), offset
}

func decodeGitStatus(payload []byte) (GitStatus, string, int) {
	if len(payload) < 13 {
		return GitStatus{}, "", len(payload)
	}
	git := GitStatus{
		RepoState: payload[1],
		Syncing:   payload[2] != 0,
		Ahead:     u16(payload, 3),
		Behind:    u16(payload, 5),
	}
	offset := 7
	branch, next, ok := readString16(payload, offset)
	if !ok || len(payload) < next+2 {
		return git, "", len(payload)
	}
	git.Branch = branch
	count := int(u16(payload, next))
	offset = next + 2
	git.Entries = make([]GitStatusEntry, 0, count)
	for i := 0; i < count && len(payload) >= offset+9; i++ {
		entry := GitStatusEntry{PathHash: u32(payload, offset), Section: payload[offset+4], Status: payload[offset+5]}
		offset += 6
		entry.Path, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		git.Entries = append(git.Entries, entry)
	}
	if len(payload) < offset+1 {
		return git, gitSummary(git), offset
	}
	if payload[offset] != 0 && len(payload) >= offset+5 {
		git.Toast.Visible = true
		git.Toast.Level = payload[offset+1]
		git.Toast.Action = payload[offset+2]
		git.Toast.Message, offset, ok = readString16(payload, offset+3)
		if !ok {
			return git, gitSummary(git), len(payload)
		}
	} else {
		offset++
	}
	if git.EntryBasePath, offset, ok = readString16(payload, offset); !ok {
		return git, gitSummary(git), len(payload)
	}
	if git.LastCommitMessage, offset, ok = readString16(payload, offset); !ok || len(payload) < offset+2 {
		return git, gitSummary(git), len(payload)
	}
	git.StashCount = u16(payload, offset)
	offset += 2
	return git, gitSummary(git), offset
}

func gitSummary(git GitStatus) string {
	parts := []string{git.Branch}
	if git.Ahead > 0 {
		parts = append(parts, fmt.Sprintf("ahead %d", git.Ahead))
	}
	if git.Behind > 0 {
		parts = append(parts, fmt.Sprintf("behind %d", git.Behind))
	}
	if len(git.Entries) > 0 {
		parts = append(parts, fmt.Sprintf("%d changes", len(git.Entries)))
	}
	if git.StashCount > 0 {
		parts = append(parts, fmt.Sprintf("%d stashes", git.StashCount))
	}
	return stringsJoin(parts, "  ")
}

func decodeSearchState(payload []byte) (SearchState, string, int) {
	if len(payload) < 4 {
		return SearchState{}, "", len(payload)
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size || size < 9 {
		return SearchState{}, "", len(payload)
	}
	search := SearchState{Active: payload[3] != 0, Count: u16(payload, 4), CurrentIndex: u16(payload, 6), Flags: payload[8]}
	summary := ""
	if search.Active {
		summary = fmt.Sprintf("%d/%d", search.CurrentIndex, search.Count)
	}
	return search, summary, size
}

func decodeChangeSummary(payload []byte) (ChangeSummary, string, int) {
	if len(payload) < 6 {
		return ChangeSummary{}, "", len(payload)
	}
	change := ChangeSummary{Visible: payload[1] != 0, SelectedIndex: u16(payload, 2)}
	count := int(u16(payload, 4))
	offset := 6
	change.Entries = make([]ChangeEntry, 0, count)
	for i := 0; i < count && len(payload) >= offset+11; i++ {
		entry := ChangeEntry{}
		var ok bool
		entry.Path, offset, ok = readString16(payload, offset)
		if !ok || len(payload) < offset+9 {
			break
		}
		entry.Action = payload[offset]
		entry.LinesAdded = u32(payload, offset+1)
		entry.LinesRemoved = u32(payload, offset+5)
		offset += 9
		change.Entries = append(change.Entries, entry)
	}
	return change, fmt.Sprintf("%d changes", len(change.Entries)), offset
}

func decodeHoverPopup(payload []byte) (HoverPopup, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return HoverPopup{}, "", min(len(payload), 2)
	}
	if len(payload) < 11 {
		return HoverPopup{Visible: true}, "", len(payload)
	}
	hover := HoverPopup{
		Visible:      true,
		AnchorRow:    u16(payload, 2),
		AnchorCol:    u16(payload, 4),
		Focused:      payload[6] != 0,
		ScrollOffset: u16(payload, 7),
	}
	count := int(u16(payload, 9))
	offset := 11
	hover.Lines = make([]RichLine, 0, count)
	summary := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+3; i++ {
		offset++
		segmentCount := int(u16(payload, offset))
		offset += 2
		line, next, ok := decodeRichLine(payload, offset, segmentCount)
		if !ok {
			break
		}
		hover.Lines = append(hover.Lines, line)
		summary = append(summary, richLineText(line))
		offset = next
	}
	return hover, stringsJoin(summary, "  "), offset
}

func decodeHoverAction(payload []byte) (HoverAction, string, int) {
	if len(payload) < 4 {
		return HoverAction{}, "", len(payload)
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size || payload[3] == 0 {
		return HoverAction{}, "", min(len(payload), size)
	}
	name, _, ok := readString16(payload, 4)
	if !ok {
		return HoverAction{Visible: true}, "", size
	}
	return HoverAction{Visible: true, Name: name}, name, size
}

func decodeSignatureHelp(payload []byte) (SignatureHelp, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return SignatureHelp{}, "", min(len(payload), 2)
	}
	if len(payload) < 10 {
		return SignatureHelp{Visible: true}, "", len(payload)
	}
	help := SignatureHelp{
		Visible:         true,
		AnchorRow:       u16(payload, 2),
		AnchorCol:       u16(payload, 4),
		ActiveSignature: payload[6],
		ActiveParameter: payload[7],
	}
	count := int(payload[8])
	offset := 9
	help.Signatures = make([]Signature, 0, count)
	for i := 0; i < count; i++ {
		sig, next, ok := decodeSignature(payload, offset)
		if !ok {
			break
		}
		help.Signatures = append(help.Signatures, sig)
		offset = next
	}
	summary := ""
	if len(help.Signatures) > 0 {
		summary = help.Signatures[min(int(help.ActiveSignature), len(help.Signatures)-1)].Label
	}
	return help, summary, offset
}

func decodeSignature(payload []byte, offset int) (Signature, int, bool) {
	var ok bool
	sig := Signature{}
	sig.Label, offset, ok = readString16(payload, offset)
	if !ok {
		return sig, offset, false
	}
	sig.Doc, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+1 {
		return sig, offset, false
	}
	count := int(payload[offset])
	offset++
	sig.Parameters = make([]SignatureParameter, 0, count)
	for i := 0; i < count; i++ {
		param := SignatureParameter{}
		param.Label, offset, ok = readString16(payload, offset)
		if !ok {
			return sig, offset, false
		}
		param.Doc, offset, ok = readString16(payload, offset)
		if !ok {
			return sig, offset, false
		}
		sig.Parameters = append(sig.Parameters, param)
	}
	return sig, offset, true
}

func decodeFloatPopup(payload []byte) (FloatPopup, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return FloatPopup{}, "", min(len(payload), 2)
	}
	if len(payload) < 8 {
		return FloatPopup{Visible: true}, "", len(payload)
	}
	float := FloatPopup{Visible: true, Width: u16(payload, 2), Height: u16(payload, 4)}
	offset := 6
	var ok bool
	float.Title, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+2 {
		return float, float.Title, len(payload)
	}
	count := int(u16(payload, offset))
	offset += 2
	float.Lines = make([]string, 0, count)
	for i := 0; i < count; i++ {
		line, next, ok := readString16(payload, offset)
		if !ok {
			break
		}
		float.Lines = append(float.Lines, line)
		offset = next
	}
	return float, strings.TrimSpace(float.Title + " " + stringsJoin(float.Lines, " ")), offset
}

func decodeExtensionOverlay(payload []byte) (ExtensionOverlay, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return ExtensionOverlay{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 1 {
		return ExtensionOverlay{}, "", size
	}
	count := int(body[0])
	offset := 1
	overlay := ExtensionOverlay{Entries: make([]ExtensionOverlayEntry, 0, count)}
	for i := 0; i < count && len(body) >= offset+16; i++ {
		entry := ExtensionOverlayEntry{}
		var ok bool
		entry.Extension, offset, ok = readString8(body, offset)
		if !ok {
			break
		}
		entry.ID, offset, ok = readString8(body, offset)
		if !ok || len(body) < offset+12 {
			break
		}
		entry.WindowID = u16(body, offset)
		entry.Row = u16(body, offset+2)
		entry.Col = u16(body, offset+4)
		entry.Shape = body[offset+6]
		entry.FG = u24(body, offset+7)
		entry.Opacity = body[offset+10]
		offset += 11
		entry.Content, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		overlay.Entries = append(overlay.Entries, entry)
	}
	return overlay, fmt.Sprintf("%d overlays", len(overlay.Entries)), size
}

func decodeNotifications(payload []byte) (Notifications, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return Notifications{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 3 {
		return Notifications{}, "", size
	}
	notes := Notifications{Visible: body[0] != 0}
	count := int(u16(body, 1))
	offset := 3
	notes.Items = make([]Notification, 0, count)
	for i := 0; i < count; i++ {
		note, next, ok := decodeNotification(body, offset)
		if !ok {
			break
		}
		notes.Items = append(notes.Items, note)
		offset = next
	}
	return notes, fmt.Sprintf("%d notifications", len(notes.Items)), size
}

func decodeNotification(payload []byte, offset int) (Notification, int, bool) {
	note := Notification{}
	var ok bool
	note.ID, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+22 {
		return note, offset, false
	}
	note.Level = payload[offset]
	note.Dismissable = payload[offset+1]&0x01 != 0
	note.CreatedAt = binary.BigEndian.Uint64(payload[offset+2 : offset+10])
	note.UpdatedAt = binary.BigEndian.Uint64(payload[offset+10 : offset+18])
	note.AutoDismissMS = u32(payload, offset+18)
	offset += 22
	note.Title, offset, ok = readString16(payload, offset)
	if !ok {
		return note, offset, false
	}
	note.Body, offset, ok = readString16(payload, offset)
	if !ok {
		return note, offset, false
	}
	note.Source, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+1 {
		return note, offset, false
	}
	count := int(payload[offset])
	offset++
	note.Actions = make([]NotificationAction, 0, count)
	for i := 0; i < count; i++ {
		action := NotificationAction{}
		action.ID, offset, ok = readString16(payload, offset)
		if !ok {
			return note, offset, false
		}
		action.Label, offset, ok = readString16(payload, offset)
		if !ok {
			return note, offset, false
		}
		note.Actions = append(note.Actions, action)
	}
	return note, offset, true
}

func decodeBottomPanel(payload []byte) (BottomPanel, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return BottomPanel{}, "", min(len(payload), 2)
	}
	if len(payload) < 7 {
		return BottomPanel{Visible: true}, "", len(payload)
	}
	panel := BottomPanel{Visible: true, ActiveTab: payload[2], HeightPercent: payload[3], Filter: payload[4]}
	count := int(payload[5])
	offset := 6
	panel.Tabs = make([]PanelTab, 0, count)
	for i := 0; i < count && len(payload) >= offset+2; i++ {
		tab := PanelTab{Type: payload[offset]}
		offset++
		var ok bool
		tab.Name, offset, ok = readString8(payload, offset)
		if !ok {
			break
		}
		panel.Tabs = append(panel.Tabs, tab)
	}
	if len(payload) < offset+2 {
		return panel, bottomPanelSummary(panel), offset
	}
	msgCount := int(u16(payload, offset))
	offset += 2
	panel.Messages = make([]PanelMessage, 0, msgCount)
	for i := 0; i < msgCount && len(payload) >= offset+14; i++ {
		msg := PanelMessage{ID: u32(payload, offset), Level: payload[offset+4], Subsystem: payload[offset+5], Timestamp: u32(payload, offset+6)}
		offset += 10
		var ok bool
		msg.Path, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		msg.Text, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		panel.Messages = append(panel.Messages, msg)
	}
	return panel, bottomPanelSummary(panel), offset
}

func bottomPanelSummary(panel BottomPanel) string {
	tab := ""
	if len(panel.Tabs) > int(panel.ActiveTab) {
		tab = panel.Tabs[panel.ActiveTab].Name
	}
	return strings.TrimSpace(fmt.Sprintf("%s %d messages", tab, len(panel.Messages)))
}

func decodeExtensionPanel(payload []byte) (ExtensionPanel, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return ExtensionPanel{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 1 {
		return ExtensionPanel{}, "", size
	}
	count := int(body[0])
	offset := 1
	panel := ExtensionPanel{Panels: make([]ExtensionPanelEntry, 0, count)}
	for i := 0; i < count; i++ {
		entry, next, ok := decodeExtensionPanelEntry(body, offset)
		if !ok {
			break
		}
		panel.Panels = append(panel.Panels, entry)
		offset = next
	}
	return panel, fmt.Sprintf("%d extension panels", len(panel.Panels)), size
}

func decodeExtensionPanelEntry(body []byte, offset int) (ExtensionPanelEntry, int, bool) {
	entry := ExtensionPanelEntry{}
	var ok bool
	entry.Extension, offset, ok = readString8(body, offset)
	if !ok {
		return entry, offset, false
	}
	entry.ID, offset, ok = readString8(body, offset)
	if !ok {
		return entry, offset, false
	}
	entry.Title, offset, ok = readString8(body, offset)
	if !ok || len(body) < offset+5 {
		return entry, offset, false
	}
	entry.Position = body[offset]
	entry.SizeType = body[offset+1]
	entry.SizeValue = body[offset+2]
	entry.Visible = body[offset+3] != 0
	count := int(body[offset+4])
	offset += 5
	entry.Blocks = make([]string, 0, count)
	for i := 0; i < count && offset < len(body); i++ {
		text, next, ok := decodePanelBlock(body, offset)
		if !ok {
			break
		}
		if text != "" {
			entry.Blocks = append(entry.Blocks, text)
		}
		offset = next
	}
	return entry, offset, true
}

func decodePanelBlock(body []byte, offset int) (string, int, bool) {
	if len(body) < offset+1 {
		return "", offset, false
	}
	kind := body[offset]
	offset++
	switch kind {
	case 0:
		return readString16(body, offset)
	case 1:
		if len(body) < offset+1 {
			return "", offset, false
		}
		count := int(body[offset])
		offset++
		parts := make([]string, 0, count)
		for i := 0; i < count; i++ {
			text, next, ok := readString16(body, offset)
			if !ok || len(body) < next+5 {
				return stringsJoin(parts, ""), offset, false
			}
			parts = append(parts, text)
			offset = next + 5
		}
		return stringsJoin(parts, ""), offset, true
	case 2:
		if len(body) < offset+5 {
			return "table", offset, false
		}
		cols := int(body[offset])
		rows := int(u16(body, offset+1))
		offset += 5
		headers := make([]string, 0, cols)
		var ok bool
		for i := 0; i < cols; i++ {
			var header string
			header, offset, ok = readString16(body, offset)
			if !ok {
				return "table", offset, false
			}
			headers = append(headers, header)
		}
		for i := 0; i < rows*cols; i++ {
			_, offset, ok = readString16(body, offset)
			if !ok {
				return stringsJoin(headers, "  "), offset, false
			}
		}
		return stringsJoin(headers, "  "), offset, true
	case 3:
		if len(body) < offset+1 {
			return "", offset, false
		}
		count := int(body[offset])
		offset++
		pairs := make([]string, 0, count)
		for i := 0; i < count; i++ {
			key, next, ok := readString16(body, offset)
			if !ok {
				return stringsJoin(pairs, "  "), offset, false
			}
			value, next, ok := readString16(body, next)
			if !ok {
				return stringsJoin(pairs, "  "), offset, false
			}
			pairs = append(pairs, key+": "+value)
			offset = next
		}
		return stringsJoin(pairs, "  "), offset, true
	case 4:
		return "-----", offset, true
	case 5:
		label, next, ok := readString16(body, offset)
		if !ok || len(body) < next+2 {
			return label, next, ok
		}
		return fmt.Sprintf("%s %d%%", label, u16(body, next)), next + 2, true
	case 6:
		if len(body) < offset+2 {
			return "tree", offset, false
		}
		size := int(u16(body, offset))
		offset += 2
		if len(body) < offset+size {
			return "tree", offset, false
		}
		return "tree", offset + size, true
	case 255:
		return "", offset, true
	default:
		return "", offset, true
	}
}

func decodeSidebars(payload []byte) (Sidebars, string, int) {
	size := payloadLen32Size(payload)
	if size == 0 {
		return Sidebars{}, "", len(payload)
	}
	body := payload[5:size]
	if len(body) < 3 {
		return Sidebars{}, "", size
	}
	sidebars := Sidebars{Visible: body[0] != 0}
	count := int(u16(body, 1))
	offset := 3
	var ok bool
	sidebars.ActiveID, offset, ok = readString16(body, offset)
	if !ok {
		return sidebars, "", size
	}
	sidebars.Items = make([]Sidebar, 0, count)
	for i := 0; i < count; i++ {
		sidebar := Sidebar{}
		sidebar.ID, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		sidebar.DisplayName, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		sidebar.SemanticKind, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		sidebar.Icon, offset, ok = readString16(body, offset)
		if !ok || len(body) < offset+7 {
			break
		}
		sidebar.Order = u16(body, offset)
		sidebar.Flags = body[offset+2]
		sidebar.PreferredWidth = u16(body, offset+3)
		sidebar.BadgeCount = u16(body, offset+5)
		sidebar.Visible = sidebar.Flags&0x01 != 0
		sidebar.Focused = sidebar.Flags&0x02 != 0
		offset += 7
		sidebars.Items = append(sidebars.Items, sidebar)
	}
	return sidebars, fmt.Sprintf("%d sidebars", len(sidebars.Items)), size
}

func decodeObservatory(payload []byte) (Observatory, string, int) {
	size := payloadLen32Size(payload)
	if size == 0 {
		return Observatory{}, "", len(payload)
	}
	body := payload[5:size]
	obs := Observatory{}
	offset := 0
	for offset+3 <= len(body) {
		sectionID := body[offset]
		sectionLen := int(u16(body, offset+1))
		offset += 3
		if len(body) < offset+sectionLen {
			return obs, observatorySummary(obs), size
		}
		section := body[offset : offset+sectionLen]
		offset += sectionLen
		switch sectionID {
		case 0x01:
			if len(section) >= 3 {
				obs.Visible = section[0] != 0
				obs.Count = u16(section, 1)
			}
		case 0x02:
			obs.Nodes = append(obs.Nodes, decodeObservatoryNodes(section)...)
		}
	}
	return obs, observatorySummary(obs), size
}

func decodeObservatoryNodes(section []byte) []ObservatoryNode {
	nodes := []ObservatoryNode{}
	offset := 0
	for offset < len(section) {
		node := ObservatoryNode{}
		var ok bool
		node.PID, offset, ok = readString8(section, offset)
		if !ok {
			break
		}
		node.ParentPID, offset, ok = readString8(section, offset)
		if !ok {
			break
		}
		node.Name, offset, ok = readString16(section, offset)
		if !ok || len(section) < offset+12 {
			break
		}
		node.ProcessClass = section[offset]
		node.Depth = section[offset+1]
		node.Memory = u32(section, offset+2)
		node.MessageQueueLen = u16(section, offset+6)
		node.Reductions = u32(section, offset+8)
		offset += 12
		nodes = append(nodes, node)
	}
	return nodes
}

func observatorySummary(obs Observatory) string {
	count := int(obs.Count)
	if count == 0 {
		count = len(obs.Nodes)
	}
	return fmt.Sprintf("%d processes", count)
}

func decodeAgentContext(payload []byte) (AgentContext, string, int) {
	if len(payload) < 12 {
		return AgentContext{}, "", len(payload)
	}
	ctx := AgentContext{Visible: payload[1] != 0}
	task, offset, ok := readString16(payload, 2)
	if !ok || len(payload) < offset+10 {
		return ctx, "", len(payload)
	}
	ctx.Task = task
	ctx.Timestamp = binary.BigEndian.Uint64(payload[offset : offset+8])
	ctx.Status = payload[offset+8]
	ctx.CanApprove = payload[offset+9] != 0
	offset += 10
	return ctx, task, offset
}

func decodeAgentChat(payload []byte) (AgentChat, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return AgentChat{}, "", min(len(payload), 2)
	}
	size := sectionedSize(payload)
	if size == 0 {
		return AgentChat{Visible: true}, "", len(payload)
	}
	chat := AgentChat{}
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		section := payload[offset : offset+sectionLen]
		offset += sectionLen
		switch sectionID {
		case 0x01:
			if len(section) >= 2 {
				chat.Visible = section[0] != 0
				chat.Status = section[1]
			}
		case 0x02:
			if value, _, ok := readString16(section, 0); ok {
				chat.ModelName = value
			}
		case 0x03:
			if value, _, ok := readString16(section, 0); ok {
				chat.Prompt = value
			}
		case 0x04:
			chat.Pending = decodeAgentPending(section)
		case 0x07:
			chat.Completion = decodeAgentCompletion(section)
		case 0x08:
			if value, _, ok := readString16(section, 0); ok {
				chat.ThinkingLevel = value
			}
		case 0x06:
			chat.Messages = decodeAgentMessages(section)
		}
	}
	return chat, fmt.Sprintf("%s %d messages", chat.ModelName, len(chat.Messages)), size
}

func decodeAgentPending(section []byte) string {
	if len(section) < 1 || section[0] == 0 {
		return ""
	}
	name, offset, ok := readString16(section, 1)
	if !ok {
		return ""
	}
	summary, _, ok := readString16(section, offset)
	if !ok {
		return name
	}
	return strings.TrimSpace(name + " " + summary)
}

func decodeAgentCompletion(section []byte) []string {
	if len(section) < 8 || section[0] == 0 {
		return nil
	}
	count := int(section[7])
	offset := 8
	items := make([]string, 0, count)
	for i := 0; i < count; i++ {
		name, next, ok := readString16(section, offset)
		if !ok {
			break
		}
		desc, next, ok := readString16(section, next)
		if !ok {
			break
		}
		items = append(items, strings.TrimSpace(name+" "+desc))
		offset = next
	}
	return items
}

func decodeAgentMessages(section []byte) []AgentChatMessage {
	if len(section) < 4 || section[0] != 0xFF {
		return nil
	}
	count := int(u16(section, 2))
	offset := 4
	messages := make([]AgentChatMessage, 0, count)
	for i := 0; i < count && len(section) >= offset+4; i++ {
		size := int(u32(section, offset))
		offset += 4
		if len(section) < offset+size {
			break
		}
		if msg, ok := decodeAgentMessage(section[offset : offset+size]); ok {
			messages = append(messages, msg)
		}
		offset += size
	}
	return messages
}

func decodeAgentMessage(body []byte) (AgentChatMessage, bool) {
	if len(body) < 5 {
		return AgentChatMessage{}, false
	}
	msg := AgentChatMessage{ID: u32(body, 0), Kind: body[4]}
	offset := 5
	switch msg.Kind {
	case 0x01, 0x02:
		if len(body) < offset+4 {
			return msg, true
		}
		size := int(u32(body, offset))
		offset += 4
		if len(body) >= offset+size {
			msg.Text = string(body[offset : offset+size])
		}
	case 0x03:
		if len(body) < offset+5 {
			return msg, true
		}
		size := int(u32(body, offset+1))
		offset += 5
		if len(body) >= offset+size {
			msg.Text = string(body[offset : offset+size])
		}
	case 0x04:
		if len(body) < offset+7 {
			return msg, true
		}
		offset += 7
		name, next, ok := readString16(body, offset)
		if !ok {
			return msg, true
		}
		summary, _, ok := readString16(body, next)
		if ok {
			msg.Text = strings.TrimSpace(name + " " + summary)
		} else {
			msg.Text = name
		}
	case 0x05:
		if len(body) < offset+5 {
			return msg, true
		}
		size := int(u32(body, offset+1))
		offset += 5
		if len(body) >= offset+size {
			msg.Text = string(body[offset : offset+size])
		}
	case 0x06:
		if len(body) >= offset+20 {
			msg.Text = fmt.Sprintf("usage in:%d out:%d", u32(body, offset), u32(body, offset+4))
		}
	case 0x07:
		msg.Text = decodeStyledLines(body[offset:])
	case 0x08:
		if len(body) < offset+7 {
			return msg, true
		}
		offset += 7
		name, next, ok := readString16(body, offset)
		if !ok {
			return msg, true
		}
		summary, _, ok := readString16(body, next)
		if ok {
			msg.Text = strings.TrimSpace(name + " " + summary)
		} else {
			msg.Text = name
		}
	case 0x09:
		if len(body) < offset+1 {
			return msg, true
		}
		name, next, ok := readString16(body, offset+1)
		if !ok {
			return msg, true
		}
		summary, _, ok := readString16(body, next)
		if ok {
			msg.Text = strings.TrimSpace(name + " " + summary)
		} else {
			msg.Text = name
		}
	}
	return msg, true
}

func decodeStyledLines(body []byte) string {
	if len(body) < 2 {
		return ""
	}
	count := int(u16(body, 0))
	offset := 2
	lines := make([]string, 0, count)
	for i := 0; i < count && len(body) >= offset+2; i++ {
		runCount := int(u16(body, offset))
		offset += 2
		parts := make([]string, 0, runCount)
		for j := 0; j < runCount; j++ {
			text, next, ok := readString16(body, offset)
			if !ok || len(body) < next+7 {
				return stringsJoin(lines, " ")
			}
			flags := body[next+6]
			offset = next + 7
			if flags&0x08 != 0 {
				_, next, ok = readString16(body, offset)
				if !ok {
					return stringsJoin(lines, " ")
				}
				offset = next
			}
			parts = append(parts, text)
		}
		lines = append(lines, stringsJoin(parts, ""))
	}
	return stringsJoin(lines, " ")
}

func decodeBoard(payload []byte) (Board, string, int) {
	if len(payload) < 10 {
		return Board{}, "", len(payload)
	}
	board := Board{Visible: payload[1] != 0, FocusedCardID: u32(payload, 2), FilterMode: payload[8] != 0}
	count := int(u16(payload, 6))
	offset := 9
	var ok bool
	board.FilterText, offset, ok = readString16(payload, offset)
	if !ok {
		return board, "", len(payload)
	}
	board.Cards = make([]BoardCard, 0, count)
	for i := 0; i < count && len(payload) >= offset+16; i++ {
		card := BoardCard{ID: u32(payload, offset), Status: payload[offset+4], Flags: payload[offset+5]}
		offset += 6
		card.Task, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		card.Model, offset, ok = readString8(payload, offset)
		if !ok || len(payload) < offset+5 {
			break
		}
		card.Timestamp = u32(payload, offset)
		fileCount := int(payload[offset+4])
		offset += 5
		card.RecentFiles = make([]string, 0, fileCount)
		for j := 0; j < fileCount; j++ {
			file, next, ok := readString16(payload, offset)
			if !ok {
				break
			}
			card.RecentFiles = append(card.RecentFiles, file)
			offset = next
		}
		if len(payload) < offset+1 {
			break
		}
		sparkCount := int(payload[offset])
		offset += 1 + sparkCount*2
		if len(payload) < offset {
			break
		}
		board.Cards = append(board.Cards, card)
	}
	return board, fmt.Sprintf("%d cards", len(board.Cards)), offset
}

func decodeEditTimeline(payload []byte) (EditTimeline, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return EditTimeline{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 4 {
		return EditTimeline{}, "", size
	}
	timeline := EditTimeline{Visible: body[0] != 0, ViewingIndex: u16(body, 1)}
	count := int(body[3])
	offset := 4
	timeline.Entries = make([]TimelineEntry, 0, count)
	for i := 0; i < count && len(body) >= offset+6; i++ {
		entry := TimelineEntry{Index: body[offset]}
		offset++
		var ok bool
		entry.ToolName, offset, ok = readString8(body, offset)
		if !ok || len(body) < offset+4 {
			break
		}
		entry.TimestampDelta = u32(body, offset)
		offset += 4
		timeline.Entries = append(timeline.Entries, entry)
	}
	return timeline, fmt.Sprintf("%d edits", len(timeline.Entries)), size
}

func decodeGutterSeparator(payload []byte) (GutterSeparator, string, int) {
	if len(payload) < 6 {
		return GutterSeparator{}, "", len(payload)
	}
	gutter := GutterSeparator{Col: u16(payload, 1), Color: u24(payload, 3)}
	return gutter, fmt.Sprintf("col %d", gutter.Col), 6
}

func decodeSplitSeparators(payload []byte) (SplitSeparators, string, int) {
	if len(payload) < 5 {
		return SplitSeparators{}, "", len(payload)
	}
	splits := SplitSeparators{Color: u24(payload, 1)}
	count := int(payload[4])
	offset := 5
	splits.Verticals = make([]VerticalSeparator, 0, count)
	for i := 0; i < count && len(payload) >= offset+6; i++ {
		splits.Verticals = append(splits.Verticals, VerticalSeparator{Col: u16(payload, offset), StartRow: u16(payload, offset+2), EndRow: u16(payload, offset+4)})
		offset += 6
	}
	if len(payload) < offset+1 {
		return splits, splitSummary(splits), offset
	}
	hCount := int(payload[offset])
	offset++
	splits.Horizontals = make([]HorizontalSeparator, 0, hCount)
	for i := 0; i < hCount && len(payload) >= offset+8; i++ {
		sep := HorizontalSeparator{Row: u16(payload, offset), Col: u16(payload, offset+2), Width: u16(payload, offset+4)}
		offset += 6
		var ok bool
		sep.Filename, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		splits.Horizontals = append(splits.Horizontals, sep)
	}
	return splits, splitSummary(splits), offset
}

func splitSummary(splits SplitSeparators) string {
	return fmt.Sprintf("%d vertical %d horizontal", len(splits.Verticals), len(splits.Horizontals))
}

func decodeRichLine(payload []byte, offset int, count int) (RichLine, int, bool) {
	line := RichLine{Segments: make([]RichSegment, 0, count)}
	for i := 0; i < count && offset < len(payload); i++ {
		segment := RichSegment{Style: payload[offset]}
		offset++
		if segment.Style == 13 {
			if len(payload) < offset+6 {
				return line, offset, false
			}
			segment.FG = u24(payload, offset)
			segment.Flags = payload[offset+3]
			offset += 4
		}
		text, next, ok := readString16(payload, offset)
		if !ok {
			return line, offset, false
		}
		segment.Text = text
		offset = next
		line.Segments = append(line.Segments, segment)
	}
	return line, offset, true
}

func richLineText(line RichLine) string {
	parts := make([]string, 0, len(line.Segments))
	for _, segment := range line.Segments {
		parts = append(parts, segment.Text)
	}
	return stringsJoin(parts, "")
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

func payloadLen16Size(payload []byte) int {
	if len(payload) < 3 {
		return 0
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size {
		return 0
	}
	return size
}

func payloadLen32Size(payload []byte) int {
	if len(payload) < 5 {
		return 0
	}
	size := 5 + int(u32(payload, 1))
	if len(payload) < size {
		return 0
	}
	return size
}

func opcodeName(opcode byte) string {
	switch opcode {
	case generated.OPGuiTabBar:
		return "tabs"
	case generated.OPGuiWorkspaces:
		return "workspaces"
	case generated.OPGuiSidebars:
		return "sidebars"
	case generated.OPGuiFileTree:
		return "file tree"
	case generated.OPGuiPicker:
		return "picker"
	case generated.OPGuiPickerPreview:
		return "picker preview"
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
	case generated.OPGuiTheme:
		return "theme"
	case generated.OPGuiBreadcrumb:
		return "breadcrumb"
	case generated.OPGuiGitStatus:
		return "git"
	case generated.OPGuiSearchState:
		return "search"
	case generated.OPGuiChangeSummary:
		return "changes"
	case generated.OPGuiHoverPopup:
		return "hover"
	case generated.OPGuiHoverAction:
		return "hover action"
	case generated.OPGuiSignatureHelp:
		return "signature"
	case generated.OPGuiFloatPopup:
		return "float"
	case generated.OPGuiExtensionOverlay:
		return "extension overlay"
	case generated.OPGuiObservatory:
		return "observatory"
	case generated.OPGuiAgentContext:
		return "agent context"
	case generated.OPGuiAgentChat:
		return "agent chat"
	case generated.OPGuiBoard:
		return "board"
	case generated.OPGuiEditTimeline:
		return "edit timeline"
	case generated.OPGuiGutterSep:
		return "gutter separator"
	case generated.OPGuiSplitSeparators:
		return "split separators"
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
