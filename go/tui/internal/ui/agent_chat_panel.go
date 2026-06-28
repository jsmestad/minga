package ui

import (
	"fmt"
	"image/color"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

type agentPanel struct {
	animationFrame   uint64
	animationRunning bool
}

func (a *agentPanel) animating(chat protocol.AgentChat) bool {
	if !chat.Visible {
		return false
	}
	if chat.Status == 1 || chat.Status == 2 || chat.Pending != "" {
		return true
	}
	for _, msg := range chat.Messages {
		if msg.Kind == agentKindThinking || ((msg.Kind == agentKindTool || msg.Kind == agentKindStyledTool) && msg.Status == 0) {
			return true
		}
	}
	return false
}

func (a *agentPanel) tick() {
	a.animationFrame++
}

func (a *agentPanel) spinner() string {
	frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	return frames[int(a.animationFrame)%len(frames)]
}

func (a *agentPanel) handleKey(chat protocol.AgentChat, msg tea.KeyPressMsg) ([]byte, bool) {
	if !chat.Visible {
		return nil, false
	}
	key := msg.Key()
	if !key.Mod.Contains(tea.ModCtrl) || !key.Mod.Contains(tea.ModAlt) {
		return nil, false
	}
	switch key.Code {
	case 'x', 'X':
		index, ok := latestToolMessageIndex(chat.Messages)
		if !ok {
			return nil, false
		}
		return protocol.EncodeGUIAgentToolToggle(index), true
	case 'z', 'Z':
		index, ok := latestThinkingMessageIndex(chat.Messages)
		if !ok {
			return nil, false
		}
		return protocol.EncodeGUIAgentToolToggle(index), true
	default:
		return nil, false
	}
}

func (a *agentPanel) panelHeight(height int) int {
	return min(max(height/2, 8), 18)
}

const (
	agentKindUser              byte = 0x01
	agentKindAssistant         byte = 0x02
	agentKindThinking          byte = 0x03
	agentKindTool              byte = 0x04
	agentKindSystem            byte = 0x05
	agentKindUsage             byte = 0x06
	agentKindStyled            byte = 0x07
	agentKindStyledTool        byte = 0x08
	agentKindApprovalTool      byte = 0x09
	agentKindAssistantMarkdown byte = 0x0A
)

const (
	agentThinkingCollapsedLines = 1
	agentThinkingExpandedLines  = 5
	agentToolExpandedLines      = 10
	agentAssistantStyledLines   = 12
)

func (m Model) renderAgentChatPanel(chat protocol.AgentChat) []string {
	return m.renderAgentChatPanelWithLimit(chat, max(m.width, 1), m.agent.panelHeight(m.height))
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
	return m.agent.panelHeight(m.height)
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
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render("Minga is ready")
	subtitle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render("Ask in plain language, or start with a slash command.")
	section := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(m.editorBackground()).Render("Suggested next moves")
	return []string{
		m.renderAgentBlankLine(width),
		lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled("  "+title+"  "+subtitle, width)),
		m.renderAgentBlankLine(width),
		lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled("  "+section, width)),
		m.renderAgentSuggestionRow(width, "/explain", "Explain this file", "/tests", "Find failing tests"),
		m.renderAgentSuggestionRow(width, "/review", "Review changes", "/edit", "Edit current buffer"),
		m.renderAgentSuggestionRow(width, "/run", "Run a command", "/plan", "Draft a plan"),
	}
}

func (m Model) renderAgentSuggestionRow(width int, leftCommand string, leftLabel string, rightCommand string, rightLabel string) string {
	columnWidth := max((width-6)/2, 12)
	left := m.renderAgentSuggestionAction(leftCommand, leftLabel, columnWidth)
	right := m.renderAgentSuggestionAction(rightCommand, rightLabel, columnWidth)
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled("  "+left+"  "+right, width))
}

func (m Model) renderAgentSuggestionAction(command string, label string, width int) string {
	p := m.palette()
	cmd := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render(command)
	text := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground()).Render(" " + firstCompactLine(label, max(width-lipgloss.Width(command)-1, 4)))
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(cmd+text, width))
}

func (m Model) renderAgentHeader(chat protocol.AgentChat, width int) string {
	p := m.palette()
	base := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground()).Width(width)
	provider, modelName := splitAgentModelName(chat.ModelName)
	modelName = nonEmpty(modelName, "no model")

	icon := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render(agentHeaderIcon())
	label := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render(" Agent")
	model := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground()).Render(modelName)
	muted := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground())

	title := icon + label
	identity := model
	if provider != "" && width >= 52 {
		identity = muted.Render(provider) + muted.Render(" / ") + model
	}
	if width < 34 {
		title = icon
	}

	left := title + muted.Render("  ") + identity
	right := m.renderAgentStatusBadge(chat.Status)
	if chat.ThinkingLevel != "" && width >= 56 {
		right += muted.Render("  ◌ " + chat.ThinkingLevel)
	}

	leftBudget := max(width-lipgloss.Width(right)-1, 1)
	left = fitStyled(left, leftBudget)
	spacer := muted.Render(strings.Repeat(" ", max(width-lipgloss.Width(left)-lipgloss.Width(right), 1)))
	return base.Render(fitStyled(left+spacer+right, width))
}

func agentHeaderIcon() string {
	return "󰚩"
}

func (m Model) joinAgentColumns(left []string, right []string, leftWidth int, rightWidth int, height int) []string {
	p := m.palette()
	separator := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(m.editorBackground()).Render(" │ ")
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
	ruleStyle := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(m.editorBackground())
	text := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(m.editorBackground()).Render(" " + label + " ")
	// renderAgentDetailContentLine uses bodyWidth = width-2 and prepends a space,
	// so available content width is width-3.
	labelVisual := lipgloss.Width(text)
	totalRule := max(width-3-labelVisual, 0)
	leftRule := min(3, totalRule)
	rightRule := max(totalRule-leftRule, 0)
	content := ruleStyle.Render(strings.Repeat("─", leftRule)) + text + ruleStyle.Render(strings.Repeat("─", rightRule))
	return m.renderAgentDetailContentLine(content, width)
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
	style := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(p.SurfaceAlt()).Padding(0, 1)
	switch status {
	case 1, 2:
		label = m.agentSpinner() + " " + label
		style = style.Foreground(p.SelectionText()).Background(p.Accent())
	case 3:
		style = style.Foreground(p.SelectionText()).Background(p.Diagnostic(0))
	}
	return style.Render(label)
}

func (m Model) agentSpinner() string {
	return m.agent.spinner()
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
		return m.renderAgentUserMessage(msg, width)
	case agentKindAssistant, agentKindStyled, agentKindAssistantMarkdown:
		return m.renderAgentAssistantMessage(msg, width)
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
		return m.renderAgentAssistantMessage(protocol.AgentChatMessage{Text: msg.Text}, width)
	}
}

func (m Model) renderAgentSystemMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	label := "System"
	marker := "i"
	markerColor := p.Accent()
	textColor := p.Muted()
	if msg.Status == 1 || strings.Contains(strings.ToLower(msg.Text), "error") || strings.Contains(strings.ToLower(msg.Text), "couldn't authenticate") {
		label = "Needs attention"
		marker = "!"
		markerColor = p.Diagnostic(0)
		textColor = p.Text()
	}
	markerText := lipgloss.NewStyle().Bold(true).Foreground(markerColor).Background(m.editorBackground()).Render(marker)
	labelText := lipgloss.NewStyle().Bold(true).Foreground(markerColor).Background(m.editorBackground()).Render(" " + label)
	body := lipgloss.NewStyle().Foreground(textColor).Background(m.editorBackground()).Render("  " + firstCompactLine(msg.Text, max(width-lipgloss.Width(label)-8, 8)))
	line := "  " + markerText + labelText + body
	return []string{lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width))}
}

func (m Model) renderAgentUserMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	lines := compactTextLines(msg.Text, max(width-12, 8), 2)
	if len(lines) == 0 {
		lines = []string{""}
	}
	header := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render("  ❯ You")
	out := []string{lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(header, width))}
	bodyStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground())
	for _, bodyLine := range lines {
		line := bodyStyle.Render("    " + firstCompactLine(bodyLine, max(width-6, 8)))
		out = append(out, lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width)))
	}
	return out
}

func (m Model) renderAgentAssistantMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	header := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(m.editorBackground()).Render("  ◇ Minga")
	out := []string{lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(header, width))}

	if len(msg.MarkdownBlocks) > 0 {
		out = append(out, m.renderAgentAssistantMarkdownBlocks(msg.MarkdownBlocks, width)...)
		return out
	}

	if len(msg.StyledLines) > 0 {
		out = append(out, m.renderAgentAssistantStyledLines(msg.StyledLines, width)...)
		return out
	}

	lines := compactTextLines(msg.Text, max(width-12, 8), 3)
	if len(lines) == 0 {
		lines = []string{""}
	}
	rail := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render("  │ ")
	bodyStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground())
	for _, bodyLine := range lines {
		line := rail + bodyStyle.Render(firstCompactLine(bodyLine, max(width-5, 8)))
		out = append(out, lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width)))
	}
	return out
}

func (m Model) renderAgentAssistantMarkdownBlocks(blocks []protocol.AgentMarkdownBlock, width int) []string {
	if len(blocks) == 0 {
		return nil
	}
	out := make([]string, 0, len(blocks)*2)
	for _, block := range blocks {
		out = append(out, m.renderAgentMarkdownBlock(block, width)...)
	}
	return out
}

func (m Model) renderAgentMarkdownBlock(block protocol.AgentMarkdownBlock, width int) []string {
	switch block.Kind {
	case 0x01, 0x02, 0x03, 0x04:
		return m.renderAgentAssistantStyledLines(block.Lines, width)
	case 0x05:
		p := m.palette()
		surface := m.editorBackground()
		rule := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("  ─" + strings.Repeat("─", max(width-4, 1)))
		return []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rule, width))}
	case 0x06:
		return []string{lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render("")}
	case 0x07:
		return m.renderAgentCodeCard(block, width)
	default:
		return nil
	}
}

func (m Model) renderAgentCodeCard(block protocol.AgentMarkdownBlock, width int) []string {
	p := m.palette()
	surface := m.editorBackground()
	rail := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("  │ ")
	bodyWidth := max(width-lipgloss.Width(rail)-2, 8)
	label := nonEmpty(block.Label, "Code")
	if block.TargetPath != "" {
		label += " · " + block.TargetPath
	}
	if !block.Complete() {
		label += " · streaming"
	}
	header := rail + lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Bold(true).Render("╭─ "+label)
	out := []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header, width))}
	for _, line := range block.Lines {
		body := m.renderAgentCodeCardLine(line, bodyWidth)
		out = append(out, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rail+"│ "+body, width)))
	}
	footer := rail + lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("╰"+strings.Repeat("─", max(min(bodyWidth, width-6), 1)))
	out = append(out, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(footer, width)))
	return out
}

func (m Model) renderAgentCodeCardLine(line protocol.AgentStyledLine, width int) string {
	if len(line) == 0 {
		return strings.Repeat(" ", width)
	}
	rendered := m.renderAgentStyledLine(line, width)
	return fitStyled(rendered, width)
}

func (m Model) renderAgentAssistantStyledLines(lines []protocol.AgentStyledLine, width int) []string {
	if len(lines) == 0 {
		return nil
	}
	p := m.palette()
	surface := m.editorBackground()
	rail := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("  │ ")
	bodyWidth := max(width-lipgloss.Width(rail), 8)
	visible := min(len(lines), agentAssistantStyledLines)
	out := make([]string, 0, visible+1)
	for _, line := range lines[:visible] {
		rendered := rail + m.renderAgentStyledLine(line, bodyWidth)
		out = append(out, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rendered, width)))
	}
	if hidden := len(lines) - visible; hidden > 0 {
		more := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(fmt.Sprintf("… +%d lines · ⏎ expand", hidden))
		out = append(out, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rail+more, width)))
	}
	return out
}

func (m Model) renderAgentStyledLine(line protocol.AgentStyledLine, width int) string {
	if len(line) == 0 {
		return strings.Repeat(" ", width)
	}
	isCode := agentStyledLineIsAllCode(line)
	remaining := width
	truncated := false
	var rendered strings.Builder
	for index, run := range line {
		if remaining <= 0 {
			truncated = true
			break
		}
		text := run.Text
		if displayWidth(text) > remaining {
			truncated = true
			text = fit(text, remaining)
		}
		part := agentStyledRunStyle(run, m.editorBackground()).Render(text)
		rendered.WriteString(part)
		remaining -= lipgloss.Width(part)
		if remaining <= 0 && index < len(line)-1 {
			truncated = true
			break
		}
	}
	if isCode && truncated {
		marker := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.editorBackground()).Render("›")
		if width <= 1 {
			return marker
		}
		return fitStyled(rendered.String(), width-1) + marker
	}
	return fitStyled(rendered.String(), width)
}

func agentStyledRunStyle(run protocol.AgentStyledRun, background color.Color) lipgloss.Style {
	style := lipgloss.NewStyle().Background(background).ColorWhitespace(true)
	if run.FG != 0 {
		style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", run.FG&0xFFFFFF)))
	}
	if run.BG != 0 {
		style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", run.BG&0xFFFFFF)))
	}
	if run.Bold() {
		style = style.Bold(true)
	}
	if run.Italic() {
		style = style.Italic(true)
	}
	if run.Underline() || run.URL != "" {
		style = style.Underline(true)
	}
	return style
}

func agentStyledLineIsAllCode(line protocol.AgentStyledLine) bool {
	hasCodeRun := false
	for _, run := range line {
		if run.Text == "" {
			continue
		}
		hasCodeRun = true
		if !run.Code() {
			return false
		}
	}
	return hasCodeRun
}

func (m Model) renderAgentThinkingMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	state := "expanded"
	if msg.Collapsed {
		state = "collapsed"
	}
	text := msg.Text
	if text == "" {
		text = "working through the request"
	}
	marker := "⋯"
	if !msg.Collapsed {
		marker = m.agentSpinner()
	}
	markerStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Bold(true)
	labelStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Italic(true)
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground())
	header := "  " + markerStyle.Render(marker) + labelStyle.Render(" Thinking "+state)
	lines := []string{lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(header, width))}
	bodyLines := agentThinkingBodyLines(msg.Collapsed)
	for _, bodyLine := range compactTextLines(text, max(width-8, 8), bodyLines) {
		line := bodyStyle.Render("    " + firstCompactLine(bodyLine, max(width-6, 8)))
		lines = append(lines, lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width)))
	}
	return lines
}

func agentThinkingBodyLines(collapsed bool) int {
	if collapsed {
		return agentThinkingCollapsedLines
	}
	return agentThinkingExpandedLines
}

func (m Model) renderAgentToolMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	statusIcon, statusColor := m.agentToolStatus(msg)
	name := nonEmpty(msg.Name, "tool")
	presentation := agentToolPresentationFor(name)
	summary := nonEmpty(msg.Summary, msg.Text)
	surface := m.editorBackground()
	status := lipgloss.NewStyle().Bold(true).Foreground(statusColor).Background(surface).Render(statusIcon)
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(surface).Render(presentation.Icon + " " + presentation.Title)
	rawName := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(name)
	meta := agentToolMeta(msg)
	metaText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(meta)
	header := "  ├─ " + status + " " + title + lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" · ") + rawName
	if meta != "" {
		header += lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" · ") + metaText
	}
	label := lipgloss.NewStyle().Foreground(p.Accent()).Background(surface).Render(presentation.SummaryLabel + ":")
	summaryText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" " + firstCompactLine(summary, max(width-lipgloss.Width(presentation.SummaryLabel)-9, 8)))
	body := "  │  " + label + summaryText
	lines := []string{
		lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header, width)),
		lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(body, width)),
	}

	if len(msg.PreviewLines) > 0 {
		lines = append(lines, m.renderAgentToolPreviewLines(msg.PreviewKind, msg.PreviewLines, width)...)
	}

	if msg.IsError && msg.Result != "" {
		lines = append(lines, m.renderAgentToolTextLines("ERROR", msg.Result, width, agentToolExpandedLines)...)
	} else if hasAgentToolResult(msg) && msg.Collapsed {
		lines = append(lines, m.renderAgentToolCollapsedHint(width))
	} else if !msg.Collapsed {
		lines = append(lines, m.renderAgentToolResultLines(presentation.ResultLabel, msg, width)...)
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

func hasAgentToolResult(msg protocol.AgentChatMessage) bool {
	return strings.TrimSpace(msg.Result) != "" || len(msg.StyledLines) > 0
}

func (m Model) renderAgentToolCollapsedHint(width int) string {
	p := m.palette()
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Italic(true)
	line := "  │  " + bodyStyle.Render("result collapsed, Ctrl+Alt+X expands latest tool")
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width))
}

func (m Model) renderAgentToolPreviewLines(kind byte, lines []string, width int) []string {
	label := approvalPreviewKindName(kind)
	return m.renderAgentToolPlainLines(label, lines, width, min(len(lines), 8))
}

func (m Model) renderAgentToolResultLines(label string, msg protocol.AgentChatMessage, width int) []string {
	if len(msg.StyledLines) > 0 {
		return m.renderAgentToolStyledLines(label, msg.StyledLines, width, agentToolExpandedLines)
	}
	return m.renderAgentToolTextLines(label, msg.Result, width, agentToolExpandedLines)
}

func (m Model) renderAgentToolTextLines(label string, text string, width int, limit int) []string {
	return m.renderAgentToolPlainLines(label, agentToolTextLines(text), width, limit)
}

func agentToolTextLines(text string) []string {
	text = strings.TrimRight(text, "\n")
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}

func (m Model) renderAgentToolPlainLines(label string, rawLines []string, width int, limit int) []string {
	if len(rawLines) == 0 || limit <= 0 {
		return nil
	}
	p := m.palette()
	out := make([]string, 0, min(len(rawLines), limit)+1)
	for index, raw := range rawLines[:min(len(rawLines), limit)] {
		out = append(out, m.renderAgentToolLine(label, raw, index == 0, width, agentToolLineColor(raw, p)))
	}
	if len(rawLines) > limit {
		remaining := fmt.Sprintf("… +%d lines", len(rawLines)-limit)
		out = append(out, m.renderAgentToolLine(label, remaining, false, width, p.Muted()))
	}
	return out
}

func (m Model) renderAgentToolStyledLines(label string, styledLines []protocol.AgentStyledLine, width int, limit int) []string {
	if len(styledLines) == 0 || limit <= 0 {
		return nil
	}
	p := m.palette()
	out := make([]string, 0, min(len(styledLines), limit)+1)
	for index, runs := range styledLines[:min(len(styledLines), limit)] {
		out = append(out, m.renderAgentToolStyledLine(label, runs, index == 0, width))
	}
	if len(styledLines) > limit {
		remaining := fmt.Sprintf("… +%d lines", len(styledLines)-limit)
		out = append(out, m.renderAgentToolLine(label, remaining, false, width, p.Muted()))
	}
	return out
}

func (m Model) renderAgentToolStyledLine(label string, runs protocol.AgentStyledLine, showLabel bool, width int) string {
	p := m.palette()
	labelText := strings.Repeat(" ", len(label))
	if showLabel {
		labelText = label
	}
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(m.editorBackground())
	body := renderAgentStyledRuns(runs, p.Muted(), m.editorBackground())
	line := "  │  " + labelStyle.Render(labelText+":") + " " + body
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width))
}

func renderAgentStyledRuns(runs protocol.AgentStyledLine, fallback color.Color, background color.Color) string {
	parts := make([]string, 0, len(runs))
	for _, run := range runs {
		style := lipgloss.NewStyle().Foreground(fallback).Background(background)
		if run.FG != 0 {
			style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", run.FG)))
		}
		if run.Flags&0x01 != 0 {
			style = style.Bold(true)
		}
		if run.Flags&0x02 != 0 {
			style = style.Italic(true)
		}
		parts = append(parts, style.Render(run.Text))
	}
	return strings.Join(parts, "")
}

func (m Model) renderAgentToolLine(label string, text string, showLabel bool, width int, textColor color.Color) string {
	p := m.palette()
	labelText := strings.Repeat(" ", len(label))
	if showLabel {
		labelText = label
	}
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(m.editorBackground())
	bodyStyle := lipgloss.NewStyle().Foreground(textColor).Background(m.editorBackground())
	body := fit(strings.TrimRight(text, "\r"), max(width-lipgloss.Width(label)-9, 8))
	line := "  │  " + labelStyle.Render(labelText+":") + bodyStyle.Render(" "+body)
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(line, width))
}

func agentToolLineColor(line string, p palette) color.Color {
	if strings.HasPrefix(line, "+") {
		return p.Diagnostic(3)
	}
	if strings.HasPrefix(line, "-") {
		return p.Diagnostic(0)
	}
	return p.Muted()
}

func (m Model) renderAgentApprovalMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	surface := m.editorBackground()
	header := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(surface).Render("  ◆ Approval")
	name := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(surface).Render(" " + nonEmpty(msg.Name, "tool"))
	kind := lipgloss.NewStyle().Foreground(p.Accent()).Background(surface).Render(" · " + approvalPreviewKindName(msg.PreviewKind))
	summary := lipgloss.NewStyle().Foreground(p.Text()).Background(surface).Render("  " + firstCompactLine(msg.Summary, max(width-lipgloss.Width(header)-lipgloss.Width(name)-lipgloss.Width(kind)-3, 8)))
	lines := []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header+name+kind+summary, width))}
	for _, previewLine := range msg.PreviewLines[:min(len(msg.PreviewLines), 2)] {
		preview := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("  │  " + firstCompactLine(previewLine, max(width-5, 8)))
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
	text := fmt.Sprintf("  ◌ Usage · in %s · out %s", formatAgentTokens(usage.Input), formatAgentTokens(usage.Output))
	if usage.CostMicros > 0 {
		text += fmt.Sprintf(" · $%.2f", float64(usage.CostMicros)/1_000_000)
	}
	return lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Width(width).Render(fitStyled(text, width))
}

func (m Model) renderAgentComposer(chat protocol.AgentChat, width int) []string {
	p := m.palette()
	if width < 4 {
		return nil
	}
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
	borderColor := p.PopupBorder()
	if chat.Status == 1 || chat.Status == 2 {
		borderColor = markerColor
	}
	border := lipgloss.NewStyle().Foreground(borderColor).Background(m.editorBackground())
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(m.editorBackground()).Render(" Prompt ")
	top := border.Render("╭") + title + border.Render(strings.Repeat("─", max(width-2-lipgloss.Width(title), 0))+"╮")
	innerWidth := max(width-2, 1)
	marker := lipgloss.NewStyle().Bold(true).Foreground(markerColor).Background(m.editorBackground()).Render("❯")
	modeText := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(m.editorBackground()).Render(mode)
	promptStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(m.editorBackground())
	if placeholder {
		promptStyle = promptStyle.Foreground(p.Muted()).Italic(true)
	}
	prefix := " " + marker + " " + modeText + "  "
	promptText := promptStyle.Render(firstCompactLine(prompt, max(innerWidth-lipgloss.Width(prefix)-1, 8)))
	input := border.Render("│") + lipgloss.NewStyle().Background(m.editorBackground()).Width(innerWidth).Render(fitStyled(prefix+promptText, innerWidth)) + border.Render("│")
	hints := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render(" Enter send · Esc normal · / commands · " + cursor)
	help := border.Render("│") + lipgloss.NewStyle().Background(m.editorBackground()).Width(innerWidth).Render(fitStyled(" "+hints, innerWidth)) + border.Render("│")
	bottom := border.Render("╰" + strings.Repeat("─", max(width-2, 0)) + "╯")
	style := lipgloss.NewStyle().Background(m.editorBackground()).Width(width)
	return []string{
		style.Render(fitStyled(top, width)),
		style.Render(fitStyled(input, width)),
		style.Render(fitStyled(help, width)),
		style.Render(fitStyled(bottom, width)),
	}
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
