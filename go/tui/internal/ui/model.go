package ui

import (
	"fmt"
	"os"
	"sort"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/latency"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	arrowLeft  rune = 57350
	arrowRight rune = 57351
	arrowUp    rune = 57352
	arrowDown  rune = 57353
)

type Model struct {
	width            int
	height           int
	out              chan<- []byte
	viewport         viewport.Model
	zones            *zoneManager
	windows          map[uint16]protocol.WindowContent
	windowOrder      []uint16
	chrome           map[byte]protocol.ChromePayload
	activePalette    palette
	themeApplied     bool
	gutters          map[uint16]protocol.Gutter
	indentGuides     map[uint16]protocol.IndentGuides
	cursorRow        uint16
	cursorCol        uint16
	cursorShape      byte
	title            string
	bg               uint32
	cursorlineChrome protocol.CursorlineChrome
	pendingClipboard string
	lastError        string
	// protocolError holds the reason from a protocol_error (0x18) command. The
	// BEAM emits it when this frontend's handshake protocol_version does not
	// match the BEAM's, so the frontend never reaches ready. While set, the UI
	// renders a blocking full-screen error surface that takes precedence over
	// normal content instead of showing a blank screen (ticket #2237).
	protocolError string
	// extensionRuntimes holds the most recent gui_extension_runtime (0xA3)
	// envelope per extension id, mirroring the macOS registry that routes
	// payloads by extension id (FrontendExtensionRuntime.swift:26). No
	// in-tree extension registers a terminal renderer yet, so the payload is
	// opaque: we store it keyed by extension id and surface a diagnostic line
	// (footerLines) so the envelope is consumed rather than silently dropped.
	// Once an extension ships a terminal runtime decoder, it reads from here.
	extensionRuntimes     map[string]protocol.ExtensionRuntimePayload
	bottomPanelScrollback int
	agentAnimationFrame   uint64
	agentAnimationRunning bool
	// latency records end-to-end keystroke-to-write samples (ticket #2215).
	// It is a pointer so the recorder persists across value-copied Model
	// updates. hudVisible toggles the on-screen p50/p99 overlay at runtime.
	latency    *latency.Recorder
	hudVisible bool
	// lineCache memoizes composed window body lines so a window-content delta
	// whose rows are mostly refs reuses cached lines instead of recomposing the
	// whole body every frame (#2288). It is a pointer so it persists across the
	// value-copied Model the Update loop produces (same lifetime trick as
	// latency). Structural commands, resize, and keyframe resync clear it; see
	// invalidateLineCache and the keyframe reset in commitStaging.
	lineCache *lineCache
	// mouseDrag tracks an in-progress press-drag over a draggable chrome zone
	// (a tab or a file-tree row), so a release over a different target can emit
	// a tab_reorder or file_tree_drop gui_action (ticket #2229, AC3). It is nil
	// when no draggable press is active.
	mouseDrag *chromeDrag
	// renderedHeaderHeight caches the number of header rows the last rendered
	// frame placed above the editor body. Since #2244 collapsed layout to
	// Layout.GUI (editor at BEAM row 0), outbound editor-body mouse rows must
	// subtract this offset to mirror the inbound translation
	// (render_content.go semanticContentOffsets). It is the single source of
	// truth shared with the renderer (headerLines), recomputed whenever the
	// inputs to headerLines change: applied commands (chrome) and resize
	// (width/height). Caching avoids recomputing headerLines inconsistently per
	// mouse event (ticket #2256).
	renderedHeaderHeight int
	// staging holds the open frame transaction (#2219). It is non-nil only
	// between a begin_frame and its commit_frame: semantic/chrome commands
	// accumulate here instead of mutating the live model, so View() never paints
	// a partially-applied frame. commit_frame validates seq/base and replays the
	// buffer through the live per-command mutation switch in one shot; any
	// invalidation discards it. nil between commits means the live model is the
	// last cleanly committed frame.
	staging *frameStaging
	// lastCommittedSeq is the frame_seq of the most recently committed (applied)
	// transaction. It validates a delta transaction's base_frame_seq and is the
	// last_good_frame_seq carried by request_keyframe. 0 means no frame committed
	// yet (only a base-0 keyframe is valid until then).
	lastCommittedSeq uint32
	// resyncPending is set when the model discarded a transaction and asked the
	// BEAM for a keyframe (#2219). It drives a subtle footer indicator while the
	// frontend waits, and clears when a valid commit applies.
	resyncPending bool
	// surfacePlacements is the BEAM's authoritative per-frame surface layout from
	// gui_surface_layout (0xA4, #2268): one rect+z list. Compositing reads the z
	// of a placed surface to order it instead of the old hand-coded
	// overlayLines() precedence chain; the rects equal what BEAM mouse
	// hit-testing uses. Surfaces not yet promoted into the BEAM surface registry
	// keep a reduced hand-ordered chain (transitional split, see overlayLines).
	surfacePlacements []generated.SurfacePlacement
}

// frameStaging is the open frame transaction buffer (#2219). It lives only
// between begin_frame and commit_frame. Memory is one frame's worth of decoded
// commands (the same commands the model would otherwise apply immediately);
// it is released at commit or discard, so nothing accumulates between frames.
type frameStaging struct {
	// seq is the begin_frame's frame_seq; commit_frame must echo it.
	seq uint32
	// base is the begin_frame's base_frame_seq; 0 means keyframe (always valid),
	// otherwise it must equal lastCommittedSeq.
	base uint32
	// commands are the buffered semantic/chrome commands in arrival order,
	// replayed through the live mutation switch at a valid commit.
	commands []protocol.Command
}

func New(width, height uint16, out chan<- []byte) Model {
	vp := viewport.New(viewport.WithWidth(int(width)), viewport.WithHeight(max(int(height)-3, 1)))
	m := Model{
		width:             int(width),
		height:            int(height),
		out:               out,
		viewport:          vp,
		zones:             newZoneManager(),
		windows:           map[uint16]protocol.WindowContent{},
		chrome:            map[byte]protocol.ChromePayload{},
		activePalette:     bootstrapPalette(),
		gutters:           map[uint16]protocol.Gutter{},
		indentGuides:      map[uint16]protocol.IndentGuides{},
		extensionRuntimes: map[string]protocol.ExtensionRuntimePayload{},
		latency:           latency.New(),
		// MINGA_LATENCY_HUD=1 shows the latency overlay at boot; it is also
		// toggled at runtime with ctrl+alt+l (ticket #2215).
		hudVisible: latencyHUDEnvEnabled(),
		lineCache:  newLineCache(),
	}
	// Seed the header-offset cache so the first mouse event before any
	// frame/resize still translates against the rendered fallback header.
	m.refreshRenderedHeaderHeight()
	return m
}

// latencyHUDEnvEnabled reports whether MINGA_LATENCY_HUD requests the overlay on
// at startup. Any non-empty value other than "0"/"false" enables it.
func latencyHUDEnvEnabled() bool {
	switch os.Getenv("MINGA_LATENCY_HUD") {
	case "", "0", "false", "no":
		return false
	default:
		return true
	}
}

type agentAnimationTickMsg struct{}

func (m Model) Init() tea.Cmd {
	return nil
}

func agentAnimationTick() tea.Cmd {
	return tea.Tick(180*time.Millisecond, func(time.Time) tea.Msg {
		return agentAnimationTickMsg{}
	})
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	m.pendingClipboard = ""
	var cmd tea.Cmd
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		// Resize is a structural change: every cached line was composed at the
		// old width, so drop the cache and take the full composition path
		// (#2288 AC 2). The context fingerprint would catch the width change on
		// its own, but resetting here keeps the cache from holding stale lines
		// for the old geometry.
		m.lineCache.reset()
		m.refreshRenderedHeaderHeight()
		m.viewport.SetWidth(msg.Width)
		m.viewport.SetHeight(m.bodyHeight())
		m.send(protocol.EncodeResize(uint16(max(msg.Width, 1)), uint16(max(msg.Height, 1))))
	case tea.KeyPressMsg:
		if m.toggleHUD(msg) {
			break
		}
		// Stamp the latency correlation sequence (ticket #2215) before
		// encoding so the resulting frame's commit_frame resolves the sample.
		seq := m.latency.Stamp()
		if packet, ok := keyPacket(msg, seq); ok {
			m.send(packet)
		}
	case tea.PasteMsg:
		m.send(pastePacket(msg))
	case tea.MouseMsg:
		if updated, ok := m.localMouse(msg); ok {
			m = updated
		} else {
			updated, dragPacket, handled := m.handleChromeDrag(msg)
			m = updated
			switch {
			case dragPacket != nil:
				m.send(dragPacket)
			case handled:
				// A chrome drag consumed the event (origin press recorded or an
				// in-progress drag motion). Do not also forward it as a raw
				// buffer event or a single-click select.
			default:
				if packet, ok := m.semanticMousePacket(msg); ok {
					m.send(packet)
				} else if packet, ok := m.mousePacket(msg); ok {
					m.send(packet)
				}
			}
		}
	case agentAnimationTickMsg:
		m.agentAnimationFrame++
		if m.agentAnimating() {
			cmd = agentAnimationTick()
		} else {
			m.agentAnimationRunning = false
		}
	case port.PacketMsg:
		cmd = m.applyCommands(msg.Commands)
		m.refreshRenderedHeaderHeight()
	case port.LogMsg:
		m.send(protocol.EncodeLogMessage(msg.Level, msg.Text))
	case port.ErrorMsg:
		m.lastError = msg.Err.Error()
		m.send(protocol.EncodeLogMessage(protocol.LogLevelErr, msg.Err.Error()))
	}

	if m.agentAnimating() && !m.agentAnimationRunning {
		m.agentAnimationRunning = true
		cmd = tea.Batch(cmd, agentAnimationTick())
	}

	m.viewport.SetWidth(max(m.width, 1))
	m.viewport.SetHeight(m.bodyHeight())
	m.viewport.SetContent(m.composeBody())
	return m, cmd
}

// composeBody renders the editor body (the expensive lipgloss path) and records
// how long it took plus how many body lines came from the line cache vs were
// recomposed (#2288). The line cache mutates its per-compose hit/miss counters
// through its pointer while content() runs, so reset them first and fold the
// elapsed time and counts into the latency HUD afterward. This is the single
// compose-time observation per frame; it is where the line-cache win shows up.
func (m *Model) composeBody() string {
	start := time.Now()
	m.lineCache.resetCounters()
	content := m.content()
	if m.latency != nil {
		hits, misses := m.lineCache.takeCounters()
		m.latency.ObserveCompose(time.Since(start), hits, misses)
	}
	return content
}

func (m Model) View() tea.View {
	var content string
	if m.protocolError != "" {
		// A protocol_error (0x18) latched: this frontend's protocol_version was
		// rejected, so it will never reach ready. Render a blocking full-screen
		// error surface that takes precedence over normal content instead of
		// leaving a blank screen (ticket #2237).
		content = m.protocolErrorView()
	} else {
		body := m.viewport.View()
		parts := append(m.headerLines(), body)
		parts = append(parts, m.footerLines()...)
		content = m.zones.Scan(lipgloss.JoinVertical(lipgloss.Left, parts...))
	}
	out := m.cursorStyleSequence() + m.composeFrame(content) + m.latencyHUDSequence() + m.cursorPositionSequence()
	if m.pendingClipboard != "" {
		out += ansi.SetClipboard(ansi.SystemClipboard, m.pendingClipboard)
	}
	view := tea.NewView(out)
	view.AltScreen = true
	view.MouseMode = tea.MouseModeCellMotion
	view.WindowTitle = m.title
	view.BackgroundColor = m.editorBackground()
	view.ForegroundColor = m.palette().Text()
	return view
}

// protocolErrorView renders the blocking full-screen surface shown when a
// protocol_error (0x18) latched. It centers a short title and the BEAM-supplied
// reason on the standard editor background so a version-mismatched frontend
// shows an explicit error instead of a blank screen (ticket #2237).
func (m Model) protocolErrorView() string {
	width := max(m.width, 1)
	height := max(m.height, 1)
	bg := m.editorBackground()
	title := lipgloss.NewStyle().Bold(true).Foreground(m.palette().Error()).Background(bg).Render("Protocol error")
	message := lipgloss.NewStyle().Foreground(m.palette().Text()).Background(bg).Render(m.protocolError)
	block := lipgloss.JoinVertical(lipgloss.Center, title, "", message)
	return lipgloss.Place(
		width, height,
		lipgloss.Center, lipgloss.Center,
		block,
		lipgloss.WithWhitespaceStyle(lipgloss.NewStyle().Background(bg)),
	)
}

func (m Model) cursorPositionSequence() string {
	return ansi.CursorPosition(int(m.cursorCol)+1, int(m.cursorRow)+1)
}

// latencyHUDSequence renders the latency overlay (ticket #2215) as a top-right
// badge positioned with raw ANSI so it sits above the composited frame without
// re-laying-out the lipgloss tree. It is intentionally cheap: a single
// percentile snapshot and one styled string per frame, so the HUD does not
// distort the numbers it reports.
func (m Model) latencyHUDSequence() string {
	if !m.hudVisible || m.latency == nil {
		return ""
	}

	text := " " + m.latency.Snapshot().HUD() + " "
	badge := lipgloss.NewStyle().
		Background(lipgloss.Color("#1f2335")).
		Foreground(lipgloss.Color("#7aa2f7")).
		Render(text)

	col := max(m.width-lipgloss.Width(badge)+1, 1)
	return ansi.SaveCursor + ansi.CursorPosition(col, 1) + badge + ansi.RestoreCursor
}

func (m Model) cursorStyleSequence() string {
	switch m.cursorShape {
	case 1:
		return ansi.SetCursorStyle(6)
	case 2:
		return ansi.SetCursorStyle(4)
	default:
		return ansi.SetCursorStyle(2)
	}
}

// applyCommands routes a decoded batch through the frame-transaction state
// machine (#2219). begin_frame opens a staging buffer; semantic/chrome commands
// accumulate in it without touching the live model; commit_frame validates and
// replays the buffer atomically. Out-of-band commands (set_title/set_window_bg, clipboard writes, no-op compatibility commands, protocol_error, transport survivors) apply directly with no open transaction; the same command inside a transaction stages and applies at commit. A semantic/chrome command with NO open transaction, or any stream
// error / invalidation, is a protocol violation under the staged model and
// triggers request_keyframe instead of a partial paint.
func (m *Model) applyCommands(commands []protocol.Command) tea.Cmd {
	cmds := make([]tea.Cmd, 0, 1)
	for _, command := range commands {
		switch command.Kind {
		case protocol.CommandBeginFrame:
			if m.staging != nil {
				// A new begin while one is open means the prior transaction was
				// truncated before its commit. Discard it and resync (#2219).
				cmds = m.invalidateStaging(cmds, "truncated frame transaction (begin while open)")
			}
			m.staging = &frameStaging{
				seq:      command.FrameSeq,
				base:     command.BaseFrameSeq,
				commands: make([]protocol.Command, 0, 16),
			}
		case protocol.CommandCommitFrame:
			cmds = m.commitStaging(cmds, command)
		case protocol.CommandStreamError:
			// The reader hit a sizing/decode failure: byte boundaries inside an
			// open transaction are no longer trustworthy, so abort it and resync.
			// Out of band it is harmless (warned already), so only act when staging.
			if m.staging != nil {
				cmds = m.invalidateStaging(cmds, "stream error inside open frame transaction")
			}
		case protocol.CommandProtocolError:
			// Out-of-band by design (#2219): the BEAM rejected this frontend's
			// handshake protocol_version, so it never enters a transaction. Latch
			// the reason so View renders a blocking error surface (ticket #2237).
			// Do not write diagnostics to stderr: the TUI owns the terminal, so raw
			// stderr can corrupt the rendered frame. Send them back to BEAM so they
			// land in Minga's *Messages* buffer instead.
			m.protocolError = command.ProtocolError
			m.logToMessages(protocol.LogLevelErr, "Go TUI protocol error: %s", command.ProtocolError)
		case protocol.CommandNoop:
			// Sized-but-ignored compatibility commands, such as font setup, can arrive out of band during startup. They do not mutate the Go TUI and should not be treated as frame-transaction violations.
			continue
		case protocol.CommandSetTitle, protocol.CommandSetWindowBg, protocol.CommandClipboardWrite:
			// Sanctioned out-of-band side channels (emit.ex send_title/send_window_bg and command helpers can write these outside the begin/commit bracket). If one arrives inside an open transaction it still stages so the swap stays atomic; outside one it applies directly.
			if m.staging != nil {
				m.staging.commands = append(m.staging.commands, command)
			} else {
				m.applyMutation(command)
			}
		default:
			// Semantic/chrome commands. These are only legitimate inside a
			// transaction. Outside one they are a protocol violation under the
			// staged model, so resync rather than partially paint (#2219).
			if m.staging == nil {
				cmds = m.invalidateStaging(cmds, "semantic command outside frame transaction")
				continue
			}
			m.staging.commands = append(m.staging.commands, command)
		}
	}
	return tea.Batch(cmds...)
}

func stagingThemeValidation(commands []protocol.Command) (found bool, missing []byte) {
	for _, command := range commands {
		if command.Kind == protocol.CommandChrome && command.Chrome.Opcode == generated.OPGuiTheme {
			found = true
			missing = missingThemeSlots(command.Chrome.Theme)
			if len(missing) > 0 {
				return true, missing
			}
		}
	}
	return found, nil
}

// commitStaging validates the open transaction against the commit and, if valid,
// replays its buffered commands through the live mutation switch in one shot,
// then fires the commit-gated behaviors (latency resolve). An invalid or missing
// transaction discards staging and requests a keyframe (#2219), except a missing theme on a keyframe latches a protocol error because the BEAM must own theme selection.
func (m *Model) commitStaging(cmds []tea.Cmd, command protocol.Command) []tea.Cmd {
	if m.staging == nil {
		// commit with no open begin: the begin was lost or truncated. Resync.
		return m.invalidateStaging(cmds, "commit_frame with no open transaction")
	}
	if command.FrameSeq != m.staging.seq {
		return m.invalidateStaging(cmds, "commit_frame seq mismatch")
	}
	// base 0 is a keyframe and always valid; a non-zero base must match the last
	// committed frame_seq, otherwise this delta assumes a frame we never applied.
	if m.staging.base != 0 && m.staging.base != m.lastCommittedSeq {
		return m.invalidateStaging(cmds, "frame base mismatch")
	}

	// Resync safety (#2288 AC 5): gui_theme must be complete before any frame
	// promotes. Keyframes must also carry gui_theme at all because the BEAM owns
	// theme selection; otherwise the frontend would silently keep using
	// bootstrap colors and hide a startup bug.
	found, missing := stagingThemeValidation(m.staging.commands)
	if found && len(missing) > 0 {
		if m.staging.base == 0 {
			m.protocolError = fmt.Sprintf("missing gui_theme slots in keyframe: %s", formatMissingThemeSlots(missing))
			return m.invalidateStaging(cmds, "missing gui_theme slots in keyframe")
		}
		m.protocolError = fmt.Sprintf("missing gui_theme slots: %s", formatMissingThemeSlots(missing))
		return m.invalidateStaging(cmds, "missing gui_theme slots")
	}
	if m.staging.base == 0 {
		if !found {
			m.protocolError = "missing gui_theme in keyframe"
			return m.invalidateStaging(cmds, "missing gui_theme in keyframe")
		}
		m.lineCache.reset()
	}

	// Valid: replay the buffer atomically through the live mutation path.
	for _, staged := range m.staging.commands {
		m.applyMutation(staged)
	}
	m.lastCommittedSeq = m.staging.seq
	m.staging = nil
	// A clean commit clears any pending resync indicator: the frontend is back
	// in sync with the BEAM (#2219).
	m.resyncPending = false

	// Commit-gated behaviors: the frame is fully applied and about to be written
	// to the terminal, so resolve the keystroke-to-write latency sample now for
	// the echoed correlation sequence (ticket #2215, resolved on commit).
	m.latency.Resolve(command.InputSeq)
	return cmds
}

// invalidateStaging discards any open transaction and emits a request_keyframe
// carrying the last cleanly committed frame_seq (#2219). It is the single sink
// for every invalidation: truncation, seq mismatch, base mismatch, a stream
// error inside a transaction, and an out-of-transaction semantic command. The
// live model keeps the last committed frame, so View() never paints a partial.
func (m *Model) invalidateStaging(cmds []tea.Cmd, reason string) []tea.Cmd {
	m.staging = nil
	// Debounce the keyframe request: after an invalidation, every stale
	// in-flight frame also fails its base check (the BEAM advances
	// base_frame_seq for frames we discarded), and re-requesting per frame
	// would force a duplicate BEAM render each. One request per resync
	// window; the pending flag clears when a valid commit applies. The diagnostic
	// follows the same debounce and is sent to BEAM's *Messages* log instead of
	// raw stderr, because stderr writes can corrupt the terminal renderer.
	if !m.resyncPending {
		m.resyncPending = true
		m.logToMessages(protocol.LogLevelWarn, "Go TUI frame invalidated (%s), requesting keyframe from %d", reason, m.lastCommittedSeq)
		m.send(protocol.EncodeRequestKeyframe(m.lastCommittedSeq))
	}
	return cmds
}

// applyMutation runs a single command through the live per-command mutation
// switch (#2219). It is the ONE mutation path: both a committed transaction's
// replay and an out-of-band side-channel write go through here, so there is no
// shadow Model and no forked mutators.
func (m *Model) applyMutation(command protocol.Command) {
	switch command.Kind {
	case protocol.CommandSetCursorShape:
		m.cursorShape = command.CursorShape
	case protocol.CommandSetTitle:
		m.title = command.Title
	case protocol.CommandSetWindowBg:
		m.bg = command.WindowBg
	case protocol.CommandWindowContent:
		m.putWindow(command.Window)
	case protocol.CommandWindowDelta:
		m.applyWindowDelta(command.Window)
	case protocol.CommandClipboardWrite:
		m.pendingClipboard = command.ClipboardText
	case protocol.CommandExtensionRuntime:
		m.applyExtensionRuntime(command.ExtensionRuntime)
	case protocol.CommandChrome:
		m.chrome[command.Chrome.Opcode] = command.Chrome
		switch command.Chrome.Opcode {
		case generated.OPGuiTheme:
			m.activePalette = paletteFromTheme(command.Chrome.Theme)
			m.themeApplied = true
		case generated.OPGuiCursorline:
			m.cursorlineChrome = command.Chrome.CursorlineChrome
		case generated.OPGuiGutter:
			m.gutters[command.Chrome.WindowGutter.WindowID] = command.Chrome.WindowGutter
		case generated.OPGuiIndentGuides:
			m.indentGuides[command.Chrome.IndentGuides.WindowID] = command.Chrome.IndentGuides
		case generated.OPGuiFileTreeSelection:
			m.applyFileTreeSelection(command.Chrome.FileTreeSelection)
		case generated.OPGuiBottomPanel:
			m.clampBottomPanelScrollback(command.Chrome.Bottom)
		case generated.OPGuiSurfaceLayout:
			// The authoritative per-frame surface layout (#2268). Replace wholesale
			// each frame: it is a full snapshot, not a delta, and an absent opcode
			// (older BEAM) leaves the prior list which compositing tolerates.
			m.surfacePlacements = command.Chrome.Placements
		}
	}
}

// applyExtensionRuntime stores the latest gui_extension_runtime (0xA3) envelope
// keyed by extension id, mirroring the macOS registry dispatch by extension id
// (FrontendExtensionRuntime.swift:26). The payload is opaque: the shared
// protocol owns only the envelope (gui.ex:873), and no in-tree extension ships
// a terminal decoder yet, so we keep the most recent envelope per extension so
// a future extension renderer can read it and footerLines can surface that a
// runtime is active instead of dropping the frame.
func (m *Model) applyExtensionRuntime(payload protocol.ExtensionRuntimePayload) {
	if payload.ExtensionID == "" {
		return
	}
	if m.extensionRuntimes == nil {
		m.extensionRuntimes = map[string]protocol.ExtensionRuntimePayload{}
	}
	m.extensionRuntimes[payload.ExtensionID] = payload
}

func (m *Model) putWindow(window protocol.WindowContent) {
	if _, ok := m.windows[window.ID]; !ok {
		m.windowOrder = append(m.windowOrder, window.ID)
		sort.Slice(m.windowOrder, func(i, j int) bool { return m.windowOrder[i] < m.windowOrder[j] })
	}
	m.windows[window.ID] = window
	m.refreshCursorFromWindows()
}

func (m *Model) applyWindowDelta(delta protocol.WindowContent) {
	window, ok := m.windows[delta.ID]
	if !ok || window.ContentEpoch != delta.ContentEpoch {
		return
	}
	window.CursorRow = delta.CursorRow
	window.CursorCol = delta.CursorCol
	window.CursorShape = delta.CursorShape
	window.CursorVisible = delta.CursorVisible
	window.ContentEpoch = delta.ContentEpoch
	if delta.ScrollLeftSet {
		window.ScrollLeft = delta.ScrollLeft
	}
	window.Cursorline = delta.Cursorline
	if delta.SelectionSet {
		window.Selection = delta.Selection
		window.SelectionSet = true
	}
	if delta.SearchSet {
		window.SearchMatches = delta.SearchMatches
		window.SearchSet = true
	}
	if delta.DiagnosticsSet {
		window.Diagnostics = delta.Diagnostics
		window.DiagnosticsSet = true
	}
	if delta.HighlightsSet {
		window.Highlights = delta.Highlights
		window.HighlightsSet = true
	}
	if delta.AnnotationsSet {
		window.Annotations = delta.Annotations
		window.AnnotationsSet = true
	}
	if delta.GeometrySet {
		window.Geometry = delta.Geometry
		window.GeometrySet = true
	}
	if delta.Rows == nil {
		if delta.ScrollSet && delta.Scroll.WindowID == window.ID && delta.Scroll.ContentEpoch == window.ContentEpoch {
			window.Scroll = delta.Scroll
			window.ScrollSet = true
		}
	} else if delta.ScrollSet && delta.Scroll.WindowID == window.ID && delta.Scroll.ContentEpoch == window.ContentEpoch {
		window.Scroll = delta.Scroll
		window.ScrollSet = true
	} else {
		window.Scroll = protocol.ScrollPresentation{}
		window.ScrollSet = false
	}
	if delta.Rows != nil {
		rows, err := resolveWindowRows(window.Rows, delta.Rows)
		if err != nil {
			m.removeWindow(delta.ID)
			return
		}
		window.Rows = rows
	}
	m.windows[delta.ID] = window
	m.refreshCursorFromWindows()
}

func (m *Model) refreshCursorFromWindows() {
	for _, id := range m.windowOrder {
		window := m.windows[id]
		if !window.CursorVisible {
			continue
		}
		m.cursorRow = window.CursorRow
		m.cursorCol = window.CursorCol
		m.cursorShape = window.CursorShape
	}
}

func resolveWindowRows(previous []protocol.WindowRow, delta []protocol.WindowRow) ([]protocol.WindowRow, error) {
	byID := make(map[uint64]protocol.WindowRow, len(previous))
	for _, row := range previous {
		byID[row.ID] = row
	}
	rows := make([]protocol.WindowRow, 0, len(delta))
	for _, row := range delta {
		if row.Ref {
			existing, ok := byID[row.ID]
			if !ok {
				return nil, fmt.Errorf("missing retained row ref %d", row.ID)
			}
			if existing.ContentHash != row.ContentHash {
				return nil, fmt.Errorf("retained row ref %d hash mismatch", row.ID)
			}
			rows = append(rows, existing)
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func (m *Model) removeWindow(id uint16) {
	delete(m.windows, id)
	m.lineCache.dropWindow(id)
	for index, windowID := range m.windowOrder {
		if windowID == id {
			m.windowOrder = append(m.windowOrder[:index], m.windowOrder[index+1:]...)
			return
		}
	}
}

func (m Model) bodyHeight() int {
	return max(m.height-len(m.headerLines())-len(m.footerLines()), 1)
}

// refreshRenderedHeaderHeight recomputes the cached header offset from the same
// headerLines the renderer uses, so outbound mouse translation (mousePacket)
// stays consistent with the frame on screen (ticket #2256). Call it whenever an
// input to headerLines changes: applied commands (chrome content) and resize
// (width drives the breadcrumb threshold).
func (m *Model) refreshRenderedHeaderHeight() {
	m.renderedHeaderHeight = len(m.headerLines())
}

func (m Model) maxOverlayHeight() int {
	return min(max(m.height/3, 4), 12)
}

func (m Model) send(payload []byte) {
	if m.out != nil {
		m.out <- payload
	}
}

func (m Model) logToMessages(level byte, format string, args ...any) {
	m.send(protocol.EncodeLogMessage(level, fmt.Sprintf(format, args...)))
}

// toggleHUD flips the latency overlay when the toggle chord (ctrl+alt+l) is
// pressed and reports whether it consumed the key. Consuming it keeps the chord
// from being forwarded to the editor as a normal keystroke (ticket #2215).
func (m *Model) toggleHUD(msg tea.KeyPressMsg) bool {
	key := msg.Key()
	if key.Code == 'l' && key.Mod.Contains(tea.ModCtrl) && key.Mod.Contains(tea.ModAlt) {
		m.hudVisible = !m.hudVisible
		return true
	}
	return false
}
