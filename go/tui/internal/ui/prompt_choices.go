package ui

import (
	"fmt"
	"net/url"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func zoneIDPromptChoice(generation uint32, itemID string) string {
	return fmt.Sprintf("minibuffer:choice:%d:%s", generation, url.QueryEscape(itemID))
}

// Generic prompt choices share the BEAM-authored single minibuffer row. Keep
// both choices reachable at narrow widths by shrinking the input first, then
// sharing the available cells between choices. Input comes from the committed minibuffer.
func (m Model) renderPromptChoices(mini protocol.Minibuffer) string {
	width := max(m.width, 1)
	wanted := len(mini.Items) - 1
	for _, item := range mini.Items {
		wanted += displayWidth(item.Label) + 2
	}
	budget := min(wanted, width)
	inputWidth := max(width-budget-1, 0)
	parts := make([]string, 0, len(mini.Items)+1)
	if inputWidth > 0 {
		inputModel := m
		inputModel.width = inputWidth
		parts = append(parts, inputModel.charmInput(mini.Prompt, mini.Input, mini.CursorPos))
	}
	style := lipgloss.NewStyle().Foreground(m.palette().Accent()).Background(m.palette().PopupSurface()).Bold(true)
	for index, item := range mini.Items {
		remaining := len(mini.Items) - index
		gap := 0
		if budget >= remaining*2-1 {
			gap = remaining - 1
		}
		cells := displayWidth(item.Label) + 2
		if wanted > width {
			cells = min(cells, max((budget-gap)/remaining, 0))
		}
		if cells == 0 {
			continue
		}
		label := fit("["+item.Label+"]", cells)
		parts = append(parts, m.zones.Mark(zoneIDPromptChoice(mini.Generation, item.ID), style.Render(label)))
		budget -= cells
		if gap > 0 {
			budget--
		}
	}
	separator := " "
	if width < len(mini.Items)*2-1 {
		separator = ""
	}
	return strings.Join(parts, separator)
}

func (m Model) promptChoiceMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	mini, ok := m.minibuffer()
	if !ok || !mini.Visible || mini.Mode != 10 || mini.Generation == 0 {
		return nil, false
	}
	for _, item := range mini.Items {
		zone := m.zones.Get(zoneIDPromptChoice(mini.Generation, item.ID))
		if zone != nil && zone.InBounds(msg) {
			return protocol.EncodeGUISemanticItemActivate(4, 1, mini.Generation, []byte(item.ID)), true
		}
	}
	return nil, false
}
