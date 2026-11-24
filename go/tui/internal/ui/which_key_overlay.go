package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
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
	// The panel sits two columns in, or flush left when a narrow terminal leaves no room for the offset.
	x := max(min(2, m.width-lipgloss.Width(popup)), 0)
	y := max(m.height-lipgloss.Height(popup)-2, 0)
	return lipgloss.NewLayer(popup).X(x).Y(y).Z(whichKeyLayerZ)
}

func (m Model) renderFloatingWhichKey(which protocol.WhichKey) string {
	popupWidth := m.whichKeyWidth()
	frame := m.whichKeyFrame()
	inner := frame.contentWidth(popupWidth)
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

	return frame.render(popupWidth, strings.Join(lines, "\n"))
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
		wideRight := strings.Join([]string{"Tab next", "•", "Esc close"}, gap(spaceXL))
		if lipgloss.Width(left)+lipgloss.Width(wideRight)+4 <= width {
			right = wideRight
		} else {
			right = strings.Join([]string{"Tab next", "Esc"}, gap(spaceXL))
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

// renderWhichKeyCell draws one entry. Group rows arrive from the BEAM as Title Case labels with a trailing chevron ("Session ›"); they draw in the group colour role, and the label is never rewritten here.
func (m Model) renderWhichKeyCell(binding protocol.WhichKeyBinding, width int, keyWidth int) string {
	p := m.palette()
	group := whichKeyGroup(binding)
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(p.KeycapText()).Background(p.KeycapSurface()).Width(keyWidth).Align(lipgloss.Center)
	descStyle := lipgloss.NewStyle().Foreground(p.PopupText()).Background(p.PopupSurface())
	iconBackground := p.PopupSurface()
	if group {
		keyStyle = lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupSurface()).Width(keyWidth).Align(lipgloss.Center)
		descStyle = lipgloss.NewStyle().Foreground(p.Role(generated.ColorRoleGroup)).Background(p.PopupSurface())
	}
	key := strings.TrimSpace(binding.Key)
	icon := whichKeyIcon(binding)
	iconStyle := lipgloss.NewStyle().Foreground(p.PopupText()).Background(iconBackground)
	if group {
		iconStyle = iconStyle.Foreground(p.Role(generated.ColorRoleGroup))
	} else if icon.color != "" {
		iconStyle = iconStyle.Foreground(lipgloss.Color(icon.color))
	}
	keyPart := keyStyle.Render(fit(key, keyWidth))
	cell := keyPart
	// The icon and the label render separately so the icon's reset never strips the label's colour.
	if remaining := width - lipgloss.Width(keyPart) - 1; remaining > 0 {
		cell += " "
		if glyph := strings.TrimSpace(icon.glyph); glyph != "" && displayWidth(glyph)+1 < remaining {
			cell += iconStyle.Render(glyph) + descStyle.Render(" ")
			remaining -= displayWidth(glyph) + 1
		}
		label := strings.TrimSpace(binding.Description)
		if displayWidth(label) > remaining {
			label = ansi.TruncateWc(label, remaining, "…")
		}
		cell += descStyle.Render(fit(label, remaining))
	}
	return lipgloss.NewStyle().Background(p.PopupSurface()).Width(width).Render(fitStyled(cell, width))
}

// whichKeyGroup reports whether the entry leads to more keys. The BEAM says so in the binding kind; the label's text never decides it.
func whichKeyGroup(binding protocol.WhichKeyBinding) bool {
	return binding.Kind == whichKeyKindGroup
}

// whichKeyKindGroup is the binding kind the BEAM sends for a group (docs/GUI_PROTOCOL.md, gui_which_key).
const whichKeyKindGroup byte = 1

func whichKeyKeyWidth(bindings []protocol.WhichKeyBinding) int {
	width := 3
	for _, binding := range bindings {
		width = max(width, lipgloss.Width(strings.TrimSpace(binding.Key)))
	}
	return min(max(width, 3), 6)
}

func (m Model) whichKeyColumnGutter() string {
	return lipgloss.NewStyle().Foreground(m.palette().PopupBorder()).Background(m.palette().PopupSurface()).Render(gap(spaceXL) + "│" + gap(spaceXL))
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
