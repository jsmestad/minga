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
	"github.com/charmbracelet/colorprofile"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/latency"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/jsmestad/minga/go/tui/internal/terminal"
)

const (
	arrowLeft   rune = 57350
	arrowRight  rune = 57351
	arrowUp     rune = 57352
	arrowDown   rune = 57353
	homeKeyCode rune = 57360
	endKeyCode  rune = 57361
	pageUp      rune = 57362
	pageDown    rune = 57363
)

type Model struct {
	width  int
	height int
	out    chan<- []byte
	done   <-chan struct{}
	// capabilities is what this frontend knows about its host terminal. It drives the frontend's fallbacks and is what the BEAM is told.
	capabilities terminal.Capabilities
	// reportedCapabilities is the value the BEAM was last told, so an unchanged value is not sent again.
	reportedCapabilities terminal.Capabilities
	// termcapQueries are the terminfo capabilities Init asks the terminal for. They are set from the environment,
	// because one terminal must not be asked at all.
	termcapQueries []string
	// terminalInBackground is true while the terminal reported that its window lost the focus. Borders dim then.
	// A terminal that reports nothing is treated as focused.
	terminalInBackground bool
	viewport             viewport.Model
	zones                *zoneManager
	presentedClick       *presentedMouseClick
	gitStatusHits        *gitStatusHits
	gitHitRevision       uint64
	windows              map[uint16]protocol.WindowContent
	// residentRows is the indexed, value-semantic authority for window rows.
	// WindowContent.Rows is retained only as a small-fixture compatibility view.
	residentRows      map[uint16]residentRows
	residentSemantics map[uint16]*residentSemanticStore
	windowOrder       []uint16
	chrome            map[byte]protocol.ChromePayload
	activePalette     palette
	themeApplied      bool
	gutters           map[uint16]protocol.Gutter
	indentGuides      map[uint16]protocol.IndentGuides
	cursorRow         uint16
	cursorCol         uint16
	cursorShape       byte
	title             string
	bg                uint32
	cursorlineChrome  protocol.CursorlineChrome
	pendingClipboard  string
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
	// timelineFirstPath is a discardable reading anchor in the BEAM-ordered file list.
	// New offers and review-status changes never select or reveal a file.
	timelineFirstPath string
	agentHelpScroll   int
	agent             agentPanel
	feedback          feedbackState
	now               func() time.Time
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
	// textDrag preserves the pane that owned a body-text press. Drag and release
	// stay attached to that pane even when the pointer crosses another split.
	textDrag *editorTextDrag
	// textPresentations are the immutable presentation identities backing the
	// exact committed model used for input during this Update cycle.
	textPresentations              map[uint16]uint64
	pendingTextPresentations       map[uint16]uint64
	pendingTextPresentationCommit  bool
	pendingTextPresentationDiscard map[textPresentationRef]struct{}
	// layout caches the spatial arrangement of every top-level region (header,
	// body, footer, left pane) for the current frame. It is the single source
	// of truth for region positions, replacing the old renderedHeaderHeight
	// cache. Recomputed whenever inputs change: applied commands (chrome) and
	// resize (width/height).
	layout       uiLayout
	reportedGrid gridSize
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
	// modelineHoverSegment is the 1-based index of the modeline segment under the pointer, 0 for none: a local hover preview whose text is read from the current segments.
	modelineHoverSegment int
	// lastFrameOutcome is set by the production transaction gate itself. Corpus
	// tests observe it after submission; they never infer or pre-populate status.
	lastFrameOutcome      frameOutcome
	lastTerminalRejection *terminalRejection
	// surfacePlacements is the BEAM's per-frame rect+z list from gui_surface_layout.
	// The BEAM hit-tests these rects in primary-grid coordinates. The frontend
	// translates them to screen coordinates for compositing and pointer input.
	surfacePlacements []generated.SurfacePlacement
	localPresentation localPresentation
	// lastPickerFit is the picker row fit last sent to the BEAM, so each picker reports once and again only when its rows change.
	lastPickerFit protocol.PickerFit
	// transcript is the resident agent-chat transcript store (#2654). It folds
	// gui_agent_transcript (0x86) frames and owns the local message anchor + pin
	// flag so j/k/wheel repaint the transcript same-frame from local data. It is
	// a pointer so it persists across the value-copied Update loop (same lifetime
	// trick as lineCache/latency).
	transcript *residentTranscript
	// transcriptRenderer owns the bounded, disposable styled-row cache for the
	// resident transcript. It never owns semantic messages or scroll state.
	transcriptRenderer *agentTranscriptRenderer
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

func New(width, height uint16, out chan<- []byte) Model {
	return NewWithTransport(width, height, out, nil)
}

func NewWithTransport(width, height uint16, out chan<- []byte, done <-chan struct{}) Model {
	vp := viewport.New(viewport.WithWidth(int(width)), viewport.WithHeight(1))
	m := Model{
		width:                          int(width),
		height:                         int(height),
		out:                            out,
		done:                           done,
		capabilities:                   terminal.NewCapabilities(),
		reportedCapabilities:           terminal.NewCapabilities(),
		viewport:                       vp,
		zones:                          newZoneManager(),
		presentedClick:                 &presentedMouseClick{},
		windows:                        map[uint16]protocol.WindowContent{},
		residentRows:                   map[uint16]residentRows{},
		residentSemantics:              map[uint16]*residentSemanticStore{},
		chrome:                         map[byte]protocol.ChromePayload{},
		activePalette:                  bootstrapPalette(),
		gutters:                        map[uint16]protocol.Gutter{},
		indentGuides:                   map[uint16]protocol.IndentGuides{},
		extensionRuntimes:              map[string]protocol.ExtensionRuntimePayload{},
		latency:                        latency.New(),
		hudVisible:                     latencyHUDEnvEnabled(),
		lineCache:                      newLineCache(),
		renderWork:                     &renderWorkCollector{},
		localPresentation:              newLocalPresentation(),
		textPresentations:              map[uint16]uint64{},
		pendingTextPresentationDiscard: map[textPresentationRef]struct{}{},
		transcript:                     newResidentTranscript(),
		transcriptRenderer:             newAgentTranscriptRenderer(),
		now:                            time.Now,
	}
	// Seed the layout so the first mouse event lands in the correct
	// region before the first BEAM frame arrives.
	m.layout = m.computeLayout()
	m.reportedGrid = m.layout.gridSize()
	m.viewport.SetHeight(m.layout.body.Height)
	return m
}

// ReadyPacket reports the initial primary grid, before any BEAM chrome arrives.
func (m Model) ReadyPacket() []byte {
	size := m.layout.gridSize()
	return protocol.EncodeReady(size.cols, size.rows)
}

// WithTerminalEnvironment settles the features the terminal is known to have from the variables it sets.
// The renderer calls it once with the process environment; tests leave it out so they do not depend on the shell they run in.
func (m Model) WithTerminalEnvironment(getenv func(string) string) Model {
	m.capabilities = m.capabilities.WithEnvironment(getenv)
	m.termcapQueries = terminal.TermcapQueries(getenv)
	return m
}

// WithTerminalOverrides applies the features the user forced on or off (terminal.OverridesVariable) and returns one
// message for every entry it could not use. The renderer calls it before WithTerminalEnvironment, so nothing the
// frontend works out by itself replaces the user's choice.
func (m Model) WithTerminalOverrides(value string) (Model, []string) {
	capabilities, problems := m.capabilities.WithOverrides(value)
	m.capabilities = capabilities
	return m, problems
}

// ForcedColorProfile returns the colour profile the program must use because the user forced true colour on or off.
// Without it Bubble Tea detects the profile from the environment, and the report follows what it finds.
func (m Model) ForcedColorProfile() (colorprofile.Profile, bool) {
	forced, on := m.capabilities.Forced(generated.TerminalFeatureTrueColor)
	if !forced {
		return colorprofile.Unknown, false
	}
	if on {
		return colorprofile.TrueColor, true
	}
	return colorprofile.ANSI256, true
}

// TerminalReportPacket reports what is known about the host terminal before it has answered anything: a feature is
// pending unless the terminal is a known one that is taken to have it. It follows the ready packet, so the BEAM knows
// from the start that this frontend has a host terminal.
func (m Model) TerminalReportPacket() []byte {
	return protocol.EncodeTerminalReport(m.capabilities)
}

func (m *Model) reportGridResize() {
	size := m.layout.gridSize()
	if size != m.reportedGrid && m.send(protocol.EncodeResize(size.cols, size.rows)) {
		m.reportedGrid = size
	}
}

func (m Model) currentTime() time.Time {
	if m.now != nil {
		return m.now()
	}
	return time.Now()
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

// Init starts capability detection. Bubble Tea asks the terminal for its colour profile, its keyboard enhancements
// and synchronized output on its own. Asked for here are focus reporting and, where the terminal can be asked safely,
// the terminfo capabilities for styled and coloured underlines. The timeout settles whatever the terminal never answers.
func (m Model) Init() tea.Cmd {
	cmds := []tea.Cmd{tea.Raw(ansi.RequestModeFocusEvent)}
	for _, capability := range m.termcapQueries {
		cmds = append(cmds, tea.RequestCapability(capability))
	}
	return tea.Batch(append(cmds,
		tea.Tick(terminal.DetectionTimeout, func(time.Time) tea.Msg { return capabilityTimeoutMsg{} }),
	)...)
}

// capabilityTimeoutMsg ends the wait for the terminal's answers to capability queries.
type capabilityTimeoutMsg struct{}

// observeTerminal records what a terminal message says about the terminal's features and where the terminal is,
// and tells the BEAM. It never consumes the message.
//
// The terminal's answers arrive one by one right after the start. They are collected, and the report goes out once:
// when the last answer is in, or when the timeout settles the rest. A later change (a first focus event from a
// terminal that answered no query) is reported when it happens.
func (m *Model) observeTerminal(msg tea.Msg) {
	before, wasInBackground := m.capabilities, m.terminalInBackground
	switch msg := msg.(type) {
	case tea.FocusMsg:
		m.send(protocol.EncodeFrontendForeground(true))
		m.capabilities.Resolve(generated.TerminalFeatureFocusReporting, true)
		m.terminalInBackground = false
	case tea.BlurMsg:
		m.send(protocol.EncodeFrontendForeground(false))
		m.capabilities.Resolve(generated.TerminalFeatureFocusReporting, true)
		m.terminalInBackground = true
	case tea.KeyboardEnhancementsMsg:
		m.capabilities.Resolve(generated.TerminalFeatureKittyKeyboard, msg.SupportsKeyDisambiguation())
	case tea.ColorProfileMsg:
		m.capabilities.Resolve(generated.TerminalFeatureTrueColor, msg.Profile == colorprofile.TrueColor)
	case tea.ModeReportMsg:
		// A mode the terminal knows but has permanently off cannot be used, so it counts as absent.
		usable := !msg.Value.IsNotRecognized() && !msg.Value.IsPermanentlyReset()
		switch msg.Mode {
		case ansi.ModeFocusEvent:
			m.capabilities.Resolve(generated.TerminalFeatureFocusReporting, usable)
		case ansi.ModeSynchronizedOutput:
			m.capabilities.Resolve(generated.TerminalFeatureSynchronizedOutput, usable)
		}
	case tea.CapabilityMsg:
		m.capabilities.ObserveTermcap(msg.Content)
	case capabilityTimeoutMsg:
		m.capabilities.Expire()
	default:
		return
	}
	// What is drawn depends on the terminal's features and on where the terminal is, so lines composed before the
	// change are stale.
	if m.capabilities != before || m.terminalInBackground != wasInBackground {
		m.lineCache.reset()
	}
	if m.capabilities != m.reportedCapabilities && !m.capabilities.Pending() && m.send(protocol.EncodeTerminalReport(m.capabilities)) {
		m.reportedCapabilities = m.capabilities
	}
}

func agentAnimationTick() tea.Cmd {
	return tea.Tick(180*time.Millisecond, func(time.Time) tea.Msg {
		return agentAnimationTickMsg{}
	})
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	msg = normalizeTerminalInput(msg)
	m.pendingClipboard = ""
	m.observeTerminal(msg)
	var cmd tea.Cmd
	transitionNow := time.Time{}
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
		m.reportGridResize()
	case tea.KeyPressMsg:
		if m.toggleHUD(msg) {
			break
		}
		component, _ := m.focusedComponent()
		if m.presentAgentHelpKey(msg, component) {
			// Presentation scrolling does not change input ownership; the canonical encoder still forwards supported keys to the BEAM's Help handler.
			seq := m.latency.Stamp()
			if packet, ok := keyPacket(msg, seq); ok {
				m.send(packet)
			}
			break
		}
		if packet, handled := m.localPreviewActivationPacket(msg, component); handled {
			m.send(packet)
			break
		}
		if chat, ok := m.agentChat(); ok && component == "agent" {
			if packet, handled := m.agent.handleKey(chat, m.transcript, msg); handled {
				m.send(packet)
				break
			}
		}
		// Local transcript scroll (#2654): when the agent chat owns the view and
		// its composer is not capturing keys, a nav key adjusts the resident scroll
		// offset and repaints same-frame. The key is still forwarded so the BEAM's
		// authoritative scroll/pin state stays in sync (it just no longer gates the
		// paint).
		if component == "agent" {
			m.queueAgentTranscriptScroll(msg)
		}
		// Stamp the latency correlation sequence (ticket #2215) before
		// encoding so the resulting frame's commit_frame resolves the sample.
		seq := m.latency.Stamp()
		chat, _ := m.agentChat()
		packet, sent := keyPacket(msg, seq, chat.DraftAttachmentOffer)
		if sent {
			m.send(packet)
		}
		switch component {
		case "completion":
			m.previewCompletionNavigation(msg)
		case "picker":
			if sent {
				m.previewPickerNavigation(packet)
			}
		case "file_tree":
			m.previewFileTreeNavigation(msg)
		case "empty_state":
			m.previewEmptyStateNavigation(msg)
		}
	case tea.PasteMsg:
		m.send(pastePacket(msg))
	case tea.MouseMsg:
		if _, motion := msg.(tea.MouseMotionMsg); motion && msg.Mouse().Button == tea.MouseNone {
			m.modelineHoverSegment = m.modelineSegmentUnder(msg)
		}
		hit := m.presentedClick.take()
		if m.textDrag != nil && isEditorTextDragContinuation(msg) {
			updated, packet, handled := m.handleEditorTextMouse(msg)
			m = updated
			if packet != nil {
				m.send(packet)
			}
			if handled {
				break
			}
		}
		if m.mouseDrag != nil && isChromeDragContinuation(msg) {
			updated, packet, _ := m.handleChromeDrag(msg)
			m = updated
			if packet != nil {
				m.send(packet)
			}
			break
		}
		if click, ok := msg.(tea.MouseClickMsg); ok && click.Button == tea.MouseLeft {
			if hit.publicationChanged() {
				break // The press could belong to either side of the terminal write.
			}
			if hit.claimed && !hit.maskedGit {
				if hit.packet != nil {
					m.send(hit.packet)
				}
				break
			}
			if packet, handled := m.pickerPointerPacket(click); handled {
				if packet != nil {
					m.send(packet)
				}
				break
			}
			if hit.maskedGit {
				if packet, _ := m.overlayMousePacket(msg); packet != nil {
					m.send(packet)
				}
				break // Covered Git cells do not fall through to the editor.
			}
		}
		mouse := msg.Mouse()
		if delta, horizontal := wheelScroll(mouse); delta != 0 {
			if horizontal {
				// There is no raw mouse fallback for a horizontal wheel: only
				// an unobscured editor pane can accept a column displacement.
				if m.layout.body.Contains(mouse.X, mouse.Y) && !m.editorTextOccluded(mouse.X, mouse.Y) {
					m.scrollWindowByWheel(mouse, delta, true)
				}
				break
			}
			if updated, ok := m.localMouse(msg); ok {
				m = updated
				break
			}
			if m.sendAgentPromptScroll(msg, delta) {
				break
			}
			m.queueAgentWheelScroll(msg, delta)
			if !m.scrollWindowByWheel(mouse, delta, false) {
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
					if packet != nil {
						m.send(packet)
					}
				} else if updated, packet, handled := m.handleEditorTextMouse(msg); handled {
					m = updated
					if packet != nil {
						m.send(packet)
					}
				} else if packet, ok := m.mousePacket(msg); ok {
					m.send(packet)
				}
			}
		}
	case agentAnimationTickMsg:
		m.agent.tick()
		if chat, ok := m.agentChat(); ok && m.agentAnimating(chat) {
			cmd = agentAnimationTick()
		} else {
			m.agent.animationRunning = false
		}
	case feedbackTickMsg:
		// The command that produced this message owns the frame timestamp. Using
		// it here keeps every threshold deterministic and lets a final late tick
		// drain without consulting the wall clock.
		transitionNow = msg.at
		m.feedback.ticking = false
		m.feedback.tick(msg.at)
	case port.PacketMsg:
		cmd = m.applyCommands(msg.Commands)
		m.layout = m.computeLayout()
		m.publishTextPresentationInputModel()
		m.reportGridResize()
	case port.LogMsg:
		m.send(protocol.EncodeLogMessage(msg.Level, msg.Text))
	}

	if chat, ok := m.agentChat(); ok && m.agentAnimating(chat) && !m.agent.animationRunning {
		m.agent.animationRunning = true
		cmd = tea.Batch(cmd, agentAnimationTick())
	}

	if transitionNow.IsZero() {
		transitionNow = m.currentTime()
	}
	if status, ok := m.statusBar(); ok {
		m.feedback.transition(status.Operation, transitionNow)
	} else {
		m.feedback.transition(nil, transitionNow)
	}
	pickerLoading := false
	if picker, ok := m.chrome[generated.OPGuiPicker]; ok && picker.Picker.LoadStatus == 1 {
		pickerLoading = true
	}
	if delay, needsTick := m.feedback.nextTick(transitionNow, pickerLoading); needsTick && !m.feedback.ticking {
		m.feedback.ticking = true
		cmd = tea.Batch(cmd, feedbackTick(delay))
	}

	m.reportAgentPromptFit()
	m.reportPickerFit()
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
	page := 1
	if agentTranscriptUsesPageSize(msg) {
		page = m.agentTranscriptPageSize()
	}
	if rows, ok := agentTranscriptScrollRows(msg, page); ok {
		m.transcript.scrollBy(rows)
	}
}

func agentTranscriptUsesPageSize(msg tea.KeyPressMsg) bool {
	key := msg.Key()
	return (key.Mod == tea.ModCtrl && (key.Code == 'd' || key.Code == 'u')) ||
		(key.Mod == 0 && (key.Code == tea.KeyPgDown || key.Code == tea.KeyPgUp))
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
	m.transcript.scrollBy(delta)
}

// agentTranscriptScrollRows maps a nav key to a signed scroll amount in rendered
// lines (+down toward newest / -up toward oldest). page is the visible height,
// used for half/full-page and jump-to-bottom keys.
func agentTranscriptScrollRows(msg tea.KeyPressMsg, page int) (int, bool) {
	page = max(page, 1)
	half := max(page/2, 1)
	key := msg.Key()
	switch key.Code {
	case 'j':
		if key.Mod == 0 {
			return 1, true
		}
	case 'k':
		if key.Mod == 0 {
			return -1, true
		}
	case 'd':
		if key.Mod == tea.ModCtrl {
			return half, true
		}
	case 'u':
		if key.Mod == tea.ModCtrl {
			return -half, true
		}
	case 'G':
		// Synthetic form: a key built with the uppercase rune and no modifier.
		if key.Mod == 0 || key.Mod == tea.ModShift {
			// Jump to bottom: a large downward amount the render clamps and re-pins.
			return 1 << 20, true
		}
	case 'g':
		// A PTY delivers uppercase letters as the lowercase code plus ModShift
		// (ultraviolet EventDecoder.parseUtf8), so shift+g is the real G key.
		if key.Mod == tea.ModShift {
			return 1 << 20, true
		}
	case tea.KeyPgDown:
		if key.Mod == 0 {
			return page, true
		}
	case tea.KeyPgUp:
		if key.Mod == 0 {
			return -page, true
		}
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
	content, hits := m.renderBody()
	if !hits.sameTargets(m.gitStatusHits) {
		m.gitHitRevision++
	}
	m.gitStatusHits = hits
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
		parts := m.headerLines()[:m.layout.header.Height]
		if m.layout.body.Height > 0 {
			parts = append(parts, m.viewport.View())
		}
		if gap := m.layout.footer.Y - m.layout.body.Y - m.layout.body.Height; gap > 0 {
			blank := strings.Repeat(" ", max(m.width, 1))
			for range gap {
				parts = append(parts, blank)
			}
		}
		parts = append(parts, m.footerLines()[:m.layout.footer.Height]...)
		content = m.zones.Scan(lipgloss.JoinVertical(lipgloss.Left, parts...))
	}
	frame, layers := m.composeFrameWithLayers(content)
	out := m.cursorStyleSequence() + frame + m.latencyHUDSequence()
	if m.zones != nil && len(m.zones.approvalMarkers) != 0 {
		if m.transcriptRenderer != nil {
			m.transcriptRenderer.retainApprovalMarkers(m.zones)
		}
		m.zones.retireUnreferencedApprovals()
	}
	if m.pendingClipboard != "" {
		out += ansi.SetClipboard(ansi.SystemClipboard, m.pendingClipboard)
	}
	if m.protocolError == "" && m.gitStatusHits != nil {
		// Bubble Tea compares Content, but not OnMouse, when deciding whether
		// to publish a new View. This trailing SGR paints no cells and makes
		// target-only changes (such as a new panel ID) publishable.
		out += fmt.Sprintf("\x1b[0:%dm", m.gitHitRevision)
	}
	view := tea.NewView(out)
	view.AltScreen = true
	// The terminal reports when its window gets or loses the focus (mode 1004), which the BEAM hears as frontend_foreground.
	view.ReportFocus = true
	view.MouseMode = tea.MouseModeCellMotion
	view.WindowTitle = m.title
	view.BackgroundColor = m.editorBackground()
	view.ForegroundColor = m.palette().Text()
	if m.protocolError == "" {
		view.OnMouse = m.presentedMouseHandler(layers)
	}
	if chat, ok := m.agentChat(); ok && chat.Visible {
		view.Cursor = m.agentPromptCursor()
	} else {
		view.Cursor = m.residentCursor()
	}
	return view
}

func (m Model) residentCursor() *tea.Cursor {
	for _, id := range m.windowOrder {
		window := m.windows[id]
		semantics := m.residentSemanticsFor(window)
		if semantics == nil {
			continue
		}
		if !semantics.cursor.Eligible {
			continue
		}
		gutter, hasGutter := m.windowGutter(id)
		width, height := m.windowRenderDimensions(window, hasGutter, gutter)
		start := m.presentationSourceStart(window, height)
		row := int(semantics.cursor.Row)
		if row < start || row >= start+height {
			continue
		}
		scrollLeft := m.presentationScrollEffectiveLeft(window)
		col := int(semantics.cursor.Col) - scrollLeft
		if col < 0 {
			continue
		}
		width, _, _ = windowRowComposition(window, width, height, start)
		textWidth := windowTextWidth(width, gutter)
		if authoredWidth := int(window.Geometry.TextRect.Width); authoredWidth > 0 {
			textWidth = min(textWidth, authoredWidth)
		}
		if col >= textWidth {
			continue
		}
		x := int(window.Geometry.TextRect.Col) + col
		y := m.layout.grid.Y + int(window.Geometry.TextRect.Row) + (row - start)
		if y < m.layout.body.Y || y >= m.layout.body.Y+m.layout.body.Height {
			continue
		}
		cursor := tea.NewCursor(x, y)
		switch window.CursorShape {
		case 1:
			cursor.Shape = tea.CursorBar
		case 2:
			cursor.Shape = tea.CursorUnderline
		default:
			cursor.Shape = tea.CursorBlock
		}
		return cursor
	}
	return nil
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
		case protocol.CommandRendererShutdown:
			// Out of band: the BEAM is stopping and waits for this process to
			// exit. Quitting lets Bubble Tea restore the terminal; any open
			// transaction is abandoned with the session.
			m.staging = nil
			cmds = append(cmds, tea.Quit)
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
		m.discardStagedTextPresentations()
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
	}

	transcriptPlan, transcriptFailure := m.prepareTranscriptPlan()
	if transcriptFailure != transcriptApplied {
		return m.rejectStaging(
			cmds,
			protocol.RejectTranscriptDesync,
			fmt.Sprintf("transcript frame rejected: %s", transcriptFailure),
		)
	}

	// Validate every window reference against a temporary snapshot before any
	// publication. Missing refs use targeted recovery; wrong epochs reject the
	// entire frame through the generation-aware status contract.
	windowSnapshot, failure := m.validateWindowReferences()
	if failure != nil {
		if failure.targeted {
			m.lastFrameOutcome = frameOutcomeRecoveryRequired
			generation, seq := m.staging.generation, m.staging.seq
			m.send(protocol.EncodeWindowRefMiss(generation, seq, m.lastCommittedSeq, failure.windowID))
			m.discardStagedTextPresentations()
			m.staging = nil
			return cmds
		}
		description := "window epoch mismatch"
		switch failure.reason {
		case protocol.RejectInvalidRetainedRows:
			description = "invalid retained rows or resident semantics"
		case protocol.RejectInvalidRowSplice:
			description = "invalid row splice"
		}
		return m.rejectStaging(cmds, failure.reason, description)
	}

	gutterCandidate, gutterFailure := m.prepareGutterCandidate(windowSnapshot)
	if gutterFailure != nil {
		if gutterFailure.targeted {
			m.lastFrameOutcome = frameOutcomeRecoveryRequired
			generation, seq := m.staging.generation, m.staging.seq
			m.send(protocol.EncodeWindowRefMiss(generation, seq, m.lastCommittedSeq, gutterFailure.windowID))
			m.discardStagedTextPresentations()
			m.staging = nil
			return cmds
		}
		return m.rejectStaging(cmds, gutterFailure.reason, gutterFailure.description)
	}

	if transcriptPlan != nil {
		transcriptPlan.commit()
	}
	if m.staging.base == 0 {
		m.retireMissingWindows(windowSnapshot.windows)
		m.lineCache.reset()
		m.renderWork.fullResets++
	}

	// Publish the validated row roots; replay only the remaining mutations.
	generation, seq := m.staging.generation, m.staging.seq
	nextTextPresentations, unusedTextPresentations := stagedTextPresentations(m.staging.commands)
	for id := range windowSnapshot.updated {
		m.publishWindow(windowSnapshot.windows[id], windowSnapshot.stores[id])
	}
	if len(windowSnapshot.updated) > 0 {
		m.refreshCursorFromWindows()
	}
	for _, staged := range m.staging.commands {
		if staged.Kind == protocol.CommandWindowDelta {
			m.renderWork.rowUpdates += len(staged.Window.RowSplices)
		}
		if staged.Kind == protocol.CommandWindowContent || staged.Kind == protocol.CommandWindowDelta {
			continue
		}
		m.applyMutation(staged)
	}
	m.scrollAgentHelp(0)
	// Gutter state is prepared as a detached frame candidate so retain updates,
	// keyframe clears, and structural replacements publish atomically.
	m.gutters = gutterCandidate
	m.residentSemantics = windowSnapshot.semantics
	m.queueCommittedTextPresentations(nextTextPresentations, unusedTextPresentations)
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

// prepareTranscriptPlan simulates every transcript command in arrival order.
// Its overlay contains only affected entries; all resident pages stay read-only.
func (m *Model) prepareTranscriptPlan() (*transcriptPlan, transcriptDropReason) {
	var plan *transcriptPlan
	for _, command := range m.staging.commands {
		if command.Kind != protocol.CommandChrome || command.Chrome.Opcode != generated.OPGuiAgentTranscript {
			continue
		}
		if plan == nil {
			plan = m.transcript.prepare()
		}
		if reason := plan.apply(command.Chrome.AgentTranscript); reason != transcriptApplied {
			return nil, reason
		}
	}
	return plan, transcriptApplied
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
	m.discardStagedTextPresentations()
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

type windowReferenceSnapshot struct {
	windows   map[uint16]protocol.WindowContent
	stores    map[uint16]residentRows
	semantics map[uint16]*residentSemanticStore
	updated   map[uint16]bool
}

type wrappedSemanticBasis struct {
	hydration bool
	splices   []protocol.WindowRowSplice
}

type gutterReferenceFailure struct {
	windowID    uint16
	reason      byte
	targeted    bool
	description string
}

// validateWindowReferences resolves deltas against a temporary window snapshot.
// It performs no observable writes, so any failure is reported before publication.
func (m *Model) validateWindowReferences() (*windowReferenceSnapshot, *windowReferenceFailure) {
	retained := 0
	if m.staging.base != 0 {
		retained = len(m.windows)
	}
	working := make(map[uint16]protocol.WindowContent, retained)
	stores := make(map[uint16]residentRows, retained)
	semantics := make(map[uint16]*residentSemanticStore, retained)
	initializedSemantics := make(map[uint16]bool, retained)
	pendingSemantics := make(map[uint16]bool)
	updated := make(map[uint16]bool)
	wrappedUpdates := make(map[uint16]wrappedSemanticBasis)
	if m.staging.base != 0 {
		for id, window := range m.windows {
			working[id] = window
		}
		for id, store := range m.residentRows {
			stores[id] = store
		}
		for id, semantic := range m.residentSemantics {
			semantics[id] = semantic
			initializedSemantics[id] = true
		}
	}
	for _, command := range m.staging.commands {
		switch command.Kind {
		case protocol.CommandWindowContent:
			store, err := buildWindowRowStore(command.Window)
			if err != nil {
				return nil, &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectInvalidRowSplice}
			}
			id := command.Window.ID
			window := command.Window
			window.Rows = compatibilityRows(store)
			working[id], stores[id], updated[id] = window, store, true
			if store.mode == wrappedRows {
				wrappedUpdates[id] = wrappedSemanticBasis{hydration: true}
			} else {
				delete(wrappedUpdates, id)
			}
			if !store.complete() {
				delete(semantics, id)
				delete(pendingSemantics, id)
			} else if store.mode == wrappedRows || initializedSemantics[id] || semantics[id] != nil {
				pendingSemantics[id] = true
			}
		case protocol.CommandWindowDelta:
			previous, ok := working[command.Window.ID]
			if !ok {
				return nil, &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
			}
			if previous.ContentEpoch != command.Window.ContentEpoch {
				return nil, &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectWindowEpoch}
			}
			if command.Window.RowSplicesSet {
				store, exists := stores[command.Window.ID]
				if !exists {
					return nil, &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
				}
				if store.mode == wrappedRows && len(command.Window.RowSplices) > 0 {
					if _, pending := wrappedUpdates[command.Window.ID]; pending {
						return nil, &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectInvalidRetainedRows}
					}
					wrappedUpdates[command.Window.ID] = wrappedSemanticBasis{splices: command.Window.RowSplices}
				}
				next, refMiss, err := store.splice(command.Window, m.renderWork)
				if err != nil {
					if refMiss {
						return nil, &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
					}
					return nil, &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectInvalidRowSplice}
				}
				stores[command.Window.ID] = next
				if len(command.Window.RowSplices) > 0 {
					previous.Rows = compatibilityRows(next)
				}
				if next.complete() && (next.mode == sequentialRows || len(command.Window.RowSplices) > 0) &&
					(initializedSemantics[command.Window.ID] || semantics[command.Window.ID] != nil) {
					pendingSemantics[command.Window.ID] = true
				}
			} else if command.Window.Rows != nil {
				store, exists := stores[command.Window.ID]
				if !exists {
					return nil, &windowReferenceFailure{windowID: command.Window.ID, targeted: true}
				}
				if store.mode == wrappedRows {
					return nil, &windowReferenceFailure{windowID: command.Window.ID, reason: protocol.RejectInvalidRowSplice}
				}
				next, refMiss, err := store.resolveRows(command.Window.Rows)
				if err != nil {
					return nil, &windowReferenceFailure{windowID: command.Window.ID, targeted: refMiss}
				}
				stores[command.Window.ID] = next
				previous.Rows = compatibilityRows(next)
				if next.complete() && (initializedSemantics[command.Window.ID] || semantics[command.Window.ID] != nil) {
					pendingSemantics[command.Window.ID] = true
				}
			}
			working[command.Window.ID] = mergeWindowDelta(previous, command.Window)
			updated[command.Window.ID] = true
		case protocol.CommandResidentSemantics:
			wire := command.ResidentSemantics
			window, windowOK := working[wire.WindowID]
			store, storeOK := stores[wire.WindowID]
			if !windowOK || !storeOK {
				return nil, &windowReferenceFailure{windowID: wire.WindowID, reason: protocol.RejectInvalidRetainedRows}
			}
			if store.mode == wrappedRows {
				basis := wrappedUpdates[wire.WindowID]
				if (basis.hydration && wire.Mode != 0) || !residentSplicesMatch(basis.splices, wire.RowSplices) {
					return nil, &windowReferenceFailure{windowID: wire.WindowID, reason: protocol.RejectInvalidRetainedRows}
				}
				delete(wrappedUpdates, wire.WindowID)
			}
			next, err := applyResidentSemantics(semantics[wire.WindowID], wire, window, store)
			if err != nil {
				return nil, &windowReferenceFailure{windowID: wire.WindowID, reason: protocol.RejectInvalidRetainedRows}
			}
			semantics[wire.WindowID] = next
			initializedSemantics[wire.WindowID] = true
			delete(pendingSemantics, wire.WindowID)
		}
	}
	for id, window := range working {
		store := stores[id]
		if store.complete() && (!window.GeometrySet || store.count() != int(window.Geometry.TotalVisualRows) || store.lineCount() != int(window.Geometry.TotalLines)) {
			return nil, &windowReferenceFailure{windowID: id, reason: protocol.RejectInvalidRetainedRows}
		}
		if store.mode == wrappedRows {
			anchorRank, anchorOK := store.wrappedAnchor(window.Scroll)
			maxAnchorRank := max(store.count()-int(window.Geometry.ViewportRows), 0)
			if !window.ScrollSet || !window.Scroll.Wrapped || !anchorOK || store.count() > maxResidentSemanticRows ||
				window.Scroll.AnchorTop != window.Geometry.ViewportTop ||
				uint32(window.Scroll.AnchorVisualRowOffset) != window.Geometry.VisualRowOffset ||
				anchorRank > maxAnchorRank {
				return nil, &windowReferenceFailure{windowID: id, reason: protocol.RejectInvalidRetainedRows}
			}
		}
		if semantic, ok := semantics[id]; ok {
			firstID, lastID := uint64(0), uint64(0)
			if store.count() > 0 {
				first, firstOK := store.get(0)
				last, lastOK := store.get(store.count() - 1)
				if !firstOK || !lastOK {
					return nil, &windowReferenceFailure{windowID: id, reason: protocol.RejectInvalidRetainedRows}
				}
				firstID, lastID = first.ID, last.ID
			}
			if semantic.rowCount != uint32(store.count()) || semantic.firstRowID != firstID || semantic.lastRowID != lastID {
				return nil, &windowReferenceFailure{windowID: id, reason: protocol.RejectInvalidRetainedRows}
			}
		}
	}
	var pendingWindowID uint16
	hasPendingWindow := false
	for id := range pendingSemantics {
		if !hasPendingWindow || id < pendingWindowID {
			pendingWindowID = id
			hasPendingWindow = true
		}
	}
	if hasPendingWindow {
		return nil, &windowReferenceFailure{windowID: pendingWindowID, reason: protocol.RejectInvalidRetainedRows}
	}
	return &windowReferenceSnapshot{windows: working, stores: stores, semantics: semantics, updated: updated}, nil
}

func residentSplicesMatch(text []protocol.WindowRowSplice, semantics []protocol.ResidentRowSplice) bool {
	if len(text) != len(semantics) {
		return false
	}
	for i, splice := range semantics {
		if splice.Start != text[i].StartIndex || splice.DeleteCount != text[i].DeleteCount || int(splice.InsertCount) != len(text[i].InsertRows) {
			return false
		}
	}
	return true
}

// prepareGutterCandidate resolves resident gutter updates against the frame's
// already-validated window snapshot. A keyframe starts from an empty gutter
// set; a delta starts from the last committed set. Nothing here mutates live
// state, so a failed retain key or document extent cannot partially publish.
func (m *Model) prepareGutterCandidate(snapshot *windowReferenceSnapshot) (map[uint16]protocol.Gutter, *gutterReferenceFailure) {
	candidate := make(map[uint16]protocol.Gutter, len(m.gutters))
	if m.staging.base != 0 {
		for id, gutter := range m.gutters {
			candidate[id] = gutter
		}
	}

	for _, command := range m.staging.commands {
		if command.Kind != protocol.CommandChrome || command.Chrome.Opcode != generated.OPGuiGutter {
			continue
		}
		next := command.Chrome.WindowGutter
		if next.DecodeError != "" {
			return nil, &gutterReferenceFailure{windowID: next.WindowID, reason: protocol.RejectDecodeFailure, description: next.DecodeError}
		}
		if next.Resident == nil {
			candidate[next.WindowID] = next
			continue
		}

		window, windowOK := snapshot.windows[next.WindowID]
		store, storeOK := snapshot.stores[next.WindowID]
		if !windowOK || !storeOK {
			return nil, &gutterReferenceFailure{windowID: next.WindowID, targeted: true}
		}
		if window.ContentEpoch != next.Resident.ContentEpoch {
			return nil, &gutterReferenceFailure{windowID: next.WindowID, reason: protocol.RejectWindowEpoch, description: "gutter content epoch mismatch"}
		}
		if !store.complete() {
			return nil, &gutterReferenceFailure{windowID: next.WindowID, reason: protocol.RejectInvalidRetainedRows, description: "resident gutter requires a complete row store"}
		}
		if store.lineCount() != int(next.Resident.LineCount) {
			return nil, &gutterReferenceFailure{windowID: next.WindowID, reason: protocol.RejectInvalidRetainedRows, description: "gutter line count mismatch"}
		}

		if next.Resident.RetainOverrides {
			previous, ok := m.gutters[next.WindowID]
			if m.staging.base == 0 || !ok || previous.Resident == nil || previous.Resident.ContentEpoch != next.Resident.ContentEpoch || previous.Resident.LineCount != next.Resident.LineCount {
				return nil, &gutterReferenceFailure{windowID: next.WindowID, targeted: true}
			}
			// The cache uses the immutable overrides snapshot as its identity.
			next.Resident = previous.Resident
		}
		candidate[next.WindowID] = next
	}
	return candidate, nil
}

// applyMutation handles commands that have no prepared resident snapshot.
func (m *Model) applyMutation(command protocol.Command) {
	switch command.Kind {
	case protocol.CommandSetCursorShape:
		m.cursorShape = command.CursorShape
	case protocol.CommandSetTitle:
		m.title = command.Title
	case protocol.CommandSetWindowBg:
		m.bg = command.WindowBg
	case protocol.CommandTextPresentation:
		// Presentation identities publish as one complete map at commit. Keeping
		// this command mutation-free prevents a partial replay from changing input.
	case protocol.CommandClipboardWrite:
		m.pendingClipboard = command.ClipboardText
	case protocol.CommandExtensionRuntime:
		m.applyExtensionRuntime(command.ExtensionRuntime)
	case protocol.CommandChrome:
		// Transcript commands were consumed by the sole resident owner after
		// validation. Never replay or retain their decoded payload in chrome.
		if command.Chrome.Opcode == generated.OPGuiAgentTranscript {
			return
		}
		if command.Chrome.Opcode == generated.OPGuiAgentHelp {
			previous, _ := m.agentHelp()
			if !command.Chrome.AgentHelp.Visible || !previous.Visible {
				m.agentHelpScroll = 0
			}
		}
		if command.Chrome.Opcode == generated.OPGuiBottomPanel {
			command.Chrome.Bottom = m.mergedBottomPanel(command.Chrome.Bottom)
		}
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
		case generated.OPGuiFileTree:
			m.reconcileFileTree(command.Chrome.Tree)
		case generated.OPGuiFileTreeSelection:
			m.applyFileTreeSelection(command.Chrome.FileTreeSelection)
		case generated.OPGuiCompletion:
			m.reconcileCompletion(command.Chrome.Complete)
		case generated.OPGuiCompletionSelection:
			m.applyCompletionSelection(command.Chrome.CompletionSelection)
		case generated.OPGuiPicker:
			m.reconcilePicker(command.Chrome.Picker)
		case generated.OPGuiPickerSelection:
			m.applyPickerSelection(command.Chrome.PickerSelection)
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

func buildWindowRowStore(window protocol.WindowContent) (residentRows, error) {
	mode := windowedRows
	if window.WrappedResidentRows {
		if window.SequentialRows {
			return residentRows{}, fmt.Errorf("conflicting resident row modes")
		}
		mode = wrappedRows
	} else if window.SequentialRows {
		mode = sequentialRows
	}
	return newResidentRows(window.Rows, mode)
}

func (m *Model) publishWindow(window protocol.WindowContent, store residentRows) {
	previous, hadWindow := m.residentRows[window.ID]
	if hadWindow && (previous.mode != store.mode || (store.mode == wrappedRows && previous.root != store.root)) {
		m.localPresentation.removeWindow(window.ID)
		m.lineCache.dropWindow(window.ID)
	}
	m.residentRows[window.ID] = store
	if _, ok := m.windows[window.ID]; !ok {
		m.windowOrder = append(m.windowOrder, window.ID)
		sort.Slice(m.windowOrder, func(i, j int) bool { return m.windowOrder[i] < m.windowOrder[j] })
	}
	m.reconcilePresentationScroll(window)
	window.Scroll.ResetRequired = false
	m.windows[window.ID] = window
}

func mergeWindowDelta(window, delta protocol.WindowContent) protocol.WindowContent {
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
	if delta.AccessibilitySet {
		window.AccessibilityGeneration = delta.AccessibilityGeneration
		window.AccessibilitySet = true
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
	return window
}

func (m *Model) reconcilePresentationScroll(window protocol.WindowContent) {
	anchor := 0
	if window.WrappedResidentRows {
		anchor, _ = m.residentRows[window.ID].wrappedAnchor(window.Scroll)
	}
	m.localPresentation.reconcileScroll(window, anchor)
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

func (m *Model) discardWindowState(id uint16) {
	delete(m.windows, id)
	delete(m.residentSemantics, id)
	delete(m.residentRows, id)
	delete(m.gutters, id)
	delete(m.indentGuides, id)
	m.localPresentation.removeWindow(id)
	if m.textDrag != nil && m.textDrag.windowID == id {
		m.textDrag = nil
	}
}

func (m *Model) retireMissingWindows(next map[uint16]protocol.WindowContent) {
	for id := range m.windows {
		if _, retained := next[id]; !retained {
			m.discardWindowState(id)
		}
	}
	order := m.windowOrder[:0]
	for _, id := range m.windowOrder {
		if _, retained := next[id]; retained {
			order = append(order, id)
		}
	}
	m.windowOrder = order
}

func (m Model) bodyHeight() int {
	return m.layout.body.Height
}

func (m Model) maxOverlayHeight() int {
	return min(max(m.layout.grid.Height/3, 4), maxPopupRows)
}

func (m Model) send(payload []byte) bool {
	if m.out == nil {
		return false
	}
	if m.done != nil {
		select {
		case <-m.done:
			return false
		default:
		}
	}
	select {
	case <-m.done:
		return false
	case m.out <- payload:
		return true
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

func latestToolMessageID(messages *residentTranscript) (uint32, bool) {
	message, found := messages.latest(transcriptSummaryTool)
	return message.ID, found
}

func latestThinkingMessageID(messages *residentTranscript) (uint32, bool) {
	message, found := messages.latest(transcriptSummaryThinking)
	return message.ID, found
}
