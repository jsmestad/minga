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
	// actionBox and actions bind the act menu's rows, painted above the picker while the BEAM has the menu open.
	actionBox uiRect
	actions   [maxPopupRows]uint32
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
	return lipgloss.NewLayer(m.zones.ScanInto(popup, x, y)).X(x).Y(y).Z(pickerLayerZ)
}

func (m Model) renderFloatingPicker(picker protocol.Picker, preview protocol.PickerPreview) string {
	popupWidth := m.floatingPickerWidth()
	frame := m.popoverFrame()
	popupModel := m.pickerPopupModel()
	lines := popupModel.renderPicker(picker, preview)
	if len(lines) == 0 {
		return ""
	}
	return frame.render(popupWidth, strings.Join(lines, "\n"))
}

// pickerPopupModel is the model the picker popup draws with: its width is the popup's content width.
func (m Model) pickerPopupModel() Model {
	popupModel := m
	popupModel.width = m.popoverFrame().contentWidth(m.floatingPickerWidth())
	return popupModel
}

// pickerShownItems counts the result rows the popup draws for this picker: the items in the drawn window, section headers left out.
func (m Model) pickerShownItems(picker protocol.Picker, preview protocol.PickerPreview) int {
	popupModel := m.pickerPopupModel()
	layout := popupModel.pickerLayout(preview)
	budget := max(layout.itemRowBudget()-len(popupModel.pickerEmptyHeader(picker, layout.listHeight, popupModel.width)), 0)
	start, end, _ := pickerItemWindow(picker.Items, m.effectivePickerIndex(picker), budget)
	return end - start
}

// reportPickerFit tells the BEAM how many result rows the open picker shows, once per picker and again when the count changes.
// The BEAM pages the picker by this count (ADR-0001: row fit is a presentation fact the frontend owns).
func (m *Model) reportPickerFit() {
	fit, ok := m.pickerFit()
	if !ok {
		m.lastPickerFit = protocol.PickerFit{}
		return
	}
	if fit.Rows > 0 && fit != m.lastPickerFit && m.send(protocol.EncodeGUIPickerFit(fit)) {
		m.lastPickerFit = fit
	}
}

// pickerFit is the row fit of the open picker, or false when no picker is open.
func (m Model) pickerFit() (protocol.PickerFit, bool) {
	picker, ok := m.picker()
	if !ok || picker.Generation == 0 {
		return protocol.PickerFit{}, false
	}
	preview, _ := m.pickerPreview()
	rows := m.pickerShownItems(picker, preview)
	return protocol.PickerFit{Generation: picker.Generation, Rows: uint16(min(max(rows, 0), 65535))}, true
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
	if pickerActionMenuVisible(picker) {
		return m.pickerActionPointerPacket(click, painted.generation), true
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
