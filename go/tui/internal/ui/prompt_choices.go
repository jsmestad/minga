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
	shortcutWidth := 0
	for _, item := range mini.Items {
		wanted += displayWidth(item.Label) + 2
		if item.Annotation != "" {
			shortcutWidth += displayWidth(item.Annotation) + 1
		}
	}
	// The prompt explains what the actions do. Show the authored shortcuts
	// together when they fit without taking cells from the question or input.
	showShortcuts := wanted+shortcutWidth+1+displayWidth(mini.Prompt)+displayWidth(mini.Input) <= width
	if showShortcuts {
		wanted += shortcutWidth
	}
	budget := min(wanted, width)
	inputWidth := max(width-budget-1, 0)
	parts := make([]string, 0, len(mini.Items)+1)
	palette := m.palette()
	textStyle := lipgloss.NewStyle().Foreground(palette.PopupText()).Background(palette.PopupSurface())
	actionStyle := textStyle.Bold(true)
	if inputWidth > 0 {
		if mini.CursorPos == 0xFFFF {
			parts = append(parts, textStyle.Render(fit(mini.Prompt, inputWidth)))
		} else {
			inputModel := m
			inputModel.width = inputWidth
			parts = append(parts, inputModel.charmInput(mini.Prompt, mini.Input, mini.CursorPos))
		}
	}
	for index, item := range mini.Items {
		remaining := len(mini.Items) - index
		gap := 0
		if budget >= remaining*2-1 {
			gap = remaining - 1
		}
		label := item.Label
		if showShortcuts && item.Annotation != "" {
			label += " " + item.Annotation
		}
		cells := displayWidth(label) + 2
		if wanted > width {
			cells = min(cells, max((budget-gap)/remaining, 0))
		}
		if cells == 0 {
			continue
		}
		caption := fit("["+label+"]", cells)
		parts = append(parts, m.zones.Mark(zoneIDPromptChoice(mini.Generation, item.ID), actionStyle.Render(caption)))

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
