package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func (m Model) whichKeyVisible() bool {
	which, ok := m.whichKey()
	return ok && which.Visible && len(which.Bindings) > 0
}

func (m Model) floatingWhichKeyLayer() *lipgloss.Layer {
	which, ok := m.whichKey()
	if !ok || !which.Visible || len(which.Bindings) == 0 {
		return nil
	}
	popup := m.renderFloatingWhichKey(which)
	if popup == "" {
		return nil
	}
	x := 2
	y := max(m.height-lipgloss.Height(popup)-2, 0)
	return lipgloss.NewLayer(popup).X(x).Y(y).Z(9)
}

func (m Model) renderFloatingWhichKey(which protocol.WhichKey) string {
	popupWidth := m.whichKeyWidth()
	contentWidth := max(popupWidth-2, 1)
	inner := max(contentWidth-2, 1)
	title := "Keys"
	if which.Prefix != "" {
		title += " " + which.Prefix
	}
	if which.PageCount > 1 {
		title += fmt.Sprintf("  %d/%d", which.Page+1, which.PageCount)
	}

	lines := []string{lipgloss.NewStyle().Bold(true).Foreground(m.palette().Accent()).Background(m.palette().PopupChrome()).Width(inner).Render(fit(title, inner))}
	columns := m.whichKeyColumns(inner)
	rows := (len(which.Bindings) + columns - 1) / columns
	cellWidth := max(inner/columns, 1)
	for row := 0; row < rows; row++ {
		cells := make([]string, 0, columns)
		for col := 0; col < columns; col++ {
			index := row*columns + col
			if index >= len(which.Bindings) {
				cells = append(cells, strings.Repeat(" ", cellWidth))
				continue
			}
			cells = append(cells, m.renderWhichKeyCell(which.Bindings[index], cellWidth))
		}
		lines = append(lines, strings.Join(cells, ""))
	}

	content := strings.Join(lines, "\n")
	return lipgloss.NewStyle().Width(contentWidth).Padding(0, 1).Border(lipgloss.RoundedBorder()).BorderForeground(m.palette().PopupBorder()).Background(m.palette().PopupSurface()).Render(content)
}

func (m Model) renderWhichKeyCell(binding protocol.WhichKeyBinding, width int) string {
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(m.palette().PopupSelectionText()).Background(m.palette().PopupSelection()).Padding(0, 1)
	descStyle := lipgloss.NewStyle().Foreground(m.palette().PopupText()).Background(m.palette().PopupSurface())
	key := strings.TrimSpace(binding.Key)
	icon := whichKeyIcon(binding)
	iconText := icon.glyph
	if icon.color != "" {
		iconText = lipgloss.NewStyle().Foreground(lipgloss.Color(icon.color)).Background(m.palette().PopupSurface()).Render(icon.glyph)
	}
	label := strings.TrimSpace(iconText + " " + binding.Description)
	keyPart := keyStyle.Render(key)
	remaining := max(width-lipgloss.Width(keyPart)-1, 0)
	cell := keyPart
	if remaining > 0 {
		cell += " " + descStyle.Render(fit(label, remaining))
	}
	return lipgloss.NewStyle().Background(m.palette().PopupSurface()).Width(width).Render(fitStyled(cell, width))
}

func (m Model) whichKeyColumns(width int) int {
	switch {
	case width >= 96:
		return 4
	case width >= 64:
		return 3
	case width >= 36:
		return 2
	default:
		return 1
	}
}

func (m Model) whichKeyWidth() int {
	if m.width <= 24 {
		return max(m.width, 1)
	}
	return min(max(m.width*2/3, 42), max(m.width-4, 1))
}
