package ui

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/table"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func (m Model) overlayLines() []string {
	if completion, ok := m.completion(); ok && completion.Visible && len(completion.Items) > 0 {
		return m.renderCompletion(completion)
	}
	if hover, ok := m.hoverPopup(); ok && hover.Visible && len(hover.Lines) > 0 {
		return m.renderHover(hover)
	}
	if sig, ok := m.signatureHelp(); ok && sig.Visible && len(sig.Signatures) > 0 {
		return m.renderSignature(sig)
	}
	if float, ok := m.floatPopup(); ok && float.Visible {
		return m.renderFloat(float)
	}
	if context, ok := m.agentContext(); ok && context.Visible {
		return m.renderAgentContext(context)
	}
	if chat, ok := m.agentChat(); ok && chat.Visible {
		return m.renderAgentChat(chat)
	}
	if tools, ok := m.toolManager(); ok && tools.Visible {
		return m.renderToolManager(tools)
	}
	if board, ok := m.board(); ok && board.Visible {
		return m.renderBoard(board)
	}
	if bottom, ok := m.bottomPanel(); ok && bottom.Visible {
		return m.renderBottomPanel(bottom)
	}
	if ext, ok := m.extensionPanel(); ok && len(ext.Panels) > 0 {
		return m.renderExtensionPanels(ext)
	}
	if obs, ok := m.observatory(); ok && obs.Visible {
		return m.renderObservatory(obs)
	}
	if timeline, ok := m.editTimeline(); ok && timeline.Visible {
		return m.renderEditTimeline(timeline)
	}
	if notes, ok := m.notifications(); ok && notes.Visible && len(notes.Items) > 0 {
		return m.renderNotifications(notes)
	}
	if overlay, ok := m.extensionOverlay(); ok && len(overlay.Entries) > 0 {
		return m.renderExtensionOverlay(overlay)
	}
	return nil
}

func (m Model) renderHover(hover protocol.HoverPopup) []string {
	style := m.panelStyle()
	title := fmt.Sprintf("Hover %d:%d", hover.AnchorRow+1, hover.AnchorCol+1)
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(title, m.width))}
	for _, line := range hover.Lines[:min(len(hover.Lines), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(renderRichLine(line), m.width)))
	}
	if action, ok := m.hoverAction(); ok && action.Visible {
		lines = append(lines, style.Foreground(m.palette().Accent()).Render(fit(action.Name, m.width)))
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderSignature(sig protocol.SignatureHelp) []string {
	style := m.panelStyle()
	active := sig.Signatures[min(int(sig.ActiveSignature), len(sig.Signatures)-1)]
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(active.Label, m.width))}
	if active.Doc != "" {
		lines = append(lines, style.Render(fit(active.Doc, m.width)))
	}
	for i, param := range active.Parameters {
		label := param.Label
		if byte(i) == sig.ActiveParameter {
			label = "> " + label
		}
		lines = append(lines, style.Render(fit(label+"  "+param.Doc, m.width)))
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderFloat(float protocol.FloatPopup) []string {
	style := m.panelStyle()
	title := float.Title
	if title == "" {
		title = "Popup"
	}
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(title, m.width))}
	for _, line := range float.Lines[:min(len(float.Lines), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(line, m.width)))
	}
	return lines
}

func (m Model) renderAgentContext(context protocol.AgentContext) []string {
	items := []componentItem{{title: statusName(context.Status), description: context.Task}}
	if context.CanApprove {
		items = append(items, componentItem{title: "approval", description: "approve or request changes"})
	}
	return takeLines(m.charmList("Agent context", items, 0, m.maxOverlayHeight(), true), m.maxOverlayHeight())
}

func (m Model) renderAgentChat(chat protocol.AgentChat) []string {
	return m.renderAgentChatPanel(chat)
}

func (m Model) renderToolManager(tools protocol.ToolManager) []string {
	items := make([]componentItem, 0, len(tools.Tools))
	selected := min(int(tools.Selected), max(len(tools.Tools)-1, 0))
	for _, tool := range tools.Tools {
		items = append(items, componentItem{title: tool.Label, description: strings.TrimSpace(tool.Name + " " + toolStatusName(tool.Status))})
	}
	if len(items) == 0 {
		items = append(items, componentItem{title: "No tools", description: "No matching tools"})
	}
	return takeLines(m.charmList("Tool manager", items, selected, m.maxOverlayHeight(), true), m.maxOverlayHeight())
}

func toolStatusName(status byte) string {
	switch status {
	case 1:
		return "installed"
	case 2:
		return "installing"
	case 3:
		return "update available"
	case 4:
		return "failed"
	default:
		return "not installed"
	}
}

func (m Model) renderBoard(board protocol.Board) []string {
	items := make([]componentItem, 0, len(board.Cards))
	selected := 0
	for i, card := range board.Cards {
		marker := " "
		if card.ID == board.FocusedCardID || card.Flags&0x02 != 0 {
			marker = ">"
			selected = i
		}
		items = append(items, componentItem{title: fmt.Sprintf("%s %s", marker, statusName(card.Status)), description: card.Task})
	}
	return takeLines(m.charmList(fmt.Sprintf("Board  %d cards", len(board.Cards)), items, selected, m.maxOverlayHeight(), true), m.maxOverlayHeight())
}

func (m Model) renderBottomPanel(panel protocol.BottomPanel) []string {
	title := "Panel"
	if len(panel.Tabs) > int(panel.ActiveTab) {
		title = panel.Tabs[panel.ActiveTab].Name
	}
	rows := make([]table.Row, 0, len(panel.Messages))
	for _, msg := range panel.Messages {
		rows = append(rows, table.Row{levelName(msg.Level), msg.Path, msg.Text})
	}
	columns := []table.Column{
		{Title: title, Width: 10},
		{Title: "Path", Width: max(m.width/4, 12)},
		{Title: "Message", Width: max(m.width-max(m.width/4, 12)-14, 20)},
	}
	return takeLines(m.charmTable(columns, rows, 0, m.maxOverlayHeight()), m.maxOverlayHeight())
}

func (m Model) renderExtensionPanels(ext protocol.ExtensionPanel) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit("Extensions", m.width))}
	for _, panel := range ext.Panels {
		if !panel.Visible {
			continue
		}
		lines = append(lines, style.Render(fit(panel.Title, m.width)))
		for _, block := range panel.Blocks[:min(len(panel.Blocks), 2)] {
			lines = append(lines, style.Foreground(m.palette().Muted()).Render(fit(block, m.width)))
		}
		if len(lines) >= m.maxOverlayHeight() {
			break
		}
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderObservatory(obs protocol.Observatory) []string {
	rows := make([]table.Row, 0, len(obs.Nodes))
	for _, node := range obs.Nodes {
		rows = append(rows, table.Row{node.PID, strings.Repeat("  ", int(node.Depth)) + node.Name, fmt.Sprintf("%d", node.MessageQueueLen)})
	}
	columns := []table.Column{
		{Title: fmt.Sprintf("Observatory %d", max(int(obs.Count), len(obs.Nodes))), Width: 12},
		{Title: "Process", Width: max(m.width-24, 20)},
		{Title: "Q", Width: 6},
	}
	return takeLines(m.charmTable(columns, rows, 0, m.maxOverlayHeight()), m.maxOverlayHeight())
}

func (m Model) renderEditTimeline(timeline protocol.EditTimeline) []string {
	rows := make([]table.Row, 0, len(timeline.Entries))
	selected := 0
	for i, entry := range timeline.Entries {
		if uint16(entry.Index) == timeline.ViewingIndex {
			selected = i
		}
		rows = append(rows, table.Row{fmt.Sprintf("%d", entry.Index), entry.ToolName, fmt.Sprintf("%d", entry.TimestampDelta)})
	}
	columns := []table.Column{
		{Title: "#", Width: 4},
		{Title: "Tool", Width: max(m.width-18, 18)},
		{Title: "Age", Width: 8},
	}
	return takeLines(m.charmTable(columns, rows, selected, m.maxOverlayHeight()), m.maxOverlayHeight())
}

func (m Model) renderNotifications(notes protocol.Notifications) []string {
	items := make([]componentItem, 0, len(notes.Items))
	for _, note := range notes.Items {
		items = append(items, componentItem{title: note.Title, description: strings.TrimSpace(note.Source + " " + note.Body)})
	}
	return takeLines(m.charmList("Notifications", items, 0, m.maxOverlayHeight(), true), m.maxOverlayHeight())
}

func (m Model) renderExtensionOverlay(overlay protocol.ExtensionOverlay) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit("Extension overlays", m.width))}
	for _, entry := range overlay.Entries[:min(len(overlay.Entries), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(fmt.Sprintf("%s %d:%d %s", entry.Extension, entry.Row+1, entry.Col+1, entry.Content), m.width)))
	}
	return lines
}
