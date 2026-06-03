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
	limit := m.agentPanelHeight()
	empty := chat.Pending == "" && strings.TrimSpace(chat.Prompt) == "" && len(chat.Messages) == 0
	lines := []string{m.renderAgentHeader(chat, width)}

	if agentDetailsVisible(width) && limit > 5 {
		bodyBudget := limit - 1
		detailWidth := agentDetailsWidth(width)
		leftWidth := max(width-detailWidth-1, 40)
		left := m.renderAgentMainColumn(chat, leftWidth, bodyBudget, empty)
		right := m.renderAgentDetailsRail(chat, detailWidth, bodyBudget)
		lines = append(lines, m.joinAgentColumns(left, right, leftWidth, detailWidth, bodyBudget)...)
		return takeLines(lines, limit)
	}

	lines = append(lines, m.renderAgentMainColumn(chat, width, limit-1, empty)...)
	return takeLines(lines, limit)
}

func (m Model) agentPanelHeight() int {
	return min(max(m.height/2, 8), 18)
}

func agentDetailsVisible(width int) bool {
	return width >= 104
}

func agentDetailsWidth(width int) int {
	return min(max(width/4, 28), 36)
}

func (m Model) renderAgentMainColumn(chat protocol.AgentChat, width int, budget int, empty bool) []string {
	lines := make([]string, 0, budget)
	if chat.Pending != "" && len(lines) < budget {
		lines = append(lines, m.renderAgentNotice("◆ approval", chat.Pending, width))
	}

	messageLines := m.renderAgentTranscriptTail(chat, max(budget-len(lines)-1, 0), width)
	lines = append(lines, messageLines...)

	if empty && len(lines) < budget-1 {
		lines = append(lines, takeLines(m.renderAgentEmptyState(width), max(budget-len(lines)-1, 0))...)
	}

	if len(lines) < budget {
		lines = append(lines, m.renderAgentPrompt(chat, width))
	}
	return takeLines(lines, budget)
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

func (m Model) joinAgentColumns(left []string, right []string, leftWidth int, rightWidth int, height int) []string {
	p := m.palette()
	separator := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Render("│")
	blankLeft := lipgloss.NewStyle().Background(p.EditorSurface()).Width(leftWidth).Render(strings.Repeat(" ", leftWidth))
	blankRight := lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(rightWidth).Render(strings.Repeat(" ", rightWidth))
	out := make([]string, 0, height)
	for row := 0; row < height; row++ {
		leftLine := lineAt(left, row)
		if leftLine == "" {
			leftLine = blankLeft
		}
		rightLine := lineAt(right, row)
		if rightLine == "" {
			rightLine = blankRight
		}
		out = append(out, leftLine+separator+rightLine)
	}
	return out
}

func (m Model) renderAgentDetailsRail(chat protocol.AgentChat, width int, budget int) []string {
	p := m.palette()
	head := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.SurfaceAlt()).Width(width).Render(fit(" Details", width))
	lines := []string{head}
	lines = append(lines, m.renderAgentDetailRow("Model", nonEmpty(chat.ModelName, "not selected"), width))
	lines = append(lines, m.renderAgentDetailRow("State", agentChatStatusLabel(chat.Status), width))
	if chat.ThinkingLevel != "" {
		lines = append(lines, m.renderAgentDetailRow("Thinking", chat.ThinkingLevel, width))
	}
	lines = append(lines, m.renderAgentDetailRow("Messages", fmt.Sprintf("%d", len(chat.Messages)), width))

	toolCount, runningTools, erroredTools := agentToolCounts(chat.Messages)
	if toolCount > 0 {
		value := fmt.Sprintf("%d", toolCount)
		if runningTools > 0 || erroredTools > 0 {
			value = fmt.Sprintf("%d · %d running · %d errors", toolCount, runningTools, erroredTools)
		}
		lines = append(lines, m.renderAgentDetailRow("Tools", value, width))
	}
	if chat.Pending != "" {
		lines = append(lines, m.renderAgentDetailRow("Approval", "waiting", width))
	}
	if usage, ok := lastAgentUsage(chat.Messages); ok {
		lines = append(lines, m.renderAgentDetailRow("Context", fmt.Sprintf("%s in · %s out", formatAgentTokens(usage.Input), formatAgentTokens(usage.Output)), width))
		if usage.CostMicros > 0 {
			lines = append(lines, m.renderAgentDetailRow("Cost", fmt.Sprintf("$%.2f", float64(usage.CostMicros)/1_000_000), width))
		}
	}
	lines = append(lines, m.renderAgentDetailsSection("Hints", width))
	lines = append(lines, m.renderAgentDetailHint("Enter", "send prompt", width))
	lines = append(lines, m.renderAgentDetailHint("Tab", "complete", width))
	lines = append(lines, m.renderAgentDetailHint("?", "agent help", width))
	return takeLines(lines, budget)
}

func (m Model) renderAgentDetailsSection(label string, width int) string {
	p := m.palette()
	line := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt()).Render("─")
	text := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(p.SurfaceAlt()).Render(" " + label + " ")
	remaining := max(width-lipgloss.Width(label)-2, 0)
	return lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(text+strings.Repeat(line, remaining), width))
}

func (m Model) renderAgentDetailRow(label string, value string, width int) string {
	p := m.palette()
	labelStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt())
	valueStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(p.SurfaceAlt())
	prefix := labelStyle.Render(" " + label + " ")
	body := valueStyle.Render(firstCompactLine(value, max(width-lipgloss.Width(label)-3, 8)))
	return lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(prefix+body, width))
}

func (m Model) renderAgentDetailHint(key string, action string, width int) string {
	p := m.palette()
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(p.SelectionText()).Background(p.Selection()).Padding(0, 1)
	actionStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt())
	line := " " + keyStyle.Render(key) + actionStyle.Render(" "+action)
	return lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(line, width))
}

func agentToolCounts(messages []protocol.AgentChatMessage) (int, int, int) {
	toolCount := 0
	runningTools := 0
	erroredTools := 0
	for _, msg := range messages {
		if msg.Kind != agentKindTool && msg.Kind != agentKindStyledTool && msg.Kind != agentKindApprovalTool {
			continue
		}
		toolCount++
		if msg.Status == 0 {
			runningTools++
		}
		if msg.Status == 2 || msg.IsError {
			erroredTools++
		}
	}
	return toolCount, runningTools, erroredTools
}

func lastAgentUsage(messages []protocol.AgentChatMessage) (protocol.AgentUsage, bool) {
	for index := len(messages) - 1; index >= 0; index-- {
		if messages[index].Kind == agentKindUsage {
			return messages[index].Usage, true
		}
	}
	return protocol.AgentUsage{}, false
}

func nonEmpty(value string, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
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
	name := nonEmpty(msg.Name, "tool")
	presentation := agentToolPresentationFor(name)
	summary := nonEmpty(msg.Summary, msg.Text)
	status := lipgloss.NewStyle().Bold(true).Foreground(statusColor).Background(p.EditorSurface()).Render(statusIcon)
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(p.EditorSurface()).Render(" " + presentation.Icon + " " + presentation.Title)
	rawName := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Render(" " + name)
	meta := agentToolMeta(msg)
	metaText := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Render(meta)
	label := lipgloss.NewStyle().Foreground(p.Accent()).Background(p.EditorSurface()).Render(presentation.SummaryLabel + ": ")
	available := max(width-lipgloss.Width(status)-lipgloss.Width(title)-lipgloss.Width(rawName)-lipgloss.Width(metaText)-lipgloss.Width(label)-6, 8)
	summaryText := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.EditorSurface()).Render(firstCompactLine(summary, available))
	line := status + title + rawName + lipgloss.NewStyle().Background(p.EditorSurface()).Render("  ") + label + summaryText
	if meta != "" {
		line += lipgloss.NewStyle().Background(p.EditorSurface()).Render("  ") + metaText
	}
	lines := []string{lipgloss.NewStyle().Background(p.EditorSurface()).Width(width).Render(fitStyled(line, width))}
	if msg.IsError && msg.Result != "" {
		lines = append(lines, m.renderAgentToolBody("ERROR", msg.Result, width))
	} else if !msg.Collapsed && msg.Result != "" && len(lines) < 3 {
		lines = append(lines, m.renderAgentToolBody(presentation.ResultLabel, msg.Result, width))
	}
	return lines
}

type agentToolPresentation struct {
	Icon         string
	Title        string
	SummaryLabel string
	ResultLabel  string
}

func agentToolPresentationFor(name string) agentToolPresentation {
	switch strings.TrimSpace(name) {
	case "shell", "bash":
		return agentToolPresentation{Icon: "", Title: "Shell", SummaryLabel: "cmd", ResultLabel: "output"}
	case "read_file":
		return agentToolPresentation{Icon: "󰈙", Title: "Read", SummaryLabel: "path", ResultLabel: "content"}
	case "write_file":
		return agentToolPresentation{Icon: "󰈔", Title: "Write", SummaryLabel: "path", ResultLabel: "content"}
	case "edit_file", "multi_edit_file":
		return agentToolPresentation{Icon: "󰏫", Title: "Edit", SummaryLabel: "path", ResultLabel: "diff"}
	case "apply_diff":
		return agentToolPresentation{Icon: "", Title: "Diff", SummaryLabel: "patch", ResultLabel: "diff"}
	case "todo":
		return agentToolPresentation{Icon: "✓", Title: "Todo", SummaryLabel: "task", ResultLabel: "state"}
	case "subagent":
		return agentToolPresentation{Icon: "◇", Title: "Subagent", SummaryLabel: "task", ResultLabel: "report"}
	case "lsp_diagnostics", "lsp_definition", "lsp_references", "lsp_hover", "lsp_rename", "lsp_code_actions", "lsp_workspace_symbols", "lsp_document_symbols":
		return agentToolPresentation{Icon: "λ", Title: "LSP", SummaryLabel: "query", ResultLabel: "result"}
	case "git", "git_stage", "git_commit":
		return agentToolPresentation{Icon: "", Title: "Git", SummaryLabel: "op", ResultLabel: "result"}
	default:
		return agentToolPresentation{Icon: "●", Title: "Tool", SummaryLabel: "args", ResultLabel: "result"}
	}
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
	name := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(p.SurfaceAlt()).Render(" " + nonEmpty(msg.Name, "tool"))
	kind := lipgloss.NewStyle().Foreground(p.Accent()).Background(p.SurfaceAlt()).Render(" " + approvalPreviewKindName(msg.PreviewKind))
	summary := lipgloss.NewStyle().Foreground(p.Text()).Background(p.SurfaceAlt()).Render("  " + firstCompactLine(msg.Summary, max(width-lipgloss.Width(header)-lipgloss.Width(name)-lipgloss.Width(kind)-3, 8)))
	lines := []string{lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(header+name+kind+summary, width))}
	for _, previewLine := range msg.PreviewLines[:min(len(msg.PreviewLines), 2)] {
		preview := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt()).Render("  " + firstCompactLine(previewLine, max(width-2, 8)))
		lines = append(lines, lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(preview, width)))
	}
	return lines
}

func approvalPreviewKindName(kind byte) string {
	switch kind {
	case 1:
		return "diff"
	case 2:
		return "command"
	case 3:
		return "target"
	default:
		return "args"
	}
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
