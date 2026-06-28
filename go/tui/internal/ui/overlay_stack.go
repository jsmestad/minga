package ui

import (
	"strings"

	"charm.land/lipgloss/v2"
)

// modalOverlayActive reports whether a modal overlay (picker, which-key, or
// agent chat) is visible. When true, local side-effects like file-tree
// navigation preview are suppressed so keystrokes pass through to the BEAM
// without the frontend acting on them independently.
func (m Model) modalOverlayActive() bool {
	return m.pickerVisible() || m.whichKeyVisible() || m.agentChatVisible()
}

// floatingOverlayLayers returns the lipgloss layers for all active floating
// overlays in compositing order (lowest Z first). The BEAM-placed secondary
// overlay sits below the modal floating layers.
func (m Model) floatingOverlayLayers() []*lipgloss.Layer {
	var layers []*lipgloss.Layer
	if overlay := m.overlayLayer(); overlay != nil {
		// Drop shadow behind bordered overlays (completion #2534, notifications
		// #2538): same popupShadow treatment that which-key and picker get.
		layers = append(layers, popupShadow(overlay)...)
	}
	if which := m.floatingWhichKeyLayer(); which != nil {
		layers = append(layers, popupShadow(which)...)
	}
	if picker := m.floatingPickerLayer(); picker != nil {
		layers = append(layers, popupShadow(picker)...)
	}
	return layers
}

// popupShadow returns the popup layer preceded by a dark shadow layer offset
// 1 cell right and 1 cell down. The shadow sits at Z-1 so the popup renders
// on top, giving floating overlays visual depth.
func popupShadow(popup *lipgloss.Layer) []*lipgloss.Layer {
	w := popup.Width()
	h := popup.Height()
	if w <= 0 || h <= 0 {
		return []*lipgloss.Layer{popup}
	}
	line := lipgloss.NewStyle().Background(lipgloss.Color("#000000")).Render(strings.Repeat(" ", w))
	shadowLines := make([]string, h)
	for i := range shadowLines {
		shadowLines[i] = line
	}
	shadow := lipgloss.NewLayer(strings.Join(shadowLines, "\n")).
		X(popup.GetX() + 1).Y(popup.GetY() + 1).Z(popup.GetZ() - 1)
	return []*lipgloss.Layer{shadow, popup}
}
