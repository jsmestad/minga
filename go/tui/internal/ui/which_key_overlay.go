package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func (m Model) whichKeyVisible() bool {
	which, ok := m.whichKey()
	return ok && which.Visible && len(which.Bindings) > 0
}

func (m Model) floatingWhichKeyLayer() *lipgloss.Layer {
	which, ok := m.whichKey()
	if !ok || !which.Visible || len(which.Bindings) == 0 {
		return nil
	}
	popup := m.renderFloatingWhichKey(which)
	if popup == "" {
		return nil
	}
	x := 2
	y := max(m.height-lipgloss.Height(popup)-2, 0)
	return lipgloss.NewLayer(popup).X(x).Y(y).Z(9)
}

func (m Model) renderFloatingWhichKey(which protocol.WhichKey) string {
	popupWidth := m.whichKeyWidth()
	contentWidth := max(popupWidth-2, 1)
	inner := max(contentWidth-2, 1)
	columns := m.whichKeyColumns(inner, len(which.Bindings))
	gutter := m.whichKeyColumnGutter()
	gutterWidth := lipgloss.Width(gutter)
	cellWidth := max((inner-gutterWidth*(columns-1))/columns, 1)
	keyWidth := whichKeyKeyWidth(which.Bindings)

	lines := []string{m.renderWhichKeyHeader(which, inner)}
	rows := (len(which.Bindings) + columns - 1) / columns
	for row := 0; row < rows; row++ {
		cells := make([]string, 0, columns)
		for col := 0; col < columns; col++ {
			index := row*columns + col
			if index >= len(which.Bindings) {
				cells = append(cells, m.popupLineStyle(cellWidth).Render(strings.Repeat(" ", cellWidth)))
				continue
			}
			cells = append(cells, m.renderWhichKeyCell(which.Bindings[index], cellWidth, keyWidth))
		}
		lines = append(lines, strings.Join(cells, gutter))
	}
	lines = append(lines, m.renderWhichKeyFooter(which, inner))

	content := strings.Join(lines, "\n")
	return lipgloss.NewStyle().Width(contentWidth).Padding(0, 1).Border(lipgloss.NormalBorder()).BorderForeground(m.palette().PopupBorder()).Background(m.palette().PopupSurface()).Render(content)
}

func (m Model) renderWhichKeyHeader(which protocol.WhichKey, width int) string {
	p := m.palette()
	label := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupChrome()).Render(" Keys ")
	prefix := which.Prefix
	if prefix == "" {
		prefix = "root"
	}
	prefixText := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.PopupChrome()).Render(prefix)
	pager := ""
	if which.PageCount > 1 {
		pager = fmt.Sprintf("%d/%d ", which.Page+1, which.PageCount)
	}
	pagerText := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupChrome()).Render(pager)
	spacer := strings.Repeat(" ", max(width-lipgloss.Width(label)-lipgloss.Width(prefixText)-lipgloss.Width(pagerText), 0))
	return lipgloss.NewStyle().Background(p.PopupChrome()).Width(width).Render(fitStyled(label+prefixText+spacer+pagerText, width))
}

func (m Model) renderWhichKeyFooter(which protocol.WhichKey, width int) string {
	p := m.palette()
	left := fmt.Sprintf(" %d bindings", len(which.Bindings))
	right := "Esc close"
	if which.PageCount > 1 {
		wideRight := "Tab next  •  Esc close"
		if lipgloss.Width(left)+lipgloss.Width(wideRight)+4 <= width {
			right = wideRight
		} else {
			right = "Tab next  Esc"
		}
	}
	if lipgloss.Width(left)+lipgloss.Width(right)+2 > width {
		right = "Esc"
	}
	leftText := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupChrome()).Render(left)
	rightText := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupChrome()).Render(right)
	spacer := strings.Repeat(" ", max(width-lipgloss.Width(leftText)-lipgloss.Width(rightText), 0))
	return lipgloss.NewStyle().Background(p.PopupChrome()).Width(width).Render(fitStyled(leftText+spacer+rightText, width))
}

func (m Model) renderWhichKeyCell(binding protocol.WhichKeyBinding, width int, keyWidth int) string {
	p := m.palette()
	group := whichKeyGroup(binding)
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(p.KeycapText()).Background(p.KeycapSurface()).Width(keyWidth).Align(lipgloss.Center)
	descStyle := lipgloss.NewStyle().Foreground(p.PopupText()).Background(p.PopupSurface())
	iconBackground := p.PopupSurface()
	if group {
		keyStyle = lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupSurface()).Width(keyWidth).Align(lipgloss.Center)
		descStyle = lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.PopupSurface())
	}
	key := strings.TrimSpace(binding.Key)
	icon := whichKeyIcon(binding)
	iconText := icon.glyph
	if icon.color != "" && !group {
		iconText = lipgloss.NewStyle().Foreground(lipgloss.Color(icon.color)).Background(iconBackground).Render(icon.glyph)
	} else if group {
		iconText = lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(iconBackground).Render("›")
	}
	label := strings.TrimSpace(iconText + " " + binding.Description)
	if group && !strings.HasSuffix(label, "›") {
		label += " ›"
	}
	keyPart := keyStyle.Render(fit(key, keyWidth))
	remaining := max(width-lipgloss.Width(keyPart)-1, 0)
	cell := keyPart
	if remaining > 0 {
		cell += " " + descStyle.Render(fit(label, remaining))
	}
	return lipgloss.NewStyle().Background(p.PopupSurface()).Width(width).Render(fitStyled(cell, width))
}

func whichKeyGroup(binding protocol.WhichKeyBinding) bool {
	return strings.HasPrefix(strings.TrimSpace(binding.Description), "+")
}

func whichKeyKeyWidth(bindings []protocol.WhichKeyBinding) int {
	width := 3
	for _, binding := range bindings {
		width = max(width, lipgloss.Width(strings.TrimSpace(binding.Key)))
	}
	return min(max(width, 3), 6)
}

func (m Model) whichKeyColumnGutter() string {
	return lipgloss.NewStyle().Foreground(m.palette().PopupBorder()).Background(m.palette().PopupSurface()).Render("  │  ")
}

func (m Model) whichKeyColumns(width int, count int) int {
	switch {
	case width >= 72 && count >= 9:
		return 3
	case width >= 42 && count >= 4:
		return 2
	default:
		return 1
	}
}

func (m Model) whichKeyWidth() int {
	if m.width <= 24 {
		return max(m.width, 1)
	}
	return min(max(m.width/2, 48), min(96, max(m.width-4, 1)))
}
