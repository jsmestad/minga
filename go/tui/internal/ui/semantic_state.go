package ui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	fileTreeVisibleFlag            byte = 0x01
	fileTreeFocusedFlag            byte = 0x02
	fileTreeLocalNavigationFlag    byte = 0x20
	fileTreeReadyStatus            byte = 3
	fileTreeLocalNavigationDownKey rune = 'j'
	fileTreeLocalNavigationUpKey   rune = 'k'
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

func (m *Model) previewFileTreeNavigation(msg tea.KeyPressMsg) bool {
	key := msg.Key()
	if key.Mod.Contains(tea.ModShift) || key.Mod.Contains(tea.ModAlt) || key.Mod.Contains(tea.ModCtrl) || key.Mod.Contains(tea.ModSuper) {
		return false
	}

	delta, ok := fileTreeNavigationDelta(key)
	if !ok {
		return false
	}

	payload, ok := m.fileTree()
	if !ok || !payload.Visible || !payload.Focused || payload.Flags&fileTreeLocalNavigationFlag == 0 || payload.Status != fileTreeReadyStatus || len(payload.Rows) == 0 {
		return false
	}

	selectedIndex := fileTreeSelectedIndex(payload)
	if m.localPresentation.previewFileTreeIndex != nil {
		selectedIndex = *m.localPresentation.previewFileTreeIndex
	}
	if selectedIndex < 0 {
		return false
	}

	nextIndex := selectedIndex + delta
	if nextIndex < 0 {
		nextIndex = 0
	} else if nextIndex >= len(payload.Rows) {
		nextIndex = len(payload.Rows) - 1
	}
	if nextIndex == selectedIndex {
		return false
	}

	m.localPresentation.previewFileTreeIndex = &nextIndex
	return true
}

func fileTreeNavigationDelta(key tea.Key) (int, bool) {
	switch key.Code {
	case fileTreeLocalNavigationDownKey, tea.KeyDown:
		return 1, true
	case fileTreeLocalNavigationUpKey, tea.KeyUp:
		return -1, true
	default:
		return 0, false
	}
}

func fileTreeSelectedIndex(tree protocol.FileTree) int {
	if tree.Selected != "" {
		for i, row := range tree.Rows {
			if row.ID == tree.Selected {
				return i
			}
		}
	}
	for i, row := range tree.Rows {
		if row.Selected {
			return i
		}
	}
	return -1
}

func (m *Model) previewCompletionNavigation(msg tea.KeyPressMsg) bool {
	key := msg.Key()

	var delta int
	if key.Mod.Contains(tea.ModCtrl) && !key.Mod.Contains(tea.ModShift) && !key.Mod.Contains(tea.ModAlt) && !key.Mod.Contains(tea.ModSuper) {
		switch key.Code {
		case 'n':
			delta = 1
		case 'p':
			delta = -1
		default:
			return false
		}
	} else if !key.Mod.Contains(tea.ModCtrl) && !key.Mod.Contains(tea.ModShift) && !key.Mod.Contains(tea.ModAlt) && !key.Mod.Contains(tea.ModSuper) {
		switch key.Code {
		case tea.KeyDown:
			delta = 1
		case tea.KeyUp:
			delta = -1
		default:
			return false
		}
	} else {
		return false
	}

	payload, ok := m.chrome[generated.OPGuiCompletion]
	if !ok || !payload.Complete.Visible || len(payload.Complete.Items) == 0 {
		return false
	}

	current := int(payload.Complete.Selected)
	if m.localPresentation.previewCompletionIndex != nil {
		current = *m.localPresentation.previewCompletionIndex
	}

	next := current + delta
	if next < 0 {
		next = 0
	} else if next >= len(payload.Complete.Items) {
		next = len(payload.Complete.Items) - 1
	}
	if next == current {
		return false
	}

	m.localPresentation.previewCompletionIndex = &next
	return true
}

func (m Model) effectiveCompletionIndex(completion protocol.Completion) int {
	if m.localPresentation.previewCompletionIndex != nil {
		idx := *m.localPresentation.previewCompletionIndex
		if idx >= 0 && idx < len(completion.Items) {
			return idx
		}
	}
	return min(max(int(completion.Selected), 0), max(len(completion.Items)-1, 0))
}

func (m Model) applyIndentGuide(window protocol.WindowContent, style lipgloss.Style, rowIndex int, col int, text string) (lipgloss.Style, string) {
	guides, ok := m.indentGuides[window.ID]
	if !ok || text != " " || !guideColumnVisible(guides, col) || !guideEnabledOnRow(guides, rowIndex, col) {
		return style, text
	}
	guideStyle := style.Foreground(m.palette().GutterText())
	if uint16(col) == guides.ActiveGuideCol {
		guideStyle = guideStyle.Foreground(m.palette().GutterCurrentText())
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
	if len(guides.IndentLevels) == 0 || rowIndex < 0 || rowIndex >= len(guides.IndentLevels) || guides.TabWidth == 0 {
		return true
	}
	return col/int(guides.TabWidth) <= int(guides.IndentLevels[rowIndex])
}

func isWhitespace(value string) bool {
	return strings.TrimSpace(value) == ""
}
