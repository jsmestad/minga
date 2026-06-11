package ui

import (
	"fmt"
	"image/color"
	"strings"

	"charm.land/bubbles/v2/table"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// Registry surface ids (mirror MingaEditor.Layout.SurfaceRegistry.surface_id_u16/1).
// Only the overlay surfaces the BEAM registry actually places are listed here;
// the rest of the overlay candidates are not yet promoted into the registry
// (transitional split, #2268; follow-up #2281 promotes them).
const (
	surfaceIDBottomPanel    uint16 = 12
	surfaceIDCompletionMenu uint16 = 16
)

// overlayCandidate is one floating surface that may occupy the single active
// overlay slot. order is its stacking key on one comparable z-band scale: lower
// paints further back, so the HIGHEST-order visible candidate wins. For surfaces
// the BEAM registry places, order is the BEAM-authoritative placement z (data,
// looked up by surfaceID). For not-yet-promoted surfaces it is a transitional
// order derived from the same registry z bands at its old relative position, so
// the two are directly comparable. Either way the precedence is no longer a
// hardcoded if-ladder: it is sorted data.
type overlayCandidate struct {
	visible bool
	order   int
	render  func() []string
}

// overlayLines returns the single active overlay's lines (the BEAM emits a
// single-active-overlay decision; multiple simultaneous overlays remain out of
// scope, #2268 AC-4). The precedence chain is deleted: candidates are collected
// and the front-most visible one (highest order) wins, where a placed surface's
// order is its gui_surface_layout z and an unplaced surface's order is a
// documented transitional rank.
func (m Model) overlayLines() []string {
	candidates := m.overlayCandidates()

	best := -1
	var winner func() []string
	for _, c := range candidates {
		if c.visible && c.order > best {
			best = c.order
			winner = c.render
		}
	}
	if winner == nil {
		return nil
	}
	return winner()
}

// overlayCandidates lists every floating overlay surface with its stacking
// order on ONE comparable scale. Placed surfaces (completion, bottom panel) use
// their BEAM placement z directly; the not-yet-promoted surfaces use
// transitional orders derived from the same registry z bands, slotted at their
// old relative positions, until each is promoted into the BEAM surface registry
// (#2281). Because everything shares the band scale, the old top-to-bottom
// precedence is preserved exactly: completion (overlay band, top) > the six
// floating overlays that historically sat above the bottom panel > bottom panel
// (floating band, z=200) > the lower transitional set.
func (m Model) overlayCandidates() []overlayCandidate {
	completion, completionOK := m.completion()
	hover, hoverOK := m.hoverPopup()
	sig, sigOK := m.signatureHelp()
	float, floatOK := m.floatPopup()
	context, contextOK := m.agentContext()
	chat, chatOK := m.agentChat()
	tools, toolsOK := m.toolManager()
	bottom, bottomOK := m.bottomPanel()
	ext, extOK := m.extensionPanel()
	obs, obsOK := m.observatory()
	timeline, timelineOK := m.editTimeline()
	notes, notesOK := m.notifications()
	overlay, overlayOK := m.extensionOverlay()

	return []overlayCandidate{
		// Completion is registry-placed in the overlay band (z=301): it sits at the
		// top, beating every transitional overlay below the overlay band, exactly
		// as the old chain listed it first. Fallback orderOverlayTop is used only
		// when the BEAM emits no placement for it (older BEAM / absent this frame).
		{
			visible: completionOK && completion.Visible && len(completion.Items) > 0,
			order:   m.surfaceOrder(surfaceIDCompletionMenu, orderOverlayTop),
			render:  func() []string { return m.renderCompletion(completion) },
		},
		// ── transitional overlays that historically sat ABOVE the bottom panel ──
		// These live between the floating band (200) and the overlay band (300),
		// preserving their old relative order: hover > signature > float >
		// agentContext > agentChat > toolManager.
		{visible: hoverOK && hover.Visible && len(hover.Lines) > 0, order: orderHover, render: func() []string { return m.renderHover(hover) }},
		{visible: sigOK && sig.Visible && len(sig.Signatures) > 0, order: orderSignatureHelp, render: func() []string { return m.renderSignature(sig) }},
		{visible: floatOK && float.Visible, order: orderFloatPopup, render: func() []string { return m.renderFloat(float) }},
		{visible: contextOK && context.Visible, order: orderAgentContext, render: func() []string { return m.renderAgentContext(context) }},
		{visible: chatOK && chat.Visible, order: orderAgentChat, render: func() []string { return m.renderAgentChat(chat) }},
		{visible: toolsOK && tools.Visible, order: orderToolManager, render: func() []string { return m.renderToolManager(tools) }},
		// Bottom panel is registry-placed in the floating band (z=200): it sits
		// BELOW the six overlays above and ABOVE the lower transitional set, exactly
		// as the old chain ordered it. Fallback orderBottomPanelFallback keeps that
		// relative position when no placement is emitted.
		{
			visible: bottomOK && bottom.Visible,
			order:   m.surfaceOrder(surfaceIDBottomPanel, orderBottomPanelFallback),
			render:  func() []string { return m.renderBottomPanel(bottom) },
		},
		// ── transitional overlays that historically sat BELOW the bottom panel ──
		// Below the floating band (200), preserving their old relative order.
		{visible: extOK && len(ext.Panels) > 0, order: orderExtensionPanel, render: func() []string { return m.renderExtensionPanels(ext) }},
		{visible: obsOK && obs.Visible, order: orderObservatory, render: func() []string { return m.renderObservatory(obs) }},
		{visible: timelineOK && timeline.Visible, order: orderEditTimeline, render: func() []string { return m.renderEditTimeline(timeline) }},
		{visible: notesOK && notes.Visible && len(notes.Items) > 0, order: orderNotifications, render: func() []string { return m.renderNotifications(notes) }},
		{visible: overlayOK && len(overlay.Entries) > 0, order: orderExtensionOverlay, render: func() []string { return m.renderExtensionOverlay(overlay) }},
	}
}

// surfaceOrder returns the BEAM placement z for a registry-placed surface, used
// directly on the shared band scale, or the transitional fallback when the BEAM
// has not (yet) emitted a placement for it (older BEAM, or the surface absent
// from this frame's layout). The placement z and the transitional orders below
// are derived from the SAME registry z bands, so a placed surface's data z and
// an unplaced surface's transitional order are comparable on one scale.
func (m Model) surfaceOrder(surfaceID uint16, fallback int) int {
	for _, p := range m.surfacePlacements {
		if p.SurfaceID == surfaceID {
			return int(p.Z)
		}
	}
	return fallback
}

// Transitional stacking orders for the not-yet-promoted overlay surfaces (#2281
// deletes this whole table once they are promoted/placed). They are derived from
// the registry z bands in MingaEditor.Layout.SurfaceRegistry (base 0 / editor
// 100 / floating 200 / overlay 300; bottom_panel emits z=200, completion_menu
// emits z=300+1). Go cannot import the Elixir bands, so this coupling is
// documented explicitly: keep these values in step with surface_registry.ex.
//
// Scale, highest paints front-most:
//   - completion (placed, overlay band, z=301) sits on top.
//   - the six overlays that historically sat above the bottom panel occupy
//     210..290, between the floating band (200) and the overlay band (300),
//     preserving their old relative order.
//   - bottom_panel (placed, floating band, z=200) sits below those six.
//   - the lower transitional set occupies 150..199, below the floating band,
//     preserving its old relative order.
const (
	// Above the bottom panel (200) and below the overlay band (300).
	orderHover         = 290
	orderSignatureHelp = 280
	orderFloatPopup    = 270
	orderAgentContext  = 260
	orderAgentChat     = 250
	orderToolManager   = 240

	// Below the bottom panel (200).
	orderExtensionPanel   = 190
	orderObservatory      = 180
	orderEditTimeline     = 170
	orderNotifications    = 160
	orderExtensionOverlay = 150

	// orderOverlayTop is the fallback for completion when the BEAM emits no
	// placement: it must outrank every transitional order, matching the live
	// completion_menu z (overlay band + 1 = 301).
	orderOverlayTop = 301

	// orderBottomPanelFallback is the fallback for the bottom panel when the BEAM
	// emits no placement: it sits at the floating band (200), keeping the bottom
	// panel below the six overlays above and above the lower transitional set,
	// exactly as the old chain ordered it.
	orderBottomPanelFallback = 200
)

func (m Model) renderHover(hover protocol.HoverPopup) []string {
	style := m.panelStyle()
	title := fmt.Sprintf("Hover %d:%d", hover.AnchorRow+1, hover.AnchorCol+1)
	lines := []string{style.Bold(true).Foreground(m.palette().Accent()).Render(fit(title, m.width))}
	for _, line := range hover.Lines[:min(len(hover.Lines), max(m.maxOverlayHeight()-1, 0))] {
		lines = append(lines, style.Render(fit(renderRichLine(line), m.width)))
	}
	if action, ok := m.hoverAction(); ok && action.Visible {
		rendered := style.Foreground(m.palette().Accent()).Render(fit(action.Name, m.width))
		lines = append(lines, m.zones.Mark(zoneIDHoverAction, rendered))
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

func (m Model) renderBottomPanel(panel protocol.BottomPanel) []string {
	title := "Panel"
	if len(panel.Tabs) > int(panel.ActiveTab) {
		title = panel.Tabs[panel.ActiveTab].Name
	}
	messages := m.visibleBottomPanelMessages(panel)
	width := max(m.width, 1)
	height := m.bottomPanelHeight(panel)
	p := m.palette()
	headerLeft := fmt.Sprintf(" %s", title)
	headerRight := fmt.Sprintf("%d messages", len(panel.Messages))
	if m.bottomPanelScrollback > 0 {
		headerRight += fmt.Sprintf("  ↑%d", m.bottomPanelScrollback)
	}
	leftText := lipgloss.NewStyle().Bold(true).Foreground(p.Accent()).Background(p.PopupChrome()).Render(headerLeft)
	rightText := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupChrome()).Render(headerRight)
	spacer := strings.Repeat(" ", max(width-lipgloss.Width(leftText)-lipgloss.Width(rightText), 0))
	lines := []string{lipgloss.NewStyle().Background(p.PopupChrome()).Width(width).Render(fitStyled(leftText+spacer+rightText, width))}
	rowBudget := max(height-1, 0)
	pathWidth := min(max(width/4, 12), max(width-18, 1))
	messageWidth := max(width-pathWidth-8, 1)
	for _, msg := range messages[:min(len(messages), rowBudget)] {
		lines = append(lines, m.renderBottomPanelMessage(msg, pathWidth, messageWidth, width))
	}
	lineStyle := m.popupLineStyle(width)
	for len(lines) < height {
		lines = append(lines, lineStyle.Render(strings.Repeat(" ", width)))
	}
	return takeLines(lines, height)
}

func (m Model) renderBottomPanelMessage(msg protocol.PanelMessage, pathWidth int, messageWidth int, width int) string {
	p := m.palette()
	badge := bottomPanelLevelBadge(msg.Level)
	badgeColor := bottomPanelLevelColor(p, msg.Level)
	badgeText := lipgloss.NewStyle().Bold(true).Foreground(p.EditorSurface()).Background(badgeColor).Width(5).Align(lipgloss.Center).Render(badge)
	path := msg.Path
	if strings.TrimSpace(path) == "" {
		path = "messages"
	}
	pathText := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupSurface()).Width(pathWidth).Render(fit(path, pathWidth))
	messageText := lipgloss.NewStyle().Foreground(p.PopupText()).Background(p.PopupSurface()).Width(messageWidth).Render(fit(msg.Text, messageWidth))
	row := " " + badgeText + " " + pathText + " " + messageText
	return lipgloss.NewStyle().Background(p.PopupSurface()).Width(width).Render(fitStyled(row, width))
}

func bottomPanelLevelBadge(level byte) string {
	switch level {
	case 1:
		return "WRN"
	case 2:
		return "ERR"
	case 3:
		return "OK"
	case 4:
		return "RUN"
	default:
		return "INF"
	}
}

func bottomPanelLevelColor(p palette, level byte) color.Color {
	switch level {
	case 1:
		return p.Warning()
	case 2:
		return p.Error()
	case 3:
		return p.Hint()
	case 4:
		return p.Info()
	default:
		return p.Info()
	}
}

func (m Model) visibleBottomPanelMessages(panel protocol.BottomPanel) []protocol.PanelMessage {
	visibleRows := m.bottomPanelVisibleRows(panel)
	if len(panel.Messages) <= visibleRows {
		return panel.Messages
	}
	start := max(len(panel.Messages)-visibleRows-m.bottomPanelScrollback, 0)
	end := min(start+visibleRows, len(panel.Messages))
	return panel.Messages[start:end]
}

func (m Model) bottomPanelVisibleRows(panel protocol.BottomPanel) int {
	return max(m.bottomPanelHeight(panel)-1, 1)
}

func (m Model) bottomPanelHeight(panel protocol.BottomPanel) int {
	maxHeight := max(m.height-1, 1)
	percent := int(panel.HeightPercent)
	if percent <= 0 {
		percent = 30
	}
	percent = min(max(percent, 1), 100)
	return min(max(m.height*percent/100, 4), maxHeight)
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
