package ui

import (
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// The which-key panel (docs/design/surfaces.md, docs/design/anatomy.md "Which-key panel"): one full-width panel
// anchored on the modeline, with the breadcrumb in its top border and its own keys in the bottom border. The BEAM
// sends the entries in display order, grouped into named sections; the panel decides how many columns each section
// takes so it fits the window, and fills each column top to bottom.

// whichKeyKindGroup is the entry kind the BEAM sends for a group (docs/GUI_PROTOCOL.md, gui_which_key).
const whichKeyKindGroup byte = 1

// whichKeyBandGapRows is the blank row between wrapped bands (xxl: one row in the TUI).
const whichKeyBandGapRows = 1

// whichKeyMinLabelCols is the narrowest a label shrinks to (with its …) when the columns do not fit the width.
const whichKeyMinLabelCols = 4

func (m Model) whichKeyVisible() bool {
	which, ok := m.whichKey()
	return ok && which.Visible && len(which.Entries) > 0
}

// floatingWhichKeyLayer places the panel directly above the modeline, full width. It casts no shadow: the shadow
// would paint over the modeline it sits on.
func (m Model) floatingWhichKeyLayer() *lipgloss.Layer {
	if !m.whichKeyVisible() {
		return nil
	}
	which, _ := m.whichKey()
	popup := m.renderFloatingWhichKey(which)
	if popup == "" {
		return nil
	}
	y := max(m.height-m.footerRows()-lipgloss.Height(popup), 0)
	return lipgloss.NewLayer(popup).X(whichKeyMarginCols).Y(y).Z(whichKeyLayerZ)
}

// whichKeyColumn is one drawn column: a section, or part of one when the section is split to fit.
type whichKeyColumn struct {
	title    string
	entries  []generated.WhichKeyEntry
	keyWidth int
	width    int // the entry width after the key column: the longest label with its count
}

func (c whichKeyColumn) outerWidth() int {
	return c.keyWidth + whichKeyKeyToLabel.cols() + c.width
}

// whichKeySections splits the entries into runs that share a section name.
func whichKeySections(entries []generated.WhichKeyEntry) [][]generated.WhichKeyEntry {
	var sections [][]generated.WhichKeyEntry
	for i, entry := range entries {
		if i == 0 || entry.Section != entries[i-1].Section {
			sections = append(sections, nil)
		}
		sections[len(sections)-1] = append(sections[len(sections)-1], entry)
	}
	return sections
}

// whichKeyEntryWidth is the label plus, when present, its count after the md gap.
func whichKeyEntryWidth(entry generated.WhichKeyEntry) int {
	width := displayWidth(entry.Label)
	if entry.Count != "" {
		width += whichKeyLabelToCount.cols() + displayWidth(entry.Count)
	}
	return width
}

// whichKeyColumnsFor splits every section into columns of at most rows entries, filled top to bottom.
func whichKeyColumnsFor(sections [][]generated.WhichKeyEntry, rows int) []whichKeyColumn {
	var columns []whichKeyColumn
	for _, section := range sections {
		for start := 0; start < len(section); start += rows {
			chunk := section[start:min(start+rows, len(section))]
			column := whichKeyColumn{entries: chunk}
			if start == 0 {
				column.title = section[0].Section
			}
			// A section that continues in further columns keeps one key column (anatomy.md rule 2).
			for _, entry := range section {
				column.keyWidth = max(column.keyWidth, displayWidth(entry.Key))
			}
			for _, entry := range chunk {
				column.width = max(column.width, whichKeyEntryWidth(entry))
			}
			column.width = max(column.width, displayWidth(column.title)-column.keyWidth-whichKeyKeyToLabel.cols())
			columns = append(columns, column)
		}
	}
	return columns
}

func whichKeyTotalWidth(columns []whichKeyColumn) int {
	total := 0
	for i, column := range columns {
		if i > 0 {
			total += whichKeyColumnGap.cols()
		}
		total += column.outerWidth()
	}
	return total
}

// whichKeyLayout arranges the sections into bands of side-by-side columns that fit width columns and height rows
// (each band takes headingRows plus its tallest column).
//
// Each section is one column, as tall as the section, so the panel is as tall as its longest group (anatomy.md); a
// section taller than the window allows continues in a further column. Columns that do not fit side by side wrap
// onto more bands; only when that does not fit either do the widest labels shrink and truncate with ….
func whichKeyLayout(entries []generated.WhichKeyEntry, width, height, headingRows int) [][]whichKeyColumn {
	sections := whichKeySections(entries)
	tallest := 1
	for _, section := range sections {
		tallest = max(tallest, len(section))
	}
	rows := max(min(tallest, height-headingRows), 1)

	if single := whichKeyColumnsFor(sections, rows); whichKeyTotalWidth(single) <= width {
		return [][]whichKeyColumn{single}
	}

	columns := whichKeyColumnsFor(sections, rows)
	if bands := whichKeyBands(columns, width); whichKeyBandsHeight(bands, headingRows) <= height && whichKeyBandsFit(bands, width) {
		return bands
	}
	return [][]whichKeyColumn{whichKeyShrink(columns, width)}
}

// whichKeyBands packs columns left to right, starting a new band when the next column does not fit.
func whichKeyBands(columns []whichKeyColumn, width int) [][]whichKeyColumn {
	var bands [][]whichKeyColumn
	for _, column := range columns {
		last := len(bands) - 1
		if last >= 0 && whichKeyTotalWidth(append(append([]whichKeyColumn{}, bands[last]...), column)) <= width {
			bands[last] = append(bands[last], column)
			continue
		}
		bands = append(bands, []whichKeyColumn{column})
	}
	return bands
}

func whichKeyBandsHeight(bands [][]whichKeyColumn, headingRows int) int {
	height := 0
	for i, band := range bands {
		if i > 0 {
			height += whichKeyBandGapRows
		}
		height += headingRows + whichKeyBandRows(band)
	}
	return height
}

func whichKeyBandsFit(bands [][]whichKeyColumn, width int) bool {
	for _, band := range bands {
		if whichKeyTotalWidth(band) > width {
			return false
		}
	}
	return true
}

func whichKeyBandRows(band []whichKeyColumn) int {
	rows := 0
	for _, column := range band {
		rows = max(rows, len(column.entries))
	}
	return rows
}

// whichKeyShrink narrows the widest labels until the columns fit; a window too small even for that shows the columns
// that fit.
func whichKeyShrink(columns []whichKeyColumn, width int) []whichKeyColumn {
	for whichKeyTotalWidth(columns) > width {
		widest := -1
		for i, column := range columns {
			if column.width > whichKeyMinLabelCols && (widest < 0 || column.width > columns[widest].width) {
				widest = i
			}
		}
		if widest < 0 {
			break
		}
		columns[widest].width--
	}
	for len(columns) > 1 && whichKeyTotalWidth(columns) > width {
		columns = columns[:len(columns)-1]
	}
	if len(columns) == 1 && whichKeyTotalWidth(columns) > width {
		columns[0].width = max(width-columns[0].keyWidth-whichKeyKeyToLabel.cols(), 1)
	}
	return columns
}

func (m Model) renderFloatingWhichKey(which protocol.WhichKey) string {
	if len(which.Entries) == 0 || m.width < 4 {
		return ""
	}
	p := m.palette()
	surface := lipgloss.NewStyle().Background(p.PopupSurface())
	outer := max(m.width-2*whichKeyMarginCols, 4)
	inset := whichKeyInsetH.cols()
	inner := max(outer-2-2*inset, 1)

	titled := false
	for _, entry := range which.Entries {
		titled = titled || entry.Section != ""
	}
	headingRows := 0
	if titled {
		headingRows = 1
	}
	bands := whichKeyLayout(which.Entries, inner, max(m.height-m.footerRows()-2, 1), headingRows)

	var body []string
	for band, columns := range bands {
		if band > 0 {
			// Wrapped bands are blocks: one blank row (xxl) sets the next band's group names apart from the entries above.
			body = append(body, m.whichKeyRow(nil, inner))
		}
		if titled {
			cells := make([]string, len(columns))
			for i, column := range columns {
				cells[i] = lipgloss.NewStyle().Foreground(p.Role(generated.ColorRoleTextMuted)).Background(p.PopupSurface()).Render(fit(ansi.TruncateWc(column.title, column.outerWidth(), "…"), column.outerWidth()))
			}
			body = append(body, m.whichKeyRow(cells, inner))
		}
		for row := range whichKeyBandRows(columns) {
			cells := make([]string, len(columns))
			for i, column := range columns {
				if row < len(column.entries) {
					cells[i] = m.renderWhichKeyEntry(column.entries[row], column)
				} else {
					cells[i] = surface.Render(strings.Repeat(" ", column.outerWidth()))
				}
			}
			body = append(body, m.whichKeyRow(cells, inner))
		}
	}

	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.PopupSurface())
	pad := surface.Render(strings.Repeat(" ", inset))
	lines := make([]string, 0, len(body)+2)
	lines = append(lines, m.whichKeyTopBorder(which, outer))
	for _, line := range body {
		lines = append(lines, border.Render("│")+pad+line+pad+border.Render("│"))
	}
	lines = append(lines, m.whichKeyBottomBorder(which, outer))
	return strings.Join(lines, "\n")
}

// whichKeyRow joins one row of column cells with the panel column gap and pads it to the content width.
func (m Model) whichKeyRow(cells []string, width int) string {
	surface := lipgloss.NewStyle().Background(m.palette().PopupSurface())
	row := strings.Join(cells, surface.Render(gap(whichKeyColumnGap)))
	if fill := width - lipgloss.Width(row); fill > 0 {
		row += surface.Render(strings.Repeat(" ", fill))
	}
	return row
}

// renderWhichKeyEntry draws `key  Label count`: the key in the accent colour in the column's fixed key column, the
// label in the group colour role for a group (its trailing › comes from the BEAM) and plain text for a command, and
// the live count in the secondary colour after it. Captions use the secondary colour, not faint text, which is too
// light on the popup surface to read.
func (m Model) renderWhichKeyEntry(entry generated.WhichKeyEntry, column whichKeyColumn) string {
	p := m.palette()
	surface := lipgloss.NewStyle().Background(p.PopupSurface())
	key := lipgloss.NewStyle().Foreground(p.Accent()).Background(p.PopupSurface()).Render(entry.Key)
	key += surface.Render(strings.Repeat(" ", max(column.keyWidth-displayWidth(entry.Key), 0)+whichKeyKeyToLabel.cols()))

	labelStyle := whichKeyLabelText.style(p).Foreground(p.PopupText()).Background(p.PopupSurface())
	if entry.Kind == whichKeyKindGroup {
		labelStyle = labelStyle.Foreground(p.Role(generated.ColorRoleGroup))
	}
	countStyle := lipgloss.NewStyle().Foreground(whichKeyCountColor(p, entry.CountTone)).Background(p.PopupSurface())

	label, count := entry.Label, entry.Count
	countWidth := 0
	if count != "" {
		countWidth = whichKeyLabelToCount.cols() + displayWidth(count)
	}
	labelRoom := column.width - countWidth
	if labelRoom < whichKeyMinLabelCols && count != "" {
		// Too narrow for both: the count gives way before the label does.
		count, labelRoom = "", column.width
	}
	if displayWidth(label) > labelRoom {
		label = ansi.TruncateWc(label, max(labelRoom, 1), "…")
	}
	text := labelStyle.Render(label)
	if count != "" {
		text += surface.Render(gap(whichKeyLabelToCount)) + countStyle.Render(count)
	}
	if fill := column.width - lipgloss.Width(text); fill > 0 {
		text += surface.Render(strings.Repeat(" ", fill))
	}
	return key + text
}

// whichKeyTopBorder draws the breadcrumb in the panel's top border: `╭ SPC › a Minga · 1 needs you ─────╮`. The
// breadcrumb starts in column 2, the panel's leading edge, where section names and keys start (anatomy rule 1).
func (m Model) whichKeyTopBorder(which protocol.WhichKey, width int) string {
	p := m.palette()
	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.PopupSurface())
	keyStyle := lipgloss.NewStyle().Foreground(p.Accent()).Background(p.PopupSurface())
	labelStyle := lipgloss.NewStyle().Foreground(p.PopupText()).Background(p.PopupSurface())
	faint := lipgloss.NewStyle().Foreground(p.Role(generated.ColorRoleTextMuted)).Background(p.PopupSurface())
	surface := lipgloss.NewStyle().Background(p.PopupSurface())

	var crumbs strings.Builder
	for i, crumb := range which.Breadcrumb {
		if i > 0 {
			crumbs.WriteString(faint.Render(" › "))
		}
		crumbs.WriteString(keyStyle.Render(crumb.Key))
		if crumb.Label != "" {
			style := labelStyle
			if i == len(which.Breadcrumb)-1 {
				// The open group's name is the panel's title.
				style = style.Bold(true)
			}
			crumbs.WriteString(surface.Render(" ") + style.Render(crumb.Label))
		}
	}
	if which.Count != "" {
		count := lipgloss.NewStyle().Foreground(whichKeyCountColor(p, which.CountTone)).Background(p.PopupSurface())
		crumbs.WriteString(surface.Render(" ") + count.Render(which.Count))
	}
	title := surface.Render(" ") + crumbs.String() + surface.Render(" ")
	room := max(width-3, 0)
	if lipgloss.Width(title) > room {
		title = ansi.Truncate(title, room, "…")
	}
	fill := max(width-2-lipgloss.Width(title), 0)
	return border.Render("╭") + title + border.Render(strings.Repeat("─", fill)+"╮")
}

// whichKeyBottomBorder draws the panel's own keys right-aligned in the bottom border: `╰──── ⌫ back  esc close ─╯`.
func (m Model) whichKeyBottomBorder(which protocol.WhichKey, width int) string {
	p := m.palette()
	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.PopupSurface())
	keyStyle := lipgloss.NewStyle().Foreground(p.Accent()).Background(p.PopupSurface())
	muted := lipgloss.NewStyle().Foreground(p.Role(generated.ColorRoleTextMuted)).Background(p.PopupSurface())
	surface := lipgloss.NewStyle().Background(p.PopupSurface())

	hints := make([]string, 0, len(which.Hints))
	for _, hint := range which.Hints {
		hints = append(hints, keyStyle.Render(hint.Key)+surface.Render(gap(spaceXS))+muted.Render(hint.Label))
	}
	text := ""
	if len(hints) > 0 {
		text = surface.Render(" ") + strings.Join(hints, surface.Render(gap(spaceXL))) + surface.Render(" ")
	}
	if lipgloss.Width(text) > max(width-4, 0) {
		text = ""
	}
	fill := max(width-3-lipgloss.Width(text), 0)
	return border.Render("╰"+strings.Repeat("─", fill)) + text + border.Render("─╯")
}

// whichKeyCountColor is the colour role a count's tone names: the needs-you and failure state roles, as the modeline
// draws the same facts, or the secondary colour for a plain count.
func whichKeyCountColor(p palette, tone uint8) color.Color {
	switch tone {
	case protocol.WhichKeyCountNeedsYou:
		return p.Role(generated.ColorRoleNeedsYou)
	case protocol.WhichKeyCountError:
		return p.Role(generated.ColorRoleFailure)
	default:
		return p.Role(generated.ColorRoleTextMuted)
	}
}
