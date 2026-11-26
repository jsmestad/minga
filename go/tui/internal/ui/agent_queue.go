package ui

import (
	"slices"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const queueReturnToComposer = "queue_return_to_composer"

// The BEAM owns the selected row. These are only local presentation facts.
type agentQueueScroll struct {
	first       int
	reveal      bool
	dirty       bool
	hitRevision uint64
}

type agentQueueViewport struct {
	box          uiRect
	maxRows      int
	header       []string
	note         []string
	empty        []string
	emptyActions int // first action's index in empty
	items        int
}

func (v agentQueueViewport) bodyRows() int {
	return v.box.Height - len(v.header)
}

func (m Model) agentQueue() generated.GuiAgentQueueFields {
	return m.chrome[generated.OPGuiAgentQueue].AgentQueue
}

func agentQueueSelected(queue generated.GuiAgentQueueFields) int {
	if queue.SelectedID == 0 {
		return -1
	}
	return slices.IndexFunc(queue.Pending, func(row generated.AgentQueueRow) bool { return row.ID == queue.SelectedID })
}

func (m *Model) reconcileAgentQueue(next generated.GuiAgentQueueFields) {
	old := m.agentQueue()
	if next.Visible == 0 || old.Visible == 0 || old.WorkspaceID != next.WorkspaceID || old.RecordID != next.RecordID {
		m.queueScroll.first = 0
		m.queueScroll.reveal = next.Visible != 0
	} else if old.SelectedID != next.SelectedID || (old.Focused == 0 && next.Focused != 0) || agentQueueSelected(old) != agentQueueSelected(next) {
		m.queueScroll.reveal = true
	}
	if old.Visible != next.Visible || old.Focused != next.Focused || old.WorkspaceID != next.WorkspaceID ||
		old.RecordID != next.RecordID || old.SelectedID != next.SelectedID || old.Title != next.Title ||
		old.Summary != next.Summary || old.RemovedNote != next.RemovedNote || old.Empty.Title != next.Empty.Title ||
		old.Empty.Why != next.Empty.Why || old.Empty.Glyph != next.Empty.Glyph || old.Empty.Selected != next.Empty.Selected ||
		!slices.Equal(old.Pending, next.Pending) || !slices.Equal(old.Removed, next.Removed) ||
		!slices.Equal(old.Hints, next.Hints) || !slices.Equal(old.Empty.Actions, next.Empty.Actions) {
		m.queueScroll.dirty = true
		m.queueScroll.hitRevision++
	}
}

// In a short conversation the editor still gets at least a draft row and its
// controls. A tall draft can't consume the queue's last usable slot either.
func (m Model) agentComposerBudget(chat protocol.AgentChat, budget int) int {
	if chat.Lifecycle == protocol.AgentChatConversation && m.agentQueue().Visible != 0 && budget > 2 {
		return max(budget-2, 2)
	}
	return budget
}

func (m *Model) refreshAgentQueueViewport() {
	queue := m.agentQueue()
	chat, ok := m.agentChat()
	limit := m.bodyHeight()
	if queue.Visible == 0 || !ok || !chat.Visible || chat.Lifecycle != protocol.AgentChatConversation || limit == 0 {
		m.queueViewport = agentQueueViewport{}
		return
	}
	width := agentMainWidth(chat, max(m.layout.body.Width-2, 1), limit)
	budget := limit - agentPanelHeaderRows(limit)
	composer := agentComposerAllocation(chat, width, m.agentComposerBudget(chat, budget))
	available := min(budget-composer.height, max(budget/2, 2))
	if available <= 0 {
		m.queueViewport = agentQueueViewport{}
		return
	}
	oldBox, oldRows := m.queueViewport.box, m.queueViewport.bodyRows()
	if m.queueScroll.dirty || oldBox.Width != width || available != m.queueViewport.maxRows {
		m.queueViewport = m.layoutAgentQueue(queue, width, available)
		m.queueScroll.dirty = false
	}
	v := &m.queueViewport
	v.box.X = m.layout.body.X
	if m.layout.body.Width > 1 {
		v.box.X++ // the same inset as renderAgentChatBody
	}
	v.box.Y = m.layout.body.Y + limit - composer.height - v.box.Height

	rows := v.bodyRows()
	first := m.queueScroll.first
	if rows > 0 && (m.queueScroll.reveal || oldRows != rows) {
		if index := agentQueueSelected(queue); index >= 0 {
			first = clampInt(first, index-rows+1, index)
		}
		m.queueScroll.reveal = false
	}
	first = clampInt(first, 0, max(v.items-rows, 0))
	if first != m.queueScroll.first || oldBox != v.box {
		m.queueScroll.hitRevision++
	}
	m.queueScroll.first = first
}

func (m Model) layoutAgentQueue(queue generated.GuiAgentQueueFields, width, available int) agentQueueViewport {
	v := agentQueueViewport{box: uiRect{Width: width}, maxRows: available}
	if queue.RemovedNote != "" {
		room := max(width-2*agentQueueInset.cols(), 1)
		v.note = wrapText(sanitizeTerminalText(queue.RemovedNote), room)
	}
	v.items = len(queue.Pending) + len(v.note) + len(queue.Removed)
	if v.items == 0 && strings.TrimSpace(queue.Empty.Title) != "" {
		p := m.palette()
		colors := emptyListColors{p.SurfaceAlt(), p.Text(), p.Muted(), p.Accent(), p.Selection(), p.SelectionText()}
		header := emptyListHeader(queue.Empty, width, colors, p)
		if len(header)+len(queue.Empty.Actions) >= available {
			header = header[emptyStateInset.rows():]
		}
		v.emptyActions = len(header)
		v.empty = append(header, emptyListActions(queue.Empty, width, colors)...)
		v.items = len(v.empty)
	}

	maxHeader := available
	if v.items > 0 {
		maxHeader = max(available-1, 1)
	}
	v.header = m.agentQueueHeader(queue, width, maxHeader)
	v.box.Height = min(len(v.header)+v.items, available)
	return v
}

func agentQueueHintZone(index int) string {
	return "agent:queue:hint:" + strconv.Itoa(index)
}

func (m Model) agentQueueHeader(queue generated.GuiAgentQueueFields, width, maxRows int) []string {
	p := m.palette()
	base := lipgloss.NewStyle().Background(p.SurfaceAlt()).ColorWhitespace(true)
	title := textTitle.style(p).Inherit(base)
	label := textBody.style(p).Inherit(base).Foreground(p.Muted())
	key := textBody.style(p).Inherit(base).Foreground(p.Accent())
	inset := gap(agentQueueInset)
	if width <= lipgloss.Width(inset) {
		inset = ""
	}
	text := title.Render(sanitizeTerminalText(queue.Title))
	if queue.Summary != "" {
		text += base.Render(gap(agentQueueHeaderGap)) + label.Render(sanitizeTerminalText(queue.Summary))
	}
	rows := make([]string, 0, min(maxRows, 1+len(queue.Hints)))
	line := base.Render(inset) + text
	for i, hint := range queue.Hints {
		keys, words := sanitizeTerminalText(hint.Key), sanitizeTerminalText(hint.Label)
		if keys == "" || words == "" {
			continue
		}
		hintWidth := lipgloss.Width(keys) + agentQueueHintGap.cols() + lipgloss.Width(words)
		sep := gap(agentQueueHeaderGap)
		if lipgloss.Width(line)+len(sep)+hintWidth > width {
			if len(rows)+1 >= maxRows {
				break
			}
			rows = append(rows, base.Render(fitStyled(line, width)))
			line, sep = base.Render(inset), ""
		}
		room := width - lipgloss.Width(line) - len(sep) - lipgloss.Width(keys) - agentQueueHintGap.cols()
		if room <= 0 {
			continue
		}
		value := key.Render(keys) + base.Render(gap(agentQueueHintGap)) + label.Render(ansi.Truncate(words, room, "…"))
		line += base.Render(sep) + m.zones.Mark(agentQueueHintZone(i), value)
	}
	return append(rows, base.Render(fitStyled(line, width)))
}

func (m Model) appendAgentQueue(lines []string) []string {
	v := m.queueViewport
	if v.box.Height == 0 {
		return lines
	}
	lines = append(lines, v.header...)
	queue := m.agentQueue()
	p := m.palette()
	base := lipgloss.NewStyle().Background(p.SurfaceAlt()).ColorWhitespace(true)
	muted := textBody.style(p).Inherit(base).Foreground(p.Muted())
	component, _ := m.focusedComponent()
	for index := m.queueScroll.first; index < m.queueScroll.first+v.bodyRows(); index++ {
		switch {
		case len(v.empty) != 0:
			lines = append(lines, fitStyled(v.empty[index], v.box.Width))
		case index < len(queue.Pending):
			row := queue.Pending[index]
			selected := row.ID == queue.SelectedID && queue.Focused != 0 && component == "agent_queue"
			lines = append(lines, renderAgentQueueRow(row, v.box.Width, selected, false, p))
		case index < len(queue.Pending)+len(v.note):
			text := gap(agentQueueInset) + v.note[index-len(queue.Pending)]
			lines = append(lines, muted.Render(fitStyled(text, v.box.Width)))
		default:
			row := queue.Removed[index-len(queue.Pending)-len(v.note)]
			lines = append(lines, renderAgentQueueRow(row, v.box.Width, false, true, p))
		}
	}
	return lines
}

func renderAgentQueueRow(row generated.AgentQueueRow, width int, selected, removed bool, p palette) string {
	base := lipgloss.NewStyle().Background(p.SurfaceAlt()).ColorWhitespace(true)
	ordinal, preview := p.Muted(), p.Text()
	if selected {
		base = base.Background(p.Selection())
		ordinal, preview = p.SelectionText(), p.SelectionText()
	} else if removed {
		preview = p.Muted()
	}
	label := textBody.style(p).Inherit(base).Foreground(ordinal)
	text := textBody.style(p).Inherit(base).Foreground(preview).Strikethrough(removed)
	inset := gap(agentQueueInset)
	if width <= lipgloss.Width(inset) {
		inset = ""
	}
	lead := base.Render(inset) + label.Render(sanitizeTerminalText(row.Label)) + base.Render(gap(agentQueueHintGap))
	room := max(width-lipgloss.Width(lead)-len(inset), 0)
	attachment := ""
	if row.AttachmentCount > 0 {
		count := gap(agentQueueHeaderGap) + "+" + strconv.Itoa(int(row.AttachmentCount))
		if lipgloss.Width(count) < room {
			room -= lipgloss.Width(count)
			attachment = label.Render(count)
		}
	}
	return base.Render(fitStyled(lead+text.Render(ansi.Truncate(sanitizeTerminalText(row.Preview), room, "…"))+attachment, width))
}

func (m *Model) scrollAgentQueue(mouse tea.Mouse, delta int) bool {
	v := m.queueViewport
	if !v.box.Contains(mouse.X, mouse.Y) || m.floatingOverlayContains(mouse.X, mouse.Y) {
		return false
	}
	if v.bodyRows() > 0 {
		first := clampInt(m.queueScroll.first+delta, 0, max(v.items-v.bodyRows(), 0))
		if first != m.queueScroll.first {
			m.queueScroll.first = first
			m.queueScroll.hitRevision++
		}
	}
	return true
}

func agentQueueRowRef(row generated.AgentQueueRow) protocol.AgentQueueRowRef {
	return protocol.AgentQueueRowRef{ID: row.ID, Revision: row.Revision}
}

func (m Model) presentedAgentQueueHandler(layers []*lipgloss.Layer) func(tea.MouseClickMsg) {
	v := m.queueViewport
	if v.box.Height == 0 || m.pickerVisible() || m.whichKeyVisible() {
		return nil
	}
	queue, first, claim := m.agentQueue(), m.queueScroll.first, m.presentedClick
	hintZones := make([]*zoneInfo, len(queue.Hints))
	for i := range hintZones {
		hintZones[i] = m.zones.Get(agentQueueHintZone(i))
	}
	var selected, removed protocol.AgentQueueRowRef
	if index := agentQueueSelected(queue); index >= 0 {
		selected = agentQueueRowRef(queue.Pending[index])
	}
	if len(queue.Removed) > 0 {
		removed = agentQueueRowRef(queue.Removed[0])
	}
	encode := func(action generated.AgentQueueAction, row, removed protocol.AgentQueueRowRef) []byte {
		return protocol.EncodeGUIAgentQueueAction(action, queue.WorkspaceID, queue.RecordID, row, removed)
	}
	return func(click tea.MouseClickMsg) {
		if !v.box.Contains(click.X, click.Y) {
			return
		}
		for _, layer := range layers {
			bounds := uiRect{X: layer.GetX(), Y: layer.GetY(), Width: layer.Width(), Height: layer.Height()}
			if bounds.Contains(click.X, click.Y) {
				return
			}
		}
		claim.claimed = true
		for i, zone := range hintZones {
			if !zone.InBounds(click) {
				continue
			}
			action := queue.Hints[i].Action
			switch action {
			case generated.AgentQueueActionPasteBefore, generated.AgentQueueActionPasteAfter:
				claim.packet = encode(action, selected, removed)
			case generated.AgentQueueActionSelect, generated.AgentQueueActionRemove, generated.AgentQueueActionEdit:
				claim.packet = encode(action, selected, protocol.AgentQueueRowRef{})
			case generated.AgentQueueActionClose:
				claim.packet = encode(action, protocol.AgentQueueRowRef{}, protocol.AgentQueueRowRef{})
			}
			return
		}
		if offset := click.Y - v.box.Y - len(v.header); offset >= 0 {
			index := first + offset
			if index < len(queue.Pending) {
				claim.packet = encode(generated.AgentQueueActionSelect, agentQueueRowRef(queue.Pending[index]), protocol.AgentQueueRowRef{})
			} else if i := index - v.emptyActions; len(v.empty) != 0 && i >= 0 && i < len(queue.Empty.Actions) && queue.Empty.Actions[i].ID == queueReturnToComposer {
				claim.packet = encode(generated.AgentQueueActionComposer, protocol.AgentQueueRowRef{}, protocol.AgentQueueRowRef{})
			}
		}
	}
}
