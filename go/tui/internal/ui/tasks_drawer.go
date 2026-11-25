package ui

import (
	"strconv"
	"strings"

	"github.com/charmbracelet/x/ansi"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// The tasks drawer (`*minga-tasks*`) is a real split along the bottom of the window: the BEAM reserves its rows, so the
// editor above never sits under it. Its anatomy follows docs/design/anatomy.md "Drawer" and "List row": a rounded border
// that takes the focus colour only while the drawer has the keyboard, the buffer name and title with the state counts in
// the top border, the key hints in the bottom border, and one list row per task or subagent. Everything it says comes
// from the BEAM; the TUI only lays it out and turns clicks into tasks_drawer_action with the row's identity.

const (
	tasksDrawerViewList        = 0
	tasksDrawerViewDiff        = 1
	tasksDrawerRowFlagLast     = 0x01
	tasksDrawerRowFlagSelected = 0x02
	tasksDrawerCloseZone       = "tasks-drawer-close"
)

func zoneIDTasksDrawerRow(id string) string { return "tasks-drawer-row:" + id }

func zoneIDTasksDrawerAction(id, key string) string { return "tasks-drawer-action:" + id + ":" + key }

func zoneIDTasksDrawerEmptyAction(index int) string {
	return "tasks-drawer-empty-action:" + strconv.Itoa(index)
}

func (m Model) tasksDrawer() (generated.GuiTasksDrawerFields, bool) {
	payload, ok := m.chrome[generated.OPGuiTasksDrawer]
	if !ok || payload.TasksDrawer.Visible == 0 {
		return generated.GuiTasksDrawerFields{}, false
	}
	return payload.TasksDrawer, true
}

// tasksDrawerLayer paints the drawer in its reserved rows. Like the timeline it is persistent chrome, not a popup.
func (m Model) tasksDrawerLayer() *lipgloss.Layer {
	drawer, visible := m.tasksDrawer()
	rect := m.layout.drawer
	if !visible || rect.Width == 0 || rect.Height == 0 {
		return nil
	}
	content := m.zones.ScanInto(strings.Join(m.renderTasksDrawer(drawer, rect.Width, rect.Height), "\n"), rect.X, rect.Y)
	return lipgloss.NewLayer(content).X(rect.X).Y(rect.Y).Z(2)
}

func (m Model) renderTasksDrawer(drawer generated.GuiTasksDrawerFields, width, height int) []string {
	if width <= 0 || height <= 0 {
		return nil
	}
	p := m.palette()
	frame := m.tasksDrawerFrame(drawer.Focused != 0)
	innerWidth := frame.contentWidth(width)
	innerHeight := frame.contentHeight(height)

	body := m.tasksDrawerBody(drawer, innerWidth, innerHeight)
	top := m.tasksDrawerTopBorder(drawer, width, p)
	bottom := m.tasksDrawerBottomBorder(drawer, width, p)
	middle := frame.renderSides(width, body)
	lines := append([]string{top}, middle...)
	return takeLines(append(lines, bottom), height)
}

// tasksDrawerBody is the list: one row per task or subagent, the needs-you row expanded with its request and answers.
func (m Model) tasksDrawerBody(drawer generated.GuiTasksDrawerFields, width, height int) []string {
	p := m.palette()
	surface := lipgloss.NewStyle().Background(p.Surface())
	bodyHeight := height
	prompt := ""
	if drawer.Prompt != "" && height > 0 {
		bodyHeight--
		prompt = padTo(lipgloss.NewStyle().Background(p.Surface()).Foreground(p.Role(generated.ColorRoleNeedsYou)).Bold(true).Render(gap(listRowGlyphToTitle)+clipText(sanitizeTerminalText(drawer.Prompt), max(width-listRowGlyphToTitle.cols(), 1))), width, surface)
	}
	var lines []string
	switch {
	case drawer.View != tasksDrawerViewList:
		lines = m.tasksDrawerViewLines(drawer, width, bodyHeight)
	case drawer.HasEmpty != 0:
		lines = m.tasksDrawerEmptyLines(drawer.Empty, width)
	default:
		lines = m.tasksDrawerListLines(drawer, width, bodyHeight)
	}
	lines = takeLines(lines, bodyHeight)
	blank := surface.Render(strings.Repeat(" ", max(width, 0)))
	for len(lines) < bodyHeight {
		lines = append(lines, blank)
	}
	if prompt != "" {
		lines = append(lines, prompt)
	}
	return lines
}

// tasksDrawerEmptyLines draws the empty state (docs/design/anatomy.md, "Empty state"): what happened, why, and the next
// steps with the selected one barred. Each step is a click zone that runs its command.
func (m Model) tasksDrawerEmptyLines(empty generated.EmptyList, width int) []string {
	colors := m.tasksDrawerEmptyColors()
	lines := emptyListHeader(empty, width, colors, m.palette())
	for index, row := range emptyListActions(empty, width, colors) {
		lines = append(lines, m.zones.Mark(zoneIDTasksDrawerEmptyAction(index), row))
	}
	return lines
}

// tasksDrawerEmptyColors are the drawer's own colour roles, so its empty state reads as part of the drawer.
func (m Model) tasksDrawerEmptyColors() emptyListColors {
	p := m.palette()
	return emptyListColors{
		surface:       p.Surface(),
		text:          p.Text(),
		muted:         p.Muted(),
		accent:        p.Accent(),
		selection:     p.TreeSelection(),
		selectionText: p.TreeSelectionText(),
	}
}

// tasksDrawerListLines draws the rows, starting low enough that the selected row and its expanded lines are on screen,
// so a key never acts on a task the user cannot see.
func (m Model) tasksDrawerListLines(drawer generated.GuiTasksDrawerFields, width, height int) []string {
	var lines []string
	selectedStart, selectedEnd := -1, -1
	for _, row := range drawer.Rows {
		rowLines := m.tasksDrawerRowLines(row, width, drawer.Focused != 0)
		if row.Flags&tasksDrawerRowFlagSelected != 0 {
			selectedStart, selectedEnd = len(lines), len(lines)+len(rowLines)
		}
		lines = append(lines, rowLines...)
	}
	if selectedEnd > height && height > 0 {
		start := min(selectedEnd-height, selectedStart)
		lines = lines[start:]
	}
	return lines
}

// tasksDrawerViewLines draws one task's request diff or output: its title, then its lines from the BEAM's scroll offset,
// a diff's added and removed lines in their colours.
func (m Model) tasksDrawerViewLines(drawer generated.GuiTasksDrawerFields, width, height int) []string {
	p := m.palette()
	base := lipgloss.NewStyle().Background(p.Surface())
	inset := base.Render(gap(listRowGlyphToTitle))
	budget := max(width-listRowGlyphToTitle.cols()-listRowTrailingInset.cols(), 1)
	lines := []string{padTo(inset+drawerTitleText.style(p).Background(p.Surface()).Render(clipWithEllipsis(sanitizeTerminalText(drawer.ViewTitle), budget)), width, base)}
	start := min(int(drawer.ViewOffset), len(drawer.ViewLines))
	for _, line := range drawer.ViewLines[start:] {
		if len(lines) >= height {
			break
		}
		text := sanitizeTerminalText(line.Text)
		style := base.Foreground(p.Text())
		if drawer.View == tasksDrawerViewDiff {
			switch {
			case strings.HasPrefix(text, "+"):
				style = base.Foreground(p.GitAdded())
			case strings.HasPrefix(text, "-"):
				style = base.Foreground(p.GitDeleted())
			case strings.HasPrefix(text, "@@"):
				style = base.Foreground(p.Muted())
			}
		}
		lines = append(lines, padTo(inset+style.Render(clipText(text, budget)), width, base))
	}
	return lines
}

func (m Model) tasksDrawerRowLines(row generated.TasksDrawerRow, width int, focused bool) []string {
	p := m.palette()
	selected := row.Flags&tasksDrawerRowFlagSelected != 0
	// The selected row is a list selection, like the file tree's: its text takes the selection's own foreground, so
	// it reads on the selection in every theme. The glyph keeps the state's colour.
	barred := selected && focused
	background := p.Surface()
	switch {
	case barred:
		background = p.TreeSelection()
	case selected:
		background = p.SurfaceAlt()
	}
	base := lipgloss.NewStyle().Background(background)
	text := base.Foreground(p.Text())
	muted := base.Foreground(p.Muted())
	stateColor := p.Muted()
	glyph := " "
	if state, ok := generated.SpineStateFromWire(row.State); ok {
		stateColor = p.Role(state.Token().Role)
		glyph = state.Token().Glyph
	}
	glyphStyle := base.Foreground(stateColor)
	stateStyle := glyphStyle
	if barred {
		text = base.Foreground(p.TreeSelectionText())
		muted, stateStyle = text, text
	}

	// The selection edge is drawn in the row's state role, like its glyph (anatomy: List row, selection edge).
	edge := base.Render(" ")
	if selected {
		edge = glyphStyle.Render("▌")
	}
	indent := ""
	if row.Depth > 0 {
		branch := "├─"
		if row.Flags&tasksDrawerRowFlagLast != 0 {
			branch = "└─"
		}
		indent = muted.Render(gap(listRowGlyphToTitle) + branch)
	}
	lead := edge + indent + base.Render(gap(listRowGlyphToTitle)) + glyphStyle.Render(glyph) + base.Render(gap(listRowGlyphToTitle))
	titleStyle := text
	age := muted.Render(sanitizeTerminalText(row.Age))
	action := ""
	if len(row.Actions) > 0 && !(selected && len(row.Detail) > 0) {
		first, _ := m.tasksDrawerActions(row, row.Actions[:1], base, barred, 0)
		action = first + base.Render(gap(listRowTitleToMeta))
	}
	right := action + age + base.Render(gap(listRowTrailingInset))
	// The title keeps at least a third of the room between the mark and the actions; the words take the rest. A gap
	// always separates the title from the words and the words from the action, and cut text ends in an ellipsis.
	room := max(width-lipgloss.Width(lead)-lipgloss.Width(right)-2*listRowTitleToMeta.cols(), 1)
	wordsBudget := max(room-max(room/3, 1), 1)
	words := stateStyle.Render(clipWithEllipsis(sanitizeTerminalText(row.Words), wordsBudget))
	titleBudget := max(room-lipgloss.Width(words), 1)
	title := titleStyle.Render(clipWithEllipsis(sanitizeTerminalText(row.Title), titleBudget))
	left := lead + title + base.Render(gap(listRowTitleToMeta)) + words
	fill := base.Render(strings.Repeat(" ", max(width-lipgloss.Width(left)-lipgloss.Width(right), listRowTitleToMeta.cols())))
	first := m.zones.Mark(zoneIDTasksDrawerRow(row.ID), fit(left+fill+right, width))
	lines := []string{first}
	if !selected || len(row.Detail) == 0 {
		return lines
	}
	// The expanded needs-you row: the request on its own line, then its answers, aligned to the title.
	// The expanded row's lines carry the same selection edge as its first line.
	detailLead := edge + base.Render(strings.Repeat(" ", max(lipgloss.Width(lead)-lipgloss.Width(edge), 0)))
	detailBudget := max(width-lipgloss.Width(detailLead)-listRowTrailingInset.cols(), 1)
	for _, line := range row.Detail {
		content := detailLead + text.Render(clipWithEllipsis(sanitizeTerminalText(line.Text), detailBudget))
		lines = append(lines, padTo(content, width, base))
	}
	// Answers that do not fit on one line wrap onto the next, so every answer stays visible and clickable.
	for actions := row.Actions; len(actions) > 0; {
		answers, kept := m.tasksDrawerActions(row, actions, base, barred, detailBudget)
		lines = append(lines, padTo(detailLead+answers, width, base))
		actions = actions[kept:]
	}
	return lines
}

// tasksDrawerActions draws `key Label` pairs, each its own click target that names the row and the key, with keys in the
// accent like the drawer's hints. Within `budget` columns (0 for no limit) it keeps whole hints, always at least one, and
// returns how many it kept so the caller can draw the rest on another line.
func (m Model) tasksDrawerActions(row generated.TasksDrawerRow, actions []generated.TasksDrawerHint, base lipgloss.Style, barred bool, budget int) (string, int) {
	p := m.palette()
	key := base.Foreground(p.Accent()).Bold(true)
	label := base.Foreground(p.Text())
	if barred {
		key = base.Foreground(p.TreeSelectionText()).Bold(true)
		label = base.Foreground(p.TreeSelectionText())
	}
	parts := make([]string, 0, len(actions))
	used := 0
	for _, action := range actions {
		hint := key.Render(sanitizeTerminalText(action.Key)) + base.Render(gap(drawerKeyToHint)) + label.Render(sanitizeTerminalText(action.Label))
		need := lipgloss.Width(hint)
		if len(parts) > 0 {
			need += drawerHintToHint.cols()
		}
		if budget > 0 && len(parts) > 0 && used+need > budget {
			break
		}
		used += need
		parts = append(parts, m.zones.Mark(zoneIDTasksDrawerAction(row.ID, action.Key), hint))
	}
	return strings.Join(parts, base.Render(gap(drawerHintToHint))), len(parts)
}

// clipWithEllipsis cuts text to width cells, ending in "…" when it was cut, so a reader sees that text is missing.
func clipWithEllipsis(value string, width int) string {
	if width <= 0 {
		return ""
	}
	if displayWidth(value) <= width {
		return value
	}
	return ansi.TruncateWc(value, width, "…")
}

// tasksDrawerTopBorder carries the buffer name, the title and any hidden drawer's note on the left and the state counts on
// the right, inside the rounded border's top edge.
func (m Model) tasksDrawerTopBorder(drawer generated.GuiTasksDrawerFields, width int, p palette) string {
	border := m.tasksDrawerBorderStyle(drawer.Focused != 0)
	edge := lipgloss.RoundedBorder()
	muted := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.Surface())
	title := drawerTitleText.style(p).Background(p.Surface())
	left := muted.Render(" "+sanitizeTerminalText(drawer.Name)) + muted.Render(gap(drawerTitleToCounts)) + title.Render(sanitizeTerminalText(drawer.Title)+" ")
	if drawer.Note != "" {
		left += muted.Render(gap(drawerTitleToCounts) + sanitizeTerminalText(drawer.Note) + " ")
	}
	counts := make([]string, 0, len(drawer.Counts))
	for _, count := range drawer.Counts {
		state, ok := generated.SpineStateFromWire(count.State)
		if !ok {
			continue
		}
		style := lipgloss.NewStyle().Foreground(p.Role(state.Token().Role)).Background(p.Surface())
		counts = append(counts, style.Render(state.Token().Glyph+gap(spaceXS)+strconv.Itoa(int(count.Count))))
	}
	right := ""
	if len(counts) > 0 {
		// A glyph sits next to its number; count groups sit apart like hints, so each pair reads as one.
		right = muted.Render(" ") + strings.Join(counts, muted.Render(gap(drawerHintToHint))) + muted.Render(" ")
	}
	inner := max(width-2, 0)
	left = clipText(left, max(inner-lipgloss.Width(right), 0))
	fill := border.Render(strings.Repeat(edge.Top, max(inner-lipgloss.Width(left)-lipgloss.Width(right), 0)))
	return border.Render(edge.TopLeft) + left + fill + right + border.Render(edge.TopRight)
}

// tasksDrawerBottomBorder carries the key hints while the drawer has the keyboard, and a click target to close it.
func (m Model) tasksDrawerBottomBorder(drawer generated.GuiTasksDrawerFields, width int, p palette) string {
	border := m.tasksDrawerBorderStyle(drawer.Focused != 0)
	edge := lipgloss.RoundedBorder()
	key := lipgloss.NewStyle().Foreground(p.Accent()).Background(p.Surface())
	label := drawerHintText.style(p).Background(p.Surface())
	parts := make([]string, 0, len(drawer.Hints))
	for _, hint := range drawer.Hints {
		part := key.Render(sanitizeTerminalText(hint.Key)) + label.Render(gap(drawerKeyToHint)+sanitizeTerminalText(hint.Label))
		if hint.Key == "q" {
			part = m.zones.Mark(tasksDrawerCloseZone, part)
		}
		parts = append(parts, part)
	}
	hints := ""
	if len(parts) > 0 {
		hints = label.Render(" ") + strings.Join(parts, label.Render(gap(drawerHintToHint))) + label.Render(" ")
	}
	inner := max(width-2, 0)
	hints = clipText(hints, inner)
	fill := border.Render(strings.Repeat(edge.Bottom, max(inner-lipgloss.Width(hints), 0)))
	return border.Render(edge.BottomLeft) + hints + fill + border.Render(edge.BottomRight)
}

func (m Model) tasksDrawerBorderStyle(focused bool) lipgloss.Style {
	p := m.palette()
	color := p.PopupBorder()
	if focused {
		color = p.Accent()
	}
	return lipgloss.NewStyle().Foreground(color).Background(p.Surface())
}

// tasksDrawerFrame is the drawer's border and body inset; its content budget follows them.
func (m Model) tasksDrawerFrame(focused bool) tasksDrawerBox {
	return tasksDrawerBox{border: m.tasksDrawerBorderStyle(focused), surface: lipgloss.NewStyle().Background(m.palette().Surface())}
}

type tasksDrawerBox struct {
	border  lipgloss.Style
	surface lipgloss.Style
}

func (b tasksDrawerBox) contentWidth(outer int) int { return max(outer-2, 0) }

func (b tasksDrawerBox) contentHeight(outer int) int { return max(outer-2, 0) }

func (b tasksDrawerBox) renderSides(outer int, body []string) []string {
	edge := lipgloss.RoundedBorder()
	lines := make([]string, 0, len(body))
	for _, line := range body {
		lines = append(lines, b.border.Render(edge.Left)+padTo(line, b.contentWidth(outer), b.surface)+b.border.Render(edge.Right))
	}
	return lines
}

// tasksDrawerMousePacket turns a click in the drawer into tasks_drawer_action: an action names its row and key, a row
// selects itself, an empty state's next step runs its command, the close hint closes the drawer, and any other cell
// gives the drawer the keyboard.
func (m Model) tasksDrawerMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	drawer, ok := m.tasksDrawer()
	if !ok {
		return nil, false
	}
	if zone := m.zones.Get(tasksDrawerCloseZone); zone != nil && zone.InBounds(msg) {
		return protocol.EncodeGUITasksDrawerAction("", "q"), true
	}
	for _, row := range drawer.Rows {
		for _, action := range row.Actions {
			if zone := m.zones.Get(zoneIDTasksDrawerAction(row.ID, action.Key)); zone != nil && zone.InBounds(msg) {
				return protocol.EncodeGUITasksDrawerAction(row.ID, action.Key), true
			}
		}
	}
	for _, row := range drawer.Rows {
		if zone := m.zones.Get(zoneIDTasksDrawerRow(row.ID)); zone != nil && zone.InBounds(msg) {
			return protocol.EncodeGUITasksDrawerAction(row.ID, "select"), true
		}
	}
	if drawer.HasEmpty != 0 {
		for index, action := range drawer.Empty.Actions {
			if zone := m.zones.Get(zoneIDTasksDrawerEmptyAction(index)); zone != nil && zone.InBounds(msg) {
				return protocol.EncodeGUIExecuteCommand(action.ID), true
			}
		}
	}
	return protocol.EncodeGUITasksDrawerAction("", "focus"), true
}

func padTo(line string, width int, style lipgloss.Style) string {
	return fit(line+style.Render(strings.Repeat(" ", max(width-lipgloss.Width(line), 0))), width)
}

// clipText cuts text to width cells without padding it, so the caller's own styled fill follows.
func clipText(value string, width int) string {
	if width <= 0 {
		return ""
	}
	if displayWidth(value) <= width {
		return value
	}
	return ansi.TruncateWc(value, width, "")
}
