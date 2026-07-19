package protocol

import "github.com/jsmestad/minga/go/tui/internal/generated"

type TabBar struct {
	ActiveIndex byte
	Tabs        []Tab
}

type Tab struct {
	Flags     byte
	ID        uint32
	GroupID   uint16
	Icon      string
	Label     string
	Tint      uint32
	Active    bool
	Dirty     bool
	Agent     bool
	Attention bool
	Pinned    bool
	// Ephemeral marks a file tab backed by no file on disk (e.g. Untitled-1).
	Ephemeral   bool
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
	Visible       bool
	Row           uint16
	Col           uint16
	Selected      uint16
	Items         []CompletionItem
	Documentation string
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
	Flags    byte
	Status   byte
	Selected string
	Root     string
	Width    uint16
	Error    string
	Rows     []FileTreeRow
}

type FileTreeRow struct {
	ID             string
	Path           string
	PathHash       uint32
	Name           string
	Icon           string
	IconColor      uint32
	Depth          byte
	Flags          uint16
	Directory      bool
	Expanded       bool
	Selected       bool
	Focused        bool
	Active         bool
	Dirty          bool
	MatchPositions []uint16
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
	PendingKeys string
	Operation   *generated.GuiStatusBarOperation
	Left        []StatusSegment
	Right       []StatusSegment
}

type StatusSegment struct {
	Name    string
	FG      uint32
	BG      uint32
	Attrs   byte
	Text    string
	Command string
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
	Visible        bool
	ActiveTab      byte
	HeightPercent  byte
	Filter         byte
	StreamInstance uint32
	Tabs           []PanelTab
	Messages       []PanelMessage
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
	Progress   AgentProgress
	Todos      []AgentTodo
}

type AgentProgress struct {
	ActiveAction string
	ToolCount    uint16
	FileCount    uint16
	ReviewHint   string
}

type AgentTodo struct {
	Status      byte
	Description string
}

type AgentChat struct {
	Visible           bool
	Status            byte
	ModelName         string
	Prompt            string
	PromptLineCount   byte
	PromptCursorLine  uint16
	PromptCursorCol   uint16
	PromptVimMode     byte
	PromptVisibleRows byte
	ThinkingLevel     string
	// InputFocused reports whether the composer captures keys (0x78 section 0x09).
	// The resident transcript scroll (#2654) gates j/k on this so a scroll key is
	// not mistaken for composer cursor motion. Absent section leaves it false.
	InputFocused bool
	Pending      string
	Completion   []string
}

type AgentChatMessage struct {
	ID                uint32
	Kind              byte
	Text              string
	Name              string
	Summary           string
	Result            string
	Status            byte
	IsError           bool
	Collapsed         bool
	DurationMS        uint32
	AutoApprovedScope byte
	StyledLines       []AgentStyledLine
	MarkdownBlocks    []AgentMarkdownBlock
	Usage             AgentUsage
	PreviewKind       byte
	PreviewLines      []string
}

// AgentMarkdownBlock is a BEAM-authored semantic markdown block. Renderers must not infer block/card structure from styled-run flags.
type AgentMarkdownBlock struct {
	ID              uint32
	Kind            byte
	Flags           byte
	Lines           []AgentStyledLine
	Level           byte
	Indent          byte
	Ordered         bool
	Ordinal         uint32
	Height          byte
	Language        string
	Label           string
	TargetPath      string
	CapabilityFlags byte
}

func (block AgentMarkdownBlock) Complete() bool {
	return block.Flags&0x01 != 0
}

type AgentStyledLine []AgentStyledRun

type AgentStyledRun struct {
	Text  string
	FG    uint32
	BG    uint32
	Flags byte
	URL   string
}

func (run AgentStyledRun) Bold() bool {
	return run.Flags&0x01 != 0
}

func (run AgentStyledRun) Italic() bool {
	return run.Flags&0x02 != 0
}

func (run AgentStyledRun) Underline() bool {
	return run.Flags&0x04 != 0
}

func (run AgentStyledRun) Code() bool {
	return run.Flags&0x10 != 0
}

type AgentUsage struct {
	Input      uint32
	Output     uint32
	CacheRead  uint32
	CacheWrite uint32
	CostMicros uint32
}

type EditTimeline struct {
	Visible      bool
	ViewingIndex uint16
	Entries      []TimelineEntry
	Files        []TimelineFile
}

type TimelineEntry struct {
	Index          byte
	ToolName       string
	TimestampDelta uint32
}

type TimelineFile struct {
	Path         string
	EntryCount   byte
	LinesAdded   uint32
	LinesRemoved uint32
	ReviewStatus byte
}

type GutterSeparator struct {
	Col   uint16
	Color uint32
}

type Gutter struct {
	WindowID        uint16
	ContentRow      uint16
	ContentCol      uint16
	ContentHeight   uint16
	Active          bool
	ContentWidth    uint16
	CursorLine      uint32
	LineNumberStyle byte
	LineNumberWidth byte
	SignColWidth    byte
	Entries         []GutterEntry
}

type GutterEntry struct {
	BufferLine  uint32
	DisplayType byte
	SignType    byte
	FoldEndLine uint32
	SignFG      uint32
	SignText    string
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

// EmptyState is the zero-buffers launchpad surface (gui_empty_state, 0xA5,
// #2689). The BEAM owns content and activation semantics; the renderer owns
// layout. Sections are data-driven and arrive in display order (session,
// recent, start, footer); absent sections are simply not sent.
type EmptyState struct {
	Visible   bool
	Crashed   bool
	Version   string
	FocusedID string
	Sections  []EmptyStateSection
}

// EmptyStateSection groups launchpad items under a titled region. ID is the
// wire section id: 0=session, 1=recent, 2=start, 3=footer.
type EmptyStateSection struct {
	ID    byte
	Title string
	Items []EmptyStateItem
}

// EmptyStateItem is one launchpad row. Kind is the wire item kind: 0=resume,
// 1=recent_file, 2=action, 3=hint. JumpKey is a single-key/RET jump binding
// (empty when the row teaches a durable chord instead); Chord is a
// space-separated leader sequence (e.g. "SPC f f"). IconColor is a 24-bit RGB
// value in the low bytes of a u32.
type EmptyStateItem struct {
	Kind      byte
	ID        string
	Label     string
	Detail    string
	JumpKey   string
	Chord     string
	Icon      string
	IconColor uint32
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
