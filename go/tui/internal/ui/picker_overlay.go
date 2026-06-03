package ui

import (
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

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
	x := max((m.width-lipgloss.Width(popup))/2, 0)
	y := max((m.height-lipgloss.Height(popup))/2, 0)
	return lipgloss.NewLayer(popup).X(x).Y(y).Z(10)
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
	return lipgloss.NewStyle().Width(contentWidth).Padding(0, 1).Border(lipgloss.RoundedBorder()).BorderForeground(m.palette().PopupBorder()).Background(m.palette().PopupSurface()).Render(content)
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
