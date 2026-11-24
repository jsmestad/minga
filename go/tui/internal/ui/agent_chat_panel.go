package ui

import (
	"fmt"
	"image/color"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

type agentPanel struct {
	animationFrame   uint64
	animationRunning bool
	lastPromptFit    protocol.AgentPromptFit
}

func (m Model) agentAnimating(chat protocol.AgentChat) bool {
	if !chat.Visible || chat.Lifecycle != protocol.AgentChatConversation {
		return false
	}
	if chat.Status == 5 {
		return false
	}
	if chat.Status == 1 || chat.Status == 2 || chat.Pending != "" {
		return true
	}
	return m.transcript != nil && m.transcript.hasAnimatedMessages()
}

func (a *agentPanel) tick() {
	a.animationFrame++
}

func (a *agentPanel) spinner() string {
	frames := generated.StateWorking.Token().Frames
	return frames[int(a.animationFrame)%len(frames)]
}

// handleKey resolves read and collapse shortcuts against stable resident message IDs.
func (a *agentPanel) handleKey(chat protocol.AgentChat, messages *residentTranscript, msg tea.KeyPressMsg) ([]byte, bool) {
	if !chat.Visible || chat.Lifecycle != protocol.AgentChatConversation {
		return nil, false
	}
	key := msg.Key()
	if !key.Mod.Contains(tea.ModCtrl) || !key.Mod.Contains(tea.ModAlt) {
		return nil, false
	}
	switch key.Code {
	case 'o', 'O':
		message, ok := messages.latest(transcriptSummaryRetainedOutput)
		if !ok {
			return nil, false
		}
		return protocol.EncodeGUIAgentReadRetainedOutput(message.ID, message.RetainedOutputOffer), true
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
	width := max(m.layout.body.Width, 1)
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
	empty := chat.Pending == "" && strings.TrimSpace(chat.Prompt) == "" && m.transcript.len() == 0
	if limit <= 2 {
		return m.renderAgentMainColumn(chat, width, limit, empty)
	}
	lines := []string{m.renderAgentHeader(chat, width)}

	if chat.Lifecycle == protocol.AgentChatConversation && agentDetailsVisible(width) && limit > 5 {
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
	composer := m.renderAgentComposerWithLimit(chat, width, budget)
	if chat.Lifecycle != protocol.AgentChatConversation {
		lines := m.renderAgentLifecycleNotice(chat, width, budget-len(composer))
		lines = append(lines, m.renderAgentResidentTranscript(budget-len(composer)-len(lines), width)...)
		for len(lines)+len(composer) < budget {
			lines = append(lines, m.renderAgentBlankLine(width))
		}
		return append(lines, composer...)
	}
	lines := make([]string, 0, budget)
	_, statusHeight, contentBudget, messageBudget := agentMainColumnBudgets(chat, len(composer), budget)
	messageCount := m.transcript.len()
	sparse := messageCount <= 1 && chat.Pending == "" && strings.TrimSpace(chat.Prompt) == ""
	if chat.Pending != "" && len(lines) < contentBudget {
		lines = append(lines, m.renderAgentNotice("◆ approval", chat.Pending, width))
	}

	if len(lines) < contentBudget {
		lines = append(lines, m.renderAgentTranscriptHeader(width))
	}

	messageLines := m.renderAgentResidentTranscript(messageBudget, width)
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
	lines = append(lines, composer...)
	return takeLines(lines, budget)
}

// renderAgentLifecycleNotice draws a non-conversation chat: a glyph and
// headline, the BEAM's sentence about the cause, the one action it offers as a
// clickable zone with its key hint, then the muted draft note. The headline,
// action label, key hint and note are rendered exactly as sent; an empty note
// draws no line.
func (m Model) renderAgentLifecycleNotice(chat protocol.AgentChat, width, budget int) []string {
	if budget <= 0 {
		return nil
	}
	p := m.palette()
	surface := lipgloss.NewStyle().Background(p.SurfaceAlt())
	headline := lipgloss.NewStyle().Bold(true).Foreground(p.Text()).Background(p.SurfaceAlt())
	secondary := lipgloss.NewStyle().Foreground(p.Text()).Background(p.SurfaceAlt())
	muted := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.SurfaceAlt())
	row := func(content string) string {
		return surface.Width(width).Render(fitStyled(content, width))
	}

	glyph := lipgloss.NewStyle().Bold(true).Foreground(p.State(generated.StateNeedsYou)).Background(p.SurfaceAlt()).Render(generated.StateNeedsYou.Token().Glyph)
	if chat.Lifecycle == protocol.AgentChatStarting {
		glyph = lipgloss.NewStyle().Foreground(p.AgentStatusWorking()).Background(p.SurfaceAlt()).Render(m.agentSpinner())
	}
	lines := []string{row(glyph + surface.Render(" ") + headline.Render(chat.LifecycleNotice.Headline))}
	indent := surface.Render(gap(spaceXL))
	wrapWidth := max(width-lipgloss.Width(indent)-noticeInset.cols(), 1)
	appendWrapped := func(text string, style lipgloss.Style) bool {
		for _, part := range strings.Split(ansi.Wrap(text, wrapWidth, ""), "\n") {
			if len(lines) >= budget {
				return false
			}
			lines = append(lines, row(indent+style.Render(part)))
		}
		return true
	}
	if chat.Lifecycle == protocol.AgentChatFailed && chat.LifecycleReason != "" &&
		!appendWrapped(chat.LifecycleReason, secondary) {
		return lines
	}
	if remedy := chat.LifecycleRemedy; chat.Lifecycle == protocol.AgentChatFailed &&
		remedy.Kind != protocol.AgentStartRemedyNone {
		if len(lines) >= budget {
			return lines
		}
		button := lipgloss.NewStyle().Bold(true).Foreground(p.SelectionText()).Background(p.AgentStatusNeedsYou()).Padding(padding(spaceHairline, spaceSM)).Render(remedy.Label)
		action := m.zones.Mark(agentStartRemedyZoneID(remedy.Kind), button)
		if remedy.KeyHint != "" {
			action += surface.Render(" ") + muted.Render(remedy.KeyHint)
		}
		lines = append(lines, row(indent+action))
	}
	if note := chat.LifecycleNotice.Note; note != "" {
		appendWrapped(note, muted)
	}
	return lines
}

func agentMainColumnBudgets(chat protocol.AgentChat, composerRows int, budget int) (composerHeight int, statusHeight int, contentBudget int, messageBudget int) {
	composerHeight = min(composerRows, max(budget, 0))
	transcriptBudget := max(budget-composerHeight, 0)
	if transcriptBudget >= 4 {
		statusHeight = 1
	}
	contentBudget = max(transcriptBudget-statusHeight, 0)
	chromeRows := 1
	if chat.Pending != "" {
		chromeRows++
	}
	messageBudget = max(contentBudget-chromeRows, 0)
	return composerHeight, statusHeight, contentBudget, messageBudget
}

func (m Model) agentTranscriptPageSize() int {
	chat, ok := m.agentChat()
	if !ok {
		return 1
	}
	limit := m.bodyHeight()
	panelWidth := max(m.layout.body.Width-2, 1)
	mainWidth := panelWidth
	if chat.Lifecycle == protocol.AgentChatConversation && agentDetailsVisible(panelWidth) && limit > 5 {
		detailWidth := agentDetailsWidth(panelWidth)
		mainWidth = max(panelWidth-detailWidth-agentColumnGap(), 40)
	}
	mainBudget := max(limit-agentPanelHeaderRows(limit), 0)
	composerRows := agentComposerAllocation(chat, mainWidth, mainBudget).height
	if chat.Lifecycle != protocol.AgentChatConversation {
		transcriptBudget := mainBudget - composerRows
		notice := m.renderAgentLifecycleNotice(chat, mainWidth, transcriptBudget)
		return max(transcriptBudget-len(notice), 1)
	}
	_, _, _, messageBudget := agentMainColumnBudgets(chat, composerRows, mainBudget)
	return max(messageBudget, 1)
}

func (m Model) renderAgentBlankLine(width int) string {
	p := m.palette()
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(strings.Repeat(" ", max(width, 1)))
}

func (m Model) renderAgentTranscriptSeparator(width int) string {
	p := m.palette()
	indent := gap(agentTranscriptBodyIndent)
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

func (m Model) renderAgentEarlierMessagesHidden(width int) string {
	p := m.palette()
	label := " earlier messages hidden · open History "
	return lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Width(width).Align(lipgloss.Center).Render(fit(label, width))
}

func (m Model) renderAgentTranscriptStatus(chat protocol.AgentChat, width int) string {
	p := m.palette()
	status := " " + agentChatStatusLabel(agentPresentationStatus(chat))
	if total, ok := m.agentMessageTotal(); ok {
		label := "messages"
		if total == 1 {
			label = "message"
		}
		status = fmt.Sprintf(" %d %s · %s", total, label, agentChatStatusLabel(agentPresentationStatus(chat)))
	}
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
		lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(gap(spaceXL)+title+gap(spaceXL)+subtitle, width)),
		m.renderAgentBlankLine(width),
		lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(gap(spaceXL)+section, width)),
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
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(gap(spaceXL)+left+gap(spaceXL)+right, width))
}

func (m Model) renderAgentSuggestionAction(command string, label string, width int) string {
	p := m.palette()
	cmd := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.AgentPanel()).Render(command)
	text := lipgloss.NewStyle().Foreground(p.AgentText()).Background(p.AgentPanel()).Render(gap(spaceXS) + firstCompactLine(label, max(width-lipgloss.Width(command)-spaceXS.cols(), 4)))
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

	right := m.renderAgentStatusBadge(agentPresentationStatus(chat))
	if chat.ThinkingLevel != "" && width >= 56 {
		right += muted.Render(gap(spaceXL) + "◌ " + chat.ThinkingLevel)
	}
	helpLabel := "[Help]"
	if width < 24 {
		helpLabel = "?"
	}
	help := m.zones.Mark(zoneIDAgentHeaderHelp, muted.Render(helpLabel))
	if width >= 34 {
		history := m.zones.Mark(zoneIDAgentHistory, muted.Render("[History]"))
		help = history + " " + help
	}
	prefix := title + muted.Render(gap(spaceXL))
	const tasksLabel = "[Tasks]"
	if width >= 50 && lipgloss.Width(prefix+identity+right+help)+len(tasksLabel)+3 <= width {
		tasks := m.zones.Mark(zoneIDAgentChecklist, muted.Render(tasksLabel))
		help = tasks + " " + help
	}
	const queueLabel = "[Queue]"
	if width >= 44 && lipgloss.Width(prefix+identity+right+help)+len(queueLabel)+3 <= width {
		queue := m.zones.Mark(zoneIDAgentQueue, muted.Render(queueLabel))
		help += " " + queue
	}
	helpWidth := lipgloss.Width(help)
	if width <= helpWidth {
		return base.Render(help)
	}
	rightBudget := max(width-helpWidth-1, 0)
	right = fitStyled(right, min(lipgloss.Width(right), rightBudget))
	leftBudget := max(width-lipgloss.Width(right)-helpWidth-2, 0)
	identityBudget := max(leftBudget-lipgloss.Width(prefix), 0)
	identity = lipgloss.NewStyle().Inline(true).MaxWidth(identityBudget).Render(identity)
	if identityBudget == 0 {
		identity = ""
	}
	left := fitStyled(prefix+m.zones.Mark(zoneIDAgentModel, identity), leftBudget)
	helpGap := gap(spaceXS)
	spacer := muted.Render(strings.Repeat(" ", max(width-lipgloss.Width(left)-lipgloss.Width(right)-helpWidth-lipgloss.Width(helpGap), 0)))
	return base.Render(fitStyled(left+spacer+right+helpGap+help, width))
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
	messages := m.transcript
	provider, model := splitAgentModelName(chat.ModelName)
	lines := []string{m.renderAgentDetailFrame("top", "◇ Session", width)}
	lines = append(lines, m.renderAgentDetailRow("Provider", nonEmpty(provider, "unknown"), width))
	lines = append(lines, m.renderAgentDetailRow("Model", nonEmpty(model, "not selected"), width))
	lines = append(lines, m.renderAgentDetailRow("State", agentChatStatusLabel(agentPresentationStatus(chat)), width))
	if chat.ThinkingLevel != "" {
		lines = append(lines, m.renderAgentDetailRow("Thinking", chat.ThinkingLevel, width))
	}
	lines = append(lines, m.renderAgentDetailRow("Messages", fmt.Sprintf("%d", messages.len()), width))

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
	if message := lastAgentError(messages); message != "" {
		lines = append(lines, m.renderAgentDetailsSection("Needs attention", width))
		lines = append(lines, m.renderAgentDetailRow("Error", message, width))
	}
	if usage, ok := lastAgentUsage(messages); ok {
		lines = append(lines,
			m.renderAgentDetailsSection("Latest usage", width),
			m.renderAgentDetailRow("Input", formatAgentTokens(usage.Input), width),
			m.renderAgentDetailRow("Output", formatAgentTokens(usage.Output), width),
		)
		if usage.CostMicros > 0 {
			lines = append(lines, m.renderAgentDetailRow("Cost", formatAgentCost(usage.CostMicros), width))
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
	prefix := labelStyle.Render(label) + gap(spaceXS)
	body := valueStyle.Render(firstCompactLine(value, max(agentDetailContentWidth(width)-lipgloss.Width(prefix), 8)))
	return m.renderAgentDetailContentLine(prefix+body, width)
}

func (m Model) renderAgentDetailHint(key string, action string, width int) string {
	p := m.palette()
	keyStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.AgentPanel())
	actionStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel())
	line := keyStyle.Render(key) + actionStyle.Render(gap(spaceXL)+action)
	return m.renderAgentDetailContentLine(line, width)
}

func (m Model) renderAgentDetailContentLine(content string, width int) string {
	p := m.palette()
	border := lipgloss.NewStyle().Foreground(p.PopupBorder()).Background(p.AgentPanel())
	bodyWidth := max(width-2*lipgloss.Width(agentDetailBorder), 1)
	body := lipgloss.NewStyle().Background(p.AgentPanel()).Width(bodyWidth).Render(fitStyled(gap(spaceXS)+content, bodyWidth))
	return border.Render(agentDetailBorder) + body + border.Render(agentDetailBorder)
}

// agentDetailBorder is the side border of a detail card row.
const agentDetailBorder = "│"

// agentDetailContentWidth is the columns renderAgentDetailContentLine leaves for content in a row width columns wide: a border on each side and an xs lead.
func agentDetailContentWidth(width int) int {
	return max(width-2*lipgloss.Width(agentDetailBorder)-spaceXS.cols(), 1)
}

func agentToolCounts(messages *residentTranscript) (int, int, int) {
	if messages == nil {
		return 0, 0, 0
	}
	return messages.toolCounts[0], messages.toolCounts[1], messages.toolCounts[2]
}

func lastAgentError(messages *residentTranscript) string {
	message, _ := messages.latest(transcriptSummaryError)
	return message.Text
}

func splitAgentModelName(value string) (string, string) {
	parts := strings.SplitN(strings.TrimSpace(value), ":", 2)
	if len(parts) == 2 {
		return parts[0], parts[1]
	}
	return "", strings.TrimSpace(value)
}

func lastAgentUsage(messages *residentTranscript) (protocol.AgentUsage, bool) {
	message, found := messages.latest(transcriptSummaryUsage)
	return message.Usage, found
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
	style := lipgloss.NewStyle().Bold(true).Padding(padding(spaceHairline, spaceSM))
	switch status {
	case 1: // working
		label = m.agentSpinner() + " " + label
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusWorking())
	case 2: // iterating
		label = m.agentSpinner() + " " + label
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusIterating())
	case 3: // error
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusErrored())
	case 4, 5, agentStatusNeedsYou, agentStatusQuestionWaiting: // planning, awaiting input, failed start
		style = style.Foreground(p.SelectionText()).Background(p.AgentStatusNeedsYou())
	default: // idle
		style = style.Foreground(p.AgentStatusIdle()).Background(p.SurfaceAlt())
	}
	return style.Render(label)
}

func (m Model) agentSpinner() string {
	return m.agent.spinner()
}

// agentStatusNeedsYou is the wire status of a failed start waiting for the
// user's action. agentStatusQuestionWaiting is a local presentation status
// outside the wire range.
const (
	agentStatusNeedsYou        = 6
	agentStatusQuestionWaiting = 0xF0
)

func agentPresentationStatus(chat protocol.AgentChat) byte {
	if chat.QuestionOffer != 0 {
		return agentStatusQuestionWaiting
	}
	return chat.Status
}

func agentChatStatusLabel(status byte) string {
	switch status {
	case 1:
		return "thinking"
	case 2:
		return "using tools"
	case 3:
		return generated.StateFailed.Token().Word
	case 4:
		return "planning"
	case 5:
		return "Awaiting approval"
	case agentStatusNeedsYou:
		return generated.StateNeedsYou.Token().Word
	case agentStatusQuestionWaiting:
		return "Waiting for your answer"
	default:
		return "idle"
	}
}

func agentHasActiveTurn(status byte) bool {
	switch status {
	case 1, 2, 5:
		return true
	default:
		return false
	}
}

func (m Model) renderAgentNotice(label string, text string, width int) string {
	p := m.palette()
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.SurfaceAlt())
	textStyle := lipgloss.NewStyle().Foreground(p.Text()).Background(p.SurfaceAlt())
	line := labelStyle.Render(label) + textStyle.Render(gap(spaceXL)+text)
	return lipgloss.NewStyle().Background(p.SurfaceAlt()).Width(width).Render(fitStyled(line, width))
}

// renderAgentResidentTranscript renders the visible transcript window from the
// resident store, applying any queued local scroll same-frame (#2654). Pinned
// follows the bottom; unpinned holds a message-slot + row anchor so a streaming append
// does not move the reading position. It mutates the shared *transcript pointer
// (clamp + pin edge), which persists through the value-receiver render chain.
func (m Model) renderAgentResidentTranscript(budget int, width int) []string {
	t := m.transcript
	if t == nil || m.transcriptRenderer == nil {
		return nil
	}
	return m.transcriptRenderer.render(m, t, budget, width)
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
	lead := gap(agentTranscriptInset) + markerText + labelText
	body := lipgloss.NewStyle().Foreground(textColor).Background(p.AgentPanel()).Render(gap(spaceXL) + firstCompactLine(msg.Text, agentTranscriptTextWidth(width, lead+gap(spaceXL))))
	line := lead + body
	return []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width))}
}

func (m Model) renderAgentUserMessage(msg protocol.AgentChatMessage, width int) []string {
	p := m.palette()
	lines := compactTextLines(msg.Text, max(width-12, 8), 2)
	if len(lines) == 0 {
		lines = []string{""}
	}
	marker := lipgloss.NewStyle().Bold(true).Foreground(p.AgentUserBorder()).Background(p.AgentPanel()).Render(gap(agentTranscriptInset) + "❯")
	label := lipgloss.NewStyle().Bold(true).Foreground(p.AgentUserLabel()).Background(p.AgentPanel()).Render(" You")
	header := marker + label
	out := []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(header, width))}
	bodyStyle := lipgloss.NewStyle().Foreground(p.AgentText()).Background(p.AgentPanel())
	for _, bodyLine := range lines {
		line := bodyStyle.Render(gap(agentTranscriptBodyIndent) + firstCompactLine(bodyLine, agentTranscriptTextWidth(width, gap(agentTranscriptBodyIndent))))
		out = append(out, lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width)))
	}
	return out
}

func (m Model) renderAgentAssistantMessage(msg protocol.AgentChatMessage, width int) []string {
	if agentMessageHasStyledProse(msg) {
		height, layout := measureAgentMessage(msg, width)
		return m.renderAgentRichAssistantRows(msg, layout, width, 0, height)
	}

	p := m.palette()
	out := []string{m.renderAgentAssistantHeader(width)}

	lines := compactTextLines(msg.Text, max(width-12, 8), 3)
	if len(lines) == 0 {
		lines = []string{""}
	}
	rail := lipgloss.NewStyle().Foreground(p.AgentAssistantBorder()).Background(p.AgentPanel()).Render(agentProseRail)
	bodyStyle := lipgloss.NewStyle().Foreground(p.AgentText()).Background(p.AgentPanel())
	for _, bodyLine := range lines {
		line := rail + bodyStyle.Render(firstCompactLine(bodyLine, agentTranscriptTextWidth(width, rail)))
		out = append(out, lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(line, width)))
	}
	return out
}

func (m Model) renderAgentMarkdownBlock(block protocol.AgentMarkdownBlock, width int) []string {
	p := m.palette()
	switch block.Kind {
	case 0x05:
		surface := p.AgentPanel()
		rule := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(gap(agentTranscriptInset) + strings.Repeat("─", max(width-2*agentTranscriptInset.cols(), 1)))
		return []string{lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rule, width))}
	case 0x06:
		return []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render("")}
	default:
		return nil
	}
}

func (m Model) renderAgentCodeCardLine(line protocol.AgentStyledLine, width int) string {
	if len(line) == 0 {
		return strings.Repeat(" ", width)
	}
	rendered := m.renderAgentStyledLine(line, width)
	return fitStyled(rendered, width)
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
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render(agentProseRail)
	markerStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Bold(true)
	labelStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Italic(true)
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel())
	header := rail + markerStyle.Render(marker) + labelStyle.Render(" Thinking "+state)
	lines := []string{lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(header, width))}
	bodyLines := agentThinkingBodyLines(msg.Collapsed)
	for _, bodyLine := range compactTextLines(text, max(width-8, 8), bodyLines) {
		line := rail + bodyStyle.Render(firstCompactLine(bodyLine, agentTranscriptTextWidth(width, rail)))
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
	status := lipgloss.NewStyle().Bold(true).Foreground(statusColor).Background(surface).Render(statusIcon + " " + agentToolStatusLabel(msg))
	title := lipgloss.NewStyle().Bold(true).Foreground(toolHeader).Background(surface).Render(presentation.Icon + " " + presentation.Title)
	rawName := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(name)
	meta := agentToolMeta(msg)
	metaText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(meta)
	header := railStyle.Render(agentToolBranch) + " " + status + " " + title + lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" · ") + rawName
	if meta != "" {
		header += lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(" · ") + metaText
	}
	label := lipgloss.NewStyle().Foreground(toolHeader).Background(surface).Render(presentation.SummaryLabel + ":")
	lead := railStyle.Render(agentToolRail) + gap(spaceXL) + label
	summaryText := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(gap(spaceXS) + firstCompactLine(summary, agentTranscriptTextWidth(width, lead+gap(spaceXS))))
	body := lead + summaryText
	lines := []string{
		lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header, width)),
		lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(body, width)),
	}

	if len(msg.PreviewLines) > 0 {
		lines = append(lines, m.renderAgentToolPreviewLines(msg.PreviewKind, msg.PreviewLines, width, statusColor)...)
	}

	if agentToolOffersRetainedOutput(msg) {
		labelText := "[Read retained output]"
		if width < 5+len(labelText) {
			labelText = "[Output]"
		}
		label := railStyle.Render(labelText)
		if width >= 5+len(labelText) && m.zones != nil {
			zone := fmt.Sprintf("%s%d:%x", zonePrefixAgentRetainedOutput, msg.ID, msg.RetainedOutputOffer)
			label = m.zones.markCachedTranscriptControl(zone, label)
		}
		hint := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(gap(spaceXL) + "Ctrl+Alt+O reads latest")
		indent := strings.Repeat(" ", lipgloss.Width(agentToolBranch+" "))
		lines = append(lines, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(indent+label+hint, width)))
	}
	if agentToolIsError(msg) && hasAgentToolResult(msg) {
		lines = append(lines, m.renderAgentToolResultLines(agentToolStatusLabel(msg), msg, width, statusColor)...)
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
	switch msg.Status {
	case 0:
		return m.agentSpinner(), p.Warning()
	case 1:
		return "✓", p.Diagnostic(3)
	case 2:
		return "×", p.Diagnostic(0)
	case 3:
		return "⊘", p.Warning()
	case 4:
		return "■", p.Muted()
	case 5:
		return "◷", p.Warning()
	default:
		if msg.IsError {
			return "×", p.Diagnostic(0)
		}
		return "?", p.Muted()
	}
}

func agentToolStatusLabel(msg protocol.AgentChatMessage) string {
	switch msg.Status {
	case 0:
		return "running"
	case 1:
		return "done"
	case 2:
		return "ERROR"
	case 3:
		return "Denied"
	case 4:
		return "Cancelled"
	case 5:
		return "Expired"
	default:
		if msg.IsError {
			return "ERROR"
		}
		return "unknown"
	}
}

func agentToolIsError(msg protocol.AgentChatMessage) bool {
	switch msg.Status {
	case 0, 1, 3, 4:
		return false
	case 2, 5:
		return true
	default:
		return msg.IsError
	}
}

func agentToolMeta(msg protocol.AgentChatMessage) string {
	parts := make([]string, 0, 2)
	if msg.DurationMS > 0 && msg.Status != 3 && msg.Status != 5 {
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

func agentToolOffersRetainedOutput(msg protocol.AgentChatMessage) bool {
	return msg.ID != 0 && msg.RetainedOutputOffer != [16]byte{}
}

func (m Model) renderAgentToolCollapsedHint(width int, railColor color.Color) string {
	p := m.palette()
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render(agentToolRail)
	bodyStyle := lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Italic(true)
	line := rail + gap(spaceXL) + bodyStyle.Render("result collapsed, Ctrl+Alt+X expands latest tool")
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
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render(agentToolRail)
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.AgentPanel())
	body := renderAgentStyledRuns(runs, p.Muted(), p.AgentPanel())
	line := rail + gap(spaceXL) + labelStyle.Render(labelText+":") + " " + body
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
	rail := lipgloss.NewStyle().Foreground(railColor).Background(p.AgentPanel()).Render(agentToolRail)
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(p.Warning()).Background(p.AgentPanel())
	bodyStyle := lipgloss.NewStyle().Foreground(textColor).Background(p.AgentPanel())
	lead := rail + gap(spaceXL) + labelStyle.Render(labelText+":")
	body := fit(strings.TrimRight(text, "\r"), agentTranscriptTextWidth(width, lead+gap(spaceXS)))
	line := lead + bodyStyle.Render(gap(spaceXS)+body)
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
	summary := lipgloss.NewStyle().Foreground(p.AgentText()).Background(innerBG).Render(gap(spaceXL) + firstCompactLine(msg.Summary, summaryBudget))
	headerContent := headerLabel + name + kind + summary

	lines := []string{
		outerStyle.Render(fitStyled(top, width)),
		m.renderApprovalCardLine(headerContent, innerWidth, border, innerBG),
	}

	// Preview lines
	for _, previewLine := range msg.PreviewLines[:min(len(msg.PreviewLines), 2)] {
		preview := lipgloss.NewStyle().Foreground(p.Muted()).Background(innerBG).Render(gap(spaceXL) + firstCompactLine(previewLine, max(innerWidth-2*approvalCardLead.cols()-spaceXL.cols(), 8)))
		lines = append(lines, m.renderApprovalCardLine(preview, innerWidth, border, innerBG))
	}

	// These are backend shortcuts, not local composer bindings. Mouse controls
	// echo the immutable target captured in this message's rendered zone.
	for _, actions := range m.renderAgentApprovalActions(msg, innerWidth-1, innerBG) {
		lines = append(lines, m.renderApprovalCardLine(actions, innerWidth, border, innerBG))
	}

	// Bottom border
	bottom := border.Render("╰" + strings.Repeat("─", max(width-2, 0)) + "╯")
	lines = append(lines, outerStyle.Render(fitStyled(bottom, width)))

	return lines
}

// approvalCardLead is the inset inside an approval card's border, before its content and kept clear after it.
const approvalCardLead = spaceXS

func (m Model) renderApprovalCardLine(content string, innerWidth int, border lipgloss.Style, innerBG color.Color) string {
	body := lipgloss.NewStyle().Background(innerBG).Width(innerWidth).Render(fitStyled(gap(approvalCardLead)+content, innerWidth))
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
	text := gap(agentTranscriptInset) + fmt.Sprintf("◌ Usage · in %s · out %s", formatAgentTokens(usage.Input), formatAgentTokens(usage.Output))
	if usage.CostMicros > 0 {
		text += " · " + formatAgentCost(usage.CostMicros)
	}
	return lipgloss.NewStyle().Foreground(p.Muted()).Background(p.AgentPanel()).Width(width).Render(fitStyled(text, width))
}

func formatAgentCost(micros uint32) string {
	amount := fmt.Sprintf("$%d.%06d", micros/1_000_000, micros%1_000_000)
	end := len(amount)
	for cents := end - 4; end > cents && amount[end-1] == '0'; end-- {
	}
	return amount[:end]
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
	if chat.Status == 5 {
		return "Awaiting approval"
	}
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
		style.Render(fit(gap(spaceXL)+"Start an agent turn from this prompt, or use /help for slash commands.", width)),
		style.Render(fit(gap(spaceXL)+"Tool calls, approvals, thinking, and usage will appear here as structured cards.", width)),
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
