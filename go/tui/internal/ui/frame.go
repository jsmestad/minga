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
		// Drop shadow behind notification overlays (#2538).
		if shadow := m.notificationShadowLayer(); shadow != nil {
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

// notificationShadowLayer returns a drop-shadow layer behind the notification
// overlay when it is the active overlay winner. Returns nil when notifications
// are not visible or lack a BEAM placement. The shadow is offset 1 cell right
// and 1 cell down from the notification rect, at z = winner.order + 1 (just
// below the notification layer at winner.order + 2).
func (m Model) notificationShadowLayer() *lipgloss.Layer {
	winner, ok := m.overlayWinner()
	if !ok || winner.surfaceID != surfaceIDNotifications {
		return nil
	}
	rect, ok := m.surfacePlacementFor(surfaceIDNotifications)
	if !ok {
		return nil
	}
	return popupShadow(int(rect.Col), int(rect.Row), int(winner.order)+1, int(rect.Width), int(rect.Height))
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
