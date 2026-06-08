package ui

import (
	"fmt"
	"sort"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
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
	width                 int
	height                int
	out                   chan<- []byte
	viewport              viewport.Model
	zones                 *zoneManager
	windows               map[uint16]protocol.WindowContent
	windowOrder           []uint16
	chrome                map[byte]protocol.ChromePayload
	activePalette         palette
	gutters               map[uint16]protocol.Gutter
	indentGuides          map[uint16]protocol.IndentGuides
	cells                 map[position]cell
	drawSeq               uint64
	cursorRow             uint16
	cursorCol             uint16
	cursorShape           byte
	title                 string
	bg                    uint32
	cursorlineChrome      protocol.CursorlineChrome
	pendingClipboard      string
	lastError             string
	bottomPanelScrollback int
	agentAnimationFrame   uint64
	agentAnimationRunning bool
}

type position struct {
	row uint16
	col uint16
}

type cell struct {
	text  string
	fg    uint32
	bg    uint32
	attrs uint16
	// seq records the draw-command order so overlapping cells replay
	// deterministically, instead of in Go's randomized map order.
	seq uint64
}

func New(width, height uint16, out chan<- []byte) Model {
	vp := viewport.New(viewport.WithWidth(int(width)), viewport.WithHeight(max(int(height)-3, 1)))
	return Model{
		width:         int(width),
		height:        int(height),
		out:           out,
		viewport:      vp,
		zones:         newZoneManager(),
		windows:       map[uint16]protocol.WindowContent{},
		chrome:        map[byte]protocol.ChromePayload{},
		activePalette: defaultPalette(),
		gutters:       map[uint16]protocol.Gutter{},
		indentGuides:  map[uint16]protocol.IndentGuides{},
		cells:         map[position]cell{},
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
		if packet, ok := keyPacket(msg); ok {
			m.send(packet)
		}
	case tea.PasteMsg:
		m.send(pastePacket(msg))
	case tea.MouseMsg:
		if updated, ok := m.localMouse(msg); ok {
			m = updated
		} else if packet, ok := m.semanticMousePacket(msg); ok {
			m.send(packet)
		} else {
			m.send(mousePacket(msg))
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
	body := m.viewport.View()
	parts := append(m.headerLines(), body)
	parts = append(parts, m.footerLines()...)
	content := m.zones.Scan(lipgloss.JoinVertical(lipgloss.Left, parts...))
	out := m.cursorStyleSequence() + m.composeFrame(content) + m.cursorPositionSequence()
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

func (m Model) cursorPositionSequence() string {
	return ansi.CursorPosition(int(m.cursorCol)+1, int(m.cursorRow)+1)
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
		case protocol.CommandClear:
			m.windows = map[uint16]protocol.WindowContent{}
			m.windowOrder = nil
			m.chrome = map[byte]protocol.ChromePayload{}
			m.gutters = map[uint16]protocol.Gutter{}
			m.indentGuides = map[uint16]protocol.IndentGuides{}
			m.cursorlineChrome = protocol.CursorlineChrome{}
			m.cells = map[position]cell{}
			m.drawSeq = 0
		case protocol.CommandDrawText:
			m.applyDraw(command.Draw)
		case protocol.CommandSetCursor:
			m.cursorRow = command.CursorRow
			m.cursorCol = command.CursorCol
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

func (m *Model) applyDraw(draw protocol.DrawText) {
	m.drawSeq++
	m.cells[position{row: draw.Row, col: draw.Col}] = cell{text: draw.Text, fg: draw.FG, bg: draw.BG, attrs: draw.Attrs, seq: m.drawSeq}
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
