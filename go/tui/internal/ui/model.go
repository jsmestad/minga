package ui

import (
	"fmt"
	"sort"
	"strings"

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
		m.viewport.Height = max(msg.Height-3, 1)
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

	m.viewport.SetContent(m.content())
	return m, nil
}

func (m Model) View() string {
	body := m.viewport.View()
	header := m.header()
	footer := m.footer()
	return lipgloss.JoinVertical(lipgloss.Left, header, body, footer)
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
	m.windows[delta.ID] = window
	m.cursorRow = delta.CursorRow
	m.cursorCol = delta.CursorCol
	m.cursorShape = delta.CursorShape
}

func (m Model) content() string {
	if len(m.windows) > 0 {
		return m.semanticContent()
	}
	return m.cellContent()
}

func (m Model) semanticContent() string {
	lines := make([]string, 0, m.height)
	for _, id := range m.windowOrder {
		window := m.windows[id]
		for _, row := range window.Rows {
			lines = append(lines, m.renderRow(row))
		}
	}
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n")
}

func (m Model) renderRow(row protocol.WindowRow) string {
	if len(row.Spans) == 0 {
		return row.Text
	}

	var builder strings.Builder
	for _, r := range row.Text {
		col := displayWidth(builder.String())
		span := spanAt(row.Spans, uint16(col))
		style := styleFor(span)
		builder.WriteString(style.Render(string(r)))
	}
	return builder.String()
}

func (m Model) cellContent() string {
	rows := make([][]string, max(m.height-2, 1))
	for i := range rows {
		rows[i] = make([]string, max(m.width, 1))
		for j := range rows[i] {
			rows[i][j] = " "
		}
	}

	for pos, cell := range m.cells {
		if int(pos.row) < len(rows) && int(pos.col) < len(rows[pos.row]) {
			rows[pos.row][pos.col] = styleFor(protocol.Span{FG: cell.fg, BG: cell.bg, Attrs: byte(cell.attrs)}).Render(cell.text)
		}
	}

	rendered := make([]string, len(rows))
	for i, row := range rows {
		rendered[i] = strings.Join(row, "")
	}
	return strings.Join(rendered, "\n")
}

func (m Model) header() string {
	title := m.title
	if title == "" {
		title = "Minga"
	}
	chrome := make([]string, 0, len(m.chrome))
	for _, payload := range m.chrome {
		if payload.Summary != "" {
			chrome = append(chrome, payload.Name+": "+payload.Summary)
		} else {
			chrome = append(chrome, payload.Name)
		}
	}
	sort.Strings(chrome)
	if len(chrome) > 0 {
		title = fmt.Sprintf("%s  %s", title, strings.Join(chrome, "  "))
	}
	return lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#C7D1FF")).Background(lipgloss.Color("#20242C")).Width(m.width).Render(title)
}

func (m Model) footer() string {
	status := fmt.Sprintf("row %d col %d", m.cursorRow+1, m.cursorCol+1)
	if m.lastError != "" {
		status = m.lastError
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color("#9AA4B2")).Background(lipgloss.Color("#16181D")).Width(m.width).Render(status)
}

func (m Model) send(payload []byte) {
	if m.out != nil {
		m.out <- payload
	}
}

func keyPacket(msg tea.KeyMsg) ([]byte, bool) {
	switch msg.Type {
	case tea.KeyCtrlC:
		return protocol.EncodeKeyPress('c', protocol.ModCtrl), true
	case tea.KeyEnter:
		return protocol.EncodeKeyPress(13, 0), true
	case tea.KeyBackspace:
		return protocol.EncodeKeyPress(127, 0), true
	case tea.KeyEsc:
		return protocol.EncodeKeyPress(27, 0), true
	case tea.KeyTab:
		return protocol.EncodeKeyPress(9, 0), true
	case tea.KeyUp:
		return protocol.EncodeKeyPress(arrowUp, 0), true
	case tea.KeyDown:
		return protocol.EncodeKeyPress(arrowDown, 0), true
	case tea.KeyLeft:
		return protocol.EncodeKeyPress(arrowLeft, 0), true
	case tea.KeyRight:
		return protocol.EncodeKeyPress(arrowRight, 0), true
	case tea.KeyRunes:
		runes := msg.Runes
		if len(runes) == 1 {
			return protocol.EncodeKeyPress(runes[0], keyModifiers(msg)), true
		}
		if len(runes) > 1 {
			return protocol.EncodePaste(string(runes)), true
		}
	}
	return nil, false
}

func keyModifiers(msg tea.KeyMsg) byte {
	var mods byte
	if msg.Alt {
		mods |= protocol.ModAlt
	}
	return mods
}

func mousePacket(msg tea.MouseMsg) []byte {
	button := byte(3)
	eventType := byte(0)
	switch msg.Button {
	case tea.MouseButtonLeft:
		button = 0
	case tea.MouseButtonMiddle:
		button = 1
	case tea.MouseButtonRight:
		button = 2
	case tea.MouseButtonWheelUp:
		button = 0x40
	case tea.MouseButtonWheelDown:
		button = 0x41
	}
	if msg.Action == tea.MouseActionRelease {
		eventType = 1
	} else if msg.Action == tea.MouseActionMotion {
		eventType = 2
	}
	return protocol.EncodeMouseEvent(int16(msg.Y), int16(msg.X), button, 0, eventType, 1)
}

func spanAt(spans []protocol.Span, col uint16) protocol.Span {
	for _, span := range spans {
		if col >= span.StartCol && col < span.EndCol {
			return span
		}
	}
	return protocol.Span{FG: 0xFFFFFF}
}

func styleFor(span protocol.Span) lipgloss.Style {
	style := lipgloss.NewStyle()
	if span.FG != 0 {
		style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", span.FG)))
	}
	if span.BG != 0 {
		style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", span.BG)))
	}
	if span.Attrs&0x01 != 0 {
		style = style.Bold(true)
	}
	if span.Attrs&0x02 != 0 {
		style = style.Italic(true)
	}
	if span.Attrs&0x04 != 0 {
		style = style.Underline(true)
	}
	if span.Attrs&0x08 != 0 {
		style = style.Reverse(true)
	}
	return style
}

func displayWidth(value string) int {
	width := 0
	for range value {
		width++
	}
	return width
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
