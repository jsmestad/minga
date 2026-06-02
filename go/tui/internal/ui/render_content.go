package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
	xansi "github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/cellbuf"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/rivo/uniseg"
)

func (m Model) content() string {
	if len(m.windows) > 0 {
		return strings.Join(m.fillBody(m.withFileTree(m.semanticLines())), "\n")
	}
	return strings.Join(m.fillBody(m.withFileTree(m.cellLines())), "\n")
}

func (m Model) semanticLines() []string {
	lines := make([]string, 0, m.bodyHeight())
	for _, id := range m.windowOrder {
		window := m.windows[id]
		lines = append(lines, m.renderWindowRows(window)...)
	}
	if len(lines) == 0 {
		return nil
	}
	return lines
}

func (m Model) renderWindowRows(window protocol.WindowContent) []string {
	gutter, hasGutter := m.windowGutter(window.ID)
	height := len(window.Rows)
	if window.GeometrySet && window.Geometry.ViewportRows > 0 {
		height = int(window.Geometry.ViewportRows)
	} else if hasGutter && gutter.ContentHeight > 0 {
		height = int(gutter.ContentHeight)
	} else if len(m.windowOrder) <= 1 {
		height = max(height, m.bodyHeight())
	}
	lines := make([]string, 0, height)
	for rowIndex := 0; rowIndex < height; rowIndex++ {
		contentWidth := m.width
		gutterText := ""
		if hasGutter {
			gutterText = m.renderGutterEntry(gutter, rowIndex)
			contentWidth = max(m.width-lipgloss.Width(gutterText), 1)
		}

		content := m.renderSemanticContentRow(window, rowIndex, contentWidth)
		lines = append(lines, lipgloss.JoinHorizontal(lipgloss.Top, gutterText, content))
	}
	return lines
}

func (m Model) renderSemanticContentRow(window protocol.WindowContent, rowIndex int, width int) string {
	cursorline := window.Cursorline.Visible && rowIndex == int(window.Cursorline.Row)
	if rowIndex >= len(window.Rows) {
		return m.renderTildeRow(width, cursorline, window.Cursorline.BG)
	}
	return m.renderRow(window, window.Rows[rowIndex], rowIndex, width, cursorline, window.Cursorline.BG)
}

func (m Model) renderTildeRow(width int, cursorline bool, cursorlineBG uint32) string {
	style := m.editorStyle().Width(width).Foreground(m.palette().Muted())
	if cursorline && cursorlineBG != 0 {
		style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", cursorlineBG)))
	}
	return style.Render(fit("~", width))
}

func (m Model) renderRow(window protocol.WindowContent, row protocol.WindowRow, rowIndex int, width int, cursorline bool, cursorlineBG uint32) string {
	base := m.editorStyle().Width(width)
	if cursorline && cursorlineBG != 0 {
		base = base.Background(lipgloss.Color(fmt.Sprintf("#%06X", cursorlineBG)))
	}

	var builder strings.Builder
	col := 0
	for graphemes := uniseg.NewGraphemes(row.Text); graphemes.Next(); {
		text := graphemes.Str()
		span := spanAt(row.Spans, uint16(col))
		style := m.styleForEditorSpan(span)
		if cursorline && span.BG == 0 && cursorlineBG != 0 {
			style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", cursorlineBG)))
		}
		style = m.applyWindowOverlays(style, window, rowIndex, col)
		style, text = m.applyIndentGuide(window, style, rowIndex, col, text)
		builder.WriteString(style.Render(text))
		col += max(displayWidth(text), 1)
	}
	if annotation := m.renderRowAnnotations(window, rowIndex); annotation != "" {
		builder.WriteString(annotation)
	}
	return base.Render(fitStyled(builder.String(), width))
}

func (m Model) applyWindowOverlays(style lipgloss.Style, window protocol.WindowContent, rowIndex int, col int) lipgloss.Style {
	row := uint16(rowIndex)
	column := uint16(col)
	if window.Selection.Type != 0 && rangeContains(window.Selection.StartRow, window.Selection.StartCol, window.Selection.EndRow, window.Selection.EndCol, row, column) {
		style = style.Background(m.palette().Selection())
	}
	for _, highlight := range window.Highlights {
		if rangeContains(highlight.StartRow, highlight.StartCol, highlight.EndRow, highlight.EndCol, row, column) {
			style = style.Background(m.palette().DocumentHighlight())
			break
		}
	}
	for _, match := range window.SearchMatches {
		if match.Row == row && column >= match.StartCol && column < match.EndCol {
			style = style.Background(m.palette().SearchMatch(match.Current))
			break
		}
	}
	for _, diagnostic := range window.Diagnostics {
		if rangeContains(diagnostic.StartRow, diagnostic.StartCol, diagnostic.EndRow, diagnostic.EndCol, row, column) {
			style = style.Underline(true).Foreground(m.palette().Diagnostic(diagnostic.Severity))
			break
		}
	}
	return style
}

func (m Model) renderRowAnnotations(window protocol.WindowContent, rowIndex int) string {
	parts := make([]string, 0, 1)
	for _, annotation := range window.Annotations {
		if annotation.Row != uint16(rowIndex) || annotation.Text == "" || annotation.Kind == 2 {
			continue
		}
		style := lipgloss.NewStyle().Foreground(m.palette().Accent()).Background(m.editorBackground())
		if annotation.FG != 0 {
			style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", annotation.FG)))
		}
		if annotation.BG != 0 {
			style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", annotation.BG)))
		}
		parts = append(parts, style.Render(" "+annotation.Text))
	}
	return strings.Join(parts, "")
}

func rangeContains(startRow uint16, startCol uint16, endRow uint16, endCol uint16, row uint16, col uint16) bool {
	if row < startRow || row > endRow {
		return false
	}
	if row == startRow && col < startCol {
		return false
	}
	if row == endRow && col >= endCol {
		return false
	}
	return true
}

func (m Model) cellLines() []string {
	buffer := cellbuf.NewBuffer(max(m.width, 1), max(m.height-2, 1))
	for _, draw := range m.orderedCells() {
		writeCellText(buffer, int(draw.pos.col), int(draw.pos.row), draw.cell)
	}

	rendered := make([]string, buffer.Height())
	for i := range rendered {
		_, line := cellbuf.RenderLine(buffer, i)
		rendered[i] = m.editorStyle().Render(fitStyled(line, m.width))
	}
	return rendered
}

type orderedCell struct {
	pos  position
	cell cell
}

// orderedCells returns the fallback draws sorted by draw-command order. Go map
// iteration is randomized, so replaying m.cells directly lets a later wide draw
// (for example a full-row space clear) blank earlier content depending on
// iteration order. Sorting by seq replays draws in the order they arrived, which
// keeps overlaps deterministic.
func (m Model) orderedCells() []orderedCell {
	draws := make([]orderedCell, 0, len(m.cells))
	for pos, c := range m.cells {
		draws = append(draws, orderedCell{pos: pos, cell: c})
	}
	sort.Slice(draws, func(i, j int) bool { return draws[i].cell.seq < draws[j].cell.seq })
	return draws
}

func writeCellText(buffer *cellbuf.Buffer, col int, row int, fallback cell) {
	style := cellbufStyle(fallback)
	graphemes := uniseg.NewGraphemes(fallback.text)
	for graphemes.Next() {
		c := cellbuf.NewGraphemeCell(graphemes.Str())
		c.Style = style
		if !buffer.SetCell(col, row, c) {
			return
		}
		col += max(c.Width, 1)
	}
}

func cellbufStyle(fallback cell) cellbuf.Style {
	style := cellbuf.Style{}
	if fallback.fg != 0 {
		style.Fg = xansi.TrueColor(fallback.fg)
	}
	if fallback.bg != 0 {
		style.Bg = xansi.TrueColor(fallback.bg)
	}
	if fallback.attrs&0x01 != 0 {
		style.Attrs |= cellbuf.BoldAttr
	}
	if fallback.attrs&0x02 != 0 {
		style.UlStyle = cellbuf.SingleUnderline
	}
	if fallback.attrs&0x04 != 0 {
		style.Attrs |= cellbuf.ItalicAttr
	}
	if fallback.attrs&0x08 != 0 {
		style.Attrs |= cellbuf.ReverseAttr
	}
	if fallback.attrs&0x10 != 0 {
		style.Attrs |= cellbuf.StrikethroughAttr
	}
	return style
}

func (m Model) fillBody(lines []string) []string {
	height := m.bodyHeight()
	filled := make([]string, 0, height)
	for _, line := range lines[:min(len(lines), height)] {
		filled = append(filled, m.editorStyle().Render(fitStyled(line, m.width)))
	}
	for len(filled) < height {
		filled = append(filled, m.editorStyle().Render(strings.Repeat(" ", max(m.width, 1))))
	}
	return filled
}

func fitStyled(value string, width int) string {
	if width <= 0 {
		return ""
	}
	value = lipgloss.NewStyle().Inline(true).MaxWidth(width).Render(value)
	visible := lipgloss.Width(value)
	if visible >= width {
		return value
	}
	return value + strings.Repeat(" ", width-visible)
}

func (m Model) withFileTree(mainLines []string) []string {
	tree, ok := m.fileTree()
	if !ok || !tree.Visible || len(tree.Rows) == 0 || m.width < 50 {
		return m.withSemanticSidebars(mainLines)
	}

	sidebarWidth := min(max(int(tree.Width), 24), max(m.width/3, 24))
	sidebar := m.renderFileTree(tree, sidebarWidth, max(len(mainLines), m.bodyHeight()))
	lines := make([]string, max(len(mainLines), len(sidebar)))
	for i := range lines {
		left := ""
		right := ""
		if i < len(sidebar) {
			left = sidebar[i]
		}
		if i < len(mainLines) {
			right = mainLines[i]
		}
		lines[i] = lipgloss.JoinHorizontal(lipgloss.Top, left, right)
	}
	return lines
}

func (m Model) withSemanticSidebars(mainLines []string) []string {
	sidebars, ok := m.sidebars()
	if !ok || len(sidebars.Items) == 0 || m.width < 60 {
		return mainLines
	}
	visible := make([]protocol.Sidebar, 0, len(sidebars.Items))
	for _, item := range sidebars.Items {
		if item.Visible {
			visible = append(visible, item)
		}
	}
	if len(visible) == 0 {
		return mainLines
	}
	width := min(max(int(visible[0].PreferredWidth), 18), max(m.width/4, 18))
	theme := m.palette()
	style := lipgloss.NewStyle().Foreground(theme.Muted()).Background(theme.Surface()).Width(width)
	activeStyle := style.Bold(true).Foreground(theme.Text()).Background(theme.Selection())
	lines := make([]string, max(len(mainLines), len(visible)+1))
	lines[0] = lipgloss.JoinHorizontal(lipgloss.Top, style.Bold(true).Render(fit("Sidebars", width)), lineAt(mainLines, 0))
	for i, item := range visible {
		label := strings.TrimSpace(item.Icon + " " + item.DisplayName)
		if item.BadgeCount != 0xFFFF && item.BadgeCount > 0 {
			label += fmt.Sprintf(" %d", item.BadgeCount)
		}
		leftStyle := style
		if item.ID == sidebars.ActiveID || item.Focused {
			leftStyle = activeStyle
		}
		lines[i+1] = lipgloss.JoinHorizontal(lipgloss.Top, leftStyle.Render(fit(label, width)), lineAt(mainLines, i+1))
	}
	for i := len(visible) + 1; i < len(lines); i++ {
		lines[i] = lipgloss.JoinHorizontal(lipgloss.Top, style.Render(strings.Repeat(" ", width)), lineAt(mainLines, i))
	}
	return lines
}

func (m Model) renderGutterEntry(gutter protocol.Gutter, rowIndex int) string {
	width := int(gutter.SignColWidth) + max(int(gutter.LineNumberWidth)-1, 0) + 1
	if width <= 1 {
		return ""
	}
	style := lipgloss.NewStyle().Foreground(m.palette().GutterText()).Background(m.editorBackground()).Width(width)
	if rowIndex >= len(gutter.Entries) {
		return style.Render(strings.Repeat(" ", width))
	}
	entry := gutter.Entries[rowIndex]
	if entry.BufferLine == gutter.CursorLine && gutter.LineNumberStyle != 2 {
		style = style.Foreground(m.palette().GutterCurrentText()).Bold(true)
	}
	sign := m.gutterSign(entry)
	number := m.gutterLineNumber(gutter, entry)
	return style.Render(fit(sign+number+" ", width))
}

func (m Model) gutterLineNumber(gutter protocol.Gutter, entry protocol.GutterEntry) string {
	width := max(int(gutter.LineNumberWidth)-1, 0)
	if width == 0 || gutter.LineNumberStyle == 3 || entry.DisplayType == 3 || entry.DisplayType == 5 {
		return strings.Repeat(" ", width)
	}
	value := int(entry.BufferLine) + 1
	if gutter.LineNumberStyle == 2 || (gutter.LineNumberStyle == 0 && entry.BufferLine != gutter.CursorLine) {
		value = abs(int(entry.BufferLine) - int(gutter.CursorLine))
	}
	text := fmt.Sprintf("%d", value)
	if len(text) > width {
		return text[len(text)-width:]
	}
	return strings.Repeat(" ", width-len(text)) + text
}

func (m Model) gutterSign(entry protocol.GutterEntry) string {
	if entry.SignType == 8 && entry.SignText != "" {
		return fit(entry.SignText, 2)
	}
	if entry.SignType == 9 {
		return "- "
	}
	if entry.SignType != 0 {
		return "│ "
	}
	if entry.DisplayType == 1 {
		return "▸ "
	}
	if entry.DisplayType == 4 {
		return "▾ "
	}
	return "  "
}

func (m Model) renderFileTree(tree protocol.FileTree, width int, height int) []string {
	theme := m.palette()
	style := lipgloss.NewStyle().Foreground(theme.TreeText()).Background(theme.TreeSurface()).Width(width)
	selectedStyle := style.Foreground(theme.Text()).Background(theme.TreeSelection()).Bold(true)
	header := style.Bold(true).Foreground(theme.TreeHeaderText()).Background(theme.TreeHeader()).Render(fit("Files  "+tree.Root, width))
	lines := []string{header}
	for rowIndex, row := range tree.Rows {
		prefix := strings.Repeat("  ", int(row.Depth))
		marker := " "
		if row.Directory && row.Expanded {
			marker = "v"
		} else if row.Directory {
			marker = ">"
		}
		dirty := ""
		if row.Dirty {
			dirty = " *"
		}
		text := fit(fmt.Sprintf("%s%s %s %s%s", prefix, marker, row.Icon, row.Name, dirty), width)
		rendered := style.Render(text)
		if row.Selected {
			rendered = selectedStyle.Render(text)
		}
		lines = append(lines, m.zones.Mark(zoneIDFileTreeRow(rowIndex), rendered))
		if len(lines) >= height {
			return lines
		}
	}
	for len(lines) < height {
		lines = append(lines, style.Render(strings.Repeat(" ", width)))
	}
	return lines
}

func spanAt(spans []protocol.Span, col uint16) protocol.Span {
	for _, span := range spans {
		if col >= span.StartCol && col < span.EndCol {
			return span
		}
	}
	return protocol.Span{}
}

func (m Model) styleForEditorSpan(span protocol.Span) lipgloss.Style {
	style := lipgloss.NewStyle().Foreground(m.palette().Text()).Background(m.editorBackground())
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
		style = style.Strikethrough(true)
	}
	return style
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
		style = style.Underline(true)
	}
	if span.Attrs&0x04 != 0 {
		style = style.Italic(true)
	}
	if span.Attrs&0x08 != 0 {
		style = style.Reverse(true)
	}
	if span.Attrs&0x10 != 0 {
		style = style.Strikethrough(true)
	}
	return style
}
