package ui

import (
	"fmt"
	"sort"
	"strings"

	"charm.land/lipgloss/v2"
	xansi "github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/cellbuf"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/rivo/uniseg"
)

func (m Model) content() string {
	if chat, ok := m.agentChat(); ok && chat.Visible {
		return strings.Join(m.renderAgentChatBody(chat), "\n")
	}
	if len(m.windows) > 0 {
		return strings.Join(m.fillBody(m.withFileTree(m.withSplitSeparators(m.semanticLines()))), "\n")
	}
	if len(m.cells) > 0 {
		return strings.Join(m.fillBody(m.legacyCellGridDiagnosticLines()), "\n")
	}
	return strings.Join(m.fillBody(m.withFileTree(m.withSplitSeparators(m.withLegacyCursorline(m.cellLines())))), "\n")
}

func (m Model) legacyCellGridDiagnosticLines() []string {
	return []string{
		"Semantic UI required: received legacy cell-grid frame without semantic window content.",
		"Shared chrome must be emitted as Semantic UI, not draw_text cells.",
	}
}

func (m Model) semanticLines() []string {
	if lines, ok := m.composedSemanticLines(); ok {
		if len(lines) == 0 {
			return nil
		}
		return lines
	}
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

func (m Model) composedSemanticLines() ([]string, bool) {
	segmentsByRow := map[int][]semanticLineSegment{}
	fallback := make([]string, 0, len(m.windowOrder))
	maxRow := 0
	hasGeometry := false
	for _, id := range m.windowOrder {
		window := m.windows[id]
		placement, ok := m.semanticWindowPlacement(window)
		if !ok {
			fallback = append(fallback, m.renderWindowRows(window)...)
			continue
		}
		hasGeometry = true
		rendered := m.renderWindowRows(window)
		for rowOffset, line := range rendered {
			row := placement.row + rowOffset
			if row < 0 {
				continue
			}
			segmentsByRow[row] = append(segmentsByRow[row], semanticLineSegment{col: placement.col, text: line})
			maxRow = max(maxRow, row+1)
		}
	}
	if !hasGeometry {
		return fallback, false
	}
	headHeight := max(maxRow, m.bodyHeight())
	lines := make([]string, headHeight)
	for row, segments := range segmentsByRow {
		sort.SliceStable(segments, func(i, j int) bool { return segments[i].col < segments[j].col })
		lines[row] = composeSemanticLine(segments)
	}
	if len(fallback) > 0 {
		lines = append(lines, fallback...)
	}
	return lines, true
}

type semanticLineSegment struct {
	col  int
	text string
}

type semanticWindowPlacement struct {
	row    int
	col    int
	width  int
	height int
}

func composeSemanticLine(segments []semanticLineSegment) string {
	var builder strings.Builder
	visibleCol := 0
	for _, segment := range segments {
		if segment.col > visibleCol {
			builder.WriteString(strings.Repeat(" ", segment.col-visibleCol))
			visibleCol = segment.col
		}
		builder.WriteString(segment.text)
		visibleCol += displayWidth(xansi.Strip(segment.text))
	}
	return builder.String()
}

func (m Model) semanticWindowPlacement(window protocol.WindowContent) (semanticWindowPlacement, bool) {
	if !window.GeometrySet {
		return semanticWindowPlacement{}, false
	}
	rect := window.Geometry.ContentRect
	if rect == (protocol.Rect{}) {
		rect = window.Geometry.TotalRect
	}
	if rect == (protocol.Rect{}) {
		return semanticWindowPlacement{}, false
	}
	row, col := m.normalizeSemanticGeometry(int(rect.Row), int(rect.Col))
	return semanticWindowPlacement{
		row:    row,
		col:    col,
		width:  int(rect.Width),
		height: int(rect.Height),
	}, true
}

// Protocol window geometry is relative to the semantic editor surface. Bubble Tea adds TUI chrome around that surface after semantic content is composed.
func (m Model) normalizeSemanticGeometry(row int, col int) (int, int) {
	return row, col
}

// Protocol chrome geometry is absolute terminal geometry, so split separators are normalized into Bubble Tea's body canvas.
func (m Model) normalizeChromeGeometry(row int, col int) (int, int) {
	rowOffset, colOffset := m.semanticContentOffsets()
	return row - rowOffset, col - colOffset
}

func (m Model) semanticContentOffsets() (int, int) {
	return len(m.headerLines()), m.leftChromeWidth()
}

func (m Model) leftChromeWidth() int {
	if tree, ok := m.fileTree(); ok && tree.Visible && tree.Width > 0 && m.width >= 50 {
		return fileTreeWidth(m.width, tree)
	}
	if sidebars, ok := m.sidebars(); ok && len(sidebars.Items) > 0 && m.width >= 60 {
		return semanticSidebarWidth(m.width, sidebars)
	}
	return 0
}

func fileTreeWidth(totalWidth int, tree protocol.FileTree) int {
	desired := 24
	if tree.Width > 0 {
		desired = int(tree.Width)
	}
	maxWidth := max(totalWidth-1, 1)
	return min(max(desired, 1), maxWidth)
}

func semanticSidebarWidth(totalWidth int, sidebars protocol.Sidebars) int {
	visible := visibleSidebars(sidebars)
	if len(visible) == 0 {
		return 0
	}
	return min(max(int(visible[0].PreferredWidth), 18), max(totalWidth/4, 18))
}

func visibleSidebars(sidebars protocol.Sidebars) []protocol.Sidebar {
	visible := make([]protocol.Sidebar, 0, len(sidebars.Items))
	for _, item := range sidebars.Items {
		if item.Visible {
			visible = append(visible, item)
		}
	}
	return visible
}

func (m Model) renderWindowRows(window protocol.WindowContent) []string {
	gutter, hasGutter := m.windowGutter(window.ID)
	height := len(window.Rows)
	width := m.width
	if placement, ok := m.semanticWindowPlacement(window); ok {
		if placement.width > 0 {
			width = placement.width
		}
		if placement.height > 0 {
			height = placement.height
		}
	} else if window.GeometrySet && window.Geometry.ViewportRows > 0 {
		height = int(window.Geometry.ViewportRows)
	} else if hasGutter && gutter.ContentHeight > 0 {
		height = int(gutter.ContentHeight)
	} else if len(m.windowOrder) <= 1 {
		height = max(height, m.bodyHeight())
	}
	lines := make([]string, 0, height)
	for rowIndex := 0; rowIndex < height; rowIndex++ {
		contentWidth := width
		gutterText := ""
		if hasGutter {
			gutterText = m.renderGutterEntry(gutter, rowIndex)
			contentWidth = max(width-lipgloss.Width(gutterText), 1)
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
	scrollLeft := int(window.ScrollLeft)
	col := 0
	for graphemes := uniseg.NewGraphemes(row.Text); graphemes.Next(); {
		text := graphemes.Str()
		span := spanAt(row.Spans, uint16(col))
		spanWidth := max(displayWidth(text), 1)
		if col+spanWidth <= scrollLeft {
			col += spanWidth
			continue
		}
		style := m.styleForEditorSpan(span)
		if cursorline && span.BG == 0 && cursorlineBG != 0 {
			style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", cursorlineBG)))
		}
		style = m.applyWindowOverlays(style, window, rowIndex, col)
		style, text = m.applyIndentGuide(window, style, rowIndex, col, text)
		builder.WriteString(style.Render(text))
		col += spanWidth
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
			style = style.Background(m.palette().DocumentHighlight(highlight.Kind))
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

func (m Model) withLegacyCursorline(lines []string) []string {
	if !m.cursorlineChrome.Visible || int(m.cursorlineChrome.Row) >= len(lines) {
		return lines
	}
	out := append([]string(nil), lines...)
	style := m.editorStyle()
	if m.cursorlineChrome.BG != 0 {
		style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", m.cursorlineChrome.BG)))
	}
	row := int(m.cursorlineChrome.Row)
	out[row] = style.Render(fitStyled(out[row], m.width))
	return out
}

func (m Model) withSplitSeparators(lines []string) []string {
	splits, ok := m.splitSeparators()
	if !ok || len(lines) == 0 {
		return lines
	}
	out := append([]string(nil), lines...)
	style := lipgloss.NewStyle().Foreground(m.palette().PopupBorder()).Background(m.editorBackground())
	if splits.Color != 0 {
		style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", splits.Color)))
	}
	for _, vertical := range splits.Verticals {
		startRow, col := m.normalizeChromeGeometry(int(vertical.StartRow), int(vertical.Col))
		endRow, _ := m.normalizeChromeGeometry(int(vertical.EndRow), int(vertical.Col))
		if col < 0 || endRow < 0 {
			continue
		}
		for row := max(startRow, 0); row <= endRow && row < len(out); row++ {
			out[row] = extendVisibleWidth(out[row], col+1)
			out[row] = replaceVisibleCell(out[row], col, style.Render("│"))
		}
	}
	for _, horizontal := range splits.Horizontals {
		row, col := m.normalizeChromeGeometry(int(horizontal.Row), int(horizontal.Col))
		if row < 0 || row >= len(out) {
			continue
		}
		text := horizontalSeparatorText(int(horizontal.Width), horizontal.Filename)
		for offset, part := range splitGraphemes(text) {
			partWidth := max(displayWidth(part), 1)
			out[row] = extendVisibleWidth(out[row], col+offset+partWidth)
			out[row] = replaceVisibleCell(out[row], col+offset, style.Render(part))
		}
	}
	return out
}

func extendVisibleWidth(line string, width int) string {
	if width <= 0 {
		return line
	}
	if displayWidth(xansi.Strip(line)) >= width {
		return line
	}
	return fitStyled(line, width)
}

func replaceVisibleCell(line string, col int, replacement string) string {
	if col < 0 || col >= displayWidth(xansi.Strip(line)) {
		return line
	}
	var builder strings.Builder
	activeSGR := ""
	visibleCol := 0
	for index := 0; index < len(line); {
		if line[index] == '\x1b' {
			next := ansiSequenceEnd(line, index)
			sequence := line[index:next]
			activeSGR = updateActiveSGR(activeSGR, sequence)
			builder.WriteString(sequence)
			index = next
			continue
		}
		graphemes := uniseg.NewGraphemes(line[index:])
		if !graphemes.Next() {
			break
		}
		text := graphemes.Str()
		width := max(displayWidth(text), 1)
		if visibleCol == col {
			builder.WriteString(replacement)
			builder.WriteString(activeSGR)
		} else {
			builder.WriteString(text)
		}
		visibleCol += width
		index += len(text)
	}
	return builder.String()
}

func updateActiveSGR(active string, sequence string) string {
	if !strings.HasSuffix(sequence, "m") {
		return active
	}
	if strings.Contains(sequence, "[0m") || strings.Contains(sequence, "[m") {
		return ""
	}
	return sequence
}

func ansiSequenceEnd(value string, start int) int {
	if start+1 >= len(value) {
		return len(value)
	}
	if value[start+1] == '[' {
		for index := start + 2; index < len(value); index++ {
			if value[index] >= 0x40 && value[index] <= 0x7E {
				return index + 1
			}
		}
		return len(value)
	}
	if value[start+1] == ']' {
		for index := start + 2; index < len(value); index++ {
			if value[index] == '\a' {
				return index + 1
			}
			if value[index] == '\x1b' && index+1 < len(value) && value[index+1] == '\\' {
				return index + 2
			}
		}
		return len(value)
	}
	return min(start+2, len(value))
}

func horizontalSeparatorText(width int, filename string) string {
	if width <= 0 {
		return ""
	}
	line := strings.Repeat("─", width)
	label := strings.TrimSpace(filename)
	if label == "" || width < 4 {
		return line
	}
	label = " " + label + " "
	if displayWidth(label) > width {
		label = fit(label, width)
	}
	start := max((width-displayWidth(label))/2, 0)
	parts := splitGraphemes(line)
	for offset, part := range splitGraphemes(label) {
		if start+offset >= len(parts) {
			break
		}
		parts[start+offset] = part
	}
	return strings.Join(parts, "")
}

func splitGraphemes(value string) []string {
	parts := []string{}
	graphemes := uniseg.NewGraphemes(value)
	for graphemes.Next() {
		parts = append(parts, graphemes.Str())
	}
	return parts
}

func (m Model) withFileTree(mainLines []string) []string {
	tree, ok := m.fileTree()
	if !ok || !tree.Visible || tree.Width == 0 || m.width < 50 {
		return m.withSemanticSidebars(mainLines)
	}

	sidebarWidth := fileTreeWidth(m.width, tree)
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
	visible := visibleSidebars(sidebars)
	if len(visible) == 0 {
		return mainLines
	}
	width := semanticSidebarWidth(m.width, sidebars)
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
	header := style.Bold(true).Foreground(theme.TreeHeaderText()).Background(theme.TreeHeader()).Render(fit(" Files  "+tree.Root, width))
	lines := []string{header}
	if len(tree.Rows) == 0 {
		if status := fileTreeStatusText(tree); status != "" && len(lines) < height {
			lines = append(lines, style.Foreground(theme.TreeMutedText()).Render(fit(" "+status, width)))
		}
	}
	for rowIndex, row := range tree.Rows {
		rendered := m.renderFileTreeRow(row, width)
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

func (m Model) renderFileTreeRow(row protocol.FileTreeRow, width int) string {
	theme := m.palette()
	rowBackground := theme.TreeSurface()
	textColor := theme.TreeText()
	markerColor := theme.TreeMutedText()
	if row.Directory {
		textColor = theme.TreeDirectoryText()
	}
	if fileTreeRowMuted(row) {
		textColor = theme.TreeMutedText()
	}
	if row.Selected {
		rowBackground = theme.TreeSelection()
		textColor = theme.TreeSelectionText()
	}
	selectionMarker := " "
	if row.Selected {
		selectionMarker = "▌"
	}
	prefix := strings.Repeat("  ", int(row.Depth))
	expander := " "
	if row.Directory && row.Expanded {
		expander = "▾"
	} else if row.Directory {
		expander = "▸"
	}
	rowStyle := lipgloss.NewStyle().Foreground(textColor).Background(rowBackground)
	markerStyle := lipgloss.NewStyle().Foreground(markerColor).Background(rowBackground)
	if row.Selected {
		markerStyle = markerStyle.Foreground(theme.Accent()).Bold(true)
	}
	icon := fileTreeIcon(row)
	iconStyle := rowStyle
	if icon.color != "" && !row.Selected && !fileTreeRowMuted(row) {
		iconStyle = iconStyle.Foreground(lipgloss.Color(icon.color))
	}
	nameStyle := rowStyle
	if row.Selected || row.Directory {
		nameStyle = nameStyle.Bold(true)
	}
	content := markerStyle.Render(selectionMarker+prefix+expander) + rowStyle.Render(" ") + iconStyle.Render(icon.glyph) + rowStyle.Render(" ") + nameStyle.Render(row.Name)
	if row.Dirty {
		dirty := lipgloss.NewStyle().Foreground(theme.Warning()).Background(rowBackground).Render("●")
		space := strings.Repeat(" ", max(width-lipgloss.Width(content)-lipgloss.Width(dirty), 1))
		content += rowStyle.Render(space) + dirty
	} else if remaining := width - lipgloss.Width(content); remaining > 0 {
		content += rowStyle.Render(strings.Repeat(" ", remaining))
	}
	return rowStyle.Width(width).Render(fitStyled(content, width))
}

func fileTreeRowMuted(row protocol.FileTreeRow) bool {
	name := strings.TrimSpace(row.Name)
	return strings.HasPrefix(name, ".") || strings.Contains(row.Path, "/.")
}

func fileTreeStatusText(tree protocol.FileTree) string {
	switch tree.Status {
	case 1:
		return "Loading files..."
	case 2:
		return "No files"
	case 4:
		if strings.TrimSpace(tree.Error) != "" {
			return tree.Error
		}
		return "File tree error"
	default:
		return ""
	}
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
