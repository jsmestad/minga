package ui

import (
	"strconv"
	"strings"
	"sync/atomic"

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
		if chat.QuestionOffer != 0 {
			title = " Question: " + strings.Join(strings.Fields(chat.QuestionPrompt), " ") + " "
		}
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
	_, question, attachments := agentComposerControls(chat, placement.innerWidth)
	controls := agentTurnControls(chat, placement.innerWidth)
	var labels [4]string
	for i, control := range controls {
		labels[i] = control.label
		if !control.enabled {
			labels[i] = lipgloss.NewStyle().Foreground(p.Muted()).Background(bg).Render(control.label)
		}
	}
	label := strings.Join(labels[:], agentTurnControlSeparator(placement.innerWidth))
	for _, part := range []string{question, attachments} {
		if part != "" {
			label += " · " + part
		}
	}
	if placement.innerWidth >= 48 {
		const fullHint = " · Enter send · Shift+Enter newline"
		if lipgloss.Width(label)+len(fullHint) <= placement.innerWidth {
			label += fullHint
		} else if lipgloss.Width(label)+len(" · Shift+Enter newline") <= placement.innerWidth {
			label += " · Shift+Enter newline"
		}
		if lipgloss.Width(label)+len(" · Esc normal") <= placement.innerWidth {
			label += " · Esc normal"
		}
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

func agentComposerControls(chat protocol.AgentChat, width int) (control, question, attachments string) {
	controls := agentTurnControls(chat, width)
	control = strings.Join([]string{controls[0].label, controls[1].label, controls[2].label, controls[3].label}, agentTurnControlSeparator(width))
	used := lipgloss.Width(control)
	if chat.QuestionOffer != 0 {
		remaining := width - used
		// Reserve the smallest visible attachment action whenever both can fit.
		attachmentWidth := 3 + len(shortAgentAttachmentLabel(chat.DraftAttachmentCount))
		if remaining >= attachmentWidth+4 {
			remaining -= attachmentWidth
		}
		switch {
		case remaining >= 3+len("Answer question"):
			question = "Answer question"
		case remaining >= 3+len("Question"):
			question = "Question"
		case remaining >= 4:
			question = "?"
		}
		if question != "" {
			used += lipgloss.Width(" · ") + len(question)
		}
	}
	attachments = agentComposerAttachmentLabel(width, used, chat.DraftAttachmentCount)
	return control, question, attachments
}

func agentComposerAttachmentLabel(width, actionWidth int, count byte) string {
	full := "Attachments"
	if count > 0 {
		full += " (" + strconv.Itoa(int(count)) + ")"
	}
	available := width - actionWidth - 3
	if available >= len(full) {
		return full
	}
	short := shortAgentAttachmentLabel(count)
	if available >= len(short) {
		return short
	}
	return ""
}

func shortAgentAttachmentLabel(count byte) string {
	if count == 0 {
		return "A"
	}
	return "+" + strconv.Itoa(int(count))
}

const agentFullTurnLabelsWidth = 48

type agentTurnControl struct {
	label   string
	enabled bool
}

func agentTurnControlSeparator(width int) string {
	if width >= agentFullTurnLabelsWidth {
		return " · "
	}
	if width >= 7 {
		return " "
	}
	return ""
}

func agentTurnControls(chat protocol.AgentChat, width int) [4]agentTurnControl {
	active := agentHasActiveTurn(chat.Status)
	labels := [4]string{"Send", "Steer", "Queue Next", "Stop"}
	switch {
	case width == 1 && active:
		labels = [4]string{"", "", "", "■"}
	case width == 1:
		labels = [4]string{"↑", "", "", ""}
	case width < 4:
		labels = [4]string{"↑", "", "", "■"}
	case width < agentFullTurnLabelsWidth:
		labels = [4]string{"↑", "↪", "+", "■"}
	}
	draft := chat.PromptPresentation != 0 && chat.Prompt != ""
	queue := active && draft && chat.QueueTarget.Sequence != 0
	return [4]agentTurnControl{
		{labels[0], draft && !active},
		{labels[1], queue},
		{labels[2], queue},
		{labels[3], active && chat.StopTarget.SessionID != ""},
	}
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

type presentedChromeClick struct {
	packet        []byte
	claimed       bool
	epoch         *atomic.Uint64
	observedEpoch uint64
}

func (c *presentedChromeClick) take() ([]byte, bool, bool) {
	if c == nil {
		return nil, false, false
	}
	hit := *c
	*c = presentedChromeClick{}
	changed := hit.epoch != nil && hit.epoch.Load() != hit.observedEpoch
	return hit.packet, hit.claimed, changed
}

// Bubble Tea invokes OnMouse from the last flushed View, synchronously before
// Update receives that input. Capture only the displayed hit cells and target.
func (m Model) presentedComposerHandler() func(tea.MouseMsg) tea.Cmd {
	chat, _ := m.agentChat()
	p, ok := m.agentPromptPlacement()
	if !ok || m.presentedClick == nil {
		return nil
	}
	start, y := m.layout.body.X+p.col-p.prefix, m.layout.body.Y+p.controlsRow
	controls := agentTurnControls(chat, p.innerWidth)
	var startCells, endCells [4]int
	separator := lipgloss.Width(agentTurnControlSeparator(p.innerWidth))
	width := 0
	for i, control := range controls {
		startCells[i] = width
		endCells[i] = width + lipgloss.Width(control.label)
		width = endCells[i] + separator
	}
	width = min(endCells[3], p.innerWidth)
	var cells uint32
	for cell := range width {
		x := start + cell
		if m.layout.body.Contains(x, y) && !m.editorTextOccluded(x, y) {
			cells |= 1 << cell
		}
	}
	if cells == 0 {
		return nil
	}
	generation, offer := chat.PromptPresentation, chat.DraftAttachmentOffer
	stopTarget, queueTarget := chat.StopTarget, chat.QueueTarget
	claim := m.presentedClick
	return func(msg tea.MouseMsg) tea.Cmd {
		click, ok := msg.(tea.MouseClickMsg)
		if ok && click.Button == tea.MouseLeft && click.Y == y {
			cell := click.X - start
			if cell >= 0 && cell < width && cells&(1<<cell) != 0 {
				claim.claimed = true
				for i, control := range controls {
					if !control.enabled || cell < startCells[i] || cell >= endCells[i] {
						continue
					}
					switch i {
					case 0:
						claim.packet = protocol.EncodeGUIAgentComposerSubmit(generation, offer)
					case 1, 2:
						claim.packet = protocol.EncodeGUIAgentComposerQueue(generation, offer, i == 2, queueTarget)
					case 3:
						claim.packet = protocol.EncodeGUIAgentStopTurn(stopTarget)
					}
					break
				}
			}
		}
		return nil
	}
}

func (m Model) agentComposerControlPacket(msg tea.MouseMsg) ([]byte, bool) {
	p, ok := m.agentPromptPlacement()
	mouse := msg.Mouse()
	x, y := m.layout.body.Translate(mouse.X, mouse.Y)
	if !ok {
		return nil, false
	}
	chat, _ := m.agentChat()
	control, question, attachments := agentComposerControls(chat, p.innerWidth)
	controlWidth := lipgloss.Width(control)
	start := p.col - p.prefix
	if y != p.controlsRow || x < start {
		return nil, false
	}
	attachmentStart := start + controlWidth + lipgloss.Width(" · ")
	if question != "" {
		if x >= attachmentStart && x < attachmentStart+len(question) {
			return protocol.EncodeGUIAgentOpenQuestion(chat.QuestionOffer), true
		}
		attachmentStart += len(question) + lipgloss.Width(" · ")
	}
	if attachments != "" && x >= attachmentStart && x < attachmentStart+len(attachments) {
		return protocol.EncodeGUIExecuteCommand("agent_draft_attachments"), true
	}
	if x >= start+controlWidth {
		return nil, false
	}
	return nil, true // Turn controls use the last flushed View, never the newer model.
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
