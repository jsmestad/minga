package ui

import (
	"strings"

	"charm.land/lipgloss/v2"
)

func (m Model) composeFrame(content string) string {
	layers := []*lipgloss.Layer{
		lipgloss.NewLayer(m.windowBackground()).X(0).Y(0).Z(0),
		lipgloss.NewLayer(content).X(0).Y(0).Z(1),
	}
	layers = append(layers, m.floatingOverlayLayers()...)
	return lipgloss.NewCompositor(layers...).Render()
}

func (m Model) windowBackground() string {
	width := max(m.width, 1)
	height := max(m.height, 1)
	line := strings.Repeat(" ", width)
	lines := make([]string, height)
	style := lipgloss.NewStyle().Background(m.editorBackground()).Width(width)
	for i := range lines {
		lines[i] = style.Render(line)
	}
	return strings.Join(lines, "\n")
}
