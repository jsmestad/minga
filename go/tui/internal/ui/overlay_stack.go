package ui

import (
	"strings"

	"charm.land/lipgloss/v2"
)

// Which-key and the picker are what the user just asked for, so they paint above every BEAM-placed footer band (whose layer z is its placement z, 150 to 301, plus 2; see overlayLayer).
// An Agent activity card left open while Minga works must not cover them (#4157).
// The picker's action menu opens from the picker, so it paints above it.
// Which-key paints above both: the mode pill opens a picker's own keys over the picker.
// The steps leave room for each layer's shadow (its z minus 1) to stay above the layer below.
const (
	pickerLayerZ           = 1010
	pickerActionMenuLayerZ = 1020
	whichKeyLayerZ         = 1030
)

// floatingOverlayLayers returns the lipgloss layers for all active floating
// overlays in compositing order (lowest Z first). The BEAM-placed secondary
// overlay sits below the modal floating layers.
func (m Model) floatingOverlayLayers() []*lipgloss.Layer {
	var layers []*lipgloss.Layer
	if overlay := m.overlayLayer(); overlay != nil {
		if winner, ok := m.overlayWinner(); ok && !castsShadow(winner.surfaceID) {
			layers = append(layers, overlay)
		} else {
			layers = append(layers, popupShadow(overlay)...)
		}
	}
	// Which-key sits directly on the modeline, so it casts no shadow (a shadow would paint over the modeline).
	if which := m.floatingWhichKeyLayer(); which != nil {
		layers = append(layers, which)
	}
	if picker := m.floatingPickerLayer(); picker != nil {
		layers = append(layers, popupShadow(picker)...)
	}
	if menu := m.floatingPickerActionMenuLayer(); menu != nil {
		layers = append(layers, popupShadow(menu)...)
	}
	return layers
}

// castsShadow reports whether the winning secondary overlay paints a drop shadow.
// Help fills its exact authored containment, including its header. Footer bands
// sit directly above the status row and command line, so a shadow one row below
// would paint over them. Cursor-anchored popups keep their shadow.
func castsShadow(surfaceID uint16) bool {
	switch surfaceID {
	case surfaceIDAgentHelp, surfaceIDFloatPopup, surfaceIDAgentContext, surfaceIDExtensionPanel,
		surfaceIDObservatory, surfaceIDNotifications, surfaceIDExtensionOverlay:
		return false
	default:
		return true
	}
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
