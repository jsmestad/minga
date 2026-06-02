package ui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func (m *Model) applyFileTreeSelection(selection protocol.FileTreeSelection) {
	payload, ok := m.chrome[generated.OPGuiFileTree]
	if !ok || len(payload.Tree.Rows) == 0 {
		return
	}
	payload.Tree.Focused = selection.Focused
	payload.Tree.Selected = selection.SelectedID
	for i := range payload.Tree.Rows {
		selected := payload.Tree.Rows[i].ID == selection.SelectedID
		payload.Tree.Rows[i].Selected = selected
		payload.Tree.Rows[i].Focused = selected && selection.Focused
	}
	m.chrome[generated.OPGuiFileTree] = payload
}

func (m Model) applyIndentGuide(window protocol.WindowContent, style lipgloss.Style, rowIndex int, col int, text string) (lipgloss.Style, string) {
	guides, ok := m.indentGuides[window.ID]
	if !ok || text != " " || !guideColumnVisible(guides, col) || !guideEnabledOnRow(guides, rowIndex, col) {
		return style, text
	}
	guideStyle := style.Foreground(m.palette().GutterText())
	if uint16(col) == guides.ActiveGuideCol {
		guideStyle = guideStyle.Foreground(m.palette().Accent()).Bold(true)
	}
	return guideStyle, "│"
}

func guideColumnVisible(guides protocol.IndentGuides, col int) bool {
	for _, guideCol := range guides.GuideCols {
		if int(guideCol) == col {
			return true
		}
	}
	return false
}

func guideEnabledOnRow(guides protocol.IndentGuides, rowIndex int, col int) bool {
	if len(guides.IndentLevels) == 0 || rowIndex >= len(guides.IndentLevels) || guides.TabWidth == 0 {
		return true
	}
	return int(guides.IndentLevels[rowIndex]) > col/int(guides.TabWidth)
}

func isWhitespace(value string) bool {
	return strings.TrimSpace(value) == ""
}
