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
	// mouseDrag tracks an in-progress press-drag over a draggable chrome zone
	// (a tab or a file-tree row), so a release over a different target can emit
	// a tab_reorder or file_tree_drop gui_action (ticket #2229, AC3). It is nil
	// when no draggable press is active.
	mouseDrag *chromeDrag
}

func New(width, height uint16, out chan<- []byte) Model {
	vp := viewport.New(viewport.WithWidth(int(width)), viewport.WithHeight(max(int(height)-3, 1)))
	return Model{
		width:             int(width),
		height:            int(height),
		out:               out,
		viewport:          vp,
		zones:             newZoneManager(),
		windows:           map[uint16]protocol.WindowContent{},
		chrome:            map[byte]protocol.ChromePayload{},
		activePalette:     defaultPalette(),
		gutters:           map[uint16]protocol.Gutter{},
		indentGuides:      map[uint16]protocol.IndentGuides{},
		extensionRuntimes: map[string]protocol.ExtensionRuntimePayload{},
		latency:           latency.New(),
		// MINGA_LATENCY_HUD=1 shows the latency overlay at boot; it is also
		// toggled at runtime with ctrl+alt+l (ticket #2215).
		hudVisible: latencyHUDEnvEnabled(),
	}
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
		m.viewport.SetWidth(msg.Width)
		m.viewport.SetHeight(m.bodyHeight())
		m.send(protocol.EncodeResize(uint16(max(msg.Width, 1)), uint16(max(msg.Height, 1))))
	case tea.KeyPressMsg:
		if m.toggleHUD(msg) {
			break
		}
		// Stamp the latency correlation sequence (ticket #2215) before
		// encoding so the resulting frame's batch_end resolves the sample.
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
				} else {
					m.send(mousePacket(msg))
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
	m.viewport.SetContent(m.content())
	return m, cmd
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

func (m *Model) applyCommands(commands []protocol.Command) tea.Cmd {
	cmds := make([]tea.Cmd, 0, 1)
	for _, command := range commands {
		switch command.Kind {
		case protocol.CommandBatchEnd:
			// The frame is now fully applied and about to be written to the
			// terminal; resolve the keystroke-to-write latency sample for the
			// echoed correlation sequence (ticket #2215).
			m.latency.Resolve(command.BatchSeq)
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
		case protocol.CommandProtocolError:
			// The BEAM rejected this frontend's handshake protocol_version. Log
			// to stderr and latch the reason so View renders a blocking error
			// surface instead of leaving a blank screen (ticket #2237).
			m.protocolError = command.ProtocolError
			fmt.Fprintf(os.Stderr, "minga: protocol error: %s\n", command.ProtocolError)
		case protocol.CommandChrome:
			m.chrome[command.Chrome.Opcode] = command.Chrome
			switch command.Chrome.Opcode {
			case generated.OPGuiTheme:
				m.activePalette = paletteFromTheme(command.Chrome.Theme)
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
			}
		}
	}
	return tea.Batch(cmds...)
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
	if len(delta.Rows) > 0 {
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

func (m Model) maxOverlayHeight() int {
	return min(max(m.height/3, 4), 12)
}

func (m Model) send(payload []byte) {
	if m.out != nil {
		m.out <- payload
	}
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
