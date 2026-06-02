package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
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
		for _, row := range window.Rows {
			lines = append(lines, m.renderRow(row))
		}
	}
	if len(lines) == 0 {
		return nil
	}
	return lines
}

func (m Model) renderRow(row protocol.WindowRow) string {
	if len(row.Spans) == 0 {
		return m.editorStyle().Render(fit(row.Text, m.width))
	}

	var builder strings.Builder
	col := 0
	for _, r := range row.Text {
		span := spanAt(row.Spans, uint16(col))
		style := m.styleForEditorSpan(span)
		builder.WriteString(style.Render(string(r)))
		col++
	}
	return m.editorStyle().Render(fitStyled(builder.String(), m.width))
}

func (m Model) cellLines() []string {
	rows := make([][]string, max(m.height-2, 1))
	for i := range rows {
		rows[i] = make([]string, max(m.width, 1))
		for j := range rows[i] {
			rows[i][j] = " "
		}
	}

	for pos, cell := range m.cells {
		if int(pos.row) < len(rows) && int(pos.col) < len(rows[pos.row]) {
			rows[pos.row][pos.col] = m.styleForEditorSpan(protocol.Span{FG: cell.fg, BG: cell.bg, Attrs: byte(cell.attrs)}).Render(cell.text)
		}
	}

	rendered := make([]string, len(rows))
	for i, row := range rows {
		rendered[i] = m.editorStyle().Render(fitStyled(strings.Join(row, ""), m.width))
	}
	return rendered
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

func (m Model) renderFileTree(tree protocol.FileTree, width int, height int) []string {
	theme := m.palette()
	style := lipgloss.NewStyle().Foreground(theme.TreeText()).Background(theme.TreeSurface()).Width(width)
	selectedStyle := style.Foreground(theme.Text()).Background(theme.TreeSelection()).Bold(true)
	header := style.Bold(true).Foreground(theme.TreeHeaderText()).Background(theme.TreeHeader()).Render(fit("Files  "+tree.Root, width))
	lines := []string{header}
	for _, row := range tree.Rows {
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
		if row.Selected {
			lines = append(lines, selectedStyle.Render(text))
		} else {
			lines = append(lines, style.Render(text))
		}
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
		style = style.Reverse(true)
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
		style = style.Italic(true)
	}
	if span.Attrs&0x04 != 0 {
		style = style.Underline(true)
	}
	if span.Attrs&0x08 != 0 {
		style = style.Reverse(true)
	}
	return style
}
