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

func (a *agentPanel) animating(chat protocol.AgentChat, messages []protocol.AgentChatMessage) bool {
	if !chat.Visible {
		return false
	}
	if chat.Status == 1 || chat.Status == 2 || chat.Pending != "" {
		return true
	}
	for _, msg := range messages {
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

// handleKey handles the Ctrl+Alt+X/Z collapse toggles. The stable message ID is
// resolved against `messages` (the resident transcript, #2654) because it echoes
// the BEAM-owned transcript IDs and remains valid after resident front trimming.
func (a *agentPanel) handleKey(chat protocol.AgentChat, messages []protocol.AgentChatMessage, msg tea.KeyPressMsg) ([]byte, bool) {
	if !chat.Visible {
		return nil, false
	}
	key := msg.Key()
	if !key.Mod.Contains(tea.ModCtrl) || !key.Mod.Contains(tea.ModAlt) {
		return nil, false
	}
	switch key.Code {
	case 'x', 'X':
		messageID, ok := latestToolMessageID(messages)
		if !ok {
			return nil, false
		}
		return protocol.EncodeGUIAgentToolToggle(messageID), true
	case 'z', 'Z':
		messageID, ok := latestThinkingMessageID(messages)
		if !ok {
			return nil, false
		}
		return protocol.EncodeGUIAgentToolToggle(messageID), true
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
	p := m.palette()
	width := max(m.width, 1)
	limit := m.bodyHeight()
	contentWidth := max(width-2, 1)
	lines := m.renderAgentChatPanelWithLimit(chat, contentWidth, limit)
	blank := lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(strings.Repeat(" ", width))
	for index, line := range lines {
		lines[index] = m.insetAgentLine(line, width)
	}
	for len(lines) < limit {
		lines = append(lines, blank)
	}
	return takeLines(lines, limit)
}

func (m Model) insetAgentLine(line string, width int) string {
	p := m.palette()
	if width <= 1 {
		return line
	}
	inset := lipgloss.NewStyle().Background(p.AgentPanel()).Render(" ")
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(inset+line, width))
}

func (m Model) renderAgentChatPanelWithLimit(chat protocol.AgentChat, width int, limit int) []string {
	limit = max(limit, 1)
	empty := chat.Pending == "" && strings.TrimSpace(chat.Prompt) == "" && len(m.agentTranscriptMessages()) == 0
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
	messageCount := len(m.agentTranscriptMessages())
	sparse := messageCount <= 1 && chat.Pending == "" && strings.TrimSpace(chat.Prompt) == ""
	if chat.Pending != "" && len(lines) < contentBudget {
		lines = append(lines, m.renderAgentNotice("◆ approval", chat.Pending, width))
	}

	if len(lines) < contentBudget {
		lines = append(lines, m.renderAgentTranscriptHeader(width))
	}

	messageLines := m.renderAgentResidentTranscript(max(contentBudget-len(lines), 0), width)
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
	p := m.palette()
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(strings.Repeat(" ", max(width, 1)))
}

func (m Model) renderAgentTranscriptSeparator(width int) string {
	p := m.palette()
	indent := "    "
	ruleWidth := max(width-len(indent), 0)
	rule := lipgloss.NewStyle().Foreground(p.Muted()).Background(m.editorBackground()).Render(strings.Repeat("─", ruleWidth))
	return lipgloss.NewStyle().Background(m.editorBackground()).Width(width).Render(fitStyled(indent+rule, width))
}

func (m Model) renderAgentTranscriptHeader(width int) string {
	p := m.palette()
	label := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(p.AgentPanel()).Render(" Transcript ")
	rule := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Render(strings.Repeat("─", max(width-lipgloss.Width(label), 0)))
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(label+rule, width))
}

func (m Model) renderAgentTranscriptStatus(chat protocol.AgentChat, width int) string {
	p := m.palette()
	messageCount := len(m.agentTranscriptMessages())
	label := "messages"
	if messageCount == 1 {
		label = "message"
	}
	status := fmt.Sprintf(" %d %s · %s", messageCount, label, agentChatStatusLabel(chat.Status))
	if chat.ThinkingLevel != "" {
		status += " · thinking " + chat.ThinkingLevel
	}
	return lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Width(width).Render(fit(status, width))
}

func (m Model) renderAgentLandingState(width int) []string {
	p := m.palette()
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.AgentPanel()).Render("Minga is ready")
	subtitle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Render("Ask in plain language, or start with a slash command.")
	section := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(p.AgentPanel()).Render("Suggested next moves")
	return []string{
		m.renderAgentBlankLine(width),
		lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled("  "+title+"  "+subtitle, width)),
		m.renderAgentBlankLine(width),
		lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled("  "+section, width)),
		m.renderAgentSuggestionRow(width, "/explain", "Explain this file", "/tests", "Find failing tests"),
		m.renderAgentSuggestionRow(width, "/review", "Review changes", "/edit", "Edit current buffer"),
		m.renderAgentSuggestionRow(width, "/run", "Run a command", "/plan", "Draft a plan"),
	}
}

func (m Model) renderAgentSuggestionRow(width int, leftCommand string, leftLabel string, rightCommand string, rightLabel string) string {
	p := m.palette()
	columnWidth := max((width-6)/2, 12)
	left := m.renderAgentSuggestionAction(leftCommand, leftLabel, columnWidth)
	right := m.renderAgentSuggestionAction(rightCommand, rightLabel, columnWidth)
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled("  "+left+"  "+right, width))
}

func (m Model) renderAgentSuggestionAction(command string, label string, width int) string {
	p := m.palette()
	cmd := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.AgentPanel()).Render(command)
	text := lipgloss.NewStyle().Foreground(p.AgentText()).Background(p.AgentPanel()).Render(" " + firstCompactLine(label, max(width-lipgloss.Width(command)-1, 4)))
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(cmd+text, width))
}

func (m Model) renderAgentHeader(chat protocol.AgentChat, width int) string {
	p := m.palette()
	headerBG := p.AgentHeader()
	headerFG := p.AgentHeaderText()
	base := lipgloss.NewStyle().Foreground(headerFG).Background(headerBG).Width(width)
	provider, modelName := splitAgentModelName(chat.ModelName)
	modelName = nonEmpty(modelName, "no model")

	icon := lipgloss.NewStyle().Bold(true).Foreground(headerFG).Background(headerBG).Render(agentHeaderIcon())
	label := lipgloss.NewStyle().Bold(true).Foreground(headerFG).Background(headerBG).Render(" Agent")
	model := lipgloss.NewStyle().Foreground(headerFG).Background(headerBG).Render(modelName)
	muted := lipgloss.NewStyle().Foreground(p.Muted()).Background(headerBG)

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
	separator := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.AgentPanel()).Render(" │ ")
	blankLeft := lipgloss.NewStyle().Background(p.EditorSurface()).Width(leftWidth).Render(strings.Repeat(" ", leftWidth))
	blankRight := lipgloss.NewStyle().Background(p.AgentPanel()).Width(rightWidth).Render(strings.Repeat(" ", rightWidth))
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
	messages := m.agentTranscriptMessages()
	provider, model := splitAgentModelName(chat.ModelName)
	lines := []string{m.renderAgentDetailFrame("top", "◇ Session", width)}
	lines = append(lines, m.renderAgentDetailRow("Provider", nonEmpty(provider, "unknown"), width))
	lines = append(lines, m.renderAgentDetailRow("Model", nonEmpty(model, "not selected"), width))
	lines = append(lines, m.renderAgentDetailRow("State", agentChatStatusLabel(chat.Status), width))
	if chat.ThinkingLevel != "" {
		lines = append(lines, m.renderAgentDetailRow("Thinking", chat.ThinkingLevel, width))
	}
	lines = append(lines, m.renderAgentDetailRow("Messages", fmt.Sprintf("%d", len(messages)), width))

	toolCount, runningTools, erroredTools := agentToolCounts(messages)
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
	if lastAgentError(messages) != "" {
		lines = append(lines, m.renderAgentDetailsSection("Needs attention", width))
		lines = append(lines, m.renderAgentDetailRow("Auth", "run /auth or check API key", width))
	}
	if usage, ok := lastAgentUsage(messages); ok {
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
	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.AgentPanel())
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.AgentPanel())
	inner := max(width-2, 0)
	if kind == "bottom" {
		return border.Render("╰" + strings.Repeat("─", inner) + "╯")
	}
	titleText := " " + title + " "
	line := "╭" + titleStyle.Render(titleText) + border.Render(strings.Repeat("─", max(inner-lipgloss.Width(titleText), 0))+"╮")
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width))
}

func (m Model) renderAgentDetailsSection(label string, width int) string {
	p := m.palette()
	ruleStyle := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.AgentPanel())
	text := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(p.AgentPanel()).Render(" " + label + " ")
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
	labelStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Width(labelWidth)
	valueStyle := lipgloss.NewStyle().Foreground(p.AgentText()).Background(p.AgentPanel())
	prefix := labelStyle.Render(label)
	body := valueStyle.Render(firstCompactLine(value, max(width-labelWidth-4, 8)))
	return m.renderAgentDetailContentLine(prefix+" "+body, width)
}

func (m Model) renderAgentDetailHint(key string, action string, width int) string {
	p := m.palette()
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.AgentPanel())
	actionStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel())
	line := keyStyle.Render(key) + actionStyle.Render("  "+action)
	return m.renderAgentDetailContentLine(line, width)
}

func (m Model) renderAgentDetailContentLine(content string, width int) string {
	p := m.palette()
	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.AgentPanel())
	bodyWidth := max(width-2, 1)
	body := lipgloss.NewStyle().Background(p.AgentPanel()).Width(bodyWidth).Render(fitStyled(" "+content, bodyWidth))
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
	style := lipgloss.NewStyle().Bold(true).Padding(0, 1)
	switch status {
	case 1: // working
		label = m.agentSpinner() + " " + label
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusWorking())
	case 2: // iterating
		label = m.agentSpinner() + " " + label
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusIterating())
	case 3: // needs you
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusNeedsYou())
	case 4: // done
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusDone())
	case 5: // errored
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusErrored())
	default: // idle
		style = style.Foreground(p.AgentStatusIdle()).Background(p.SurfaceAlt())
	}
	return style.Render(label)
}

func (m Model) agentSpinner() string {
	return m.agent.spinner()
}

func agentChatStatusLabel(status byte) string {
	switch status {
	case 1:
		return "working"
	case 2:
		return "iterating"
	case 3:
		return "needs you"
	case 4:
		return "done"
	case 5:
		return "errored"
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

// agentTranscriptMessages is the transcript rendering source: the resident 0x86
// store (#2654).
func (m Model) agentTranscriptMessages() []protocol.AgentChatMessage {
	if m.transcript != nil && len(m.transcript.messages) > 0 {
		return m.transcript.messages
	}
	return nil
}

// renderAgentResidentTranscript renders the visible transcript window from the
// resident store, applying any queued local scroll same-frame (#2654). Pinned
// follows the bottom; unpinned holds a top-anchored offset so a streaming append
// does not move the reading position. It mutates the shared *transcript pointer
// (clamp + pin edge), which persists through the value-receiver render chain.
func (m Model) renderAgentResidentTranscript(budget int, width int) []string {
	messages := m.agentTranscriptMessages()
	t := m.transcript
	if t == nil {
		return m.agentTranscriptTail(messages, budget, width)
	}
	if budget <= 0 || len(messages) == 0 {
		t.pendingScroll = 0
		return nil
	}
	// Only pay for the full layout when scrolled up or a scroll is pending; the
	// common followed case renders just the bottom window.
	if t.pendingScroll == 0 && t.pinned {
		return m.agentTranscriptTail(messages, budget, width)
	}
	lines := m.agentTranscriptAllLines(messages, width)
	maxTop := max(len(lines)-budget, 0)
	t.resolveScroll(maxTop)
	if t.pinned {
		return windowBottom(lines, budget)
	}
	return windowTopAnchored(lines, budget, t.topOffset)
}

// agentTranscriptAllLines renders every message top-to-bottom with a separator
// between messages. It is the full line layout the unpinned (scrolled-up) window
// slices; the pinned path uses the cheaper bottom-bounded agentTranscriptTail.
func (m Model) agentTranscriptAllLines(messages []protocol.AgentChatMessage, width int) []string {
	lines := make([]string, 0, len(messages)*2)
	first := true
	for _, msg := range messages {
		block := m.renderAgentMessage(msg, width)
		if len(block) == 0 {
			continue
		}
		if !first {
			lines = append(lines, m.renderAgentTranscriptSeparator(width))
		}
		lines = append(lines, block...)
		first = false
	}
	return lines
}

// agentTranscriptTail renders the bottom `budget` lines, bounded so a followed
// session only renders enough messages to fill the view regardless of transcript
// length. Its output equals the bottom `budget` lines of agentTranscriptAllLines
// (guarded by test) so the pinned and unpinned paths stay visually consistent.
func (m Model) agentTranscriptTail(messages []protocol.AgentChatMessage, budget int, width int) []string {
	if budget <= 0 || len(messages) == 0 {
		return nil
	}
	blocks := make([][]string, 0, 8) // newest-first
	total := 0
	for i := len(messages) - 1; i >= 0; i-- {
		block := m.renderAgentMessage(messages[i], width)
		if len(block) == 0 {
			continue
		}
		if len(blocks) > 0 {
			total++ // separator above the previously added (newer) block
		}
		blocks = append(blocks, block)
		total += len(block)
		if total >= budget {
			break
		}
	}
	lines := make([]string, 0, total)
	for k := len(blocks) - 1; k >= 0; k-- {
		if k < len(blocks)-1 {
			lines = append(lines, m.renderAgentTranscriptSeparator(width))
		}
		lines = append(lines, blocks[k]...)
	}
	return windowBottom(lines, budget)
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
		textColor = p.AgentText()
	}
	markerText := lipgloss.NewStyle().Bold(true).Foreground(markerColor).Background(p.AgentPanel()).Render(marker)
	labelText := lipgloss.NewStyle().Bold(true).Foreground(markerColor).Background(p.AgentPanel()).Render(" " + label)
	body := lipgloss.NewStyle().Foreground(textColor).Background(p.AgentPanel()).Render("  " + firstCompactLine(msg.Text, max(width-lipgloss.Width(label)-8, 8)))
	line := "  " + markerText + labelText + body
	return []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width))}
}

func (m Model) renderAgentUserMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	lines := compactTextLines(msg.Text, max(width-12, 8), 2)
	if len(lines) == 0 {
		lines = []string{""}
	}
	marker := lipgloss.NewStyle().Bold(true).Foreground(p.AgentUserBorder()).Background(p.AgentPanel()).Render("  ❯")
	label := lipgloss.NewStyle().Bold(true).Foreground(p.AgentUserLabel()).Background(p.AgentPanel()).Render(" You")
	header := marker + label
	out := []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(header, width))}
	bodyStyle := lipgloss.NewStyle().Foreground(p.AgentText()).Background(p.AgentPanel())
	for _, bodyLine := range lines {
		line := bodyStyle.Render("    " + firstCompactLine(bodyLine, max(width-6, 8)))
		out = append(out, lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width)))
	}
	return out
}

func (m Model) renderAgentAssistantMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	headerMarker := lipgloss.NewStyle().Bold(true).Foreground(p.AgentAssistantBorder()).Background(p.AgentPanel()).Render("  ◇")
	headerLabel := lipgloss.NewStyle().Bold(true).Foreground(p.AgentAssistantLabel()).Background(p.AgentPanel()).Render(" Minga")
	header := headerMarker + headerLabel
	out := []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(header, width))}

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
	rail := lipgloss.NewStyle().Foreground(p.AgentAssistantBorder()).Background(p.AgentPanel()).Render("  │ ")
	bodyStyle := lipgloss.NewStyle().Foreground(p.AgentText()).Background(p.AgentPanel())
	for _, bodyLine := range lines {
		line := rail + bodyStyle.Render(firstCompactLine(bodyLine, max(width-5, 8)))
		out = append(out, lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width)))
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
	p := m.palette()
	switch block.Kind {
	case 0x01, 0x02, 0x03, 0x04:
		return m.renderAgentAssistantStyledLines(block.Lines, width)
	case 0x05:
		surface := p.AgentPanel()
		rule := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render("  ─" + strings.Repeat("─", max(width-4, 1)))
		return []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rule, width))}
	case 0x06:
		return []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render("")}
	case 0x07:
		return m.renderAgentCodeCard(block, width)
	default:
		return nil
	}
}

func (m Model) renderAgentCodeCard(block protocol.AgentMarkdownBlock, width int) []string {
	p := m.palette()
	surface := p.AgentCodeSurface()
	codeBorder := p.AgentCodeBorder()
	rail := lipgloss.NewStyle().Foreground(codeBorder).Background(surface).Render("  │ ")
	bodyWidth := max(width-lipgloss.Width(rail)-2, 8)
	label := nonEmpty(block.Label, "Code")
	if block.TargetPath != "" {
		label += " · " + block.TargetPath
	}
	if !block.Complete() {
		label += " · streaming"
	}
	header := rail + lipgloss.NewStyle().Foreground(codeBorder).Background(surface).Bold(true).Render("╭─ "+label)
	out := []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header, width))}
	for _, line := range block.Lines {
		body := m.renderAgentCodeCardLine(line, bodyWidth)
		out = append(out, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rail+"│ "+body, width)))
	}
	footer := rail + lipgloss.NewStyle().Foreground(codeBorder).Background(surface).Render("╰"+strings.Repeat("─", max(min(bodyWidth, width-6), 1)))
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
	surface := p.AgentPanel()
	rail := lipgloss.NewStyle().Foreground(p.AgentAssistantBorder()).Background(surface).Render("  │ ")
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
	p := m.palette()
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
		part := agentStyledRunStyle(run, p.AgentPanel()).Render(text)
		rendered.WriteString(part)
		remaining -= lipgloss.Width(part)
		if remaining <= 0 && index < len(line)-1 {
			truncated = true
			break
		}
	}
	if isCode && truncated {
		marker := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Render("›")
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
	// Pulse the rail between two dim shades when actively thinking;
	// use the dimmer shade when collapsed.
	railColor := p.PopupBorder()
	if !msg.Collapsed && m.agent.animationFrame/3%2 == 0 {
		railColor = p.Muted()
	}
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render("  │ ")
	markerStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Bold(true)
	labelStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Italic(true)
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel())
	header := rail + markerStyle.Render(marker) + labelStyle.Render(" Thinking "+state)
	lines := []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(header, width))}
	bodyLines := agentThinkingBodyLines(msg.Collapsed)
	for _, bodyLine := range compactTextLines(text, max(width-8, 8), bodyLines) {
		line := rail + bodyStyle.Render(firstCompactLine(bodyLine, max(width-6, 8)))
		lines = append(lines, lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width)))
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
	surface := p.AgentPanel()
	toolHeader := p.AgentToolHeader()
	railStyle := lipgloss.NewStyle().Foreground(statusColor).Background(surface)
	status := lipgloss.NewStyle().Bold(true).Foreground(statusColor).Background(surface).Render(statusIcon)
	title := lipgloss.NewStyle().Bold(true).Foreground(toolHeader).Background(surface).Render(presentation.Icon + " " + presentation.Title)
	rawName := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(name)
	meta := agentToolMeta(msg)
	metaText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(meta)
	header := railStyle.Render("  ├─") + " " + status + " " + title + lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" · ") + rawName
	if meta != "" {
		header += lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" · ") + metaText
	}
	label := lipgloss.NewStyle().Foreground(toolHeader).Background(surface).Render(presentation.SummaryLabel + ":")
	summaryText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" " + firstCompactLine(summary, max(width-lipgloss.Width(presentation.SummaryLabel)-9, 8)))
	body := railStyle.Render("  │") + "  " + label + summaryText
	lines := []string{
		lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header, width)),
		lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(body, width)),
	}

	if len(msg.PreviewLines) > 0 {
		lines = append(lines, m.renderAgentToolPreviewLines(msg.PreviewKind, msg.PreviewLines, width, statusColor)...)
	}

	if msg.IsError && msg.Result != "" {
		lines = append(lines, m.renderAgentToolTextLines("ERROR", msg.Result, width, agentToolExpandedLines, statusColor)...)
	} else if hasAgentToolResult(msg) && msg.Collapsed {
		lines = append(lines, m.renderAgentToolCollapsedHint(width, statusColor))
	} else if !msg.Collapsed {
		lines = append(lines, m.renderAgentToolResultLines(presentation.ResultLabel, msg, width, statusColor)...)
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

func (m Model) renderAgentToolCollapsedHint(width int, railColor color.Color) string {
	p := m.palette()
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render("  │")
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Italic(true)
	line := rail + "  " + bodyStyle.Render("result collapsed, Ctrl+Alt+X expands latest tool")
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width))
}

func (m Model) renderAgentToolPreviewLines(kind byte, lines []string, width int, railColor color.Color) []string {
	label := approvalPreviewKindName(kind)
	return m.renderAgentToolPlainLines(label, lines, width, min(len(lines), 8), railColor)
}

func (m Model) renderAgentToolResultLines(label string, msg protocol.AgentChatMessage, width int, railColor color.Color) []string {
	if len(msg.StyledLines) > 0 {
		return m.renderAgentToolStyledLines(label, msg.StyledLines, width, agentToolExpandedLines, railColor)
	}
	return m.renderAgentToolTextLines(label, msg.Result, width, agentToolExpandedLines, railColor)
}

func (m Model) renderAgentToolTextLines(label string, text string, width int, limit int, railColor color.Color) []string {
	return m.renderAgentToolPlainLines(label, agentToolTextLines(text), width, limit, railColor)
}

func agentToolTextLines(text string) []string {
	text = strings.TrimRight(text, "\n")
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}

func (m Model) renderAgentToolPlainLines(label string, rawLines []string, width int, limit int, railColor color.Color) []string {
	if len(rawLines) == 0 || limit <= 0 {
		return nil
	}
	p := m.palette()
	out := make([]string, 0, min(len(rawLines), limit)+1)
	for index, raw := range rawLines[:min(len(rawLines), limit)] {
		out = append(out, m.renderAgentToolLine(label, raw, index == 0, width, agentToolLineColor(raw, p), railColor))
	}
	if len(rawLines) > limit {
		remaining := fmt.Sprintf("… +%d lines", len(rawLines)-limit)
		out = append(out, m.renderAgentToolLine(label, remaining, false, width, p.Muted(), railColor))
	}
	return out
}

func (m Model) renderAgentToolStyledLines(label string, styledLines []protocol.AgentStyledLine, width int, limit int, railColor color.Color) []string {
	if len(styledLines) == 0 || limit <= 0 {
		return nil
	}
	p := m.palette()
	out := make([]string, 0, min(len(styledLines), limit)+1)
	for index, runs := range styledLines[:min(len(styledLines), limit)] {
		out = append(out, m.renderAgentToolStyledLine(label, runs, index == 0, width, railColor))
	}
	if len(styledLines) > limit {
		remaining := fmt.Sprintf("… +%d lines", len(styledLines)-limit)
		out = append(out, m.renderAgentToolLine(label, remaining, false, width, p.Muted(), railColor))
	}
	return out
}

func (m Model) renderAgentToolStyledLine(label string, runs protocol.AgentStyledLine, showLabel bool, width int, railColor color.Color) string {
	p := m.palette()
	labelText := strings.Repeat(" ", len(label))
	if showLabel {
		labelText = label
	}
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render("  │")
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.AgentPanel())
	body := renderAgentStyledRuns(runs, p.Muted(), p.AgentPanel())
	line := rail + "  " + labelStyle.Render(labelText+":") + " " + body
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width))
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

func (m Model) renderAgentToolLine(label string, text string, showLabel bool, width int, textColor color.Color, railColor color.Color) string {
	p := m.palette()
	labelText := strings.Repeat(" ", len(label))
	if showLabel {
		labelText = label
	}
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render("  │")
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.AgentPanel())
	bodyStyle := lipgloss.NewStyle().Foreground(textColor).Background(p.AgentPanel())
	body := fit(strings.TrimRight(text, "\r"), max(width-lipgloss.Width(label)-9, 8))
	line := rail + "  " + labelStyle.Render(labelText+":") + bodyStyle.Render(" "+body)
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width))
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
	outerBG := p.AgentPanel()
	innerBG := p.SurfaceAlt()
	border := lipgloss.NewStyle().Foreground(p.Warning()).Background(outerBG)
	innerWidth := max(width-2, 1)
	outerStyle := lipgloss.NewStyle().Background(outerBG).Width(width)

	// Top border
	top := border.Render("╭" + strings.Repeat("─", max(width-2, 0)) + "╮")

	// Header: ◆ Approval <name> · <kind>  <summary>
	headerLabel := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(innerBG).Render("◆ Approval")
	name := lipgloss.NewStyle().Bold(true).Foreground(p.AgentText()).Background(innerBG).Render(" " + nonEmpty(msg.Name, "tool"))
	kind := lipgloss.NewStyle().Foreground(p.Accent()).Background(innerBG).Render(" · " + approvalPreviewKindName(msg.PreviewKind))
	summaryBudget := max(innerWidth-lipgloss.Width(headerLabel)-lipgloss.Width(name)-lipgloss.Width(kind)-3, 8)
	summary := lipgloss.NewStyle().Foreground(p.AgentText()).Background(innerBG).Render("  " + firstCompactLine(msg.Summary, summaryBudget))
	headerContent := headerLabel + name + kind + summary

	lines := []string{
		outerStyle.Render(fitStyled(top, width)),
		m.renderApprovalCardLine(headerContent, innerWidth, border, innerBG),
	}

	// Preview lines
	for _, previewLine := range msg.PreviewLines[:min(len(msg.PreviewLines), 2)] {
		preview := lipgloss.NewStyle().Foreground(p.Muted()).Background(innerBG).Render("  " + firstCompactLine(previewLine, max(innerWidth-4, 8)))
		lines = append(lines, m.renderApprovalCardLine(preview, innerWidth, border, innerBG))
	}

	// Action hints
	hints := lipgloss.NewStyle().Foreground(p.Muted()).Background(innerBG).Render("y approve · n reject")
	lines = append(lines, m.renderApprovalCardLine(hints, innerWidth, border, innerBG))

	// Bottom border
	bottom := border.Render("╰" + strings.Repeat("─", max(width-2, 0)) + "╯")
	lines = append(lines, outerStyle.Render(fitStyled(bottom, width)))

	return lines
}

func (m Model) renderApprovalCardLine(content string, innerWidth int, border lipgloss.Style, innerBG color.Color) string {
	body := lipgloss.NewStyle().Background(innerBG).Width(innerWidth).Render(fitStyled(" "+content, innerWidth))
	return border.Render("│") + body + border.Render("│")
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
	return lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Width(width).Render(fitStyled(text, width))
}

func (m Model) renderAgentComposer(chat protocol.AgentChat, width int) []string {
	p := m.palette()
	if width < 4 {
		return nil
	}
	inputBG := p.AgentInputSurface()
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
	borderColor := p.AgentInputBorder()
	if chat.Status == 1 || chat.Status == 2 {
		borderColor = markerColor
	}
	border := lipgloss.NewStyle().Foreground(borderColor).Background(inputBG)
	title := lipgloss.NewStyle().Bold(true).Foreground(p.Muted()).Background(inputBG).Render(" " + agentComposerTitle(chat) + " ")
	top := border.Render("╭") + title + border.Render(strings.Repeat("─", max(width-2-lipgloss.Width(title), 0))+"╮")
	innerWidth := max(width-2, 1)
	marker := lipgloss.NewStyle().Bold(true).Foreground(markerColor).Background(inputBG).Render("❯")
	modeText := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(inputBG).Render(mode)
	promptStyle := lipgloss.NewStyle().Foreground(p.AgentText()).Background(inputBG)
	if placeholder {
		promptStyle = promptStyle.Foreground(p.AgentInputPlaceholder()).Italic(true)
	}
	prefix := " " + marker + " " + modeText + "  "
	promptText := promptStyle.Render(firstCompactLine(prompt, max(innerWidth-lipgloss.Width(prefix)-1, 8)))
	input := border.Render("│") + lipgloss.NewStyle().Background(inputBG).Width(innerWidth).Render(fitStyled(prefix+promptText, innerWidth)) + border.Render("│")
	hints := lipgloss.NewStyle().Foreground(p.Muted()).Background(inputBG).Render(" Enter send · Esc normal · / commands · " + cursor)
	help := border.Render("│") + lipgloss.NewStyle().Background(inputBG).Width(innerWidth).Render(fitStyled(" "+hints, innerWidth)) + border.Render("│")
	bottom := border.Render("╰" + strings.Repeat("─", max(width-2, 0)) + "╯")
	style := lipgloss.NewStyle().Background(inputBG).Width(width)
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

func agentComposerTitle(chat protocol.AgentChat) string {
	if chat.Pending != "" {
		return "Approval needed"
	}
	switch chat.Status {
	case 1, 2:
		return "Running..."
	case 3:
		return "Error"
	default:
		return "Prompt"
	}
}

func (m Model) renderAgentEmptyState(width int) []string {
	p := m.palette()
	style := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Width(width)
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
