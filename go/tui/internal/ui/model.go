package ui

import (
	"sort"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	zone "github.com/lrstanley/bubblezone"
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
	zones            *zone.Manager
	windows          map[uint16]protocol.WindowContent
	windowOrder      []uint16
	chrome           map[byte]protocol.ChromePayload
	activePalette    palette
	gutters          map[uint16]protocol.Gutter
	indentGuides     map[uint16]protocol.IndentGuides
	cells            map[position]cell
	drawSeq          uint64
	cursorRow        uint16
	cursorCol        uint16
	cursorShape      byte
	title            string
	bg               uint32
	cursorlineChrome protocol.CursorlineChrome
	lastError        string
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
	vp := viewport.New(int(width), max(int(height)-3, 1))
	return Model{
		width:         int(width),
		height:        int(height),
		out:           out,
		viewport:      vp,
		zones:         zone.New(),
		windows:       map[uint16]protocol.WindowContent{},
		chrome:        map[byte]protocol.ChromePayload{},
		activePalette: defaultPalette(),
		gutters:       map[uint16]protocol.Gutter{},
		indentGuides:  map[uint16]protocol.IndentGuides{},
		cells:         map[position]cell{},
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.viewport.Width = msg.Width
		m.viewport.Height = m.bodyHeight()
		m.send(protocol.EncodeResize(uint16(max(msg.Width, 1)), uint16(max(msg.Height, 1))))
	case tea.KeyMsg:
		if packet, ok := keyPacket(msg); ok {
			m.send(packet)
		}
	case tea.MouseMsg:
		if packet, ok := m.semanticMousePacket(msg); ok {
			m.send(packet)
		} else {
			m.send(mousePacket(msg))
		}
	case port.PacketMsg:
		return m, m.applyCommands(msg.Commands)
	case port.LogMsg:
		// Forward renderer diagnostics to the BEAM so they land in *Messages*.
		m.send(protocol.EncodeLogMessage(msg.Level, msg.Text))
	case port.ErrorMsg:
		m.lastError = msg.Err.Error()
		m.send(protocol.EncodeLogMessage(protocol.LogLevelErr, msg.Err.Error()))
	}

	m.viewport.Width = max(m.width, 1)
	m.viewport.Height = m.bodyHeight()
	m.viewport.SetContent(m.content())
	return m, nil
}

func (m Model) View() string {
	body := m.viewport.View()
	parts := append(m.headerLines(), body)
	parts = append(parts, m.footerLines()...)
	return m.cursorStyleSequence() + m.zones.Scan(lipgloss.JoinVertical(lipgloss.Left, parts...))
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
			cmds = append(cmds, tea.SetWindowTitle(command.Title))
		case protocol.CommandSetWindowBg:
			m.bg = command.WindowBg
		case protocol.CommandWindowContent:
			m.putWindow(command.Window)
		case protocol.CommandWindowDelta:
			m.applyWindowDelta(command.Window)
		case protocol.CommandChrome:
			m.chrome[command.Chrome.Opcode] = command.Chrome
			if command.Chrome.Opcode == generated.OPGuiTheme {
				m.activePalette = paletteFromTheme(command.Chrome.Theme)
			}
			if command.Chrome.Opcode == generated.OPGuiCursorline {
				m.cursorlineChrome = command.Chrome.CursorlineChrome
			}
			if command.Chrome.Opcode == generated.OPGuiGutter {
				m.gutters[command.Chrome.WindowGutter.WindowID] = command.Chrome.WindowGutter
			}
			if command.Chrome.Opcode == generated.OPGuiIndentGuides {
				m.indentGuides[command.Chrome.IndentGuides.WindowID] = command.Chrome.IndentGuides
			}
			if command.Chrome.Opcode == generated.OPGuiFileTreeSelection {
				m.applyFileTreeSelection(command.Chrome.FileTreeSelection)
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
	m.cursorRow = window.CursorRow
	m.cursorCol = window.CursorCol
	m.cursorShape = window.CursorShape
}

func (m *Model) applyWindowDelta(delta protocol.WindowContent) {
	window, ok := m.windows[delta.ID]
	if !ok {
		m.putWindow(delta)
		return
	}
	window.CursorRow = delta.CursorRow
	window.CursorCol = delta.CursorCol
	window.CursorShape = delta.CursorShape
	window.ContentEpoch = delta.ContentEpoch
	window.ScrollLeft = delta.ScrollLeft
	if delta.Cursorline.Visible {
		window.Cursorline = delta.Cursorline
	}
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
		window.Rows = resolveWindowRows(window.Rows, delta.Rows)
	}
	m.windows[delta.ID] = window
	m.cursorRow = delta.CursorRow
	m.cursorCol = delta.CursorCol
	m.cursorShape = delta.CursorShape
}

func resolveWindowRows(previous []protocol.WindowRow, delta []protocol.WindowRow) []protocol.WindowRow {
	byID := make(map[uint64]protocol.WindowRow, len(previous))
	for _, row := range previous {
		byID[row.ID] = row
	}
	rows := make([]protocol.WindowRow, 0, len(delta))
	for _, row := range delta {
		if row.Ref {
			if existing, ok := byID[row.ID]; ok && existing.ContentHash == row.ContentHash {
				rows = append(rows, existing)
			}
			continue
		}
		rows = append(rows, row)
	}
	return rows
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
