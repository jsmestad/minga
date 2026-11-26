package ui

import (
	"image/color"
	"strings"
	"unicode"
	"unicode/utf8"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// emptyListColors are the colour roles of the panel an empty list sits in.
type emptyListColors struct {
	surface       color.Color
	text          color.Color
	muted         color.Color
	accent        color.Color
	selection     color.Color
	selectionText color.Color
}

// emptyListHeader draws what happened and why (docs/design/anatomy.md, "Empty state"): the panel inset row, the title with its glyph, the why line, and the gap before the action list. The BEAM writes the copy; this only lays it out.
func emptyListHeader(empty generated.EmptyList, width int, colors emptyListColors, p palette) []string {
	base := lipgloss.NewStyle().Background(colors.surface).ColorWhitespace(true)
	inset := gap(emptyStateInset)
	// The text keeps a trailing inset, so a cut line's ellipsis never touches the border.
	room := max(width-len(inset)-listRowTrailingInset.cols(), 1)
	lines := make([]string, 0, 5)

	blank := base.Width(width).Render("")
	for range emptyStateInset.rows() {
		lines = append(lines, blank)
	}

	// A narrow panel, such as a sidebar, wraps the copy at word boundaries instead of cutting it off. A wrapped title hangs under its first word, not under the glyph.
	lead, hang := "", ""
	if empty.Glyph != "" {
		lead = empty.Glyph + gap(emptyStateGlyphToTitle)
		hang = strings.Repeat(" ", ansi.StringWidth(lead))
	}
	titleStyle := emptyStateTitleText.style(p).Inherit(base).Foreground(colors.text)
	for index, line := range wrapText(empty.Title, max(room-len(hang), 1)) {
		prefix := titleStyle.Render(hang)
		if index == 0 && lead != "" {
			glyphStyle := titleStyle.Foreground(emptyStateGlyphColor(empty.Glyph, colors.text, p))
			prefix = glyphStyle.Render(empty.Glyph) + titleStyle.Render(gap(emptyStateGlyphToTitle))
		}
		lines = append(lines, base.Width(width).Render(inset+prefix+titleStyle.Render(line)))
	}
	for range emptyStateTitleToWhy.rows() {
		lines = append(lines, blank)
	}

	if strings.TrimSpace(empty.Why) != "" {
		whyStyle := base.Foreground(colors.muted)
		for _, line := range wrapText(empty.Why, room) {
			lines = append(lines, base.Width(width).Render(inset+whyStyle.Render(line)))
		}
	}
	for range emptyStateWhyToActions.rows() {
		lines = append(lines, blank)
	}
	return lines
}

// truncateAtWord keeps whole words when they fit before the ellipsis. A first word wider than the line still gets cut.
func truncateAtWord(text string, width int) string {
	const ellipsis = "…"
	clipped := ansi.Truncate(text, width, ellipsis)
	if clipped == text {
		return text
	}
	prefix := strings.TrimSuffix(clipped, ellipsis)
	suffix, _ := strings.CutPrefix(text, prefix)
	if next, _ := utf8.DecodeRuneInString(suffix); unicode.IsSpace(next) {
		return strings.TrimRightFunc(prefix, unicode.IsSpace) + ellipsis
	}
	if gap := strings.LastIndexFunc(prefix, unicode.IsSpace); gap > 0 {
		return strings.TrimRightFunc(prefix[:gap], unicode.IsSpace) + ellipsis
	}
	return clipped
}

// Draw a known state glyph in its state role and any other glyph in the title colour.
func emptyStateGlyphColor(glyph string, title color.Color, p palette) color.Color {
	for _, state := range generated.SpineStates {
		if state.Token().Glyph == glyph {
			return p.State(state)
		}
	}
	return title
}

// wrapText breaks text into lines of at most width cells, at word boundaries where it can and inside a word that is wider than the line.
func wrapText(text string, width int) []string {
	return strings.Split(ansi.Wrap(text, width, ""), "\n")
}

// treeEmptyListColors are the colour roles of an empty list in a sidebar panel: the file tree or Git status.
func (m Model) treeEmptyListColors() emptyListColors {
	theme := m.palette()
	return emptyListColors{
		surface:       theme.TreeSurface(),
		text:          theme.TreeText(),
		muted:         theme.TreeMutedText(),
		accent:        theme.Accent(),
		selection:     theme.TreeSelection(),
		selectionText: theme.TreeSelectionText(),
	}
}

// emptyListActions draws the action list: a fixed key column in the accent colour, then the label. The selected row is a full-width selection bar whose key is a reverse-video chip.
func emptyListActions(empty generated.EmptyList, width int, colors emptyListColors) []string {
	keyWidth := 0
	for _, action := range empty.Actions {
		keyWidth = max(keyWidth, ansi.StringWidth(action.Key))
	}
	column := keyWidth + emptyStateKeyColumnGap.cols()
	inset := gap(emptyStateInset)

	lines := make([]string, 0, len(empty.Actions))
	for index, action := range empty.Actions {
		selected := index == int(empty.Selected)
		background := colors.surface
		labelColor := colors.text
		if selected {
			background = colors.selection
			labelColor = colors.selectionText
		}
		row := lipgloss.NewStyle().Background(background).ColorWhitespace(true)
		key := row.Foreground(colors.accent).Render(action.Key)
		if selected {
			key = row.Foreground(colors.surface).Background(colors.accent).Render(action.Key)
		}
		padding := row.Render(strings.Repeat(" ", max(column-ansi.StringWidth(action.Key), 1)))
		room := max(width-len(inset)-listRowTrailingInset.cols()-column, 1)
		label := row.Foreground(labelColor).Render(truncateAtWord(action.Label, room))
		lines = append(lines, row.Width(width).Render(row.Render(inset)+key+padding+label))
	}
	return lines
}
