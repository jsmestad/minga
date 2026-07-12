package ui

import (
	"fmt"
	"os"
	"sort"
	"strings"
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
	width    int
	height   int
	out      chan<- []byte
	viewport viewport.Model
	zones    *zoneManager
	windows  map[uint16]protocol.WindowContent
	// residentRows is the indexed, value-semantic authority for window rows.
	// WindowContent.Rows is retained only as a small-fixture compatibility view.
	residentRows     map[uint16]residentRows
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
	agent                 agentPanel
	feedback              feedbackState
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
	// renderWork records production mutation and compose operations for the
	// deterministic complexity gate. Pointer lifetime follows lineCache.
	renderWork *renderWorkCollector
	// mouseDrag tracks an in-progress press-drag over a draggable chrome zone
	// (a tab or a file-tree row), so a release over a different target can emit
	// a tab_reorder or file_tree_drop gui_action (ticket #2229, AC3). It is nil
	// when no draggable press is active.
	mouseDrag *chromeDrag
	// layout caches the spatial arrangement of every top-level region (header,
	// body, footer, left pane) for the current frame. It is the single source
	// of truth for region positions, replacing the old renderedHeaderHeight
	// cache. Recomputed whenever inputs change: applied commands (chrome) and
	// resize (width/height).
	layout uiLayout
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
	lastCommittedSeq        uint32
	lastCommittedGeneration uint32
	// resyncPending is set when the model rejected a transaction. It drives a
	// subtle footer indicator while the BEAM performs typed-status recovery, and
	// clears when a valid commit applies.
	resyncPending bool
	// lastFrameOutcome is set by the production transaction gate itself. Corpus
	// tests observe it after submission; they never infer or pre-populate status.
	lastFrameOutcome      frameOutcome
	lastTerminalRejection *terminalRejection
	// surfacePlacements is the BEAM's authoritative per-frame surface layout from
	// gui_surface_layout (0xA4, #2268): one rect+z list. Compositing reads the z
	// of a placed surface to order it instead of the old hand-coded
	// overlayLines() precedence chain; the rects equal what BEAM mouse
	// hit-testing uses. Surfaces not yet promoted into the BEAM surface registry
	// keep a reduced hand-ordered chain (transitional split, see overlayLines).
	surfacePlacements []generated.SurfacePlacement
	localPresentation localPresentation
	inputFilter       *InputFilter
	// transcript is the resident agent-chat transcript store (#2654). It folds
	// gui_agent_transcript (0x86) frames and owns the local scroll offset + pin
	// flag so j/k/wheel repaint the transcript same-frame from local data. It is
	// a pointer so it persists across the value-copied Update loop (same lifetime
	// trick as lineCache/latency).
	transcript *residentTranscript
}

// terminalRejection deduplicates an identical deterministic terminal status.
type terminalRejection struct {
	generation uint32
	frameSeq   uint32
	lastGood   uint32
	reason     byte
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
	// generation is echoed on every status event.
	generation uint32
	// staleGeneration marks a delayed transaction from an older recovery lineage.
	staleGeneration bool
	// commands are the buffered semantic/chrome commands in arrival order.
	commands []protocol.Command
}

func New(width, height uint16, out chan<- []byte, filter *InputFilter) Model {
	vp := viewport.New(viewport.WithWidth(int(width)), viewport.WithHeight(1))
	m := Model{
		width:             int(width),
		height:            int(height),
		out:               out,
		viewport:          vp,
		zones:             newZoneManager(),
		windows:           map[uint16]protocol.WindowContent{},
		residentRows:      map[uint16]residentRows{},
		chrome:            map[byte]protocol.ChromePayload{},
		activePalette:     bootstrapPalette(),
		gutters:           map[uint16]protocol.Gutter{},
		indentGuides:      map[uint16]protocol.IndentGuides{},
		extensionRuntimes: map[string]protocol.ExtensionRuntimePayload{},
		latency:           latency.New(),
		hudVisible:        latencyHUDEnvEnabled(),
		lineCache:         newLineCache(),
		renderWork:        &renderWorkCollector{},
		localPresentation: newLocalPresentation(),
		inputFilter:       filter,
		transcript:        newResidentTranscript(),
	}
	// Seed the layout so the first mouse event lands in the correct
	// region before the first BEAM frame arrives.
	m.layout = m.computeLayout()
	m.viewport.SetHeight(m.layout.body.Height)
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
		m.layout = m.computeLayout()
		m.viewport.SetWidth(msg.Width)
		m.viewport.SetHeight(m.layout.body.Height)
		m.send(protocol.EncodeResize(uint16(max(msg.Width, 1)), uint16(max(msg.Height, 1))))
	case tea.KeyPressMsg:
		if m.toggleHUD(msg) {
			break
		}
		if chat, ok := m.agentChat(); ok {
			if packet, handled := m.agent.handleKey(chat, m.agentTranscriptMessages(chat), msg); handled {
				m.send(packet)
				break
			}
		}
		// Local transcript scroll (#2654): when the agent chat owns the view and
		// its composer is not capturing keys, a nav key adjusts the resident scroll
		// offset and repaints same-frame. The key is still forwarded so the BEAM's
		// authoritative scroll/pin state stays in sync (it just no longer gates the
		// paint).
		m.queueAgentTranscriptScroll(msg)
		// Stamp the latency correlation sequence (ticket #2215) before
		// encoding so the resulting frame's commit_frame resolves the sample.
		seq := m.latency.Stamp()
		if packet, ok := keyPacket(msg, seq); ok {
			m.send(packet)
		}
		m.previewCompletionNavigation(msg)
		m.previewPickerNavigation(msg)
		if !m.modalOverlayActive() {
			m.previewFileTreeNavigation(msg)
			m.previewEmptyStateNavigation(msg)
		}
	case tea.PasteMsg:
		m.send(pastePacket(msg))
	case tea.MouseMsg:
		if updated, ok := m.localMouse(msg); ok {
			m = updated
		} else if isWheelButton(msg.Mouse().Button) {
			delta := m.drainScrollDelta(msg)
			m.queueAgentWheelScroll(msg, delta)
			m = m.applyPresentationScrollDelta(msg, delta)
			if !m.sendScrollBatchDelta(msg, delta) {
				if packet, ok := m.mousePacket(msg); ok {
					m.send(packet)
				}
			}
		} else {
			updated, dragPacket, handled := m.handleChromeDrag(msg)
			m = updated
			switch {
			case dragPacket != nil:
				m.send(dragPacket)
			case handled:
			default:
				if packet, ok := m.semanticMousePacket(msg); ok {
					m.send(packet)
				} else if packet, ok := m.mousePacket(msg); ok {
					m.send(packet)
				}
			}
		}
	case agentAnimationTickMsg:
		m.agent.tick()
		if chat, ok := m.agentChat(); ok && m.agent.animating(chat, m.agentTranscriptMessages(chat)) {
			cmd = agentAnimationTick()
		} else {
			m.agent.animationRunning = false
		}
	case feedbackTickMsg:
		m.feedback.tick()
		if status, ok := m.statusBar(); ok {
			m.feedback.updateStatus(status.Message)
		}
		pickerLoading := false
		if picker, ok := m.chrome[generated.OPGuiPicker]; ok && picker.Picker.LoadStatus == 1 {
			pickerLoading = true
		}
		if m.feedback.active() || pickerLoading {
			cmd = feedbackTick()
		} else {
			m.feedback.ticking = false
		}
	case port.PacketMsg:
		cmd = m.applyCommands(msg.Commands)
		m.layout = m.computeLayout()
	case port.LogMsg:
		m.send(protocol.EncodeLogMessage(msg.Level, msg.Text))
	case port.ErrorMsg:
		m.lastError = msg.Err.Error()
		m.send(protocol.EncodeLogMessage(protocol.LogLevelErr, msg.Err.Error()))
	}

	if chat, ok := m.agentChat(); ok && m.agent.animating(chat, m.agentTranscriptMessages(chat)) && !m.agent.animationRunning {
		m.agent.animationRunning = true
		cmd = tea.Batch(cmd, agentAnimationTick())
	}

	if status, ok := m.statusBar(); ok {
		m.feedback.updateStatus(status.Message)
	}
	needsTick := m.feedback.active()
	if !needsTick {
		if picker, ok := m.chrome[generated.OPGuiPicker]; ok && picker.Picker.LoadStatus == 1 {
			needsTick = true
		}
	}
	if needsTick && !m.feedback.ticking {
		m.feedback.ticking = true
		cmd = tea.Batch(cmd, feedbackTick())
	}

	m.viewport.SetWidth(max(m.width, 1))
	m.viewport.SetHeight(m.layout.body.Height)
	m.viewport.SetContent(m.composeBody())
	// The transcript render resolves any queued local scroll and records a pin
	// edge (#2654). Report it to the BEAM so its authoritative follow-bottom state
	// tracks the frontend; rendering already happened without waiting for it.
	m.reportTranscriptPinTransition()
	return m, cmd
}

// reportTranscriptPinTransition sends the pin gui_action for a pin edge produced
// by this frame's transcript render, if any (#2654). The frontend owns the local
// scroll offset; this only keeps the BEAM's authoritative pin state in sync.
func (m *Model) reportTranscriptPinTransition() {
	if m.transcript == nil {
		return
	}
	switch m.transcript.takePinTransition() {
	case pinScrolledAway:
		m.send(protocol.EncodeGUIChatScrolledAwayFromBottom())
	case pinReturned:
		m.send(protocol.EncodeGUIChatReturnedToBottom())
	}
}

// agentTranscriptScrollTarget reports whether local transcript scroll should
// intercept input this frame: the agent chat owns the view and its composer is
// not capturing keys (so a nav key is a scroll, not composer cursor motion).
func (m Model) agentTranscriptScrollTarget() bool {
	if m.transcript == nil {
		return false
	}
	chat, ok := m.agentChat()
	return ok && chat.Visible && !chat.InputFocused
}

// queueAgentTranscriptScroll queues a local transcript scroll for a nav key when
// the agent transcript is the scroll target (#2654). The key is still forwarded
// to the BEAM by the caller.
func (m *Model) queueAgentTranscriptScroll(msg tea.KeyPressMsg) {
	if !m.agentTranscriptScrollTarget() {
		return
	}
	if rows, ok := agentTranscriptScrollRows(msg, m.layout.body.Height); ok {
		m.transcript.scrollBy(rows)
	}
}

// queueAgentWheelScroll queues a local transcript scroll for a wheel event over
// the agent chat body (#2654). Unlike keys this does not need the composer-focus
// gate: a wheel over the transcript always scrolls it.
func (m *Model) queueAgentWheelScroll(msg tea.MouseMsg, delta int) {
	if m.transcript == nil || delta == 0 {
		return
	}
	chat, ok := m.agentChat()
	if !ok || !chat.Visible {
		return
	}
	mouse := msg.Mouse()
	if !m.layout.body.Contains(mouse.X, mouse.Y) {
		return
	}
	// wheelDeltaSign: +down / -up, matching the resident store's row convention.
	m.transcript.scrollBy(delta)
}

// agentTranscriptScrollRows maps a nav key to a signed scroll amount in rendered
// lines (+down toward newest / -up toward oldest). page is the visible height,
// used for half/full-page and jump-to-bottom keys.
func agentTranscriptScrollRows(msg tea.KeyPressMsg, page int) (int, bool) {
	page = max(page, 1)
	half := max(page/2, 1)
	key := msg.Key()
	ctrl := key.Mod.Contains(tea.ModCtrl)
	alt := key.Mod.Contains(tea.ModAlt)
	switch key.Code {
	case 'j':
		if !ctrl && !alt {
			return 1, true
		}
	case 'k':
		if !ctrl && !alt {
			return -1, true
		}
	case 'd':
		if ctrl && !alt {
			return half, true
		}
	case 'u':
		if ctrl && !alt {
			return -half, true
		}
	case 'G':
		if !ctrl && !alt {
			// Jump to bottom: a large downward amount the render clamps and re-pins.
			return 1 << 20, true
		}
	case tea.KeyPgDown:
		return page, true
	case tea.KeyPgUp:
		return -page, true
	}
	return 0, false
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
// triggers typed frame rejection instead of a partial paint.
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
				seq:             command.FrameSeq,
				base:            command.BaseFrameSeq,
				generation:      command.Generation,
				staleGeneration: m.lastCommittedGeneration != 0 && command.Generation < m.lastCommittedGeneration,
				commands:        make([]protocol.Command, 0, 16),
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
// transaction discards staging and emits typed rejection (#2219), except a missing theme on a keyframe latches a protocol error because the BEAM must own theme selection.
func (m *Model) commitStaging(cmds []tea.Cmd, command protocol.Command) []tea.Cmd {
	if m.staging != nil && m.staging.staleGeneration {
		m.staging = nil
		m.lastFrameOutcome = frameOutcomeStale
		return cmds
	}
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
		m.renderWork.fullResets++
	}

	// Validate every window reference against a temporary snapshot before any
	// publication. Missing refs use targeted recovery; wrong epochs reject the
	// entire frame through the generation-aware status contract.
	if failure := m.validateWindowReferences(); failure != nil {
		if failure.targeted {
			m.lastFrameOutcome = frameOutcomeRecoveryRequired
			generation, seq := m.staging.generation, m.staging.seq
			m.send(protocol.EncodeWindowRefMiss(generation, seq, m.lastCommittedSeq, failure.windowID))
			m.staging = nil
			return cmds
		}
		description := "window epoch mismatch"
		if failure.reason == protocol.RejectInvalidRowSplice {
			description = "invalid row splice"
		}
		return m.rejectStaging(cmds, failure.reason, description)
	}

	// Valid: replay the buffer atomically through the live mutation path.
	generation, seq := m.staging.generation, m.staging.seq
	for _, staged := range m.staging.commands {
		m.applyMutation(staged)
	}
	m.lastCommittedSeq = seq
	m.lastCommittedGeneration = generation
	m.staging = nil
	m.lastTerminalRejection = nil
	// A clean commit clears any pending resync indicator: the frontend is back
	// in sync with the BEAM (#2219).
	m.resyncPending = false
	m.lastFrameOutcome = frameOutcomeApplied

	// Commit-gated behaviors: the frame is fully applied and about to be written
	// to the terminal, so resolve the keystroke-to-write latency sample now for
	// the echoed correlation sequence (ticket #2215, resolved on commit).
	m.latency.Resolve(command.InputSeq)
	m.send(protocol.EncodeFrameApplied(generation, seq))
	return cmds
}

// invalidateStaging discards any open transaction and emits one typed
// frame_rejected status. It is the single sink for every invalidation: truncation,
// seq mismatch, base mismatch, a stream error inside a transaction, and an
// out-of-transaction semantic command. The live model keeps the last committed
// frame, so View() never paints a partial. request_keyframe remains reserved for
// an explicit manual retry rather than duplicating automatic typed recovery.
func (m *Model) invalidateStaging(cmds []tea.Cmd, reason string) []tea.Cmd {
	return m.rejectStaging(cmds, rejectionCode(reason), reason)
}

func (m *Model) rejectStaging(cmds []tea.Cmd, reason byte, description string) []tea.Cmd {
	return m.rejectStagingWithDisposition(cmds, reason, protocol.DefaultRejectionDisposition(reason), description)
}

func (m *Model) rejectStagingWithDisposition(cmds []tea.Cmd, reason byte, disposition protocol.RejectionDisposition, description string) []tea.Cmd {
	m.lastFrameOutcome = frameOutcomeRejected
	generation, frameSeq := uint32(0), uint32(0)
	if m.staging != nil {
		generation, frameSeq = m.staging.generation, m.staging.seq
	}
	terminal := terminalRejection{generation: generation, frameSeq: frameSeq, lastGood: m.lastCommittedSeq, reason: reason}
	if disposition != protocol.DispositionTerminal || m.lastTerminalRejection == nil || *m.lastTerminalRejection != terminal {
		m.send(protocol.EncodeFrameRejected(generation, frameSeq, m.lastCommittedSeq, reason, disposition))
	}
	if disposition == protocol.DispositionTerminal {
		m.lastTerminalRejection = &terminal
	}
	m.staging = nil
	// Typed rejection is the automatic recovery trigger. Keep diagnostics and
	// the visible resync state debounced while stale frames from the old credit
	// drain, but never send a second recovery trigger automatically.
	if !m.resyncPending {
		m.resyncPending = true
		m.logToMessages(protocol.LogLevelWarn, "Go TUI frame invalidated (%s), awaiting recovery from %d", description, m.lastCommittedSeq)
	}
	return cmds
}

func rejectionCode(reason string) byte {
	switch {
	case strings.Contains(reason, "begin while open"):
		return protocol.RejectTruncation
	case strings.Contains(reason, "commit_frame"):
		return protocol.RejectCommitSequence
	case strings.Contains(reason, "base mismatch"):
		return protocol.RejectBaseSequence
	case strings.Contains(reason, "missing gui_theme slots"):
		return protocol.RejectIncompleteTheme
	case strings.Contains(reason, "missing gui_theme"):
		return protocol.RejectMissingTheme
	case strings.Contains(reason, "stream error"):
		return protocol.RejectDecodeFailure
	case strings.Contains(reason, "outside frame transaction"):
		return protocol.RejectOutOfTransaction
	default:
		return 255
	}
}

type frameOutcome byte

const (
	frameOutcomeUnknown frameOutcome = iota
	frameOutcomeApplied
	frameOutcomeRecoveryRequired
	frameOutcomeStale
	frameOutcomeRejected
)

type windowReferenceFailure struct {
	windowID uint16
	reason   byte
	targeted bool
}

// validateWindowReferences resolves deltas against a temporary window snapshot.
// It performs no observable writes, so any failure is reported before publication.
func (m *Model) validateWindowReferences() *windowReferenceFailure {
	working := make(map[uint16]protocol.WindowContent, len(m.windows))
	stores := make(map[uint16]residentRows, len(m.residentRows))
	for id, window := range m.windows {
		working[id] = window
	}
	for id, store := range m.residentRows {
		stores[id] = store
	}
	for _, command := range m.staging.commands {
		switch command.Kind {
		case protocol.CommandWindowContent:
			store, err := newResidentRows(command.Window.Rows)
			if err != nil {
				return &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectInvalidRowSplice}
			}
			working[command.Window.ID] = command.Window
			stores[command.Window.ID] = store
		case protocol.CommandWindowDelta:
			previous, ok := working[command.Window.ID]
			if !ok {
				return &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
			}
			if previous.ContentEpoch != command.Window.ContentEpoch {
				return &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectWindowEpoch}
			}
			if command.Window.RowSplicesSet {
				store, exists := stores[command.Window.ID]
				if !exists {
					return &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
				}
				next, refMiss, err := store.splice(command.Window, m.renderWork)
				if err != nil {
					if refMiss {
						return &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
					}
					return &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectInvalidRowSplice}
				}
				stores[command.Window.ID] = next
				previous.Rows = compatibilityRows(next)
			} else if command.Window.Rows != nil {
				store, exists := stores[command.Window.ID]
				if !exists {
					return &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
				}
				next, refMiss, err := store.resolveRows(command.Window.Rows)
				if err != nil {
					return &windowReferenceFailure{windowID: command.Window.ID, targeted: refMiss}
				}
				stores[command.Window.ID] = next
				previous.Rows = compatibilityRows(next)
			}
			working[command.Window.ID] = previous
		}
	}
	return nil
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
		if command.Chrome.Opcode == generated.OPGuiBottomPanel {
			command.Chrome.Bottom = m.mergedBottomPanel(command.Chrome.Bottom)
		}
		m.chrome[command.Chrome.Opcode] = command.Chrome
		switch command.Chrome.Opcode {
		case generated.OPGuiAgentTranscript:
			// Fold the resident transcript delta (#2654). The 0x86 stream, not the
			// chrome snapshot, is the transcript source; the chrome entry is kept
			// only so opcode bookkeeping stays uniform.
			if m.transcript != nil {
				if reason := m.transcript.apply(command.Chrome.AgentTranscript); reason != transcriptApplied {
					// A dropped delta freezes the transcript until the next
					// full_replace; that must never be invisible.
					frame := command.Chrome.AgentTranscript
					m.send(protocol.EncodeLogMessage(protocol.LogLevelWarn,
						fmt.Sprintf("transcript frame dropped: %s (epoch %d, trim %d, base %d, count %d)",
							reason, frame.Epoch, frame.TrimFront, frame.BaseCount, len(frame.Messages))))
				}
			}
		case generated.OPGuiTheme:
			m.activePalette = paletteFromTheme(command.Chrome.Theme)
			m.themeApplied = true
		case generated.OPGuiCursorline:
			m.cursorlineChrome = command.Chrome.CursorlineChrome
		case generated.OPGuiGutter:
			m.gutters[command.Chrome.WindowGutter.WindowID] = command.Chrome.WindowGutter
		case generated.OPGuiIndentGuides:
			m.indentGuides[command.Chrome.IndentGuides.WindowID] = command.Chrome.IndentGuides
		case generated.OPGuiFileTree:
			m.localPresentation.reconcileFileTree()
		case generated.OPGuiFileTreeSelection:
			m.applyFileTreeSelection(command.Chrome.FileTreeSelection)
			m.localPresentation.reconcileFileTree()
		case generated.OPGuiCompletion:
			m.localPresentation.reconcileCompletion()
		case generated.OPGuiPicker:
			m.localPresentation.reconcilePicker()
		case generated.OPGuiBottomPanel:
			m.clampBottomPanelScrollback(command.Chrome.Bottom)
		case generated.OPGuiEmptyState:
			// The launchpad frame's focused_id is authoritative (#2689): a fresh
			// frame reconciles any locally-echoed focus movement.
			m.localPresentation.reconcileEmptyState()
		case generated.OPGuiSurfaceLayout:
			// The authoritative per-frame surface layout (#2268). Replace wholesale
			// each frame: it is a full snapshot, not a delta, and an absent opcode
			// (older BEAM) leaves the prior list which compositing tolerates.
			m.surfacePlacements = command.Chrome.Placements
		}
	}
}

func (m *Model) mergedBottomPanel(next protocol.BottomPanel) protocol.BottomPanel {
	currentPayload, ok := m.chrome[generated.OPGuiBottomPanel]
	if !next.Visible {
		if ok {
			next.StreamInstance = currentPayload.Bottom.StreamInstance
			next.Messages = currentPayload.Bottom.Messages
		}
		return next
	}

	if !ok || currentPayload.Bottom.StreamInstance != next.StreamInstance {
		return next
	}

	seen := make(map[uint32]struct{}, len(currentPayload.Bottom.Messages)+len(next.Messages))
	messages := make([]protocol.PanelMessage, 0, len(currentPayload.Bottom.Messages)+len(next.Messages))
	for _, msg := range currentPayload.Bottom.Messages {
		seen[msg.ID] = struct{}{}
		messages = append(messages, msg)
	}
	for _, msg := range next.Messages {
		if _, ok := seen[msg.ID]; ok {
			continue
		}
		seen[msg.ID] = struct{}{}
		messages = append(messages, msg)
	}
	next.Messages = messages
	return next
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
	store, err := newResidentRows(window.Rows)
	if err != nil {
		m.removeWindow(window.ID)
		return
	}
	m.residentRows[window.ID] = store
	window.Rows = compatibilityRows(store)
	if _, ok := m.windows[window.ID]; !ok {
		m.windowOrder = append(m.windowOrder, window.ID)
		sort.Slice(m.windowOrder, func(i, j int) bool { return m.windowOrder[i] < m.windowOrder[j] })
	}
	m.reconcilePresentationScroll(window)
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
	rowsChanged := delta.Rows != nil || delta.RowSplicesSet
	if !rowsChanged {
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
	if delta.RowSplicesSet {
		m.renderWork.rowUpdates += len(delta.RowSplices)
		store, exists := m.residentRows[delta.ID]
		if !exists {
			m.removeWindow(delta.ID)
			return
		}
		next, _, err := store.splice(delta, m.renderWork)
		if err != nil {
			m.removeWindow(delta.ID)
			return
		}
		m.residentRows[delta.ID] = next
		window.Rows = compatibilityRows(next)
	} else if delta.Rows != nil {
		store, exists := m.residentRows[delta.ID]
		if !exists {
			m.removeWindow(delta.ID)
			return
		}
		next, _, err := store.resolveRows(delta.Rows)
		if err != nil {
			m.removeWindow(delta.ID)
			return
		}
		m.residentRows[delta.ID] = next
		window.Rows = compatibilityRows(next)
	}
	m.reconcilePresentationScroll(window)
	m.windows[delta.ID] = window
	m.refreshCursorFromWindows()
}

func (m *Model) reconcilePresentationScroll(window protocol.WindowContent) {
	m.localPresentation.reconcileScroll(window)
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

func (m *Model) removeWindow(id uint16) {
	delete(m.windows, id)
	delete(m.residentRows, id)
	m.localPresentation.removeWindow(id)
	m.lineCache.dropWindow(id)
	for index, windowID := range m.windowOrder {
		if windowID == id {
			m.windowOrder = append(m.windowOrder[:index], m.windowOrder[index+1:]...)
			return
		}
	}
}

func (m Model) bodyHeight() int {
	return m.layout.body.Height
}

func (m Model) maxOverlayHeight() int {
	return min(max(m.height/3, 4), 12)
}

func (m *Model) drainScrollDelta(msg tea.MouseMsg) int {
	if m.inputFilter != nil {
		delta, _ := m.inputFilter.DrainCoalesced()
		return delta
	}
	return wheelDeltaSign(msg.Mouse().Button)
}

func (m *Model) sendScrollBatchDelta(msg tea.MouseMsg, delta int) bool {
	mouse := msg.Mouse()
	windowID, ok := m.presentationScrollWindowAt(mouse.X, mouse.Y)
	if !ok {
		return false
	}
	if _, ok := m.windows[windowID]; !ok {
		return false
	}

	if delta == 0 {
		return true
	}
	var deltaLines int16
	var direction byte
	if delta > 0 {
		deltaLines = int16(min(delta, 0x7FFF))
		direction = 0
	} else {
		deltaLines = int16(max(delta, -0x7FFF))
		direction = 1
	}

	m.send(protocol.EncodeScrollBatch(windowID, deltaLines, direction))
	return true
}

func (m Model) send(payload []byte) {
	if m.out != nil {
		m.out <- payload
	}
}

func (m Model) logToMessages(level byte, format string, args ...interface{}) {
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

func latestToolMessageIndex(messages []protocol.AgentChatMessage) (uint16, bool) {
	for index := len(messages) - 1; index >= 0; index-- {
		if (messages[index].Kind == agentKindTool || messages[index].Kind == agentKindStyledTool) && index <= 0xFFFF {
			return uint16(index), true
		}
	}
	return 0, false
}

func latestThinkingMessageIndex(messages []protocol.AgentChatMessage) (uint16, bool) {
	for index := len(messages) - 1; index >= 0; index-- {
		if messages[index].Kind == agentKindThinking && index <= 0xFFFF {
			return uint16(index), true
		}
	}
	return 0, false
}
