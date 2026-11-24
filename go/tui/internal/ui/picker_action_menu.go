package ui

import (
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// pickerActionMenuTitle and pickerActionMenuKey head the picker's act menu, as the macOS PickerOverlay does: the key is the one that opened it.
const (
	pickerActionMenuTitle = "Actions"
	pickerActionMenuKey   = "⌃."
)

// pickerActionIntent is the semantic intent that runs one picker action (PickerUI.activate_action on the BEAM).
const pickerActionIntent = 2

func pickerActionZone(row int) string {
	return "picker:action:" + strconv.Itoa(row)
}

// pickerActionMenuVisible reports whether the BEAM has the picker's act menu open with at least one action.
func pickerActionMenuVisible(picker protocol.Picker) bool {
	return picker.Visible && picker.ActionVisible && len(picker.Actions) > 0
}

// floatingPickerActionMenuLayer draws the picker's act menu as a popover centred over the picker, above it.
// The BEAM owns the menu: ⌃J / ⌃K move its selection, ↩ runs it and esc closes it, so this layer only presents the committed model.
func (m Model) floatingPickerActionMenuLayer() *lipgloss.Layer {
	picker, ok := m.picker()
	if !ok || !pickerActionMenuVisible(picker) {
		return nil
	}
	menu := m.renderPickerActionMenu(picker)
	width, height := lipgloss.Width(menu), lipgloss.Height(menu)
	x := max((m.width-width)/2, 0)
	y := max((m.height-height)/2, 0)
	m.zones.picker.actionBox = uiRect{X: x, Y: y, Width: width, Height: height}
	return lipgloss.NewLayer(m.zones.ScanInto(menu, x, y)).X(x).Y(y).Z(pickerActionMenuLayerZ)
}

// pickerActionMenuWidth is the popover's outer width: the widest row inside the anatomy.md popover bounds, never wider than the terminal.
func (m Model) pickerActionMenuWidth(picker protocol.Picker, frame popupFrame) int {
	content := lipgloss.Width(pickerActionMenuTitle) + popoverLabelToDirectKey.cols() + lipgloss.Width(pickerActionMenuKey)
	for _, action := range picker.Actions {
		content = max(content, lipgloss.Width(pickerActionMarker)+listRowGlyphToTitle.cols()+lipgloss.Width(action))
	}
	outer := content + frame.style.GetHorizontalFrameSize()
	return min(min(max(outer, popoverMinCols), popoverMaxCols), max(m.width, 1))
}

// pickerActionMarker marks the selected action, like the selected row of a list.
const pickerActionMarker = "▌"

func (m Model) renderPickerActionMenu(picker protocol.Picker) string {
	frame := m.popoverFrame()
	outer := m.pickerActionMenuWidth(picker, frame)
	width := frame.contentWidth(outer)
	maxRows := max(min(m.height-frame.style.GetVerticalFrameSize()-1, maxPopupRows), 1)
	lines := []string{m.renderPickerActionMenuHeader(width)}
	selected := int(picker.ActionIndex)
	start := 0
	if selected >= maxRows {
		start = selected - maxRows + 1
	}
	end := min(len(picker.Actions), start+maxRows)
	for index := start; index < end; index++ {
		row := m.renderPickerActionRow(picker.Actions[index], index == selected, width)
		if slot := index - start; slot < len(m.zones.picker.actions) && index < len(picker.ActionActivationIDs) && picker.ActionActivationIDs[index] != 0 {
			m.zones.picker.actions[slot] = picker.ActionActivationIDs[index]
			row = m.zones.Mark(pickerActionZone(slot), row)
		}
		lines = append(lines, row)
	}
	return frame.render(outer, strings.Join(lines, "\n"))
}

func (m Model) renderPickerActionMenuHeader(width int) string {
	p := m.palette()
	title := popoverLabelText.style(p).Bold(true).Foreground(p.Accent()).Background(p.PopupSurface()).Render(pickerActionMenuTitle)
	key := textCaption.style(p).Background(p.PopupSurface()).Render(pickerActionMenuKey)
	fill := max(width-lipgloss.Width(title)-lipgloss.Width(key), popoverLabelToDirectKey.cols())
	spacer := lipgloss.NewStyle().Background(p.PopupSurface()).Render(strings.Repeat(" ", fill))
	return renderPadded(m.popupLineStyle(width), title+spacer+key, width)
}

func (m Model) renderPickerActionRow(label string, selected bool, width int) string {
	p := m.palette()
	background, foreground := p.PopupSurface(), p.PopupText()
	if selected {
		background, foreground = p.PopupSelection(), p.PopupSelectionText()
	}
	marker := lipgloss.NewStyle().Background(background).ColorWhitespace(true).Render(" ")
	if selected {
		marker = lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(background).Render(pickerActionMarker)
	}
	labelStyle := popoverLabelText.style(p).Foreground(foreground).Background(background).ColorWhitespace(true)
	if selected {
		labelStyle = labelStyle.Bold(true)
	}
	text := marker + labelStyle.Render(gap(listRowGlyphToTitle)+label)
	rowStyle := lipgloss.NewStyle().Background(background).Width(width).ColorWhitespace(true)
	return renderPadded(rowStyle, text, width)
}

// pickerActionPointerPacket routes a click while the act menu is open: a row runs its action, and any other click is absorbed so it cannot activate the picker row underneath.
func (m Model) pickerActionPointerPacket(click tea.MouseClickMsg, generation uint32) []byte {
	painted := &m.zones.picker
	if painted.actionBox.Width == 0 || !painted.actionBox.Contains(click.X, click.Y) {
		return nil
	}
	for row, id := range painted.actions {
		if id != 0 && m.zones.Get(pickerActionZone(row)).InBounds(click) {
			return protocol.EncodeGUISemanticItemActivate(byte(presentationPicker), pickerActionIntent, generation, []byte{byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)})
		}
	}
	return nil
}
