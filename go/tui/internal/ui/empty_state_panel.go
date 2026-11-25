package ui

import (
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// Project home wire section ids and item kinds (#4056), mirrored from the
// BEAM encoder (Minga.Frontend.Adapter.GUI.EmptyStateEncoder).
const (
	emptyStateSectionRecent   byte = 1
	emptyStateSectionProjects byte = 4
	emptyStateSectionTasks    byte = 5
	emptyStateSectionNext     byte = 6

	emptyStateKindRecentFile byte = 1
	emptyStateKindAction     byte = 2
	emptyStateKindProject    byte = 4
	emptyStateKindTask       byte = 5
)

// The home is a resting view laid out like a buffer: the empty-state inset
// (spacePanel), a short top margin, then the header and sections. A row puts
// spacePanel between its key column and its label, and spaceXL between the
// label and its muted detail and meta.
const (
	homeInset        = spacePanel
	homeKeyToLabel   = spaceSM
	homeLabelToMuted = spaceXL
	homeTopMargin    = 1
)

// focusableEmptyStateItems returns the home rows that take focus and clicks,
// in display order: every row is activatable.
func focusableEmptyStateItems(state protocol.EmptyState) []protocol.EmptyStateItem {
	items := make([]protocol.EmptyStateItem, 0, 16)
	for _, section := range state.Sections {
		items = append(items, section.Items...)
	}
	return items
}

func emptyStateFocusedIndex(items []protocol.EmptyStateItem, focusedID string) int {
	for i, item := range items {
		if item.ID == focusedID {
			return i
		}
	}
	return -1
}

// effectiveEmptyFocus resolves the focused item id, preferring the locally
// echoed focus so j/k feel instant, and falling back to the BEAM-authoritative
// focused_id from the last frame.
func (m Model) effectiveEmptyFocus(state protocol.EmptyState) string {
	if m.localPresentation.previewEmptyStateIndex != nil {
		items := focusableEmptyStateItems(state)
		idx := *m.localPresentation.previewEmptyStateIndex
		if idx >= 0 && idx < len(items) {
			return items[idx].ID
		}
	}
	return state.FocusedID
}

// renderEmptyState draws the project home, *home* (#4056): the header that
// says where you are, then recent files or projects, Minga's tasks and the
// next actions. It returns exactly bodyHeight full-width lines; rows below the
// bottom are clipped, so the header and first rows always fit first.
func (m Model) renderEmptyState(state protocol.EmptyState) []string {
	width := max(m.width, 1)
	height := max(m.bodyHeight(), 1)
	focusID := m.effectiveEmptyFocus(state)
	p := m.palette()

	lines := make([]string, 0, height)
	for i := 0; i < homeTopMargin && height > 8; i++ {
		lines = append(lines, m.homeBlank(width))
	}

	lines = append(lines, m.homeText(state.Title, p.Text(), true, width))
	for _, line := range []string{state.Path, state.Status, state.Note} {
		if line != "" {
			lines = append(lines, m.homeText(line, p.Muted(), false, width))
		}
	}

	for _, section := range state.Sections {
		lines = append(lines, m.homeBlank(width))
		// Section labels sit below the title in the hierarchy: muted, not the title's colour.
		lines = append(lines, m.homeText(section.Title, p.Muted(), true, width))
		if len(section.Items) == 0 && section.Empty != "" {
			lines = append(lines, m.homeText(section.Empty, p.Muted(), false, width))
			continue
		}
		keyWidth := homeKeyWidth(section)
		for _, item := range section.Items {
			lines = append(lines, m.homeRow(item, keyWidth, width, item.ID == focusID))
		}
	}

	blank := m.homeBlank(width)
	for len(lines) < height {
		lines = append(lines, blank)
	}
	return takeLines(lines, height)
}

// homeKeyWidth is the fixed key column of a section: the widest number or
// chord, so labels line up the way the empty-state anatomy asks.
func homeKeyWidth(section protocol.EmptyStateSection) int {
	widest := 0
	for _, item := range section.Items {
		widest = max(widest, lipgloss.Width(homeKey(item)))
	}
	return widest
}

// homeKey is what a row's key column shows: the number key, the chord, or a
// task's state glyph.
func homeKey(item protocol.EmptyStateItem) string {
	switch {
	case item.JumpKey != "":
		return item.JumpKey
	case item.Chord != "":
		return item.Chord
	case item.Kind == emptyStateKindTask:
		if state, ok := homeState(item.State); ok {
			return state.Token().Glyph
		}
		return "○"
	default:
		return ""
	}
}

// homeState maps a design-token state name from the wire to its token.
func homeState(name string) (generated.SpineState, bool) {
	for _, state := range generated.SpineStates {
		if state.Token().ID == name {
			return state, true
		}
	}
	return generated.StateWorking, false
}

// homeRow draws one row: the key column in the accent colour (a task's glyph
// in its state colour), the label, then muted detail and meta. The focused row
// is a full-width selection bar whose key is a reverse-video chip.
func (m Model) homeRow(item protocol.EmptyStateItem, keyWidth int, width int, focused bool) string {
	p := m.palette()
	var rowBg color.Color = m.editorBackground()
	text := p.Text()
	muted := p.Muted()
	if focused {
		rowBg = p.Selection()
		text = p.SelectionText()
		muted = p.SelectionText()
	}
	base := lipgloss.NewStyle().Foreground(text).Background(rowBg)

	keyColor := p.Accent()
	stateColor := muted
	if item.Kind == emptyStateKindTask {
		if state, ok := homeState(item.State); ok {
			keyColor = p.State(state)
			stateColor = p.State(state)
		}
	}

	key := homeKey(item)
	keyCell := lipgloss.NewStyle().Foreground(keyColor).Background(rowBg).Bold(true).Render(key)
	// The accent colour on the selection bar misses the text contrast target in some themes, so the focused key
	// is a reverse-video chip.
	if focused && key != "" {
		keyCell = lipgloss.NewStyle().Reverse(true).Bold(true).Render(key)
	}
	keyPad := base.Render(strings.Repeat(" ", max(keyWidth-lipgloss.Width(key), 0)))

	row := base.Render(gap(homeInset)) + keyCell + keyPad + base.Render(gap(homeKeyToLabel))
	if item.Kind == emptyStateKindRecentFile && strings.TrimSpace(item.Icon) != "" {
		row += m.emptyIcon(item, rowBg, text, focused) + base.Render(" ")
	}
	row += base.Bold(focused).Render(item.Label)

	if item.Detail != "" {
		detailColor := muted
		if item.Kind == emptyStateKindTask {
			detailColor = stateColor
		}
		row += base.Render(gap(homeLabelToMuted)) + lipgloss.NewStyle().Foreground(detailColor).Background(rowBg).Render(item.Detail)
	}
	if item.Meta != "" {
		row += base.Render(gap(homeLabelToMuted)) + lipgloss.NewStyle().Foreground(muted).Background(rowBg).Render(item.Meta)
	}

	row = padExactWith(row, width, base)
	return m.zones.Mark(zoneIDEmptyStateItem(item.ID), row)
}

// homeText draws one header or section line at the inset.
func (m Model) homeText(text string, fg color.Color, bold bool, width int) string {
	bg := m.emptyBg()
	style := lipgloss.NewStyle().Foreground(fg).Background(m.editorBackground()).Bold(bold)
	return padExactWith(bg.Render(gap(homeInset))+style.Render(text), width, bg)
}

func (m Model) homeBlank(width int) string {
	return m.emptyBg().Render(strings.Repeat(" ", width))
}

func (m Model) emptyBg() lipgloss.Style {
	return lipgloss.NewStyle().Background(m.editorBackground())
}

// padExactWith pads (or truncates) a styled fragment to exactly width, filling
// with the given background style.
func padExactWith(fragment string, width int, bg lipgloss.Style) string {
	vis := lipgloss.Width(fragment)
	if vis == width {
		return fragment
	}
	if vis > width {
		return lipgloss.NewStyle().Inline(true).MaxWidth(width).Render(fragment)
	}
	return fragment + bg.Render(strings.Repeat(" ", width-vis))
}

// emptyIcon renders a file row's devicon glyph in its wire colour, in a fixed
// two-cell slot so the label column never shifts with glyph widths.
// emptyIcon draws a file's icon in its file-type colour, or in the row's text
// colour on the focused row, where a file-type colour on the selection bar can
// fall below the glyph contrast target.
func (m Model) emptyIcon(item protocol.EmptyStateItem, rowBg color.Color, textColor color.Color, focused bool) string {
	style := lipgloss.NewStyle().Background(rowBg).Width(wideGlyphCols).MaxWidth(wideGlyphCols)
	if item.IconColor != 0 && !focused {
		style = style.Foreground(lipgloss.Color(iconColorHex(item.IconColor)))
	} else {
		style = style.Foreground(textColor)
	}
	return style.Render(strings.TrimSpace(item.Icon))
}
