package ui

import (
	"fmt"
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	agentKindUser         byte = 0x01
	agentKindAssistant    byte = 0x02
	agentKindThinking     byte = 0x03
	agentKindTool         byte = 0x04
	agentKindSystem       byte = 0x05
	agentKindUsage        byte = 0x06
	agentKindStyled       byte = 0x07
	agentKindStyledTool   byte = 0x08
	agentKindApprovalTool byte = 0x09
)

func (m Model) renderAgentChatPanel(chat protocol.AgentChat) []string {
	width := max(m.width, 1)
	limit := m.maxOverlayHeight()
	lines := []string{m.renderAgentHeader(chat, width)}
	empty := chat.Pending == "" && strings.TrimSpace(chat.Prompt) == "" && len(chat.Messages) == 0

	if chat.Pending != "" && len(lines) < limit {
		lines = append(lines, m.renderAgentNotice("◆ approval", chat.Pending, width))
	}

	messageLines := m.renderAgentTranscriptTail(chat, max(limit-len(lines)-1, 0), width)
	lines = append(lines, messageLines...)

	if empty && len(lines) < limit-1 {
		lines = append(lines, takeLines(m.renderAgentEmptyState(width), max(limit-len(lines)-1, 0))...)
	}

	if len(lines) < limit {
		lines = append(lines, m.renderAgentPrompt(chat, width))
	}

	return takeLines(lines, limit)
}

func (m Model) renderAgentHeader(chat protocol.AgentChat, width int) string {
	p := m.palette()
	base := lipgloss.NewStyle().Foreground(p.Text()).Background(p.Base()).Width(width)
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.Base()).Render("◇ Agent")
	model := chat.ModelName
	if model == "" {
		model = "no model selected"
	}
	model = lipgloss.NewStyle().Foreground(p.Text()).Background(p.Base()).Render(model)
	status := m.renderAgentStatusBadge(chat.Status)
	parts := []string{title, model, status}
	if chat.ThinkingLevel != "" {
		parts = append(parts, lipgloss.NewStyle().Foreground(p.Muted()).Background(p.Base()).Render("thinking "+chat.ThinkingLevel))
	}
	content := strings.Join(parts, lipgloss.NewStyle().Foreground(p.Muted()).Background(p.Base()).Render("  •  "))
	return base.Render(fitStyled(content, width))
}

func (m Model) renderAgentStatusBadge(status byte) string {
	p := m.palette()
	label := agentChatStatusLabel(status)
	style := lipgloss.NewStyle().Bold(true).Foreground(p.SelectionText()).Background(p.Selection()).Padding(0, 1)
	switch status {
	case 1, 2:
		style = style.Background(p.Accent())
	case 3:
		style = style.Background(p.Diagnostic(0))
	}
	return style.Render(label)
}

func agentChatStatusLabel(status byte) string {
	switch status {
	case 1:
		return "thinking"
	case 2:
		return "tool"
	case 3:
		return "error"
	default:
		return "idle"
	}
}

func (m Model) renderAgentNotice(label string, text string, width int) string {
	p := m.palette()
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.SurfaceAlt())
	textStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(p.SurfaceAlt())
	line := labelStyle.Render(label) + textStyle.Render("  "+text)
	return lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(line, width))
}

func (m Model) renderAgentTranscriptTail(chat protocol.AgentChat, budget int, width int) []string {
	if budget <= 0 || len(chat.Messages) == 0 {
		return nil
	}
	rendered := make([][]string, 0, len(chat.Messages))
	for i := len(chat.Messages) - 1; i >= 0; i-- {
		block := m.renderAgentMessage(chat.Messages[i], width)
		if len(block) == 0 {
			continue
		}
		rendered = append(rendered, block)
		used := 0
		for _, part := range rendered {
			used += len(part)
		}
		if used >= budget {
			break
		}
	}
	lines := make([]string, 0, budget)
	for i := len(rendered) - 1; i >= 0; i-- {
		lines = append(lines, rendered[i]...)
	}
	if len(lines) > budget {
		lines = lines[len(lines)-budget:]
	}
	return lines
}

func (m Model) renderAgentMessage(msg protocol.AgentChatMessage, width int) []string {
	switch msg.Kind {
	case agentKindUser:
		return m.renderAgentTextMessage("┃ You", msg.Text, m.palette().Accent(), width, 2)
	case agentKindAssistant, agentKindStyled:
		return m.renderAgentTextMessage("▌ Assistant", msg.Text, m.palette().Text(), width, 3)
	case agentKindThinking:
		return m.renderAgentThinkingMessage(msg, width)
	case agentKindTool, agentKindStyledTool:
		return m.renderAgentToolMessage(msg, width)
	case agentKindApprovalTool:
		return m.renderAgentApprovalMessage(msg, width)
	case agentKindSystem:
		return m.renderAgentTextMessage("• System", msg.Text, m.palette().Muted(), width, 1)
	case agentKindUsage:
		return []string{m.renderAgentUsageMessage(msg, width)}
	default:
		return m.renderAgentTextMessage("• Message", msg.Text, m.palette().Muted(), width, 1)
	}
}

func (m Model) renderAgentTextMessage(label string, text string, fg color.Color, width int, maxLines int) []string {
	p := m.palette()
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(fg).Background(p.EditorSurface())
	bodyStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(p.EditorSurface())
	prefix := labelStyle.Render(label)
	bodyWidth := max(width-lipgloss.Width(label)-2, 8)
	parts := compactTextLines(text, bodyWidth, maxLines)
	if len(parts) == 0 {
		parts = []string{""}
	}
	lines := make([]string, 0, len(parts))
	for index, part := range parts {
		left := prefix
		if index > 0 {
			left = labelStyle.Render(strings.Repeat(" ", lipgloss.Width(label)))
		}
		line := left + bodyStyle.Render("  "+part)
		lines = append(lines, lipgloss.NewStyle().Background(p.EditorSurface()).Width(width).Render(fitStyled(line, width)))
	}
	return lines
}

func (m Model) renderAgentThinkingMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	label := "⋯ Thinking"
	if msg.Collapsed {
		label = "⋯ Thinking collapsed"
	}
	text := msg.Text
	if text == "" {
		text = "working through the request"
	}
	line := lipgloss.NewStyle().Italic(true).Foreground(p.Muted()).Background(p.SurfaceAlt()).Render(label) + lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt()).Render("  "+firstCompactLine(text, max(width-lipgloss.Width(label)-2, 8)))
	return []string{lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(line, width))}
}

func (m Model) renderAgentToolMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	statusIcon, statusColor := m.agentToolStatus(msg)
	name := msg.Name
	if name == "" {
		name = "tool"
	}
	summary := msg.Summary
	if summary == "" {
		summary = msg.Text
	}
	status := lipgloss.NewStyle().Bold(true).Foreground(statusColor).Background(p.EditorSurface()).Render(statusIcon)
	nameText := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(p.EditorSurface()).Render(" Tool " + name)
	meta := agentToolMeta(msg)
	metaText := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Render(meta)
	available := max(width-lipgloss.Width(status)-lipgloss.Width(nameText)-lipgloss.Width(metaText)-4, 8)
	summaryText := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Render(firstCompactLine(summary, available))
	line := status + nameText + lipgloss.NewStyle().Background(p.EditorSurface()).Render("  ") + summaryText
	if meta != "" {
		line += lipgloss.NewStyle().Background(p.EditorSurface()).Render("  ") + metaText
	}
	lines := []string{lipgloss.NewStyle().Background(p.EditorSurface()).Width(width).Render(fitStyled(line, width))}
	if msg.IsError && msg.Result != "" {
		lines = append(lines, m.renderAgentToolBody("ERROR", msg.Result, width))
	} else if !msg.Collapsed && msg.Result != "" && len(lines) < 3 {
		lines = append(lines, m.renderAgentToolBody("result", msg.Result, width))
	}
	return lines
}

func (m Model) agentToolStatus(msg protocol.AgentChatMessage) (string, color.Color) {
	p := m.palette()
	if msg.IsError || msg.Status == 2 {
		return "×", p.Diagnostic(0)
	}
	if msg.Status == 1 {
		return "✓", p.Diagnostic(3)
	}
	return "●", p.Warning()
}

func agentToolMeta(msg protocol.AgentChatMessage) string {
	parts := make([]string, 0, 2)
	if msg.DurationMS > 0 {
		parts = append(parts, fmt.Sprintf("%dms", msg.DurationMS))
	}
	switch msg.AutoApprovedScope {
	case 1:
		parts = append(parts, "auto session")
	case 2:
		parts = append(parts, "auto turn")
	}
	return strings.Join(parts, " · ")
}

func (m Model) renderAgentToolBody(label string, text string, width int) string {
	p := m.palette()
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.SurfaceAlt())
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt())
	body := firstCompactLine(text, max(width-lipgloss.Width(label)-4, 8))
	line := labelStyle.Render("  "+label) + bodyStyle.Render("  "+body)
	return lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(line, width))
}

func (m Model) renderAgentApprovalMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	header := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.SurfaceAlt()).Render("◆ Approval")
	name := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(p.SurfaceAlt()).Render(" " + msg.Name)
	summary := lipgloss.NewStyle().Foreground(p.Text()).Background(p.SurfaceAlt()).Render("  " + firstCompactLine(msg.Summary, max(width-lipgloss.Width(header)-lipgloss.Width(name)-3, 8)))
	lines := []string{lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(header+name+summary, width))}
	if len(msg.PreviewLines) > 0 {
		preview := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt()).Render("  " + firstCompactLine(msg.PreviewLines[0], max(width-2, 8)))
		lines = append(lines, lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(preview, width)))
	}
	return lines
}

func (m Model) renderAgentUsageMessage(msg protocol.AgentChatMessage, width int) string {
	p := m.palette()
	usage := msg.Usage
	text := fmt.Sprintf("◇ Usage  in %s  out %s", formatAgentTokens(usage.Input), formatAgentTokens(usage.Output))
	if usage.CostMicros > 0 {
		text += fmt.Sprintf("  $%.2f", float64(usage.CostMicros)/1_000_000)
	}
	return lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Width(width).Render(fit(text, width))
}

func (m Model) renderAgentPrompt(chat protocol.AgentChat, width int) string {
	p := m.palette()
	prompt := strings.TrimSpace(chat.Prompt)
	if prompt == "" {
		prompt = "Ask Minga to edit, explain, search, or run tools"
	}
	prefix := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.Base()).Render("::: ")
	text := lipgloss.NewStyle().Foreground(p.Text()).Background(p.Base()).Render(firstCompactLine(prompt, max(width-lipgloss.Width(prefix), 8)))
	return lipgloss.NewStyle().Background(p.Base()).Width(width).Render(fitStyled(prefix+text, width))
}

func (m Model) renderAgentEmptyState(width int) []string {
	p := m.palette()
	style := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Width(width)
	return []string{
		style.Render(fit("  Start an agent turn from this prompt, or use /help for slash commands.", width)),
		style.Render(fit("  Tool calls, approvals, thinking, and usage will appear here as structured cards.", width)),
	}
}

func compactTextLines(text string, width int, limit int) []string {
	text = strings.TrimSpace(text)
	if text == "" || limit <= 0 {
		return nil
	}
	rawLines := strings.Split(text, "\n")
	lines := make([]string, 0, min(len(rawLines), limit))
	for _, raw := range rawLines {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		lines = append(lines, firstCompactLine(raw, width))
		if len(lines) == limit {
			break
		}
	}
	return lines
}

func firstCompactLine(text string, width int) string {
	text = strings.Join(strings.Fields(strings.TrimSpace(text)), " ")
	return fit(text, width)
}

func formatAgentTokens(value uint32) string {
	if value >= 1_000_000 {
		return fmt.Sprintf("%.1fM", float64(value)/1_000_000)
	}
	if value >= 1_000 {
		return fmt.Sprintf("%.1fK", float64(value)/1_000)
	}
	return fmt.Sprintf("%d", value)
}
