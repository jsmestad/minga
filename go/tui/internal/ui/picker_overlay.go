package ui

import (
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const maxPopupRows = 12

// pickerPointerZones binds bounded row labels to the exact picker drawn by View.
type pickerPointerZones struct {
	box        uiRect
	generation uint32
	items      [maxPopupRows]uint32
}

func pickerPointerZone(row int) string {
	return "picker:row:" + strconv.Itoa(row)
}

func (m Model) pickerVisible() bool {
	picker, ok := m.picker()
	return ok && picker.Visible
}

func (m Model) floatingPickerLayer() *lipgloss.Layer {
	picker, ok := m.picker()
	if !ok || !picker.Visible {
		return nil
	}
	preview, _ := m.pickerPreview()
	popup := m.renderFloatingPicker(picker, preview)
	if popup == "" {
		return nil
	}
	width, height := lipgloss.Width(popup), lipgloss.Height(popup)
	x := max((m.width-width)/2, 0)
	y := max((m.height-height)/2, 0)
	m.zones.picker.box = uiRect{X: x, Y: y, Width: width, Height: height}
	m.zones.picker.generation = picker.Generation
	return lipgloss.NewLayer(m.zones.ScanInto(popup, x, y)).X(x).Y(y).Z(10)
}

func (m Model) renderFloatingPicker(picker protocol.Picker, preview protocol.PickerPreview) string {
	popupWidth := m.floatingPickerWidth()
	contentWidth := max(popupWidth-4, 1)
	popupModel := m
	popupModel.width = contentWidth
	lines := popupModel.renderPicker(picker, preview)
	if len(lines) == 0 {
		return ""
	}
	content := strings.Join(lines, "\n")
	// The outer width includes both padding and border. Pass it intact to avoid wrapping fitted rows.
	return lipgloss.NewStyle().Width(popupWidth).Padding(0, 1).Border(lipgloss.RoundedBorder()).BorderForeground(m.palette().PopupBorder()).BorderBackground(m.palette().PopupSurface()).Background(m.palette().PopupSurface()).ColorWhitespace(true).Render(content)
}

func (m Model) floatingPickerWidth() int {
	if m.width <= 24 {
		return max(m.width, 1)
	}
	if m.width >= 120 {
		return min(m.width-8, 120)
	}
	return min(m.width-4, max(48, m.width*9/10))
}

func (m Model) pickerPointerPacket(click tea.MouseClickMsg) ([]byte, bool) {
	painted := &m.zones.picker
	picker, ok := m.picker()
	if !ok || !picker.Visible {
		return nil, painted.box.Width != 0
	}
	if painted.box.Width == 0 || painted.generation == 0 || painted.generation != picker.Generation {
		return nil, true
	}
	if !painted.box.Contains(click.X, click.Y) {
		return protocol.EncodeGUISemanticItemActivate(byte(presentationPicker), 3, painted.generation, nil), true
	}
	for row, id := range painted.items {
		if id != 0 && m.zones.Get(pickerPointerZone(row)).InBounds(click) {
			return pickerActivationPacket(painted.generation, id), true
		}
	}
	return nil, true
}

func pickerActivationPacket(generation, id uint32) []byte {
	return protocol.EncodeGUISemanticItemActivate(byte(presentationPicker), 1, generation, []byte{byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)})
}
