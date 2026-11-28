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
	Generation    uint32
	Items         []MinibufferCandidate
}

type MinibufferCandidate struct {
	ID             string
	MatchScore     byte
	Label          string
	Description    string
	Annotation     string
	MatchPositions []uint16
}

type Completion struct {
	Visible       bool
	Generation    uint32
	Row           uint16
	Col           uint16
	Selected      uint16
	SelectedID    string
	Items         []CompletionItem
	Documentation string
	Total         uint32
	Matched       uint32
	Incomplete    bool
}

type CompletionItem struct {
	Kind        byte
	Label       string
	Detail      string
	ID          string
	Source      string
	MatchRanges []generated.CompletionMatchRange
}

// Count tones for WhichKey.CountTone and WhichKeyEntry.CountTone: the colour role a count draws in.
const (
	WhichKeyCountMuted    uint8 = 0
	WhichKeyCountNeedsYou uint8 = 1
	WhichKeyCountError    uint8 = 2
)

// WhichKey is the which-key panel (docs/GUI_PROTOCOL.md, gui_which_key). Entries arrive in display order; consecutive
// entries with the same Section form one section. A count's tone names its colour role: WhichKeyCountMuted,
// WhichKeyCountNeedsYou or WhichKeyCountError.
type WhichKey struct {
	Visible    bool
	Path       string
	Breadcrumb []generated.WhichKeyCrumb
	Count      string
	CountTone  uint8
	Hints      []generated.WhichKeyHint
	Entries    []generated.WhichKeyEntry
}

type Picker struct {
	Visible    bool
	Generation uint32
	Selected   uint16
	SelectedID uint32
	Filtered   uint16
	Total      uint16
	Marked     uint16
	HasPreview bool
	Title      string
	Query      string
	ModePrefix string
	LoadStatus byte
	LoadError  string
	Items      []PickerItem
	// Empty is set while the picker offers its source's next steps instead of results: the header says what happened and why, and Items are the next-step rows.
	Empty *generated.EmptyList
	// ListKeys is true while the picker has nothing to filter: it takes no text, and j and k move, q closes.
	ListKeys bool
	// Hints are the footer's key hints of an empty picker, resolved by the BEAM from the live keymap.
	Hints []generated.KeyHint
	// MovementKeys are the keys the BEAM's picker keymap scope resolves to one-row movement. The local selection preview moves only for these keys.
	MovementKeys []PickerMovementKey
	// EnterSelects is the BEAM keymap's permission to activate the locally previewed picker row on plain Enter.
	EnterSelects bool
}

// PickerMovementKey is one key_press identity and the rows it moves the highlighted row: 1 down, -1 up.
type PickerMovementKey struct {
	Codepoint uint32
	Modifiers byte
	Delta     int
}

type PickerItem struct {
	ActivationID uint32
	IconColor    uint32
	Flags        byte
	Label        string
	Description  string
	Annotation   string
	Marked       bool
	// Active marks the current value, such as the current model (flags bit 3).
	Active bool
	// Status is the BEAM-authored chip text, rendered verbatim; empty means no chip.
	Status     string
	StatusTone generated.PickerStatusTone
	// Group is the item's section. A non-selectable header row names it before the first drawn item of each run of items with the same group; empty means no section.
	Group string
}

// HasStatus reports whether the row carries a status chip. Rows with a chip keep
// the chip visible and shorten the end of their description.
func (item PickerItem) HasStatus() bool {
	return item.Status != "" && item.StatusTone != generated.PickerStatusToneNone
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
	Visible    bool
	Focused    bool
	Generation uint32
	Flags      byte
	Status     byte
	Selected   string
	Root       string
	Width      uint16
	Error      string
	Rows       []FileTreeRow
	// Empty is the empty-folder anatomy (status 2): what happened and the next steps, which run their command on click.
	Empty *generated.EmptyList
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
	Editing        bool
	EditingText    string
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
	// MessageActions are the next steps the echo-line notice names, drawn after Message; a click runs the action's command.
	MessageActions []generated.EmptyListAction
	PendingKeys    string
	Operation      *generated.GuiStatusBarOperation
	Review         *StatusReview
	// Agent is set only for agent-content status bars (content kind 1). It carries
	// the BEAM-owned conversation total, not the resident transcript count.
	Agent *StatusAgent
	Left  []StatusSegment
	Right []StatusSegment
}

// StatusAgent is the agent section (0x09) of an agent-content status bar.
type StatusAgent struct {
	MessageCount uint32
}

// StatusSegment is one modeline segment in the order the BEAM sends it.
// Drop is its rank when the window narrows (0 never drops); a segment with HasCompact collapses to its state mark and Compact text at that rank instead of dropping.
// State is a design-token state byte (0 for none), Key the key that does what a click does, and Label what the segment means, for hover text.
type StatusSegment struct {
	Name       string
	FG         uint32
	BG         uint32
	Attrs      byte
	Text       string
	Command    string
	Drop       byte
	HasCompact bool
	State      byte
	Compact    string
	Key        string
	Label      string
}

type Theme struct {
	Colors map[byte]uint32
}

type Breadcrumb struct {
	Segments []string
}

type GitStatus struct {
	PanelID           uint64
	CommitTargetID    uint64
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
	TerminalCursor    uint32
	TerminalCollapsed byte
	// Empty is a clean tree's empty-state anatomy: what happened and the next steps, which run their command on click.
	Empty *generated.EmptyList
}

type GitStatusEntry struct {
	PathHash uint32
	Section  byte
	Status   byte
	Path     string
}

type GitToast struct {
	ID      uint64
	Visible bool
	Level   byte
	Action  byte
	Message string
}

type SearchState struct {
	Active              bool
	Count               uint32
	CurrentIndex        uint32
	Flags               byte
	Query               string
	SessionID           uint32
	AcknowledgedEditSeq uint32
	Status              byte
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

type ReviewFreshness byte

const (
	ReviewCurrent ReviewFreshness = iota
	ReviewStale
)

// StatusReview is an immutable action offer, not a mutable buffer selection.
type StatusReview struct {
	Path          string
	Freshness     ReviewFreshness
	ConflictIndex uint32 // one-based; zero means read-only Review
	// KeepMineKey and UseAgentKey are the BEAM-authored key hints for the two
	// conflict decisions in the active editing model; empty when not offered.
	KeepMineKey string
	UseAgentKey string
	Generation  uint32
	ItemID      string
}

type AgentHelp struct {
	Visible bool
	Groups  []AgentHelpGroup
}

type AgentHelpGroup struct {
	Title    string
	Bindings []AgentHelpBinding
}

type AgentHelpBinding struct {
	Key         string
	Description string
}

// AgentQueueTarget identifies both the active turn and its next queue entry.
type AgentQueueTarget struct {
	AgentStopTarget
	Sequence uint64
}

// AgentStopTarget carries the exact session and request identity for a turn control.
type AgentStopTarget struct {
	SessionID string
	RequestID string
}

type AgentChatLifecycle byte

const (
	AgentChatConversation AgentChatLifecycle = iota
	AgentChatStarting
	AgentChatFailed
	AgentChatUnavailable
)

// AgentStartRemedyKind names the one action a failed Agent start offers.
type AgentStartRemedyKind byte

const (
	AgentStartRemedyNone AgentStartRemedyKind = iota
	AgentStartRemedyRetry
	AgentStartRemedySetUpProvider
)

// AgentStartRemedy is the failed start's action as the BEAM sends it. The
// frontend renders Label and KeyHint verbatim and never authors remedy copy.
type AgentStartRemedy struct {
	Kind    AgentStartRemedyKind
	Label   string
	KeyHint string
}

// AgentLifecycleNotice is the BEAM's copy for a non-conversation chat: what
// happened to the tab and the draft note under it. The frontend renders both
// verbatim; an empty Note means no note line.
type AgentLifecycleNotice struct {
	Headline string
	Note     string
}

type AgentChat struct {
	Visible           bool
	Status            byte
	Lifecycle         AgentChatLifecycle
	LifecycleReason   string
	LifecycleRemedy   AgentStartRemedy
	LifecycleNotice   AgentLifecycleNotice
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
	InputFocused         bool
	DraftAttachmentCount byte
	DraftAttachmentOffer uint64
	QueueTarget          AgentQueueTarget
	PromptPresentation   uint64
	QuestionOffer        uint64
	QuestionPrompt       string
	StopTarget           AgentStopTarget
	ContinueTarget       AgentStopTarget
	Pending              string
	Completion           []string
	// ComposerHints are the focused composer's key hints, authored by the BEAM
	// (0x78 section 0x10). Absent while the composer does not have focus.
	ComposerHints []generated.ComposerHint
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
	ApprovalTarget    AgentApprovalTarget
	// Step is the tool call's one-line sentence and State its shared state
	// byte (generated.SpineStateFromWire), both authored by the BEAM.
	Step  string
	State byte

	RetainedOutputOffer [16]byte
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
	Generation   uint32
	Entries      []TimelineEntry
	Files        []TimelineFile
}

type TimelineEntry struct {
	Index          byte
	EntryID        string
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
	WindowID         uint16
	ContentRow       uint16
	ContentCol       uint16
	ContentHeight    uint16
	Active           bool
	ContentWidth     uint16
	CursorLine       uint32
	LineNumberStyle  byte
	LineNumberWidth  byte
	SignColWidth     byte
	Resident         *ResidentGutterEntries
	Entries          []GutterEntry
	Authorship       *GutterAuthorship
	AuthorshipUpdate *GutterAuthorshipUpdate
	DecodeError      string
}

const (
	GutterAuthorshipSnapshot byte = iota
	GutterAuthorshipRetain
	GutterAuthorshipPatch
)

const (
	AuthoredGutterPending byte = iota
	AuthoredGutterDeletion
	AuthoredGutterKept
	AuthoredGutterYou
	AuthoredGutterShared
)

type AuthoredGutterRegion struct {
	Role        byte
	Unit        uint64
	FirstLine   uint32
	FirstColumn uint32
	LastLine    uint32
}

// GutterAuthorship is the committed, immutable authored-region snapshot.
type GutterAuthorship struct {
	Revision uint64
	regions  []indexedGutterRegion
}

type GutterAuthorshipUpdate struct {
	Kind     byte
	Base     uint64
	Revision uint64
	Added    []AuthoredGutterRegion
	Removed  []AuthoredGutterRegion
}

// ResidentGutterEntries carries the document-sized gutter contract. Every
// buffer-line index below LineCount has an implicit ordinary entry; Overrides
// stores only folds and signs. RetainOverrides is a wire update instruction
// that the frame transaction resolves before publication.
type ResidentGutterEntries struct {
	ContentEpoch    uint32
	LineCount       uint32
	RetainOverrides bool
	Overrides       map[uint32]GutterEntry
}

// EntryCount returns the resident document extent, or the legacy dense entry
// count when the sender does not use the resident gutter contract.
func (g Gutter) EntryCount() int {
	if g.Resident != nil {
		return int(g.Resident.LineCount)
	}
	return len(g.Entries)
}

// EntryAt resolves one gutter entry in O(1). Resident gutters synthesize the
// ordinary no-sign baseline instead of allocating one entry per document line.
func (g Gutter) EntryAt(index int) (GutterEntry, bool) {
	if index < 0 || index >= g.EntryCount() {
		return GutterEntry{}, false
	}
	if g.Resident == nil {
		return g.Entries[index], true
	}
	bufferLine := uint32(index)
	if entry, ok := g.Resident.Overrides[bufferLine]; ok {
		return entry, true
	}
	return GutterEntry{BufferLine: bufferLine}, true
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

// EmptyState is the project home, *home* (#4056): a header that says where
// you are (Title, Path, Status, an optional muted Note), then sections.
type EmptyState struct {
	Visible   bool
	Title     string
	Path      string
	Status    string
	Note      string
	FocusedID string
	Sections  []EmptyStateSection
}

// EmptyStateSection groups home rows under a title. ID is the wire section
// id: 1=recent files, 4=recent projects, 5=Minga tasks, 6=next actions.
// Empty is the muted line shown when the section has no rows.
type EmptyStateSection struct {
	ID    byte
	Title string
	Empty string
	Items []EmptyStateItem
}

// EmptyStateItem is one home row. Kind is the wire item kind: 1=recent file,
// 2=action, 4=project, 5=task. JumpKey is the number key that opens the row;
// Chord is the leader sequence an action runs (e.g. "SPC SPC"). Detail and
// Meta are muted text after the label. State is a design-token state name
// ("needs_you") whose glyph and colour a task row draws. IconColor is a
// 24-bit RGB value in the low bytes of a u32.
type EmptyStateItem struct {
	Kind      byte
	ID        string
	Label     string
	Detail    string
	Meta      string
	JumpKey   string
	Chord     string
	Icon      string
	IconColor uint32
	State     string
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
