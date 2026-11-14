package ui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// agentComposerPlacement is the one physical transform used for drawing, pointer input, fit observations and the terminal insertion cursor.
type agentComposerPlacement struct {
	row, col, width, rows                       int
	maxRows, height, border, prefix, innerWidth int
	controlsRow                                 int
}

func agentPanelHeaderRows(limit int) int {
	if limit <= 2 {
		return 0
	}
	return 1
}

func agentComposerAllocation(chat protocol.AgentChat, width, budget int) agentComposerPlacement {
	p := agentComposerPlacement{}
	if budget <= 0 {
		return p
	}
	p.border = 0
	if budget >= 4 && width >= 4 {
		p.border = 1
	}
	p.innerWidth = max(width-2*p.border, 1)
	if p.innerWidth >= 24 {
		p.prefix = lipgloss.Width(" ❯ " + agentPromptModeName(chat.PromptVimMode) + "  ")
	} else if p.innerWidth >= 4 {
		p.prefix = 1
	}
	padding := 0
	if p.innerWidth-p.prefix >= 2 {
		padding = 1
	}
	p.width = max(p.innerWidth-p.prefix-padding, 1)
	p.maxRows = max(budget-2*p.border-1, 0)
	p.rows = min(max(int(chat.PromptVisibleRows), 1), p.maxRows)
	p.height = p.rows + 2*p.border + 1
	p.row, p.col = p.border, p.border+p.prefix
	p.controlsRow = p.border + p.rows
	return p
}

func (m Model) agentPromptPlacement() (agentComposerPlacement, bool) {
	chat, ok := m.agentChat()
	if !ok || !chat.Visible || m.bodyHeight() <= 0 {
		return agentComposerPlacement{}, false
	}
	limit := m.bodyHeight()
	width := max(m.layout.body.Width-2, 1)
	if agentDetailsVisible(width) && limit > 5 {
		width = max(width-agentDetailsWidth(width)-agentColumnGap(), 40)
	}
	p := agentComposerAllocation(chat, width, limit-agentPanelHeaderRows(limit))
	// The main column bottom-aligns its complete composer after allocating the transcript.
	// The outer chat body contributes a one-cell left inset.
	p.row += limit - p.height
	p.controlsRow += limit - p.height
	if m.layout.body.Width > 1 {
		p.col++
	}
	return p, true
}

func (m Model) renderAgentComposerWithLimit(chat protocol.AgentChat, width, budget int) []string {
	placement := agentComposerAllocation(chat, width, budget)
	if placement.height == 0 {
		return nil
	}
	p := m.palette()
	bg := p.AgentInputSurface()
	border := lipgloss.NewStyle().Foreground(p.AgentInputBorder()).Background(bg)
	base := lipgloss.NewStyle().Background(bg).Width(max(width, 1))
	lines := make([]string, 0, placement.height)
	if placement.border != 0 {
		title := " " + agentComposerTitle(chat) + " "
		title = fit(title, max(width-2, 0))
		lines = append(lines, base.Render(border.Render("╭"+title+strings.Repeat("─", max(width-2-lipgloss.Width(title), 0))+"╮")))
	}
	window, committed := m.windows[protocol.AgentPromptWindowID]
	start := m.presentationSourceStart(window, placement.rows)
	for index := range placement.rows {
		prefix := strings.Repeat(" ", placement.prefix)
		if index == 0 && placement.prefix > 1 {
			prefix = lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(bg).Render(" ❯ " + agentPromptModeName(chat.PromptVimMode) + "  ")
		}
		text := ""
		if committed {
			if row, ok := m.windowRow(window, start+index); ok {
				text = m.renderRowAt(window, row, start+index, index, placement.width, false, 0)
				if index == 0 && row.Text == "" && chat.Prompt == "" {
					text = lipgloss.NewStyle().Foreground(p.AgentInputPlaceholder()).Background(bg).Italic(true).Render(fit("Ask Minga to edit, explain, search, or run tools", placement.width))
				}
			}
		}
		inner := lipgloss.NewStyle().Background(bg).Width(placement.innerWidth).Render(fitStyled(prefix+text, placement.innerWidth))
		if placement.border != 0 {
			inner = border.Render("│") + inner + border.Render("│")
		}
		lines = append(lines, base.Render(fitStyled(inner, width)))
	}
	control := agentComposerControlLabel(chat, placement.innerWidth)
	label := control
	if placement.innerWidth >= 48 {
		label += " · Enter send · Shift+Enter newline · Esc normal"
	}
	inner := lipgloss.NewStyle().Foreground(p.Accent()).Background(bg).Width(placement.innerWidth).Render(fitStyled(label, placement.innerWidth))
	if placement.border != 0 {
		inner = border.Render("│") + inner + border.Render("│")
	}
	lines = append(lines, base.Render(fitStyled(inner, width)))
	if placement.border != 0 {
		lines = append(lines, base.Render(border.Render("╰"+strings.Repeat("─", max(width-2, 0))+"╯")))
	}
	return lines
}

func agentComposerControlLabel(chat protocol.AgentChat, width int) string {
	if chat.Status == 1 || chat.Status == 2 {
		if width < 4 {
			return "■"
		}
		return "Stop"
	}
	if width < 4 {
		return "↑"
	}
	return "Send"
}

func (m *Model) reportAgentPromptFit() {
	p, ok := m.agentPromptPlacement()
	generation := m.textPresentations[protocol.AgentPromptWindowID]
	if !ok || p.maxRows <= 0 || generation == 0 {
		m.agent.lastPromptFit = protocol.AgentPromptFit{}
		return
	}
	if _, ok := m.windows[protocol.AgentPromptWindowID]; !ok {
		return
	}
	fit := protocol.AgentPromptFit{WindowID: protocol.AgentPromptWindowID, Generation: generation, Columns: uint16(min(p.width, 65535)), MaxRows: uint16(min(p.maxRows, 65535))}
	if fit != m.agent.lastPromptFit && m.send(protocol.EncodeGUIAgentPromptFit(fit)) {
		m.agent.lastPromptFit = fit
	}
}

func (m Model) agentPromptCursor() *tea.Cursor {
	p, ok := m.agentPromptPlacement()
	window, exists := m.windows[protocol.AgentPromptWindowID]
	if !ok || !exists || !window.CursorVisible || int(window.CursorRow) >= p.rows || int(window.CursorCol) > p.width {
		return nil
	}
	x := m.layout.body.X + p.col + int(window.CursorCol)
	y := m.layout.body.Y + p.row + int(window.CursorRow)
	if x >= int(m.width) || y >= int(m.height) {
		return nil
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

func (m *Model) sendAgentPromptScroll(msg tea.MouseMsg, delta int) bool {
	p, ok := m.agentPromptPlacement()
	mouse := msg.Mouse()
	x, y := m.layout.body.Translate(mouse.X, mouse.Y)
	if !ok || x < p.col || x >= p.col+p.width || y < p.row || y >= p.row+p.rows {
		return false
	}
	generation := m.textPresentations[protocol.AgentPromptWindowID]
	if generation != 0 && delta != 0 && (mouse.Button == tea.MouseWheelDown || mouse.Button == tea.MouseWheelUp) {
		m.send(protocol.EncodeGUIAgentPromptScroll(protocol.AgentPromptScroll{WindowID: protocol.AgentPromptWindowID, Generation: generation, DeltaRows: int32(clampInt(delta, -2147483648, 2147483647))}))
	}
	// No horizontal scrolling or frontend-local draft/caret mutation.
	return true
}

func (m Model) agentComposerControlPacket(msg tea.MouseMsg) ([]byte, bool) {
	p, ok := m.agentPromptPlacement()
	mouse := msg.Mouse()
	x, y := m.layout.body.Translate(mouse.X, mouse.Y)
	if !ok {
		return nil, false
	}
	chat, _ := m.agentChat()
	controlWidth := lipgloss.Width(agentComposerControlLabel(chat, p.innerWidth))
	if y != p.controlsRow || x < p.col-p.prefix || x >= p.col-p.prefix+controlWidth {
		return nil, false
	}
	command := "agent_submit_or_newline"
	if chat.Status == 1 || chat.Status == 2 {
		command = "agent_abort"
	}
	return protocol.EncodeGUIExecuteCommand(command), true
}

func (m Model) agentPromptTextTargetAt(screenX, screenY int, captured bool) (editorTextTarget, bool) {
	p, ok := m.agentPromptPlacement()
	window, exists := m.windows[protocol.AgentPromptWindowID]
	generation := m.textPresentations[protocol.AgentPromptWindowID]
	if !ok || !exists || generation == 0 || p.rows <= 0 {
		return editorTextTarget{}, false
	}
	x, y := m.layout.body.Translate(screenX, screenY)
	if !captured && (x < p.col || x >= p.col+p.width || y < p.row || y >= p.row+p.rows) {
		return editorTextTarget{}, false
	}
	localRow := clampInt(y-p.row, 0, p.rows-1)
	source := m.presentationSourceStart(window, p.rows) + localRow
	row, exists := m.windowRow(window, source)
	if !exists || row.ID == 0 {
		return editorTextTarget{}, false
	}
	column := clampInt(x-p.col, 0, p.width-1)
	return editorTextTarget{
		windowID: protocol.AgentPromptWindowID, presentationID: generation,
		rowIndex: uint32(source), rowID: row.ID,
		utf16Offset: uint32(composedUTF16OffsetAtCell(row.Text, 0, column)),
		scrollY:     edgeDirection(y, p.row, p.row+p.rows),
	}, true
}
