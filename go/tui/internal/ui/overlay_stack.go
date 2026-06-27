package ui

import "charm.land/lipgloss/v2"

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
		layers = append(layers, overlay)
	}
	if which := m.floatingWhichKeyLayer(); which != nil {
		layers = append(layers, which)
	}
	if picker := m.floatingPickerLayer(); picker != nil {
		layers = append(layers, picker)
	}
	return layers
}
