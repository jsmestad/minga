package ui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	zoneIDAgentHeaderHelp = "agent:header-help"
	zoneIDAgentHelpClose  = "agent:help-close"
)

func (m Model) agentHelp() (protocol.AgentHelp, bool) {
	payload, ok := m.chrome[generated.OPGuiAgentHelp]
	return payload.AgentHelp, ok
}

// This is a placement query, never an inferred editor/body rectangle or a focus decision.
// Modal ordering remains the existing compositor's responsibility.
func (m Model) activeAgentHelpRect() (generated.Rect, bool) {
	if help, ok := m.agentHelp(); !ok || !help.Visible {
		return generated.Rect{}, false
	}
	winner, ok := m.overlayWinner()
	if !ok || winner.surfaceID != surfaceIDAgentHelp {
		return generated.Rect{}, false
	}
	rect, ok := m.surfacePlacementFor(surfaceIDAgentHelp)
	return rect, ok && rect.Width > 0 && rect.Height > 0
}

func (m Model) agentHelpContent(help protocol.AgentHelp, width int) []string {
	style := lipgloss.NewStyle().Foreground(m.palette().ChromeText()).Background(m.palette().PopupSurface())
	var lines []string
	appendWrapped := func(text string, heading bool) {
		wrapped := strings.Split(lipgloss.NewStyle().Width(width).Render(text), "\n")
		rowStyle := style
		if heading {
			rowStyle = rowStyle.Bold(true).Foreground(m.palette().Accent())
		}
		for _, line := range wrapped {
			lines = append(lines, rowStyle.Render(fit(line, width)))
		}
	}
	for index, group := range help.Groups {
		if index > 0 {
			lines = append(lines, style.Render(strings.Repeat(" ", width)))
		}
		appendWrapped(group.Title, true)
		for _, binding := range group.Bindings {
			appendWrapped(binding.Key+"  "+binding.Description, false)
		}
	}
	return lines
}

func (m Model) renderAgentHelp(help protocol.AgentHelp) []string {
	rect, ok := m.surfacePlacementFor(surfaceIDAgentHelp)
	if !ok || rect.Width == 0 || rect.Height == 0 {
		return nil
	}
	width, height := int(rect.Width), int(rect.Height)
	style := lipgloss.NewStyle().Foreground(m.palette().ChromeText()).Background(m.palette().PopupSurface())
	closeLabel := "[Close Help]"
	if width < len(closeLabel) {
		closeLabel = "Close"
	}
	if width < len(closeLabel) {
		closeLabel = "x"
	}
	titleWidth := max(width-len(closeLabel), 0)
	title := style.Bold(true).Render(fit("Agent help", titleWidth))
	close := m.zones.Mark(zoneIDAgentHelpClose, style.Bold(true).Foreground(m.palette().Accent()).Render(closeLabel))
	lines := make([]string, 0, height)
	lines = append(lines, title+close)
	if height == 1 {
		return lines
	}
	content := m.agentHelpContent(help, width)
	rows := height - 1
	start := min(max(m.agentHelpScroll, 0), max(len(content)-rows, 0))
	lines = append(lines, content[start:min(start+rows, len(content))]...)
	blank := style.Render(strings.Repeat(" ", width))
	for len(lines) < height {
		lines = append(lines, blank)
	}
	return lines
}

func (m *Model) scrollAgentHelp(delta int) {
	rect, ok := m.activeAgentHelpRect()
	if !ok {
		return
	}
	m.agentHelpScroll = min(max(m.agentHelpScroll+delta, 0), m.maxAgentHelpScroll(rect))
}

func (m Model) maxAgentHelpScroll(rect generated.Rect) int {
	rows := int(rect.Height) - 1
	if rows <= 0 {
		return 0
	}
	help, _ := m.agentHelp()
	return max(len(m.agentHelpContent(help, int(rect.Width)))-rows, 0)
}

func (m *Model) agentHelpWheel(mouse tea.Mouse) bool {
	rect, ok := m.activeAgentHelpRect()
	if !ok || !pointInHelpRect(rect, mouse.X, mouse.Y) {
		return false
	}
	delta := bottomPanelWheelLines
	if mouse.Button == tea.MouseWheelUp {
		delta = -delta
	}
	m.scrollAgentHelp(delta)
	return true
}

func pointInHelpRect(rect generated.Rect, x, y int) bool {
	return x >= int(rect.Col) && x < int(rect.Col)+int(rect.Width) &&
		y >= int(rect.Row) && y < int(rect.Row)+int(rect.Height)
}

func (m Model) agentHelpMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	rect, ok := m.activeAgentHelpRect()
	mouse := msg.Mouse()
	if !ok || !pointInHelpRect(rect, mouse.X, mouse.Y) {
		return nil, false
	}
	if zone := m.zones.Get(zoneIDAgentHelpClose); zone != nil && zone.InBounds(msg) {
		return protocol.EncodeGUIExecuteCommand("agent_dismiss_help"), true
	}
	// Do not activate underlying timeline/composer/semantic zones in Help's authored containment.
	// Non-primary pointer routes still go to the BEAM.
	return nil, true
}

func (m *Model) presentAgentHelpKey(msg tea.KeyPressMsg, component string) bool {
	if component == "" || component == "picker" || component == "completion" || component == "command_completion" || component == "search" {
		return false
	}
	rect, ok := m.activeAgentHelpRect()
	if !ok {
		return false
	}
	key := msg.Key()
	if key.Mod == 0 {
		switch key.Code {
		case tea.KeyDown, 'j':
			m.scrollAgentHelp(1)
		case tea.KeyUp, 'k':
			m.scrollAgentHelp(-1)
		case tea.KeyPgDown:
			m.scrollAgentHelp(max(int(rect.Height)-1, 1))
		case tea.KeyPgUp:
			m.scrollAgentHelp(-max(int(rect.Height)-1, 1))
		case tea.KeyHome:
			m.scrollAgentHelp(-m.agentHelpScroll)
		case tea.KeyEnd:
			m.agentHelpScroll = m.maxAgentHelpScroll(rect)
		}
	}
	// Preserve the committed owner and forward the original key, but do not preview underlying transcript/tree navigation while this modal is active.
	return true
}
