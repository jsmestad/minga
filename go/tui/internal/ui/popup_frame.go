package ui

import "charm.land/lipgloss/v2"

// popupFrame is the border and padding around a floating popup. A popup renders through its frame and takes its content budget from the same frame, so the budget and the padding come from the same tokens and a token change cannot make fitted rows wrap.
type popupFrame struct {
	style lipgloss.Style
}

// popupFrameFor builds the frame for a corner step and the vertical and horizontal inset steps. A square corner draws no border.
func (m Model) popupFrameFor(corner radius, vertical, horizontal space) popupFrame {
	p := m.palette()
	style := lipgloss.NewStyle().Padding(padding(vertical, horizontal)).Background(p.PopupSurface()).ColorWhitespace(true)
	if border, ok := corner.border(); ok {
		style = style.Border(border).BorderForeground(p.PopupBorder()).BorderBackground(p.PopupSurface())
	}
	return popupFrame{style: style}
}

// popoverFrame is the frame of the anatomy.md popover and menu part, used by the floating picker and the notification center.
func (m Model) popoverFrame() popupFrame {
	return m.popupFrameFor(popoverCorner, popoverVerticalPadding, popoverRowInset)
}

// contentWidth is the columns left for content inside a popup outerWidth columns wide, border and padding taken out.
func (f popupFrame) contentWidth(outerWidth int) int {
	return max(outerWidth-f.style.GetHorizontalFrameSize(), 1)
}

// contentHeight is the rows left for content inside a popup outerHeight rows tall, border and padding taken out.
func (f popupFrame) contentHeight(outerHeight int) int {
	return max(outerHeight-f.style.GetVerticalFrameSize(), 1)
}

// render draws content inside the frame. outerWidth includes the border and padding, so rows fitted to contentWidth(outerWidth) never wrap.
func (f popupFrame) render(outerWidth int, content string) string {
	return f.style.Width(outerWidth).Render(content)
}
