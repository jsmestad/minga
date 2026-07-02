package ui

import (
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// Launchpad wire section ids and item kinds (#2689), mirrored from the BEAM
// encoder (Minga.Frontend.Adapter.GUI.EmptyStateEncoder).
const (
	emptyStateSectionSession byte = 0
	emptyStateSectionRecent  byte = 1
	emptyStateSectionStart   byte = 2
	emptyStateSectionFooter  byte = 3

	emptyStateKindResume     byte = 0
	emptyStateKindRecentFile byte = 1
	emptyStateKindAction     byte = 2
	emptyStateKindHint       byte = 3
)

// focusableEmptyStateItems returns the launchpad items that participate in
// focus movement and click activation, in display order. Hint rows (footer)
// are informational and excluded.
func focusableEmptyStateItems(state protocol.EmptyState) []protocol.EmptyStateItem {
	items := make([]protocol.EmptyStateItem, 0, 8)
	for _, section := range state.Sections {
		for _, item := range section.Items {
			if item.Kind == emptyStateKindHint {
				continue
			}
			items = append(items, item)
		}
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
// echoed focus (#2689) so j/k feel instant, and falling back to the
// BEAM-authoritative focused_id from the last frame.
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

// renderEmptyState composes the launchpad body from the shared chrome
// primitives (titled card, section rule, keycap chip, devicon) per the #2689
// visual spec. It returns exactly bodyHeight full-width lines: the centered
// column never scrolls and never clips mid-card. A fixed degradation ladder
// drops elements as the terminal shrinks (footer, then recents cap + rules +
// wordmark, then a minimal hint block).
func (m Model) renderEmptyState(state protocol.EmptyState) []string {
	width := max(m.width, 1)
	height := max(m.bodyHeight(), 1)

	if height < 12 {
		return m.emptyStateMinimal(state, width, height)
	}

	colWidth := min(max(width-8, 44), 56)
	colWidth = min(colWidth, width)
	if colWidth < 1 {
		colWidth = 1
	}
	leftPad := max((width-colWidth)/2, 0)

	dropDir := width < 64
	dropBorders := width < 48
	showChrome := height >= 16 // wordmark + section rules
	showFooter := height >= 22
	recentCap := 5
	if height < 22 {
		recentCap = 3
	}

	focusID := m.effectiveEmptyFocus(state)

	col := make([]string, 0, 24)
	if showChrome {
		col = append(col, m.emptyWordmark(state.Version, colWidth))
		col = append(col, m.emptyBlankCol(colWidth))
	}

	for _, section := range state.Sections {
		switch section.ID {
		case emptyStateSectionSession:
			col = append(col, m.emptySessionSection(section, colWidth, focusID, state.Crashed, dropBorders)...)
			col = append(col, m.emptyBlankCol(colWidth))
		case emptyStateSectionRecent:
			if showChrome {
				col = append(col, m.emptyRule(section.Title, colWidth, m.palette().TextFaint()))
			}
			col = append(col, m.emptyRecentRows(section, colWidth, focusID, recentCap, dropDir)...)
			col = append(col, m.emptyBlankCol(colWidth))
		case emptyStateSectionStart:
			if showChrome {
				col = append(col, m.emptyRule(section.Title, colWidth, m.palette().TextFaint()))
			}
			col = append(col, m.emptyStartRows(section, colWidth, focusID)...)
			col = append(col, m.emptyBlankCol(colWidth))
		case emptyStateSectionFooter:
			if showFooter && len(section.Items) > 0 {
				col = append(col, m.emptyFooter(section, colWidth))
			}
		}
	}
	col = trimTrailingBlank(col, m.emptyBlankCol(colWidth))

	return m.emptyPlaceColumn(col, leftPad, colWidth, width, height)
}

// emptyStateMinimal is the sub-12-row fallback: a compact wordmark plus a
// single hint line, centered. It still teaches "write" and "quit" without any
// cards, rules, or recents.
func (m Model) emptyStateMinimal(state protocol.EmptyState, width int, height int) []string {
	colWidth := min(max(width-8, 20), 56)
	colWidth = min(colWidth, width)
	if colWidth < 1 {
		colWidth = 1
	}
	leftPad := max((width-colWidth)/2, 0)
	p := m.palette()
	bg := m.editorBackground()

	mark := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(bg).Render("◆") +
		lipgloss.NewStyle().Background(bg).Render(" ") +
		lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(bg).Render("minga")
	if v := strings.TrimSpace(state.Version); v != "" {
		mark += lipgloss.NewStyle().Background(bg).Render(" ") + lipgloss.NewStyle().Foreground(p.TextFaint()).Background(bg).Render(v)
	}

	col := []string{m.emptyCenterInCol(mark, colWidth)}
	if footer := m.emptyFooterText(state); footer != "" {
		col = append(col, m.emptyCenterInCol(footer, colWidth))
	}

	return m.emptyPlaceColumn(col, leftPad, colWidth, width, height)
}

// emptyPlaceColumn centers a list of colWidth-wide styled lines horizontally
// (leftPad) and vertically within height, padding with editor-background
// blanks so the result is exactly height full-width lines.
func (m Model) emptyPlaceColumn(col []string, leftPad int, colWidth int, width int, height int) []string {
	placed := make([]string, 0, len(col))
	for _, line := range col {
		placed = append(placed, m.emptyPlace(line, leftPad, colWidth, width))
	}
	blank := m.emptyBg().Render(strings.Repeat(" ", width))
	top := max((height-len(placed))/2, 0)
	out := make([]string, 0, height)
	for i := 0; i < top; i++ {
		out = append(out, blank)
	}
	out = append(out, placed...)
	for len(out) < height {
		out = append(out, blank)
	}
	return takeLines(out, height)
}

func trimTrailingBlank(col []string, blank string) []string {
	for len(col) > 0 && col[len(col)-1] == blank {
		col = col[:len(col)-1]
	}
	return col
}

func (m Model) emptyBg() lipgloss.Style {
	return lipgloss.NewStyle().Background(m.editorBackground())
}

func (m Model) emptyBlankCol(colWidth int) string {
	return m.emptyBg().Render(strings.Repeat(" ", max(colWidth, 0)))
}

// emptyPlace wraps a colWidth-wide line with editor-background left/right pad to
// center it within width. The line may carry zero-width zone markers, so the
// pad math uses the known colWidth rather than measuring the marked string.
func (m Model) emptyPlace(line string, leftPad int, colWidth int, width int) string {
	bg := m.emptyBg()
	right := max(width-leftPad-colWidth, 0)
	return bg.Render(strings.Repeat(" ", leftPad)) + line + bg.Render(strings.Repeat(" ", right))
}

// emptyCenterInCol centers a pre-styled fragment within a colWidth cell,
// padding both sides with editor background.
func (m Model) emptyCenterInCol(fragment string, colWidth int) string {
	vis := lipgloss.Width(fragment)
	if vis >= colWidth {
		return m.emptyPadExact(fragment, colWidth)
	}
	leftN := (colWidth - vis) / 2
	rightN := colWidth - vis - leftN
	bg := m.emptyBg()
	return bg.Render(strings.Repeat(" ", leftN)) + fragment + bg.Render(strings.Repeat(" ", rightN))
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

func (m Model) emptyPadExact(fragment string, width int) string {
	return padExactWith(fragment, width, m.emptyBg())
}

// emptyWordmark renders the `◆  m i n g a   v<version>` mark: accent-bold
// diamond, letter-spaced product name in bold body text, muted version.
func (m Model) emptyWordmark(version string, colWidth int) string {
	p := m.palette()
	bg := m.editorBackground()
	diamond := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(bg).Render("◆")
	name := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(bg).Render("m i n g a")
	space := lipgloss.NewStyle().Background(bg)
	mark := diamond + space.Render("  ") + name
	if v := strings.TrimSpace(version); v != "" {
		mark += space.Render("   ") + lipgloss.NewStyle().Foreground(p.TextFaint()).Background(bg).Render(v)
	}
	return m.emptyCenterInCol(mark, colWidth)
}

// emptyRule renders a labeled section rule: `─── LABEL ───────`. Rules are
// tertiary chrome: faint dashes and an uppercase muted label, receding below
// row labels so the hero card carries the only at-rest emphasis.
func (m Model) emptyRule(title string, colWidth int, borderColor color.Color) string {
	p := m.palette()
	bg := m.editorBackground()
	dash := lipgloss.NewStyle().Foreground(borderColor).Background(bg)
	label := lipgloss.NewStyle().Foreground(p.Muted()).Background(bg).Render(strings.ToUpper(title))
	content := dash.Render("  ─── ") + label + dash.Render(" ")
	fill := max(colWidth-lipgloss.Width(content), 0)
	content += dash.Render(strings.Repeat("─", fill))
	return m.emptyPadExact(content, colWidth)
}

// emptyKeycap renders a content-hugging keycap chip (one padding cell per
// side, so "SPC" and "f" get the same visual margin). Two classes: jump chips
// are "press me right now" affordances in accent on the accent wash; chord
// chips are quiet educational neutrals on the chip surface. KeycapSurface is
// deliberately NOT used here — it is tuned for elevated popup backgrounds
// (which-key) and outshines everything on the editor surface. RET renders as ↵.
func (m Model) emptyKeycap(text string, jump bool) string {
	p := m.palette()
	if text == "RET" {
		text = "↵"
	}

	style := lipgloss.NewStyle().Padding(0, 1)
	if jump {
		style = style.Bold(true).Foreground(p.Accent()).Background(p.AccentWash())
	} else {
		style = style.Foreground(p.Muted()).Background(p.ChipSurface())
	}

	return style.Render(text)
}

// emptyBorderColor returns the card border/title/glyph color for the session
// hero: warning on crash, accent while a row inside is focused, otherwise a
// dimmed accent so the hero is the only accent-hued element at rest. Only one
// full-accent border exists on screen at a time.
func (m Model) emptyBorderColor(crashed bool, focused bool) color.Color {
	p := m.palette()
	switch {
	case crashed:
		return p.Warning()
	case focused:
		return p.Accent()
	default:
		return p.AccentSoft()
	}
}

// emptySessionSection renders the hero card (resume / get-started / crashed).
// With borders it is a three-line rounded card with the title in the top edge;
// below the 48-column breakpoint it degrades to a plain row under a rule.
func (m Model) emptySessionSection(section protocol.EmptyStateSection, colWidth int, focusID string, crashed bool, dropBorders bool) []string {
	if len(section.Items) == 0 {
		return nil
	}
	item := section.Items[0]
	focused := item.ID == focusID
	bg := m.editorBackground()
	border := m.emptyBorderColor(crashed, focused)

	if dropBorders {
		rule := m.emptyRule(section.Title, colWidth, border)
		row := m.emptyCardRow(item, colWidth, focused)
		return []string{rule, row}
	}

	borderStyle := lipgloss.NewStyle().Foreground(border).Background(bg)
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(border).Background(bg)
	inner := max(colWidth-2, 1)
	titleText := " " + section.Title + " "
	dashCount := max(inner-lipgloss.Width(titleText), 0)
	topLine := m.emptyPadExact(borderStyle.Render("╭")+titleStyle.Render(titleText)+borderStyle.Render(strings.Repeat("─", dashCount)+"╮"), colWidth)

	rowInner := m.emptyCardInner(item, inner, focused)
	midLine := m.emptyPadExact(borderStyle.Render("│")+rowInner+borderStyle.Render("│"), colWidth)
	midLine = m.zones.Mark(zoneIDEmptyStateItem(item.ID), midLine)

	bottomLine := m.emptyPadExact(borderStyle.Render("╰"+strings.Repeat("─", inner)+"╯"), colWidth)

	return []string{topLine, midLine, bottomLine}
}

// emptyCardInner builds the resume/tutorial card's content row to exactly the
// inner card width: focus marker, jump keycap chip, label, right-aligned detail.
func (m Model) emptyCardInner(item protocol.EmptyStateItem, inner int, focused bool) string {
	p := m.palette()
	var rowBg color.Color = m.editorBackground()
	detailColor := p.TextFaint()
	if focused {
		// A faint accent wash instead of the heavy text-selection gray: the
		// bold label, accent marker, and chip keep their contrast on it.
		rowBg = p.AccentWash()
		detailColor = p.Muted()
	}
	base := lipgloss.NewStyle().Foreground(p.Text()).Background(rowBg)

	marker := base.Render("  ")
	if focused {
		marker = lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(rowBg).Render("▸") + base.Render(" ")
	}
	chip := m.emptyKeycap(item.JumpKey, true)
	label := base.Bold(focused).Render(item.Label)
	left := base.Render(" ") + marker + chip + base.Render("  ") + label

	right := ""
	if item.Detail != "" {
		right = lipgloss.NewStyle().Foreground(detailColor).Background(rowBg).Render(item.Detail) + base.Render(" ")
	}

	gap := max(inner-lipgloss.Width(left)-lipgloss.Width(right), 1)
	content := left + base.Render(strings.Repeat(" ", gap)) + right
	return padExactWith(content, inner, base)
}

// emptyCardRow renders the borderless session row used below the 48-column
// breakpoint. It reuses the card inner layout at the full column width.
func (m Model) emptyCardRow(item protocol.EmptyStateItem, colWidth int, focused bool) string {
	row := m.emptyCardInner(item, colWidth, focused)
	return m.zones.Mark(zoneIDEmptyStateItem(item.ID), row)
}

func (m Model) emptyRecentRows(section protocol.EmptyStateSection, colWidth int, focusID string, limit int, dropDir bool) []string {
	rows := make([]string, 0, len(section.Items))
	for i, item := range section.Items {
		if i >= limit {
			break
		}
		rows = append(rows, m.emptyRecentRow(item, colWidth, item.ID == focusID, dropDir))
	}
	return rows
}

// emptyRecentRow renders one recent-file row: jump keycap, per-file devicon,
// basename in body text, right-aligned directory in muted (dropped under the
// 64-column breakpoint). A focused row gets the selection bar and ▸ marker.
func (m Model) emptyRecentRow(item protocol.EmptyStateItem, colWidth int, focused bool, dropDir bool) string {
	p := m.palette()
	var rowBg color.Color = m.editorBackground()
	detailColor := p.TextFaint()
	if focused {
		rowBg = p.AccentWash()
		detailColor = p.Muted()
	}
	base := lipgloss.NewStyle().Foreground(p.Text()).Background(rowBg)

	marker := base.Render("  ")
	if focused {
		marker = lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(rowBg).Render("▸") + base.Render(" ")
	}
	chip := m.emptyKeycap(item.JumpKey, true)
	icon := m.emptyIcon(item, rowBg, p.Text(), focused)
	label := base.Bold(focused).Render(item.Label)
	left := base.Render(" ") + marker + chip + base.Render("  ") + icon + base.Render(" ") + label

	right := ""
	if !dropDir && item.Detail != "" {
		right = lipgloss.NewStyle().Foreground(detailColor).Background(rowBg).Render(item.Detail) + base.Render(" ")
	}

	gap := max(colWidth-lipgloss.Width(left)-lipgloss.Width(right), 1)
	content := left + base.Render(strings.Repeat(" ", gap)) + right
	content = padExactWith(content, colWidth, base)
	return m.zones.Mark(zoneIDEmptyStateItem(item.ID), content)
}

func (m Model) emptyStartRows(section protocol.EmptyStateSection, colWidth int, focusID string) []string {
	rows := make([]string, 0, len(section.Items))
	for _, item := range section.Items {
		rows = append(rows, m.emptyStartRow(item, colWidth, item.ID == focusID))
	}
	return rows
}

// emptyStartRow renders one action row: devicon, label, and a right-aligned
// input affordance. A chord ("SPC f f") renders as one keycap chip per token; a
// leading-colon detail (":Tutor") renders as accent-bold ex-command text.
func (m Model) emptyStartRow(item protocol.EmptyStateItem, colWidth int, focused bool) string {
	p := m.palette()
	var rowBg color.Color = m.editorBackground()
	if focused {
		rowBg = p.AccentWash()
	}
	base := lipgloss.NewStyle().Foreground(p.Text()).Background(rowBg)

	marker := base.Render("  ")
	if focused {
		marker = lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(rowBg).Render("▸") + base.Render(" ")
	}
	icon := m.emptyIcon(item, rowBg, p.Text(), focused)
	label := base.Bold(focused).Render(item.Label)
	left := base.Render(" ") + marker + base.Render("  ") + icon + base.Render("  ") + label

	right := m.emptyStartAffordance(item, rowBg, base)

	gap := max(colWidth-lipgloss.Width(left)-lipgloss.Width(right), 1)
	content := left + base.Render(strings.Repeat(" ", gap)) + right
	content = padExactWith(content, colWidth, base)
	return m.zones.Mark(zoneIDEmptyStateItem(item.ID), content)
}

func (m Model) emptyStartAffordance(item protocol.EmptyStateItem, rowBg color.Color, base lipgloss.Style) string {
	p := m.palette()
	if strings.TrimSpace(item.Chord) != "" {
		tokens := strings.Fields(item.Chord)
		parts := make([]string, 0, len(tokens))
		for _, token := range tokens {
			parts = append(parts, m.emptyKeycap(token, false))
		}
		return strings.Join(parts, base.Render(" ")) + base.Render(" ")
	}
	if strings.HasPrefix(strings.TrimSpace(item.Detail), ":") {
		return lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(rowBg).Render(strings.TrimSpace(item.Detail)) + base.Render(" ")
	}
	if item.Detail != "" {
		return lipgloss.NewStyle().Foreground(p.TextFaint()).Background(rowBg).Render(item.Detail) + base.Render(" ")
	}
	return ""
}

// emptyIcon renders an item's devicon glyph colored by its wire icon_color —
// on focused rows too, since the accent wash is faint enough for full-color
// glyphs to read against it. A missing glyph keeps the slot so columns align.
func (m Model) emptyIcon(item protocol.EmptyStateItem, rowBg color.Color, textColor color.Color, _ bool) string {
	// Fixed two-cell slot: glyph widths vary (missing, single-cell PUA,
	// double-cell symbols), and the label column must not shift with them.
	style := lipgloss.NewStyle().Background(rowBg).Width(2).MaxWidth(2)
	glyph := strings.TrimSpace(item.Icon)
	if glyph == "" {
		return style.Render(" ")
	}
	if item.IconColor != 0 {
		style = style.Foreground(lipgloss.Color(iconColorHex(item.IconColor)))
	} else {
		style = style.Foreground(textColor)
	}
	return style.Render(glyph)
}

// emptyFooter renders the one-line footer: keys/ex-commands accent-bold, verbs
// muted, joined by muted middots, centered in the column.
func (m Model) emptyFooter(section protocol.EmptyStateSection, colWidth int) string {
	return m.emptyCenterInCol(m.footerFragment(section.Items), colWidth)
}

func (m Model) emptyFooterText(state protocol.EmptyState) string {
	for _, section := range state.Sections {
		if section.ID == emptyStateSectionFooter {
			return m.footerFragment(section.Items)
		}
	}
	return ""
}

func (m Model) footerFragment(items []protocol.EmptyStateItem) string {
	p := m.palette()
	bg := m.editorBackground()
	space := lipgloss.NewStyle().Background(bg)
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(bg)
	verbStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(bg)

	parts := make([]string, 0, len(items))
	for _, item := range items {
		key := item.JumpKey
		if key == "" {
			key = item.Detail
		}
		if key == "" && item.Label == "" {
			continue
		}
		fragment := keyStyle.Render(key)
		if item.Label != "" {
			fragment += space.Render("  ") + verbStyle.Render(item.Label)
		}
		parts = append(parts, fragment)
	}

	dotStyle := lipgloss.NewStyle().Foreground(p.TextFaint()).Background(bg)
	return strings.Join(parts, dotStyle.Render("  ·  "))
}
