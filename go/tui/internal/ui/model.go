package ui

import (
	"sort"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
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
	width       int
	height      int
	out         chan<- []byte
	viewport    viewport.Model
	windows     map[uint16]protocol.WindowContent
	windowOrder []uint16
	chrome      map[byte]protocol.ChromePayload
	cells       map[position]cell
	cursorRow   uint16
	cursorCol   uint16
	cursorShape byte
	title       string
	bg          uint32
	lastError   string
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
}

func New(width, height uint16, out chan<- []byte) Model {
	vp := viewport.New(int(width), max(int(height)-3, 1))
	return Model{
		width:    int(width),
		height:   int(height),
		out:      out,
		viewport: vp,
		windows:  map[uint16]protocol.WindowContent{},
		chrome:   map[byte]protocol.ChromePayload{},
		cells:    map[position]cell{},
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
		m.send(mousePacket(msg))
	case port.PacketMsg:
		m.applyCommands(msg.Commands)
	case port.ErrorMsg:
		m.lastError = msg.Err.Error()
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
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

func (m *Model) applyCommands(commands []protocol.Command) {
	for _, command := range commands {
		switch command.Kind {
		case protocol.CommandClear:
			m.windows = map[uint16]protocol.WindowContent{}
			m.windowOrder = nil
			m.cells = map[position]cell{}
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
		case protocol.CommandChrome:
			m.chrome[command.Chrome.Opcode] = command.Chrome
		}
	}
}

func (m *Model) applyDraw(draw protocol.DrawText) {
	m.cells[position{row: draw.Row, col: draw.Col}] = cell{text: draw.Text, fg: draw.FG, bg: draw.BG, attrs: draw.Attrs}
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
