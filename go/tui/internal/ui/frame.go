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
	// The single active secondary overlay is composited at its BEAM placement
	// rect (#2281), below the picker/which-key floating layers but above the base
	// content, instead of being footer-appended into the vertical layout.
	if overlay := m.overlayLayer(); overlay != nil {
		// Drop shadow for the completion popup (#2534): a dark rectangle at
		// (x+1, y+1) below the overlay Z creates a subtle depth cue matching
		// the rounded-border treatment the picker and which-key popups use.
		if shadow := m.completionShadowLayer(overlay); shadow != nil {
			layers = append(layers, shadow)
		}
		layers = append(layers, overlay)
	}
	if which := m.floatingWhichKeyLayer(); which != nil {
		layers = append(layers, which)
	}
	if picker := m.floatingPickerLayer(); picker != nil {
		layers = append(layers, picker)
	}
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
