package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	arrowLeft  rune = 57350
	arrowRight rune = 57351
	arrowUp    rune = 57352
	arrowDown  rune = 57353
)

const (
	themeEditorFG       byte = 0x02
	themeTreeBG         byte = 0x03
	themeTreeFG         byte = 0x04
	themeTreeSelectBG   byte = 0x05
	themeTreeHeaderBG   byte = 0x08
	themeTreeHeaderFG   byte = 0x09
	themeTabBG          byte = 0x10
	themeTabActiveBG    byte = 0x11
	themeTabActiveFG    byte = 0x12
	themeTabInactiveFG  byte = 0x13
	themeTabModifiedFG  byte = 0x14
	themeTabAttentionFG byte = 0x17
	themePopupSelBG     byte = 0x23
	themeBreadcrumbBG   byte = 0x27
	themeModelineBG     byte = 0x30
	themeModelineFG     byte = 0x31
	themeAccent         byte = 0x40
	themeWarningFG      byte = 0x53
)

type Model struct {
	width       int
	height      int
	out         chan<- []byte
	viewport    viewport.Model
	windows     map[uint16]protocol.WindowContent
	windowOrder []uint16
	chrome      map[byte]protocol.ChromePayload
	cells       map[position]cell
	cursorRow   uint16
	cursorCol   uint16
	cursorShape byte
	title       string
	bg          uint32
	lastError   string
}

type position struct {
	row uint16
	col uint16
}

type cell struct {
	text  string
	fg    uint32
	bg    uint32
	attrs uint16
}

func New(width, height uint16, out chan<- []byte) Model {
	vp := viewport.New(int(width), max(int(height)-3, 1))
	return Model{
		width:    int(width),
		height:   int(height),
		out:      out,
		viewport: vp,
		windows:  map[uint16]protocol.WindowContent{},
		chrome:   map[byte]protocol.ChromePayload{},
		cells:    map[position]cell{},
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.viewport.Width = msg.Width
		m.viewport.Height = m.bodyHeight()
		m.send(protocol.EncodeResize(uint16(max(msg.Width, 1)), uint16(max(msg.Height, 1))))
	case tea.KeyMsg:
		if packet, ok := keyPacket(msg); ok {
			m.send(packet)
		}
	case tea.MouseMsg:
		m.send(mousePacket(msg))
	case port.PacketMsg:
		m.applyCommands(msg.Commands)
	case port.ErrorMsg:
		m.lastError = msg.Err.Error()
	}

	m.viewport.Width = max(m.width, 1)
	m.viewport.Height = m.bodyHeight()
	m.viewport.SetContent(m.content())
	return m, nil
}

func (m Model) View() string {
	body := m.viewport.View()
	parts := append(m.headerLines(), body)
	parts = append(parts, m.footerLines()...)
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

func (m *Model) applyCommands(commands []protocol.Command) {
	for _, command := range commands {
		switch command.Kind {
		case protocol.CommandClear:
			m.windows = map[uint16]protocol.WindowContent{}
			m.windowOrder = nil
			m.cells = map[position]cell{}
		case protocol.CommandDrawText:
			m.applyDraw(command.Draw)
		case protocol.CommandSetCursor:
			m.cursorRow = command.CursorRow
			m.cursorCol = command.CursorCol
		case protocol.CommandSetCursorShape:
			m.cursorShape = command.CursorShape
		case protocol.CommandSetTitle:
			m.title = command.Title
		case protocol.CommandSetWindowBg:
			m.bg = command.WindowBg
		case protocol.CommandWindowContent:
			m.putWindow(command.Window)
		case protocol.CommandWindowDelta:
			m.applyWindowDelta(command.Window)
		case protocol.CommandChrome:
			m.chrome[command.Chrome.Opcode] = command.Chrome
		}
	}
}

func (m *Model) applyDraw(draw protocol.DrawText) {
	m.cells[position{row: draw.Row, col: draw.Col}] = cell{text: draw.Text, fg: draw.FG, bg: draw.BG, attrs: draw.Attrs}
}

func (m *Model) putWindow(window protocol.WindowContent) {
	if _, ok := m.windows[window.ID]; !ok {
		m.windowOrder = append(m.windowOrder, window.ID)
		sort.Slice(m.windowOrder, func(i, j int) bool { return m.windowOrder[i] < m.windowOrder[j] })
	}
	m.windows[window.ID] = window
	m.cursorRow = window.CursorRow
	m.cursorCol = window.CursorCol
	m.cursorShape = window.CursorShape
}

func (m *Model) applyWindowDelta(delta protocol.WindowContent) {
	window, ok := m.windows[delta.ID]
	if !ok {
		m.putWindow(delta)
		return
	}
	window.CursorRow = delta.CursorRow
	window.CursorCol = delta.CursorCol
	window.CursorShape = delta.CursorShape
	window.ContentEpoch = delta.ContentEpoch
	window.ScrollLeft = delta.ScrollLeft
	if len(delta.Rows) > 0 {
		window.Rows = resolveWindowRows(window.Rows, delta.Rows)
	}
	m.windows[delta.ID] = window
	m.cursorRow = delta.CursorRow
	m.cursorCol = delta.CursorCol
	m.cursorShape = delta.CursorShape
}

func resolveWindowRows(previous []protocol.WindowRow, delta []protocol.WindowRow) []protocol.WindowRow {
	byID := make(map[uint64]protocol.WindowRow, len(previous))
	for _, row := range previous {
		byID[row.ID] = row
	}
	rows := make([]protocol.WindowRow, 0, len(delta))
	for _, row := range delta {
		if row.Ref {
			if existing, ok := byID[row.ID]; ok && existing.ContentHash == row.ContentHash {
				rows = append(rows, existing)
			}
			continue
		}
		rows = append(rows, row)
	}
	return rows
}

func (m Model) content() string {
	if len(m.windows) > 0 {
		return strings.Join(m.withFileTree(m.semanticLines()), "\n")
	}
	return strings.Join(m.withFileTree(m.cellLines()), "\n")
}

func (m Model) semanticLines() []string {
	lines := make([]string, 0, m.height)
	for _, id := range m.windowOrder {
		window := m.windows[id]
		for _, row := range window.Rows {
			lines = append(lines, m.renderRow(row))
		}
	}
	if len(lines) == 0 {
		return nil
	}
	return lines
}

func (m Model) renderRow(row protocol.WindowRow) string {
	if len(row.Spans) == 0 {
		return row.Text
	}

	var builder strings.Builder
	for _, r := range row.Text {
		col := displayWidth(builder.String())
		span := spanAt(row.Spans, uint16(col))
		style := styleFor(span)
		builder.WriteString(style.Render(string(r)))
	}
	return builder.String()
}

func (m Model) cellLines() []string {
	rows := make([][]string, max(m.height-2, 1))
	for i := range rows {
		rows[i] = make([]string, max(m.width, 1))
		for j := range rows[i] {
			rows[i][j] = " "
		}
	}

	for pos, cell := range m.cells {
		if int(pos.row) < len(rows) && int(pos.col) < len(rows[pos.row]) {
			rows[pos.row][pos.col] = styleFor(protocol.Span{FG: cell.fg, BG: cell.bg, Attrs: byte(cell.attrs)}).Render(cell.text)
		}
	}

	rendered := make([]string, len(rows))
	for i, row := range rows {
		rendered[i] = strings.Join(row, "")
	}
	return rendered
}

func (m Model) withFileTree(mainLines []string) []string {
	tree, ok := m.fileTree()
	if !ok || !tree.Visible || len(tree.Rows) == 0 || m.width < 50 {
		return m.withSemanticSidebars(mainLines)
	}

	sidebarWidth := min(max(int(tree.Width), 24), max(m.width/3, 24))
	sidebar := m.renderFileTree(tree, sidebarWidth, max(len(mainLines), m.bodyHeight()))
	lines := make([]string, max(len(mainLines), len(sidebar)))
	for i := range lines {
		left := ""
		right := ""
		if i < len(sidebar) {
			left = sidebar[i]
		}
		if i < len(mainLines) {
			right = mainLines[i]
		}
		lines[i] = lipgloss.JoinHorizontal(lipgloss.Top, left, right)
	}
	return lines
}

func (m Model) withSemanticSidebars(mainLines []string) []string {
	sidebars, ok := m.sidebars()
	if !ok || len(sidebars.Items) == 0 || m.width < 60 {
		return mainLines
	}
	visible := make([]protocol.Sidebar, 0, len(sidebars.Items))
	for _, item := range sidebars.Items {
		if item.Visible {
			visible = append(visible, item)
		}
	}
	if len(visible) == 0 {
		return mainLines
	}
	width := min(max(int(visible[0].PreferredWidth), 18), max(m.width/4, 18))
	style := lipgloss.NewStyle().Foreground(m.color("muted", "#AEB7C2")).Background(m.color("surface", "#151820")).Width(width)
	activeStyle := style.Bold(true).Foreground(m.color("text", "#FFFFFF")).Background(m.color("selection", "#2D3A4D"))
	lines := make([]string, max(len(mainLines), len(visible)+1))
	lines[0] = lipgloss.JoinHorizontal(lipgloss.Top, style.Bold(true).Render(fit("Sidebars", width)), lineAt(mainLines, 0))
	for i, item := range visible {
		label := strings.TrimSpace(item.Icon + " " + item.DisplayName)
		if item.BadgeCount != 0xFFFF && item.BadgeCount > 0 {
			label += fmt.Sprintf(" %d", item.BadgeCount)
		}
		leftStyle := style
		if item.ID == sidebars.ActiveID || item.Focused {
			leftStyle = activeStyle
		}
		lines[i+1] = lipgloss.JoinHorizontal(lipgloss.Top, leftStyle.Render(fit(label, width)), lineAt(mainLines, i+1))
	}
	for i := len(visible) + 1; i < len(lines); i++ {
		lines[i] = lipgloss.JoinHorizontal(lipgloss.Top, style.Render(strings.Repeat(" ", width)), lineAt(mainLines, i))
	}
	return lines
}

func (m Model) renderFileTree(tree protocol.FileTree, width int, height int) []string {
	style := lipgloss.NewStyle().Foreground(m.color("treeText", "#AEB7C2")).Background(m.color("treeSurface", "#151820")).Width(width)
	selectedStyle := style.Foreground(m.color("text", "#E6EDF3")).Background(m.color("treeSelection", "#2D3A4D")).Bold(true)
	header := style.Bold(true).Foreground(m.color("treeHeaderText", "#C7D1FF")).Background(m.color("treeHeader", "#151820")).Render(fit("Files  "+tree.Root, width))
	lines := []string{header}
	for _, row := range tree.Rows {
		prefix := strings.Repeat("  ", int(row.Depth))
		marker := " "
		if row.Directory && row.Expanded {
			marker = "v"
		} else if row.Directory {
			marker = ">"
		}
		dirty := ""
		if row.Dirty {
			dirty = " *"
		}
		text := fit(fmt.Sprintf("%s%s %s %s%s", prefix, marker, row.Icon, row.Name, dirty), width)
		if row.Selected {
			lines = append(lines, selectedStyle.Render(text))
		} else {
			lines = append(lines, style.Render(text))
		}
		if len(lines) >= height {
			return lines
		}
	}
	for len(lines) < height {
		lines = append(lines, style.Render(strings.Repeat(" ", width)))
	}
	return lines
}

func (m Model) headerLines() []string {
	title := m.title
	if title == "" {
		title = "Minga"
	}
	if crumb, ok := m.breadcrumb(); ok && len(crumb.Segments) > 0 {
		title += "  " + strings.Join(crumb.Segments, " / ")
	}

	lines := []string{
		lipgloss.NewStyle().Bold(true).Foreground(m.color("accent", "#C7D1FF")).Background(m.color("surface", "#20242C")).Width(m.width).Render(title),
	}
	if spaces, ok := m.workspaceBar(); ok && len(spaces.Spaces) > 0 {
		lines = append(lines, m.renderWorkspaces(spaces))
	}
	if tabBar, ok := m.tabBar(); ok && len(tabBar.Tabs) > 0 {
		lines = append(lines, m.renderTabs(tabBar))
	}
	if git, ok := m.gitStatus(); ok && git.Branch != "" {
		lines = append(lines, m.renderGitStatus(git))
	}
	return lines
}

func (m Model) renderWorkspaces(spaces protocol.WorkspaceBar) string {
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(m.color("tabActiveText", "#FFFFFF")).Background(m.color("selection", "#2F4052")).Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().Foreground(m.color("tabInactiveText", "#AEB7C2")).Background(m.color("surfaceAlt", "#171B22")).Padding(0, 1)
	alertStyle := lipgloss.NewStyle().Foreground(m.color("warning", "#EBCB8B"))
	rendered := make([]string, 0, len(spaces.Spaces))
	for _, space := range spaces.Spaces {
		label := strings.TrimSpace(space.Icon + " " + space.Label)
		if space.TabCount > 0 {
			label += fmt.Sprintf(" %d", space.TabCount)
		}
		if space.DraftCount > 0 {
			label += alertStyle.Render(fmt.Sprintf(" D%d", space.DraftCount))
		}
		if space.ConflictCount > 0 {
			label += alertStyle.Render(fmt.Sprintf(" C%d", space.ConflictCount))
		}
		if space.BackgroundCount > 0 {
			label += alertStyle.Render(fmt.Sprintf(" B%d", space.BackgroundCount))
		}
		if space.Attention {
			label += alertStyle.Render(" !")
		}
		style := inactiveStyle
		if space.Active {
			style = activeStyle
		}
		rendered = append(rendered, style.Render(label))
	}
	return lipgloss.NewStyle().Background(m.color("surfaceAlt", "#171B22")).Width(m.width).Render(strings.Join(rendered, ""))
}

func (m Model) renderTabs(tabBar protocol.TabBar) string {
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(m.color("tabActiveText", "#FFFFFF")).Background(m.color("tabActive", "#35415A")).Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().Foreground(m.color("tabInactiveText", "#AEB7C2")).Background(m.color("surface", "#20242C")).Padding(0, 1)
	dirtyStyle := lipgloss.NewStyle().Foreground(m.color("tabDirty", "#EBCB8B"))
	rendered := make([]string, 0, len(tabBar.Tabs))
	for _, tab := range tabBar.Tabs {
		label := strings.TrimSpace(tab.Icon + " " + tab.Label)
		if tab.Dirty {
			label += dirtyStyle.Render(" *")
		}
		if tab.Attention {
			label += lipgloss.NewStyle().Foreground(m.color("tabAttention", "#EBCB8B")).Render(" !")
		}
		style := inactiveStyle
		if tab.Active {
			style = activeStyle
		}
		rendered = append(rendered, style.Render(label))
	}
	return lipgloss.NewStyle().Background(m.color("surface", "#20242C")).Width(m.width).Render(strings.Join(rendered, ""))
}

func (m Model) footerLines() []string {
	status := fmt.Sprintf("row %d col %d", m.cursorRow+1, m.cursorCol+1)
	if chromeStatus, ok := m.statusBar(); ok && chromeStatus.Filename != "" {
		status = fmt.Sprintf("%s  %d:%d", chromeStatus.Filename, chromeStatus.Line, chromeStatus.Column)
		if chromeStatus.Message != "" {
			status += "  " + chromeStatus.Message
		}
	}
	if m.lastError != "" {
		status = m.lastError
	}
	if search, ok := m.searchState(); ok && search.Active {
		status += fmt.Sprintf("  search %d/%d", search.CurrentIndex, search.Count)
	}
	if changes, ok := m.changeSummary(); ok && changes.Visible && len(changes.Entries) > 0 {
		status += fmt.Sprintf("  changes %d", len(changes.Entries))
	}
	lines := []string{
		lipgloss.NewStyle().Foreground(m.color("muted", "#9AA4B2")).Background(m.color("base", "#16181D")).Width(m.width).Render(status),
	}
	overlay := m.overlayLines()
	if len(overlay) > 0 {
		lines = append(lines, overlay...)
	} else if mini, ok := m.minibuffer(); ok && mini.Visible {
		lines = append(lines, m.renderMinibuffer(mini))
	}
	return lines
}

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

func (m Model) renderGitStatus(git protocol.GitStatus) string {
	parts := []string{"git " + git.Branch}
	if git.Syncing {
		parts = append(parts, "syncing")
	}
	if git.Ahead > 0 {
		parts = append(parts, fmt.Sprintf("ahead %d", git.Ahead))
	}
	if git.Behind > 0 {
		parts = append(parts, fmt.Sprintf("behind %d", git.Behind))
	}
	if len(git.Entries) > 0 {
		parts = append(parts, fmt.Sprintf("%d files", len(git.Entries)))
	}
	if git.Toast.Visible && git.Toast.Message != "" {
		parts = append(parts, git.Toast.Message)
	}
	return lipgloss.NewStyle().Foreground(m.color("muted", "#AEB7C2")).Background(m.color("surfaceAlt", "#171B22")).Width(m.width).Render(fit(strings.Join(parts, "  "), m.width))
}

func (m Model) renderHover(hover protocol.HoverPopup) []string {
	style := m.panelStyle()
	title := fmt.Sprintf("Hover %d:%d", hover.AnchorRow+1, hover.AnchorCol+1)
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit(title, m.width))}
	for _, line := range hover.Lines[:min(len(hover.Lines), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(renderRichLine(line), m.width)))
	}
	if action, ok := m.hoverAction(); ok && action.Visible {
		lines = append(lines, style.Foreground(m.color("accent", "#C7D1FF")).Render(fit(action.Name, m.width)))
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderSignature(sig protocol.SignatureHelp) []string {
	style := m.panelStyle()
	active := sig.Signatures[min(int(sig.ActiveSignature), len(sig.Signatures)-1)]
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit(active.Label, m.width))}
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
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit(title, m.width))}
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
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit(title, m.width))}
	if chat.ThinkingLevel != "" {
		lines = append(lines, style.Render(fit("thinking "+chat.ThinkingLevel, m.width)))
	}
	if chat.Pending != "" {
		lines = append(lines, style.Foreground(m.color("warning", "#EBCB8B")).Render(fit("approval "+chat.Pending, m.width)))
	}
	start := max(len(chat.Messages)-max(m.maxOverlayHeight()+1, 1), 0)
	for _, msg := range chat.Messages[start:] {
		prefix := agentMessagePrefix(msg.Kind)
		lines = append(lines, style.Render(fit(prefix+" "+msg.Text, m.width)))
	}
	if chat.Prompt != "" {
		lines = append(lines, style.Foreground(m.color("muted", "#AEB7C2")).Render(fit("> "+chat.Prompt, m.width)))
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderBoard(board protocol.Board) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit(fmt.Sprintf("Board  %d cards", len(board.Cards)), m.width))}
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
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit(title, m.width))}
	for _, msg := range panel.Messages[:min(len(panel.Messages), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(strings.TrimSpace(msg.Path+"  "+msg.Text), m.width)))
	}
	return lines
}

func (m Model) renderExtensionPanels(ext protocol.ExtensionPanel) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit("Extensions", m.width))}
	for _, panel := range ext.Panels {
		if !panel.Visible {
			continue
		}
		lines = append(lines, style.Render(fit(panel.Title, m.width)))
		for _, block := range panel.Blocks[:min(len(panel.Blocks), 2)] {
			lines = append(lines, style.Foreground(m.color("muted", "#AEB7C2")).Render(fit(block, m.width)))
		}
		if len(lines) >= m.maxOverlayHeight() {
			break
		}
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderObservatory(obs protocol.Observatory) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit(fmt.Sprintf("Observatory  %d processes", max(int(obs.Count), len(obs.Nodes))), m.width))}
	for _, node := range obs.Nodes[:min(len(obs.Nodes), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(strings.Repeat("  ", int(node.Depth))+node.Name, m.width)))
	}
	return lines
}

func (m Model) renderEditTimeline(timeline protocol.EditTimeline) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit("Edit timeline", m.width))}
	for _, entry := range timeline.Entries[:min(len(timeline.Entries), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(fmt.Sprintf("%d  %s", entry.Index, entry.ToolName), m.width)))
	}
	return lines
}

func (m Model) renderNotifications(notes protocol.Notifications) []string {
	style := m.panelStyle()
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit("Notifications", m.width))}
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
	lines := []string{style.Bold(true).Foreground(m.color("accent", "#C7D1FF")).Render(fit("Extension overlays", m.width))}
	for _, entry := range overlay.Entries[:min(len(overlay.Entries), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(fmt.Sprintf("%s %d:%d %s", entry.Extension, entry.Row+1, entry.Col+1, entry.Content), m.width)))
	}
	return lines
}

func (m Model) renderMinibuffer(mini protocol.Minibuffer) string {
	value := strings.TrimSpace(mini.Prompt + mini.Input)
	if mini.Context != "" {
		value += "  " + mini.Context
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color("#D8DEE9")).Background(lipgloss.Color("#101318")).Width(m.width).Render(value)
}

func (m Model) renderCompletion(completion protocol.Completion) []string {
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#D8DEE9")).Background(lipgloss.Color("#101318")).Width(m.width)
	selectedStyle := style.Bold(true).Foreground(lipgloss.Color("#FFFFFF")).Background(lipgloss.Color("#30445C"))
	limit := min(len(completion.Items), m.maxOverlayHeight())
	lines := make([]string, 0, limit)
	for i, item := range completion.Items[:limit] {
		detail := item.Detail
		if detail != "" {
			detail = "  " + detail
		}
		text := fit(item.Label+detail, m.width)
		if uint16(i) == completion.Selected {
			lines = append(lines, selectedStyle.Render(text))
		} else {
			lines = append(lines, style.Render(text))
		}
	}
	return lines
}

func (m Model) renderWhichKey(which protocol.WhichKey) []string {
	title := "Keys"
	if which.Prefix != "" {
		title += " " + which.Prefix
	}
	if which.PageCount > 1 {
		title += fmt.Sprintf("  %d/%d", which.Page+1, which.PageCount)
	}
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#B8C0CC")).Background(lipgloss.Color("#111720")).Width(m.width)
	lines := []string{style.Bold(true).Foreground(lipgloss.Color("#C7D1FF")).Render(fit(title, m.width))}
	limit := min(len(which.Bindings), max(m.maxOverlayHeight()-1, 0))
	for _, binding := range which.Bindings[:limit] {
		label := strings.TrimSpace(binding.Icon + " " + binding.Description)
		text := fit(binding.Key+"  "+label, m.width)
		lines = append(lines, style.Render(text))
	}
	return lines
}

func (m Model) renderPicker(picker protocol.Picker, preview protocol.PickerPreview) []string {
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#D8DEE9")).Background(lipgloss.Color("#101318")).Width(m.width)
	selectedStyle := style.Bold(true).Foreground(lipgloss.Color("#FFFFFF")).Background(lipgloss.Color("#30445C"))
	title := picker.Title
	if picker.Query != "" {
		title += "  " + picker.Query
	}
	if picker.Marked > 0 {
		title += fmt.Sprintf("  marked %d", picker.Marked)
	}
	if picker.LoadStatus == 1 {
		title += "  loading"
	} else if picker.LoadStatus == 2 && picker.LoadError != "" {
		title += "  " + picker.LoadError
	}

	lines := []string{style.Bold(true).Foreground(lipgloss.Color("#C7D1FF")).Render(fit(title, m.width))}
	itemBudget := max(m.maxOverlayHeight()-1, 1)
	if preview.Visible && len(preview.Lines) > 0 && m.width < 100 {
		itemBudget = max(itemBudget/2, 1)
	}
	limit := min(len(picker.Items), itemBudget)
	for i, item := range picker.Items[:limit] {
		marker := " "
		if item.Marked {
			marker = "*"
		}
		detail := item.Description
		if detail == "" {
			detail = item.Annotation
		}
		if detail != "" {
			detail = "  " + detail
		}
		text := fit(marker+" "+item.Label+detail, m.width)
		if uint16(i) == picker.Selected {
			lines = append(lines, selectedStyle.Render(text))
		} else {
			lines = append(lines, style.Render(text))
		}
	}
	if picker.ActionVisible && len(picker.Actions) > 0 {
		lines = append(lines, style.Foreground(lipgloss.Color("#AEB7C2")).Render(fit(strings.Join(picker.Actions, "  "), m.width)))
	}
	if preview.Visible && len(preview.Lines) > 0 {
		if m.width >= 100 {
			return m.renderPickerWithSidePreview(lines, preview)
		}
		lines = append(lines, m.renderPickerPreview(preview, max(m.maxOverlayHeight()-len(lines), 1), m.width)...)
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderPickerWithSidePreview(left []string, preview protocol.PickerPreview) []string {
	leftWidth := max(m.width*45/100, 36)
	rightWidth := max(m.width-leftWidth, 20)
	leftStyle := lipgloss.NewStyle().Width(leftWidth)
	right := m.renderPickerPreview(preview, max(m.maxOverlayHeight(), len(left)), rightWidth)
	height := min(max(len(left), len(right)), m.maxOverlayHeight())
	lines := make([]string, 0, height)
	for i := 0; i < height; i++ {
		leftLine := ""
		if i < len(left) {
			leftLine = left[i]
		}
		rightLine := ""
		if i < len(right) {
			rightLine = right[i]
		}
		lines = append(lines, lipgloss.JoinHorizontal(lipgloss.Top, leftStyle.Render(leftLine), rightLine))
	}
	return lines
}

func (m Model) renderPickerPreview(preview protocol.PickerPreview, height int, width int) []string {
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#AEB7C2")).Background(lipgloss.Color("#111720")).Width(width)
	limit := min(len(preview.Lines), max(height-1, 0))
	lines := []string{style.Bold(true).Foreground(lipgloss.Color("#C7D1FF")).Render(fit("Preview", width))}
	for _, line := range preview.Lines[:limit] {
		var builder strings.Builder
		for _, segment := range line.Segments {
			segmentStyle := lipgloss.NewStyle()
			if segment.FG != 0 {
				segmentStyle = segmentStyle.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", segment.FG)))
			}
			if segment.Bold {
				segmentStyle = segmentStyle.Bold(true)
			}
			builder.WriteString(segmentStyle.Render(segment.Text))
		}
		lines = append(lines, style.Render(fit(builder.String(), width)))
	}
	return lines
}

func (m Model) bodyHeight() int {
	return max(m.height-len(m.headerLines())-len(m.footerLines()), 1)
}

func (m Model) maxOverlayHeight() int {
	return min(max(m.height/3, 4), 12)
}

func (m Model) workspaceBar() (protocol.WorkspaceBar, bool) {
	for _, payload := range m.chrome {
		if len(payload.Spaces.Spaces) > 0 {
			return payload.Spaces, true
		}
	}
	return protocol.WorkspaceBar{}, false
}

func (m Model) tabBar() (protocol.TabBar, bool) {
	for _, payload := range m.chrome {
		if len(payload.Tabs.Tabs) > 0 {
			return payload.Tabs, true
		}
	}
	return protocol.TabBar{}, false
}

func (m Model) minibuffer() (protocol.Minibuffer, bool) {
	for _, payload := range m.chrome {
		if payload.Mini.Visible {
			return payload.Mini, true
		}
	}
	return protocol.Minibuffer{}, false
}

func (m Model) completion() (protocol.Completion, bool) {
	for _, payload := range m.chrome {
		if payload.Complete.Visible {
			return payload.Complete, true
		}
	}
	return protocol.Completion{}, false
}

func (m Model) whichKey() (protocol.WhichKey, bool) {
	for _, payload := range m.chrome {
		if payload.Which.Visible {
			return payload.Which, true
		}
	}
	return protocol.WhichKey{}, false
}

func (m Model) picker() (protocol.Picker, bool) {
	for _, payload := range m.chrome {
		if payload.Picker.Visible {
			return payload.Picker, true
		}
	}
	return protocol.Picker{}, false
}

func (m Model) pickerPreview() (protocol.PickerPreview, bool) {
	for _, payload := range m.chrome {
		if payload.Preview.Visible {
			return payload.Preview, true
		}
	}
	return protocol.PickerPreview{}, false
}

func (m Model) fileTree() (protocol.FileTree, bool) {
	for _, payload := range m.chrome {
		if payload.Tree.Visible || len(payload.Tree.Rows) > 0 {
			return payload.Tree, true
		}
	}
	return protocol.FileTree{}, false
}

func (m Model) statusBar() (protocol.StatusBar, bool) {
	for _, payload := range m.chrome {
		if payload.Status.Filename != "" || payload.Status.Message != "" || payload.Status.Line != 0 {
			return payload.Status, true
		}
	}
	return protocol.StatusBar{}, false
}

func (m Model) breadcrumb() (protocol.Breadcrumb, bool) {
	for _, payload := range m.chrome {
		if len(payload.Breadcrumb.Segments) > 0 {
			return payload.Breadcrumb, true
		}
	}
	return protocol.Breadcrumb{}, false
}

func (m Model) gitStatus() (protocol.GitStatus, bool) {
	for _, payload := range m.chrome {
		if payload.Git.Branch != "" || len(payload.Git.Entries) > 0 {
			return payload.Git, true
		}
	}
	return protocol.GitStatus{}, false
}

func (m Model) searchState() (protocol.SearchState, bool) {
	for _, payload := range m.chrome {
		if payload.Search.Active {
			return payload.Search, true
		}
	}
	return protocol.SearchState{}, false
}

func (m Model) changeSummary() (protocol.ChangeSummary, bool) {
	for _, payload := range m.chrome {
		if payload.Change.Visible || len(payload.Change.Entries) > 0 {
			return payload.Change, true
		}
	}
	return protocol.ChangeSummary{}, false
}

func (m Model) hoverPopup() (protocol.HoverPopup, bool) {
	for _, payload := range m.chrome {
		if payload.Hover.Visible {
			return payload.Hover, true
		}
	}
	return protocol.HoverPopup{}, false
}

func (m Model) hoverAction() (protocol.HoverAction, bool) {
	for _, payload := range m.chrome {
		if payload.HoverAction.Visible {
			return payload.HoverAction, true
		}
	}
	return protocol.HoverAction{}, false
}

func (m Model) signatureHelp() (protocol.SignatureHelp, bool) {
	for _, payload := range m.chrome {
		if payload.Signature.Visible {
			return payload.Signature, true
		}
	}
	return protocol.SignatureHelp{}, false
}

func (m Model) floatPopup() (protocol.FloatPopup, bool) {
	for _, payload := range m.chrome {
		if payload.Float.Visible {
			return payload.Float, true
		}
	}
	return protocol.FloatPopup{}, false
}

func (m Model) extensionOverlay() (protocol.ExtensionOverlay, bool) {
	for _, payload := range m.chrome {
		if len(payload.Overlay.Entries) > 0 {
			return payload.Overlay, true
		}
	}
	return protocol.ExtensionOverlay{}, false
}

func (m Model) notifications() (protocol.Notifications, bool) {
	for _, payload := range m.chrome {
		if payload.Notifications.Visible || len(payload.Notifications.Items) > 0 {
			return payload.Notifications, true
		}
	}
	return protocol.Notifications{}, false
}

func (m Model) bottomPanel() (protocol.BottomPanel, bool) {
	for _, payload := range m.chrome {
		if payload.Bottom.Visible {
			return payload.Bottom, true
		}
	}
	return protocol.BottomPanel{}, false
}

func (m Model) extensionPanel() (protocol.ExtensionPanel, bool) {
	for _, payload := range m.chrome {
		if len(payload.Extensions.Panels) > 0 {
			return payload.Extensions, true
		}
	}
	return protocol.ExtensionPanel{}, false
}

func (m Model) sidebars() (protocol.Sidebars, bool) {
	for _, payload := range m.chrome {
		if payload.Sidebars.Visible || len(payload.Sidebars.Items) > 0 {
			return payload.Sidebars, true
		}
	}
	return protocol.Sidebars{}, false
}

func (m Model) observatory() (protocol.Observatory, bool) {
	for _, payload := range m.chrome {
		if payload.Observatory.Visible || len(payload.Observatory.Nodes) > 0 {
			return payload.Observatory, true
		}
	}
	return protocol.Observatory{}, false
}

func (m Model) agentChat() (protocol.AgentChat, bool) {
	for _, payload := range m.chrome {
		if payload.AgentChat.Visible {
			return payload.AgentChat, true
		}
	}
	return protocol.AgentChat{}, false
}

func (m Model) board() (protocol.Board, bool) {
	for _, payload := range m.chrome {
		if payload.Board.Visible {
			return payload.Board, true
		}
	}
	return protocol.Board{}, false
}

func (m Model) editTimeline() (protocol.EditTimeline, bool) {
	for _, payload := range m.chrome {
		if payload.Timeline.Visible {
			return payload.Timeline, true
		}
	}
	return protocol.EditTimeline{}, false
}

func (m Model) send(payload []byte) {
	if m.out != nil {
		m.out <- payload
	}
}

func keyPacket(msg tea.KeyMsg) ([]byte, bool) {
	switch msg.Type {
	case tea.KeyCtrlC:
		return protocol.EncodeKeyPress('c', protocol.ModCtrl), true
	case tea.KeyEnter:
		return protocol.EncodeKeyPress(13, 0), true
	case tea.KeyBackspace:
		return protocol.EncodeKeyPress(127, 0), true
	case tea.KeyEsc:
		return protocol.EncodeKeyPress(27, 0), true
	case tea.KeyTab:
		return protocol.EncodeKeyPress(9, 0), true
	case tea.KeyUp:
		return protocol.EncodeKeyPress(arrowUp, 0), true
	case tea.KeyDown:
		return protocol.EncodeKeyPress(arrowDown, 0), true
	case tea.KeyLeft:
		return protocol.EncodeKeyPress(arrowLeft, 0), true
	case tea.KeyRight:
		return protocol.EncodeKeyPress(arrowRight, 0), true
	case tea.KeyRunes:
		runes := msg.Runes
		if len(runes) == 1 {
			return protocol.EncodeKeyPress(runes[0], keyModifiers(msg)), true
		}
		if len(runes) > 1 {
			return protocol.EncodePaste(string(runes)), true
		}
	}
	return nil, false
}

func keyModifiers(msg tea.KeyMsg) byte {
	var mods byte
	if msg.Alt {
		mods |= protocol.ModAlt
	}
	return mods
}

func mousePacket(msg tea.MouseMsg) []byte {
	button := byte(3)
	eventType := byte(0)
	switch msg.Button {
	case tea.MouseButtonLeft:
		button = 0
	case tea.MouseButtonMiddle:
		button = 1
	case tea.MouseButtonRight:
		button = 2
	case tea.MouseButtonWheelUp:
		button = 0x40
	case tea.MouseButtonWheelDown:
		button = 0x41
	}
	if msg.Action == tea.MouseActionRelease {
		eventType = 1
	} else if msg.Action == tea.MouseActionMotion {
		eventType = 2
	}
	return protocol.EncodeMouseEvent(int16(msg.Y), int16(msg.X), button, 0, eventType, 1)
}

func spanAt(spans []protocol.Span, col uint16) protocol.Span {
	for _, span := range spans {
		if col >= span.StartCol && col < span.EndCol {
			return span
		}
	}
	return protocol.Span{FG: 0xFFFFFF}
}

func styleFor(span protocol.Span) lipgloss.Style {
	style := lipgloss.NewStyle()
	if span.FG != 0 {
		style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", span.FG)))
	}
	if span.BG != 0 {
		style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", span.BG)))
	}
	if span.Attrs&0x01 != 0 {
		style = style.Bold(true)
	}
	if span.Attrs&0x02 != 0 {
		style = style.Italic(true)
	}
	if span.Attrs&0x04 != 0 {
		style = style.Underline(true)
	}
	if span.Attrs&0x08 != 0 {
		style = style.Reverse(true)
	}
	return style
}

func (m Model) color(name string, fallback string) lipgloss.Color {
	slot := map[string]byte{
		"base":            themeModelineBG,
		"surface":         themeTabBG,
		"surfaceAlt":      themeBreadcrumbBG,
		"text":            themeEditorFG,
		"treeSurface":     themeTreeBG,
		"treeText":        themeTreeFG,
		"treeSelection":   themeTreeSelectBG,
		"treeHeader":      themeTreeHeaderBG,
		"treeHeaderText":  themeTreeHeaderFG,
		"muted":           themeModelineFG,
		"accent":          themeAccent,
		"selection":       themePopupSelBG,
		"warning":         themeWarningFG,
		"tabActive":       themeTabActiveBG,
		"tabActiveText":   themeTabActiveFG,
		"tabInactiveText": themeTabInactiveFG,
		"tabDirty":        themeTabModifiedFG,
		"tabAttention":    themeTabAttentionFG,
	}[name]
	for _, payload := range m.chrome {
		if payload.Theme.Colors != nil {
			if rgb, ok := payload.Theme.Colors[slot]; ok {
				return lipgloss.Color(fmt.Sprintf("#%06X", rgb))
			}
		}
	}
	return lipgloss.Color(fallback)
}

func (m Model) panelStyle() lipgloss.Style {
	return lipgloss.NewStyle().Foreground(m.color("text", "#D8DEE9")).Background(m.color("base", "#101318")).Width(m.width)
}

func lineAt(lines []string, index int) string {
	if index >= 0 && index < len(lines) {
		return lines[index]
	}
	return ""
}

func renderRichLine(line protocol.RichLine) string {
	parts := make([]string, 0, len(line.Segments))
	for _, segment := range line.Segments {
		parts = append(parts, segment.Text)
	}
	return strings.Join(parts, "")
}

func agentMessagePrefix(kind byte) string {
	switch kind {
	case 0x01:
		return "you"
	case 0x02, 0x07:
		return "assistant"
	case 0x03:
		return "thinking"
	case 0x04, 0x08:
		return "tool"
	case 0x05:
		return "system"
	case 0x06:
		return "usage"
	case 0x09:
		return "approval"
	default:
		return "message"
	}
}

func statusName(status byte) string {
	switch status {
	case 0:
		return "idle"
	case 1:
		return "working"
	case 2:
		return "iterating"
	case 3:
		return "needs you"
	case 4:
		return "done"
	case 5:
		return "error"
	default:
		return "unknown"
	}
}

func displayWidth(value string) int {
	width := 0
	for range value {
		width++
	}
	return width
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func fit(value string, width int) string {
	if width <= 0 {
		return ""
	}
	if displayWidth(value) <= width {
		return value + strings.Repeat(" ", width-displayWidth(value))
	}
	runes := []rune(value)
	if len(runes) <= width {
		return value
	}
	return string(runes[:width])
}

func takeLines(lines []string, limit int) []string {
	if len(lines) <= limit {
		return lines
	}
	return lines[:limit]
}
