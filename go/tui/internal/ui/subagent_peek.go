package ui

import (
	"fmt"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	peekFocused = 1 << iota
	peekEditing
	peekBriefOpen
	peekSending
	peekHasResult
)

const peekZonePrefix = "agent:peek:"

const peekBriefScrollZone = "agent:peek-brief-body"
const peekResultScrollZone = "agent:peek-result-body"

type peekTranscriptFrame struct {
	token string
	store *residentTranscript
	plan  *transcriptPlan
}

// The parent and child may use the same epoch and message IDs. Only the
// committed child token can carry its store forward into the next frame.
func (m *Model) preparePeekTranscript() (peekTranscriptFrame, transcriptDropReason) {
	token := m.peekToken
	if m.staging.base == 0 {
		token = ""
	}
	for _, cmd := range m.staging.commands {
		if cmd.Kind == protocol.CommandChrome && cmd.Chrome.Opcode == generated.OPGuiSubagentPeek {
			token = ""
			if panes := cmd.Chrome.SubagentPeek.Panes; len(panes) != 0 {
				token = panes[0].Token
			}
		}
	}
	frame := peekTranscriptFrame{token: token}
	if token != "" {
		if token == m.peekToken && m.staging.base != 0 {
			frame.store = m.peekTranscript
		} else {
			frame.store = newResidentTranscript()
		}
	}
	for _, cmd := range m.staging.commands {
		if cmd.Kind != protocol.CommandChrome || cmd.Chrome.Opcode != generated.OPGuiSubagentPeekTranscript {
			continue
		}
		if frame.store == nil {
			return peekTranscriptFrame{}, transcriptDroppedDesync
		}
		if frame.plan == nil {
			frame.plan = frame.store.prepare()
		}
		if reason := frame.plan.apply(cmd.Chrome.AgentTranscript); reason != transcriptApplied {
			return peekTranscriptFrame{}, reason
		}
	}
	return frame, transcriptApplied
}

func (m *Model) commitPeekTranscript(frame peekTranscriptFrame) {
	if frame.plan != nil {
		frame.plan.commit()
	}
	if frame.store != m.peekTranscript {
		m.peekBriefOffset, m.peekResultOffset = 0, 0
		m.peekRenderer = nil
		if frame.store != nil {
			m.peekRenderer = newAgentTranscriptRenderer()
		}
	}
	m.peekTranscript, m.peekToken = frame.store, frame.token
}

func (m *Model) reconcilePeekMetadata(peek generated.GuiSubagentPeekFields) {
	m.peekHitRevision++
	m.peekSteps = nil
	if len(peek.Steps) == 0 {
		m.peekSelected = ""
		return
	}
	m.peekSteps = make(map[uint32]generated.SubagentPeekStep, len(peek.Steps))
	selected := false
	for _, step := range peek.Steps {
		m.peekSteps[step.EntryID] = step
		selected = selected || step.Token == m.peekSelected
	}
	if !selected {
		m.peekSelected = ""
	}
}

func (m Model) subagentPeek() generated.GuiSubagentPeekFields {
	return m.chrome[generated.OPGuiSubagentPeek].SubagentPeek
}

func (m Model) focusedSubagentPeek() (generated.SubagentPeekPane, bool) {
	if panes := m.subagentPeek().Panes; len(panes) != 0 {
		return panes[0], panes[0].Flags&peekFocused != 0
	}
	return generated.SubagentPeekPane{}, false
}

func peekZone(action protocol.SubagentPeekAction, window uint16, displayed, target string) string {
	return fmt.Sprintf("%s%d:%d:%s:%s", peekZonePrefix, action, window, displayed, target)
}

func peekZonePacket(id string, column uint32, pane generated.SubagentPeekPane) []byte {
	var row uint32
	identity, ok := strings.CutPrefix(id, peekZonePrefix)
	if !ok {
		return nil
	}
	parts := strings.SplitN(identity, ":", 4)
	if len(parts) != 4 {
		return nil
	}
	action, actionErr := strconv.ParseUint(parts[0], 10, 8)
	window, windowErr := strconv.ParseUint(parts[1], 10, 16)
	if actionErr != nil || windowErr != nil {
		return nil
	}
	kind := protocol.SubagentPeekAction(action)
	target := parts[3]
	if kind == protocol.SubagentPeekCompose {
		line, start, ok := strings.Cut(target, "/")
		n, rowErr := strconv.ParseUint(line, 10, 32)
		offset, offsetErr := strconv.ParseUint(start, 10, 32)
		if !ok || rowErr != nil || offsetErr != nil || pane.Token != parts[2] {
			return nil
		}
		row, target = uint32(n), ""
		lines := strings.Split(pane.Prompt, "\n")
		if int(row) >= len(lines) || int(offset) > len(lines[row]) {
			return nil
		}
		column = uint32(offset) + peekDraftByteAtCell(lines[row][offset:], int(column))
	} else {
		row, column = 0, 0
	}
	return protocol.EncodeGUISubagentPeekAction(kind, uint16(window), parts[2], target, row, column)
}

func peekDraftByteAtCell(text string, target int) uint32 {
	cell, offset := 0, uint32(0)
	for _, grapheme := range splitGraphemes(text) {
		cell += max(displayWidth(grapheme), 1)
		if target < cell {
			return offset
		}
		offset += uint32(len(grapheme))
	}
	return offset
}

func (m Model) presentedSubagentPeekHandler(layers []*lipgloss.Layer) func(tea.MouseClickMsg) {
	if len(m.peekSteps) == 0 || !m.agentChatVisible() || m.pickerVisible() || m.whichKeyVisible() {
		return nil
	}
	zones, claim := m.zones.zones, m.presentedClick
	var pane generated.SubagentPeekPane
	if panes := m.subagentPeek().Panes; len(panes) != 0 {
		pane = panes[0]
	}
	return func(click tea.MouseClickMsg) {
		if !m.layout.body.Contains(click.X, click.Y) {
			return
		}
		for _, layer := range layers {
			if bounds := (uiRect{X: layer.GetX(), Y: layer.GetY(), Width: layer.Width(), Height: layer.Height()}); bounds.Contains(click.X, click.Y) {
				return
			}
		}
		for id, zone := range zones {
			if strings.HasPrefix(id, peekZonePrefix) && zone.InBounds(click) {
				claim.claimed = true
				claim.packet = peekZonePacket(id, uint32(click.X-zone.StartX), pane)
				return
			}
		}
	}
}

func (m *Model) peekParentKey(chat protocol.AgentChat, msg tea.KeyPressMsg) ([]byte, bool) {
	if !chat.Visible || chat.InputFocused || len(m.peekSteps) == 0 || m.zones == nil {
		return nil, false
	}
	key := msg.Key()
	if key.Mod != 0 || (key.Code != tea.KeyTab && key.Code != tea.KeyEnter && key.Code != tea.KeyKpEnter) {
		return nil, false
	}
	parent := m.subagentPeek().ParentWindowID
	firstRow, nextRow, selectedRow := m.height, m.height, -1
	var first, next string
	for _, step := range m.peekSteps {
		id := peekZone(protocol.SubagentPeekStarted, parent, "", step.Token)
		zone := m.zones.Get(id)
		if zone == nil {
			continue
		}
		if step.Token == m.peekSelected {
			if key.Code != tea.KeyTab {
				offer := ""
				if chat.DraftAttachmentOffer != 0 {
					offer = strconv.FormatUint(chat.DraftAttachmentOffer, 10)
				}
				return protocol.EncodeGUISubagentPeekAction(protocol.SubagentPeekStartedKey, parent, offer, step.Token, 0, 0), true
			}
			selectedRow = zone.StartY
		}
		if zone.StartY < firstRow {
			firstRow, first = zone.StartY, step.Token
		}
	}
	if key.Code != tea.KeyTab || first == "" {
		return nil, false
	}
	for _, step := range m.peekSteps {
		zone := m.zones.Get(peekZone(protocol.SubagentPeekStarted, parent, "", step.Token))
		if zone != nil && zone.StartY > selectedRow && zone.StartY < nextRow {
			nextRow, next = zone.StartY, step.Token
		}
	}
	if next == "" {
		next = first
	}
	m.peekSelected = next
	return nil, true
}

func (m Model) peekStepLine(message protocol.AgentChatMessage, width int) (string, bool) {
	step, ok := m.peekSteps[message.ID]
	if !ok || m.zones == nil {
		return "", false
	}
	glyph, colour := m.agentToolStepMark(message)
	p := m.palette()
	lead := " " + glyph + " "
	report := ""
	if step.Report != "" && width > displayWidth(lead)+displayWidth(step.Report)+8 {
		report = " · " + step.Report
	}
	label := fit(step.Label, max(width-displayWidth(lead)-displayWidth(report), 1))
	base := lipgloss.NewStyle().Background(p.AgentPanel())
	link := base.Foreground(colour).Underline(true)
	if step.Token == m.peekSelected {
		link = link.Reverse(true)
	}
	id := peekZone(protocol.SubagentPeekStarted, m.subagentPeek().ParentWindowID, "", step.Token)
	return base.Width(width).Render(fitStyled(base.Foreground(colour).Render(lead)+m.zones.Mark(id, link.Render(label))+base.Foreground(p.Muted()).Render(report), width)), true
}

func (m Model) parentAgentBody() uiRect {
	if panes := m.subagentPeek().Panes; len(panes) != 0 {
		return m.peekBodyRect(panes[0].ParentRect)
	}
	return uiRect{Width: m.layout.body.Width, Height: m.bodyHeight()}
}

func (m Model) peekBodyRect(rect generated.Rect) uiRect {
	col, row := m.semanticBodyCol(int(rect.Col)), int(rect.Row)
	return uiRect{
		X: col, Y: row,
		Width:  max(min(int(rect.Width), m.layout.body.Width-col), 0),
		Height: max(min(int(rect.Height), m.bodyHeight()-row), 0),
	}
}

func (m Model) renderAgentPeekSplit(chat protocol.AgentChat, pane generated.SubagentPeekPane) []string {
	parent, child := m.parentAgentBody(), m.peekBodyRect(pane.PeekRect)
	left := m.renderAgentChatInRect(chat, parent.Width, parent.Height)
	right := m.renderSubagentPeek(pane, child.Width, child.Height)
	lines := make([]string, m.bodyHeight())
	for row := range lines {
		var segments [2]semanticLineSegment
		count := 0
		if index := row - parent.Y; index >= 0 && index < len(left) {
			segments[count] = semanticLineSegment{col: parent.X, text: left[index]}
			count++
		}
		if index := row - child.Y; index >= 0 && index < len(right) {
			segments[count] = semanticLineSegment{col: child.X, text: right[index]}
			count++
		}
		lines[row] = composeSemanticLine(segments[:count])
	}
	return lines
}

func (m Model) renderSubagentPeek(pane generated.SubagentPeekPane, width, height int) []string {
	if width <= 0 || height <= 0 {
		return nil
	}
	p := m.palette()
	base := lipgloss.NewStyle().Background(p.AgentPanel())
	text := base.Foreground(p.AgentText())
	line := func(content string) string { return base.Width(width).Render(fitStyled(content, width)) }
	control := func(action protocol.SubagentPeekAction, token, label string) string {
		if m.zones == nil {
			return label
		}
		return m.zones.Mark(peekZone(action, pane.WindowID, pane.Token, token), label)
	}
	op := text.Bold(true).Render(firstCompactLine(pane.Parent+" › "+pane.Title, max(width-spaceSection.cols(), 1)))
	lines := []string{line(op + " " + control(protocol.SubagentPeekClose, "", text.Render("×")))}
	state, ok := generated.SpineStateFromWire(pane.State)
	if ok {
		token := state.Token()
		mark := base.Foreground(p.Role(token.Role)).Render(token.Glyph)
		lines = append(lines, line(mark+text.Render(" "+token.Word+" · "+pane.Elapsed)))
	}
	var siblings strings.Builder
	used := 0
	flushSiblings := func() {
		lines = append(lines, line(siblings.String()))
		siblings.Reset()
		used = 0
	}
	for _, sibling := range pane.Siblings {
		state, ok := generated.SpineStateFromWire(sibling.State)
		if !ok {
			continue
		}
		token := state.Token()
		columns := displayWidth(token.Glyph)
		if used != 0 && used+columns > width {
			flushSiblings()
		}
		glyph := base.Foreground(p.Role(token.Role)).Reverse(pane.Token == sibling.Token).Render(token.Glyph)
		siblings.WriteString(control(protocol.SubagentPeekSibling, sibling.Token, glyph))
		siblings.WriteByte(' ')
		used += columns + 1
	}
	count := fmt.Sprintf("%d of %d", pane.Index, len(pane.Siblings))
	if used != 0 && used+len(count) > width {
		flushSiblings()
	}
	siblings.WriteString(count)
	flushSiblings()
	briefLabel := "▸ Brief" + gap(spaceXL) + "za"
	if pane.Flags&peekBriefOpen != 0 {
		briefLabel = "▾ Brief" + gap(spaceXL) + "za"
	}
	lines = append(lines, line(control(protocol.SubagentPeekBrief, "", text.Bold(true).Render(briefLabel))))
	if pane.Flags&peekBriefOpen != 0 {
		lines = append(lines, m.peekDetail(pane.Brief, peekBriefScrollZone, width, max(height/3-4, 1), m.peekBriefOffset, text, line)...)
	}
	lines = append(lines, line(control(protocol.SubagentPeekInspect, "", text.Bold(true).Render("So far"))))
	footer := make([]string, 0, 8)
	if pane.Flags&peekHasResult != 0 {
		footer = append(footer, line(text.Bold(true).Render("Result")))
		footer = append(footer, m.peekDetail(pane.Result, peekResultScrollZone, width, max(height/4, 1), m.peekResultOffset, text, line)...)
	}
	if pane.Notice != "" {
		footer = append(footer, line(text.Render(pane.Notice)))
	}
	draft := strings.Split(pane.Prompt, "\n")
	first := max(min(int(pane.CursorRow)-2, len(draft)-1), 0)
	for index, row := range draft[first:min(first+3, len(draft))] {
		start := 0
		var content string
		switch {
		case pane.Prompt == "" && pane.Flags&peekEditing == 0:
			content = text.Render("Message this subagent")
		case pane.Flags&peekEditing != 0 && first+index == int(pane.CursorRow):
			cursor := min(int(pane.CursorColumn), len(row))
			before, after := row[:cursor], row[cursor:]
			used := displayWidth(before)
			if used >= width {
				for _, grapheme := range splitGraphemes(before) {
					if used < width {
						break
					}
					start += len(grapheme)
					used -= displayWidth(grapheme)
				}
			}
			caret := " "
			if rest := splitGraphemes(after); len(rest) != 0 {
				caret = rest[0]
				after = after[len(caret):]
			}
			content = text.Render(before[start:]) + text.Reverse(true).Render(caret) + text.Render(after)
		default:
			content = text.Render(row)
		}
		footer = append(footer, control(protocol.SubagentPeekCompose, fmt.Sprintf("%d/%d", first+index, start), line(content)))
	}
	if pane.Flags&peekSending != 0 {
		footer = append(footer, line(text.Render("Sending…")))
	} else if pane.Flags&peekEditing != 0 {
		footer = append(footer, line(control(protocol.SubagentPeekSubmit, "", text.Render("[Send]"))+gap(spaceXL)+text.Render("Esc · inspect")))
	}
	if len(lines)+len(footer) > height {
		lines = takeLines(lines, max(height-len(footer), 0))
	}
	budget := max(height-len(lines)-len(footer), 0)
	if m.peekRenderer != nil {
		// Child rows may contain controls for its own runtime. No parent control
		// markers may escape from the child renderer.
		m.zones = nil
		lines = append(lines, m.peekRenderer.render(m, m.peekTranscript, budget, width)...)
	}
	for len(lines)+len(footer) < height {
		lines = append(lines, line(""))
	}
	return takeLines(append(lines, footer...), height)
}

func (m Model) peekDetail(body, zone string, width, count, offset int, style lipgloss.Style, line func(string) string) []string {
	rows := wrapText(body, width)
	from := min(offset, max(len(rows)-count, 0))
	lines := make([]string, 0, min(len(rows), count))
	for _, row := range rows[from:min(from+count, len(rows))] {
		rendered := line(style.Render(row))
		if m.zones != nil && len(rows) > count {
			rendered = m.zones.Mark(zone, rendered)
		}
		lines = append(lines, rendered)
	}
	return lines
}

func (m *Model) scrollSubagentPeek(msg tea.MouseMsg, rows int) bool {
	if m.peekTranscript == nil || m.editorTextOccluded(msg.Mouse().X, msg.Mouse().Y) {
		return false
	}
	panes := m.subagentPeek().Panes
	if len(panes) == 0 {
		return false
	}
	r := panes[0].PeekRect
	mouse := msg.Mouse()
	x, y := mouse.X-m.layout.leftPane.Width-m.semanticBodyCol(int(r.Col)), mouse.Y-m.layout.body.Y-int(r.Row)
	if x < 0 || x >= int(r.Width) || y < 0 || y >= int(r.Height) {
		return false
	}
	for _, detail := range [...]struct {
		zone, body string
		offset     *int
		rows       int
	}{
		{peekBriefScrollZone, panes[0].Brief, &m.peekBriefOffset, max(int(r.Height)/3-4, 1)},
		{peekResultScrollZone, panes[0].Result, &m.peekResultOffset, max(int(r.Height)/4, 1)},
	} {
		if m.zones != nil && m.zones.Get(detail.zone).InBounds(msg) {
			last := max(len(wrapText(detail.body, int(r.Width)))-detail.rows, 0)
			*detail.offset = min(max(*detail.offset+rows, 0), last)
			return true
		}
	}
	m.peekTranscript.scrollBy(rows)
	return true
}
