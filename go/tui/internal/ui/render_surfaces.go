package ui

import (
	"fmt"
	"strings"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func (m Model) overlayLines() []string {
	if picker, ok := m.picker(); ok && picker.Visible {
		preview, _ := m.pickerPreview()
		return m.renderPicker(picker, preview)
	}
	if completion, ok := m.completion(); ok && completion.Visible && len(completion.Items) > 0 {
		return m.renderCompletion(completion)
	}
	if which, ok := m.whichKey(); ok && which.Visible && len(which.Bindings) > 0 {
		return m.renderWhichKey(which)
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
	if chat, ok := m.agentChat(); ok && chat.Visible {
		return m.renderAgentChat(chat)
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

func (m Model) renderAgentChat(chat protocol.AgentChat) []string {
	style := m.panelStyle()
	title := "Agent"
	if chat.ModelName != "" {
		title += "  " + chat.ModelName
	}
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(title, m.width))}
	if chat.ThinkingLevel != "" {
		lines = append(lines, style.Render(fit("thinking "+chat.ThinkingLevel, m.width)))
	}
	if chat.Pending != "" {
		lines = append(lines, style.Foreground(m.palette().Warning()).Render(fit("approval "+chat.Pending, m.width)))
	}
	start := max(len(chat.Messages)-max(m.maxOverlayHeight()+1, 1), 0)
	for _, msg := range chat.Messages[start:] {
		prefix := agentMessagePrefix(msg.Kind)
		lines = append(lines, style.Render(fit(prefix+" "+msg.Text, m.width)))
	}
	if chat.Prompt != "" {
		lines = append(lines, style.Foreground(m.palette().Muted()).Render(fit("> "+chat.Prompt, m.width)))
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderBoard(board protocol.Board) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(fmt.Sprintf("Board  %d cards", len(board.Cards)), m.width))}
	for _, card := range board.Cards[:min(len(board.Cards), max(m.maxOverlayHeight()-1, 0))] {
		marker := " "
		if card.ID == board.FocusedCardID || card.Flags&0x02 != 0 {
			marker = ">"
		}
		lines = append(lines, style.Render(fit(fmt.Sprintf("%s %s  %s", marker, statusName(card.Status), card.Task), m.width)))
	}
	return lines
}

func (m Model) renderBottomPanel(panel protocol.BottomPanel) []string {
	style := m.panelStyle()
	title := "Panel"
	if len(panel.Tabs) > int(panel.ActiveTab) {
		title = panel.Tabs[panel.ActiveTab].Name
	}
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(title, m.width))}
	for _, msg := range panel.Messages[:min(len(panel.Messages), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(strings.TrimSpace(msg.Path+"  "+msg.Text), m.width)))
	}
	return lines
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
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(fmt.Sprintf("Observatory  %d processes", max(int(obs.Count), len(obs.Nodes))), m.width))}
	for _, node := range obs.Nodes[:min(len(obs.Nodes), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(strings.Repeat("  ", int(node.Depth))+node.Name, m.width)))
	}
	return lines
}

func (m Model) renderEditTimeline(timeline protocol.EditTimeline) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit("Edit timeline", m.width))}
	for _, entry := range timeline.Entries[:min(len(timeline.Entries), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(fmt.Sprintf("%d  %s", entry.Index, entry.ToolName), m.width)))
	}
	return lines
}

func (m Model) renderNotifications(notes protocol.Notifications) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit("Notifications", m.width))}
	for _, note := range notes.Items[:min(len(notes.Items), max(m.maxOverlayHeight()-1, 0))] {
		text := note.Title
		if note.Body != "" {
			text += "  " + note.Body
		}
		lines = append(lines, style.Render(fit(text, m.width)))
	}
	return lines
}

func (m Model) renderExtensionOverlay(overlay protocol.ExtensionOverlay) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit("Extension overlays", m.width))}
	for _, entry := range overlay.Entries[:min(len(overlay.Entries), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(fmt.Sprintf("%s %d:%d %s", entry.Extension, entry.Row+1, entry.Col+1, entry.Content), m.width)))
	}
	return lines
}
