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
	return m.renderAgentChatPanelWithLimit(chat, max(m.width, 1), m.agentPanelHeight())
}

func (m Model) renderAgentChatBody(chat protocol.AgentChat) []string {
	width := max(m.width, 1)
	limit := m.bodyHeight()
	contentWidth := max(width-2, 1)
	lines := m.renderAgentChatPanelWithLimit(chat, contentWidth, limit)
	blank := lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(strings.Repeat(" ", width))
	for index, line := range lines {
		lines[index] = m.insetAgentLine(line, width)
	}
	for len(lines) < limit {
		lines = append(lines, blank)
	}
	return takeLines(lines, limit)
}

func (m Model) insetAgentLine(line string, width int) string {
	if width <= 1 {
		return line
	}
	inset := lipgloss.NewStyle().Background(m.editorBackground()).Render(" ")
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(inset+line, width))
}

func (m Model) renderAgentChatPanelWithLimit(chat protocol.AgentChat, width int, limit int) []string {
	limit = max(limit, 1)
	empty := chat.Pending == "" && strings.TrimSpace(chat.Prompt) == "" && len(chat.Messages) == 0
	lines := []string{m.renderAgentHeader(chat, width)}

	if agentDetailsVisible(width) && limit > 5 {
		bodyBudget := limit - 1
		detailWidth := agentDetailsWidth(width)
		leftWidth := max(width-detailWidth-agentColumnGap(), 40)
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
	return min(max(width/5, 24), 30)
}

func agentColumnGap() int {
	return 3
}

func (m Model) renderAgentMainColumn(chat protocol.AgentChat, width int, budget int, empty bool) []string {
	lines := make([]string, 0, budget)
	composer := m.renderAgentComposer(chat, width)
	composerHeight := min(len(composer), max(budget, 0))
	transcriptBudget := max(budget-composerHeight, 0)
	statusHeight := 0
	if transcriptBudget >= 4 {
		statusHeight = 1
	}
	contentBudget := max(transcriptBudget-statusHeight, 0)
	sparse := len(chat.Messages) <= 1 && chat.Pending == "" && strings.TrimSpace(chat.Prompt) == ""
	if chat.Pending != "" && len(lines) < contentBudget {
		lines = append(lines, m.renderAgentNotice("◆ approval", chat.Pending, width))
	}

	if len(lines) < contentBudget {
		lines = append(lines, m.renderAgentTranscriptHeader(width))
	}

	messageLines := m.renderAgentTranscriptTail(chat, max(contentBudget-len(lines), 0), width)
	lines = append(lines, messageLines...)

	if empty && len(lines) < contentBudget {
		lines = append(lines, takeLines(m.renderAgentEmptyState(width), max(contentBudget-len(lines), 0))...)
	} else if sparse && len(lines) < contentBudget {
		lines = append(lines, takeLines(m.renderAgentLandingState(width), max(contentBudget-len(lines), 0))...)
	}

	for len(lines) < contentBudget {
		lines = append(lines, m.renderAgentBlankLine(width))
	}
	if statusHeight > 0 {
		lines = append(lines, m.renderAgentTranscriptStatus(chat, width))
	}
	lines = append(lines, composer[:composerHeight]...)
	return takeLines(lines, budget)
}

func (m Model) renderAgentBlankLine(width int) string {
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(strings.Repeat(" ", max(width, 1)))
}

func (m Model) renderAgentTranscriptHeader(width int) string {
	p := m.palette()
	label := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(m.editorBackground()).Render(" Transcript ")
	rule := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render(strings.Repeat("─", max(width-lipgloss.Width(label), 0)))
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(label+rule, width))
}

func (m Model) renderAgentTranscriptStatus(chat protocol.AgentChat, width int) string {
	p := m.palette()
	messageCount := len(chat.Messages)
	label := "messages"
	if messageCount == 1 {
		label = "message"
	}
	status := fmt.Sprintf(" %d %s · %s", messageCount, label, agentChatStatusLabel(chat.Status))
	if chat.ThinkingLevel != "" {
		status += " · thinking " + chat.ThinkingLevel
	}
	return lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Width(width).Render(fit(status, width))
}

func (m Model) renderAgentLandingState(width int) []string {
	p := m.palette()
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground())
	pillRow := strings.Join([]string{
		m.renderAgentSuggestionPill("Explain this file"),
		m.renderAgentSuggestionPill("Find failing tests"),
		m.renderAgentSuggestionPill("Review changes"),
	}, "  ")
	pillRowTwo := strings.Join([]string{
		m.renderAgentSuggestionPill("Edit current buffer"),
		m.renderAgentSuggestionPill("Run a command"),
		m.renderAgentSuggestionPill("Draft a plan"),
	}, "  ")
	return []string{
		lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(titleStyle.Render("Try asking Minga"), width)),
		lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(pillRow, width)),
		lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(pillRowTwo, width)),
	}
}

func (m Model) renderAgentSuggestionPill(label string) string {
	p := m.palette()
	marker := lipgloss.NewStyle().Foreground(p.Accent()).Background(m.editorBackground()).Bold(true).Render("›")
	text := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground()).Render(label)
	return marker + " " + text
}

func (m Model) renderAgentHeader(chat protocol.AgentChat, width int) string {
	p := m.palette()
	base := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground()).Width(width)
	provider, modelName := splitAgentModelName(chat.ModelName)
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render("◇ Agent")
	model := m.agentHeaderBadge(nonEmpty(modelName, "no model"), p.SurfaceAlt(), p.Text())
	status := m.renderAgentStatusBadge(chat.Status)
	parts := []string{title}
	if provider != "" {
		parts = append(parts, lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render(provider))
	}
	parts = append(parts, model, status)
	if chat.ThinkingLevel != "" {
		parts = append(parts, m.agentHeaderBadge("thinking "+chat.ThinkingLevel, m.editorBackground(), p.Muted()))
	}
	content := strings.Join(parts, lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render("  "))
	return base.Render(fitStyled(content, width))
}

func (m Model) agentHeaderBadge(text string, bg color.Color, fg color.Color) string {
	return lipgloss.NewStyle().Foreground(fg).Background(bg).Padding(0, 1).Render(text)
}

func (m Model) joinAgentColumns(left []string, right []string, leftWidth int, rightWidth int, height int) []string {
	p := m.palette()
	separator := lipgloss.NewStyle().Background(m.editorBackground()).Render(strings.Repeat(" ", agentColumnGap()))
	blankLeft := lipgloss.NewStyle().Background(p.EditorSurface()).Width(leftWidth).Render(strings.Repeat(" ", leftWidth))
	blankRight := lipgloss.NewStyle().Background(m.editorBackground()).Width(rightWidth).Render(strings.Repeat(" ", rightWidth))
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
	provider, model := splitAgentModelName(chat.ModelName)
	lines := []string{m.renderAgentDetailFrame("top", "◇ Session", width)}
	lines = append(lines, m.renderAgentDetailRow("Provider", nonEmpty(provider, "unknown"), width))
	lines = append(lines, m.renderAgentDetailRow("Model", nonEmpty(model, "not selected"), width))
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
	if lastAgentError(chat.Messages) != "" {
		lines = append(lines, m.renderAgentDetailsSection("Needs attention", width))
		lines = append(lines, m.renderAgentDetailRow("Auth", "run /auth or check API key", width))
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
	lines = append(lines, m.renderAgentDetailFrame("bottom", "", width))
	return takeLines(lines, budget)
}

func (m Model) renderAgentDetailFrame(kind string, title string, width int) string {
	p := m.palette()
	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(m.editorBackground())
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground())
	inner := max(width-2, 0)
	if kind == "bottom" {
		return border.Render("╰" + strings.Repeat("─", inner) + "╯")
	}
	titleText := " " + title + " "
	line := "╭" + titleStyle.Render(titleText) + border.Render(strings.Repeat("─", max(inner-lipgloss.Width(titleText), 0))+"╮")
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width))
}

func (m Model) renderAgentDetailsSection(label string, width int) string {
	p := m.palette()
	line := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(m.editorBackground()).Render("─")
	text := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(m.editorBackground()).Render(" " + label + " ")
	remaining := max(width-lipgloss.Width(label)-4, 0)
	return m.renderAgentDetailContentLine(text+strings.Repeat(line, remaining), width)
}

func (m Model) renderAgentDetailRow(label string, value string, width int) string {
	p := m.palette()
	labelWidth := min(max(width/3, 8), 10)
	labelStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Width(labelWidth)
	valueStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground())
	prefix := labelStyle.Render(label)
	body := valueStyle.Render(firstCompactLine(value, max(width-labelWidth-4, 8)))
	return m.renderAgentDetailContentLine(prefix+" "+body, width)
}

func (m Model) renderAgentDetailHint(key string, action string, width int) string {
	p := m.palette()
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground())
	actionStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground())
	line := keyStyle.Render(key) + actionStyle.Render("  "+action)
	return m.renderAgentDetailContentLine(line, width)
}

func (m Model) renderAgentDetailContentLine(content string, width int) string {
	p := m.palette()
	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(m.editorBackground())
	bodyWidth := max(width-2, 1)
	body := lipgloss.NewStyle().Background(m.editorBackground()).Width(bodyWidth).Render(fitStyled(" "+content, bodyWidth))
	return border.Render("│") + body + border.Render("│")
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

func lastAgentError(messages []protocol.AgentChatMessage) string {
	for index := len(messages) - 1; index >= 0; index-- {
		msg := messages[index]
		if msg.Kind == agentKindSystem && msg.Status == 1 && msg.Text != "" {
			return msg.Text
		}
		if msg.IsError && msg.Text != "" {
			return msg.Text
		}
	}
	return ""
}

func splitAgentModelName(value string) (string, string) {
	parts := strings.SplitN(strings.TrimSpace(value), ":", 2)
	if len(parts) == 2 {
		return parts[0], parts[1]
	}
	return "", strings.TrimSpace(value)
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
		label = m.agentSpinner() + " " + label
		style = style.Background(p.Accent())
	case 3:
		style = style.Background(p.Diagnostic(0))
	}
	return style.Render(label)
}

func (m Model) agentSpinner() string {
	frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	return frames[int(m.agentAnimationFrame)%len(frames)]
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
	blocks := make([][]string, 0, len(chat.Messages))
	used := 0
	for i := len(chat.Messages) - 1; i >= 0; i-- {
		block := m.renderAgentMessage(chat.Messages[i], width)
		if len(block) == 0 {
			continue
		}
		if used > 0 && used+len(block) > budget {
			break
		}
		blocks = append(blocks, block)
		used += len(block)
		if used >= budget {
			break
		}
	}
	lines := make([]string, 0, budget)
	for i := len(blocks) - 1; i >= 0; i-- {
		lines = append(lines, blocks[i]...)
		if i > 0 && len(lines) < budget {
			lines = append(lines, m.renderAgentBlankLine(width))
		}
	}
	if len(lines) > budget {
		return lines[:budget]
	}
	return lines
}

func (m Model) renderAgentMessage(msg protocol.AgentChatMessage, width int) []string {
	switch msg.Kind {
	case agentKindUser:
		return m.renderAgentTextMessage("You", msg.Text, m.palette().Accent(), width, 2)
	case agentKindAssistant, agentKindStyled:
		return m.renderAgentTextMessage("Assistant", msg.Text, m.palette().Text(), width, 3)
	case agentKindThinking:
		return m.renderAgentThinkingMessage(msg, width)
	case agentKindTool, agentKindStyledTool:
		return m.renderAgentToolMessage(msg, width)
	case agentKindApprovalTool:
		return m.renderAgentApprovalMessage(msg, width)
	case agentKindSystem:
		return m.renderAgentSystemMessage(msg, width)
	case agentKindUsage:
		return []string{m.renderAgentUsageMessage(msg, width)}
	default:
		return m.renderAgentTextMessage("• Message", msg.Text, m.palette().Muted(), width, 1)
	}
}

func (m Model) renderAgentSystemMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	label := "System"
	rail := "i"
	railColor := p.Accent()
	if msg.Status == 1 || strings.Contains(strings.ToLower(msg.Text), "error") || strings.Contains(strings.ToLower(msg.Text), "couldn't authenticate") {
		label = "Needs attention"
		rail = "!"
		railColor = p.Diagnostic(0)
	}
	return m.renderAgentCard(agentCardSpec{Label: label, Rail: rail, RailColor: railColor, Lines: compactTextLines(msg.Text, max(width-16, 8), 2), Width: width})
}

func (m Model) renderAgentTextMessage(label string, text string, fg color.Color, width int, maxLines int) []string {
	parts := compactTextLines(text, max(width-16, 8), maxLines)
	if len(parts) == 0 {
		parts = []string{""}
	}
	return m.renderAgentCard(agentCardSpec{Label: label, Rail: "▌", RailColor: fg, Lines: parts, Width: width})
}

func (m Model) renderAgentCard(spec agentCardSpec) []string {
	p := m.palette()
	width := max(spec.Width, 1)
	surface := m.editorBackground()
	railColor := spec.RailColor
	if railColor == nil {
		railColor = p.Accent()
	}
	railStyle := lipgloss.NewStyle().Bold(true).Foreground(railColor).Background(surface)
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(railColor).Background(surface)
	bodyStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(surface)
	lines := make([]string, 0, len(spec.Lines)+1)
	header := railStyle.Render(spec.Rail) + labelStyle.Render(" "+spec.Label)
	if spec.Meta != "" {
		header += lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("  " + spec.Meta)
	}
	lines = append(lines, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header, width)))
	for _, bodyLine := range spec.Lines {
		line := railStyle.Render(spec.Rail) + bodyStyle.Render("  "+firstCompactLine(bodyLine, max(width-4, 8)))
		lines = append(lines, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(line, width)))
	}
	return lines
}

type agentCardSpec struct {
	Label     string
	Meta      string
	Rail      string
	RailColor color.Color
	Lines     []string
	Width     int
}

func (m Model) renderAgentThinkingMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	label := "Thinking"
	meta := "expanded"
	if msg.Collapsed {
		meta = "collapsed"
	}
	text := msg.Text
	if text == "" {
		text = "working through the request"
	}
	rail := "⋯"
	if !msg.Collapsed {
		rail = m.agentSpinner()
	}
	return m.renderAgentCard(agentCardSpec{Label: label, Meta: meta, Rail: rail, RailColor: p.Muted(), Lines: compactTextLines(text, max(width-16, 8), 2), Width: width})
}

func (m Model) renderAgentToolMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	statusIcon, statusColor := m.agentToolStatus(msg)
	name := nonEmpty(msg.Name, "tool")
	presentation := agentToolPresentationFor(name)
	summary := nonEmpty(msg.Summary, msg.Text)
	surface := m.editorBackground()
	status := lipgloss.NewStyle().Bold(true).Foreground(statusColor).Background(surface).Render(statusIcon)
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(surface).Render(" " + presentation.Icon + " " + presentation.Title)
	rawName := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" " + name)
	meta := agentToolMeta(msg)
	metaText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(meta)
	label := lipgloss.NewStyle().Foreground(p.Accent()).Background(surface).Render(presentation.SummaryLabel + ": ")
	available := max(width-lipgloss.Width(status)-lipgloss.Width(title)-lipgloss.Width(rawName)-lipgloss.Width(metaText)-lipgloss.Width(label)-6, 8)
	summaryText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(firstCompactLine(summary, available))
	line := status + title + rawName + lipgloss.NewStyle().Background(surface).Render("  ") + label + summaryText
	if meta != "" {
		line += lipgloss.NewStyle().Background(surface).Render("  ") + metaText
	}
	lines := []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(line, width))}
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
	return m.agentSpinner(), p.Warning()
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
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(m.editorBackground())
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground())
	body := firstCompactLine(text, max(width-lipgloss.Width(label)-4, 8))
	line := labelStyle.Render("  "+label) + bodyStyle.Render("  "+body)
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width))
}

func (m Model) renderAgentApprovalMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	surface := m.editorBackground()
	header := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(surface).Render("◆ Approval")
	name := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(surface).Render(" " + nonEmpty(msg.Name, "tool"))
	kind := lipgloss.NewStyle().Foreground(p.Accent()).Background(surface).Render(" " + approvalPreviewKindName(msg.PreviewKind))
	summary := lipgloss.NewStyle().Foreground(p.Text()).Background(surface).Render("  " + firstCompactLine(msg.Summary, max(width-lipgloss.Width(header)-lipgloss.Width(name)-lipgloss.Width(kind)-3, 8)))
	lines := []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header+name+kind+summary, width))}
	for _, previewLine := range msg.PreviewLines[:min(len(msg.PreviewLines), 2)] {
		preview := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("  " + firstCompactLine(previewLine, max(width-2, 8)))
		lines = append(lines, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(preview, width)))
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

func (m Model) renderAgentComposer(chat protocol.AgentChat, width int) []string {
	p := m.palette()
	prompt := strings.TrimRight(chat.Prompt, "\n")
	placeholder := prompt == ""
	if placeholder {
		prompt = "Ask Minga to edit, explain, search, or run tools"
	}
	mode := agentPromptModeName(chat.PromptVimMode)
	cursor := fmt.Sprintf("%d:%d", int(chat.PromptCursorLine)+1, int(chat.PromptCursorCol)+1)
	markerColor := p.Accent()
	if chat.Status == 1 || chat.Status == 2 {
		markerColor = p.Warning()
	}
	marker := lipgloss.NewStyle().Bold(true).Foreground(markerColor).Background(m.editorBackground()).Render("❯")
	modeText := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render(mode)
	promptStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground())
	if placeholder {
		promptStyle = promptStyle.Foreground(p.Muted()).Italic(true)
	}
	prefix := "  " + marker + " " + modeText + "  "
	promptText := promptStyle.Render(firstCompactLine(prompt, max(width-lipgloss.Width(prefix)-4, 8)))
	line := lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(prefix+promptText, width))
	hints := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render("    Enter send  ·  Esc normal  ·  / commands  ·  " + cursor)
	help := lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(hints, width))
	return []string{line, help}
}

func agentPromptModeName(mode byte) string {
	switch mode {
	case 1:
		return "INSERT"
	case 2:
		return "VISUAL"
	case 3:
		return "COMMAND"
	case 4:
		return "OP"
	case 5:
		return "SEARCH"
	case 6:
		return "REPLACE"
	default:
		return "NORMAL"
	}
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
