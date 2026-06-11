package ui

import (
	"fmt"
	"image/color"
	"strings"

	"charm.land/bubbles/v2/table"
	"charm.land/lipgloss/v2"
	xansi "github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// overlayLayer returns the single active overlay positioned at its BEAM
// placement rect, or nil when no overlay is active this frame. This replaces the
// old footer-append: instead of joining the overlay's lines into the bottom of
// the vertical layout, the winning overlay is composited as its own lipgloss
// layer at the X/Y the BEAM emitted (the same rect BEAM mouse hit-testing routes
// against), via the NewLayer path the picker overlay already proves. The Z is
// taken from the placement so the layer sits above the base content. When the
// winning surface has no placement rect this frame the overlay does not render
// (no silent fallback position).
func (m Model) overlayLayer() *lipgloss.Layer {
	winner, ok := m.overlayWinner()
	if !ok {
		return nil
	}
	rect, ok := m.surfacePlacementFor(winner.surfaceID)
	if !ok {
		return nil
	}
	lines := winner.render()
	// Trim trailing blank lines so a short overlay (a 1-2 line notification, a
	// 2-line float popup) carries only its real content. The charm list/table
	// renderers pad their output to the requested height with blank rows at the
	// BOTTOM; the string-built renderers emit no padding. Trimming here makes the
	// compositing uniform: every footer overlay is exactly its content tall (#2281).
	lines = trimTrailingBlankLines(lines)
	// Cap the content to the band height so it can never paint outside the BEAM
	// rect the hit-tester routes against. takeLines keeps the TOP rows (the title
	// and the first items), the same rows the old footer-append showed.
	lines = takeLines(lines, int(rect.Height))
	if len(lines) == 0 {
		return nil
	}
	// Bottom-align the content inside the band rect: the rect is bottom-anchored
	// (its bottom edge sits directly above the minibuffer, where the old footer-
	// append put the overlay), so a shorter content block is pinned to the rect's
	// bottom rows rather than its top. For the count-derivable surfaces the BEAM
	// already sizes the rect to the content, so this offset is ~0; for the wrap-
	// dependent surfaces it pushes the content down to the bottom and leaves the
	// residual phantom zone ABOVE the content (documented in FooterOverlays).
	y := int(rect.Row) + int(rect.Height) - len(lines)
	if y < int(rect.Row) {
		y = int(rect.Row)
	}
	// Scan the overlay's content for zone markers and merge them into the frame's
	// zone map at the placement offset, so chrome zone routing (completion items,
	// hover action) keeps working even though the overlay is composited as its own
	// layer instead of footer-appended (#2281). ScanInto returns the marker-
	// stripped content for compositing; zones are offset by the bottom-aligned Y.
	content := m.zones.ScanInto(strings.Join(lines, "\n"), int(rect.Col), y)
	// Z is offset above the base content/window layers (Z 0 and 1 in composeFrame)
	// while staying below the picker/which-key floating layers; the placement z is
	// a large band value (150..301), so add the base offset to keep it on top of
	// content without colliding with the Z=0/1 base layers.
	return lipgloss.NewLayer(content).X(int(rect.Col)).Y(y).Z(int(winner.order) + 2)
}

// trimTrailingBlankLines drops trailing lines whose visible content (ANSI escapes
// stripped) is empty or whitespace. The charm list/table overlay renderers pad to
// a fixed height with blank rows at the bottom; trimming them lets overlayLayer
// bottom-align only the real content so a short overlay hugs the screen bottom
// (#2281). A fully blank slice trims to empty (the caller drops the layer).
func trimTrailingBlankLines(lines []string) []string {
	end := len(lines)
	for end > 0 && strings.TrimSpace(xansi.Strip(lines[end-1])) == "" {
		end--
	}
	return lines[:end]
}

// Registry surface ids (mirror MingaEditor.Layout.SurfaceRegistry.surface_id_u16/1).
// Every overlay surface is now BEAM registry-placed: #2281 promoted the eight
// footer-band secondary overlays (float popup through extension overlay) so the
// BEAM owns their geometry and z, alongside the earlier cursor-anchored popups
// (hover, signature help) and the completion/bottom-panel surfaces. There is no
// transitional fallback table any more; ordering and positioning are placement
// data end to end (see overlayCandidates / overlayLayer).
const (
	surfaceIDBottomPanel      uint16 = 12
	surfaceIDCompletionMenu   uint16 = 16
	surfaceIDHoverPopup       uint16 = 17
	surfaceIDSignatureHelp    uint16 = 18
	surfaceIDFloatPopup       uint16 = 19
	surfaceIDAgentContext     uint16 = 20
	surfaceIDToolManager      uint16 = 21
	surfaceIDExtensionPanel   uint16 = 22
	surfaceIDObservatory      uint16 = 23
	surfaceIDEditTimeline     uint16 = 24
	surfaceIDNotifications    uint16 = 25
	surfaceIDExtensionOverlay uint16 = 26
)

// overlayCandidate is one floating surface that may occupy the single active
// overlay slot. surfaceID is the surface's BEAM registry id; order is its
// gui_surface_layout placement z, looked up by surfaceID. Lower z paints further
// back, so the HIGHEST-z visible candidate with a placement wins. A candidate
// with no emitted placement this frame (placed == false) is not eligible: there
// is no fallback table any more, so a surface the BEAM did not place simply does
// not render (documented in overlayWinner). The precedence is sorted placement
// data end to end, not a hardcoded if-ladder.
type overlayCandidate struct {
	surfaceID uint16
	visible   bool
	placed    bool
	order     int
	render    func() []string
}

// overlayLines returns the single active overlay's lines (the BEAM emits a
// single-active-overlay decision; multiple simultaneous overlays remain out of
// scope, #2268 AC-4). Retained for tests and for any caller that wants only the
// rendered content; positioning is done by overlayLayer via the placement rect.
func (m Model) overlayLines() []string {
	winner, ok := m.overlayWinner()
	if !ok {
		return nil
	}
	return winner.render()
}

// overlayWinner returns the single visible, placed overlay candidate with the
// highest placement z, or ok=false when none qualifies. Selection is unchanged
// (single active winner); what changed is that an eligible candidate must carry
// a BEAM placement (placed). With no fallback table, a visible surface the BEAM
// did not place this frame is skipped rather than footer-appended at a guessed
// rank: it simply does not render that frame.
func (m Model) overlayWinner() (overlayCandidate, bool) {
	candidates := m.overlayCandidates()

	best := -1
	var winner overlayCandidate
	found := false
	for _, c := range candidates {
		if c.visible && c.placed && c.order > best {
			best = c.order
			winner = c
			found = true
		}
	}
	return winner, found
}

// overlayCandidates lists every floating overlay surface paired with its BEAM
// placement. Every surface is registry-placed now (#2281), so each candidate's
// stacking order is purely its gui_surface_layout z (surfaceOrder), looked up by
// surfaceID. The historical top-to-bottom precedence is preserved by the emitted
// z values themselves (completion 301 > hover 290 > signature help 280 > float
// 270 > agent context 260 > tool manager 240 > bottom panel 200 > extension
// panel 190 > observatory 180 > edit timeline 170 > notifications 160 > extension
// overlay 150), not by any Go-side ordering.
func (m Model) overlayCandidates() []overlayCandidate {
	completion, completionOK := m.completion()
	hover, hoverOK := m.hoverPopup()
	sig, sigOK := m.signatureHelp()
	float, floatOK := m.floatPopup()
	context, contextOK := m.agentContext()
	tools, toolsOK := m.toolManager()
	bottom, bottomOK := m.bottomPanel()
	ext, extOK := m.extensionPanel()
	obs, obsOK := m.observatory()
	timeline, timelineOK := m.editTimeline()
	notes, notesOK := m.notifications()
	overlay, overlayOK := m.extensionOverlay()

	return []overlayCandidate{
		m.candidate(surfaceIDCompletionMenu, completionOK && completion.Visible && len(completion.Items) > 0, func() []string { return m.renderCompletion(completion) }),
		m.candidate(surfaceIDHoverPopup, hoverOK && hover.Visible && len(hover.Lines) > 0, func() []string { return m.renderHover(hover) }),
		m.candidate(surfaceIDSignatureHelp, sigOK && sig.Visible && len(sig.Signatures) > 0, func() []string { return m.renderSignature(sig) }),
		m.candidate(surfaceIDFloatPopup, floatOK && float.Visible, func() []string { return m.renderFloat(float) }),
		m.candidate(surfaceIDAgentContext, contextOK && context.Visible, func() []string { return m.renderAgentContext(context) }),
		m.candidate(surfaceIDToolManager, toolsOK && tools.Visible, func() []string { return m.renderToolManager(tools) }),
		m.candidate(surfaceIDBottomPanel, bottomOK && bottom.Visible, func() []string { return m.renderBottomPanel(bottom) }),
		m.candidate(surfaceIDExtensionPanel, extOK && visiblePanelCount(ext) > 0, func() []string { return m.renderExtensionPanels(ext) }),
		m.candidate(surfaceIDObservatory, obsOK && obs.Visible, func() []string { return m.renderObservatory(obs) }),
		m.candidate(surfaceIDEditTimeline, timelineOK && timeline.Visible, func() []string { return m.renderEditTimeline(timeline) }),
		m.candidate(surfaceIDNotifications, notesOK && notes.Visible && len(notes.Items) > 0, func() []string { return m.renderNotifications(notes) }),
		m.candidate(surfaceIDExtensionOverlay, overlayOK && len(overlay.Entries) > 0, func() []string { return m.renderExtensionOverlay(overlay) }),
	}
}

// candidate builds an overlayCandidate, resolving the surface's BEAM placement z
// by surfaceID. placed is false when the BEAM emitted no placement for this
// surface this frame; such a candidate is ineligible (no fallback rank).
func (m Model) candidate(surfaceID uint16, visible bool, render func() []string) overlayCandidate {
	order, placed := m.surfaceOrder(surfaceID)
	return overlayCandidate{surfaceID: surfaceID, visible: visible, placed: placed, order: order, render: render}
}

// surfaceOrder returns the BEAM placement z for a registry-placed surface and
// whether a placement was found. There is no fallback table: a surface with no
// placement this frame returns placed=false and is not eligible to render.
func (m Model) surfaceOrder(surfaceID uint16) (int, bool) {
	for _, p := range m.surfacePlacements {
		if p.SurfaceID == surfaceID {
			return int(p.Z), true
		}
	}
	return 0, false
}

// surfacePlacementFor returns the BEAM placement rect for a surface id, or
// ok=false when the surface has no placement this frame.
func (m Model) surfacePlacementFor(surfaceID uint16) (generated.Rect, bool) {
	for _, p := range m.surfacePlacements {
		if p.SurfaceID == surfaceID {
			return p.Rect, true
		}
	}
	return generated.Rect{}, false
}

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

// visiblePanelCount counts only Visible extension panels, matching what
// renderExtensionPanels actually draws (it skips !Visible panels) and the BEAM's
// MingaEditor.Layout.FooterOverlays predicate (Minga.Extension.Panel.visible()).
// Gating on len(ext.Panels) would let an all-hidden panel set claim the overlay
// slot and render an empty band; counting Visible panels keeps the candidate
// gate, the renderer, and the BEAM placement predicate in agreement (#2281).
func visiblePanelCount(ext protocol.ExtensionPanel) int {
	count := 0
	for _, panel := range ext.Panels {
		if panel.Visible {
			count++
		}
	}
	return count
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
