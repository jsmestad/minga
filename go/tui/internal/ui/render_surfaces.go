package ui

import (
	"fmt"
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
	xansi "github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// overlayLayer renders the active overlay at its BEAM placement translated
// to screen coordinates, above the base content. Frontend hit testing uses the
// same translated rect. An overlay without a placement does not render.
func (m Model) overlayLayer() *lipgloss.Layer {
	winner, ok := m.overlayWinner()
	if !ok {
		return nil
	}
	rect, ok := m.surfaceScreenRect(winner.surfaceID)
	if !ok || rect.Width == 0 || rect.Height == 0 {
		return nil
	}
	lines := winner.render()
	// Trim trailing blank lines so a short overlay (a 1-2 line notification, a
	// 2-line float popup) carries only its real content. The charm list/table
	// renderers pad their output to the requested height with blank rows at the
	// BOTTOM; the string-built renderers emit no padding. Trimming here makes the
	// compositing uniform: every footer overlay is exactly its content tall (#2281).
	if winner.surfaceID != surfaceIDAgentHelp {
		lines = trimTrailingBlankLines(lines)
	}
	// Cap the content to the band height so it can never paint outside the BEAM
	// rect the hit-tester routes against. takeLines keeps the TOP rows (the title
	// and the first items), the same rows the old footer-append showed.
	lines = takeLines(lines, rect.Height)
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
	y := rect.Y + rect.Height - len(lines)
	// Scan the overlay's content for zone markers and merge them into the frame's
	// zone map at the placement offset, so chrome zone routing (completion items,
	// hover action) keeps working even though the overlay is composited as its own
	// layer instead of footer-appended (#2281). ScanInto returns the marker-
	// stripped content for compositing; zones are offset by the bottom-aligned Y.
	content := m.zones.ScanInto(strings.Join(lines, "\n"), rect.X, y)
	// Z is offset above the base content/window layers (Z 0 and 1 in composeFrame)
	// while staying below the picker/which-key floating layers; the placement z is
	// a large band value (150..301), so add the base offset to keep it on top of
	// content without colliding with the Z=0/1 base layers.
	return lipgloss.NewLayer(content).X(rect.X).Y(y).Z(int(winner.order) + 2)
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

// panelSeparatorLine renders a full-width ─ separator line for the top of a
// bottom panel, visually separating it from the editor body above. The caller
// must account for this line in its height budget (subtract 1 from content
// rows) so the BEAM content_height model stays exact.
func panelSeparatorLine(theme palette, width int, bg color.Color) string {
	w := max(width, 1)
	return lipgloss.NewStyle().
		Foreground(theme.TreeSeparator()).
		Background(bg).
		Width(w).
		ColorWhitespace(true).
		Render(strings.Repeat("─", w))
}

// Registry surface ids (mirror MingaEditor.Layout.SurfaceRegistry.surface_id_u16/1).
// Every overlay surface is now BEAM registry-placed: #2281 promoted the seven remaining footer-band secondary overlays (float popup through extension overlay) so the BEAM owns their geometry and z, alongside the earlier cursor-anchored popups (hover, signature help) and the completion/bottom-panel surfaces.
// There is no transitional fallback table any more; ordering and positioning are placement data end to end (see overlayCandidates / overlayLayer).
const (
	surfaceIDBottomPanel      uint16 = 12
	surfaceIDCompletionMenu   uint16 = 16
	surfaceIDHoverPopup       uint16 = 17
	surfaceIDSignatureHelp    uint16 = 18
	surfaceIDFloatPopup       uint16 = 19
	surfaceIDAgentContext     uint16 = 20
	surfaceIDExtensionPanel   uint16 = 22
	surfaceIDObservatory      uint16 = 23
	surfaceIDEditTimeline     uint16 = 24
	surfaceIDNotifications    uint16 = 25
	surfaceIDExtensionOverlay uint16 = 26
	surfaceIDAgentHelp        uint16 = 27
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

// overlayCandidates lists every floating overlay surface paired with its BEAM placement.
// Every surface is registry-placed now (#2281), so each candidate's stacking order is purely its gui_surface_layout z (surfaceOrder), looked up by surfaceID.
// The historical top-to-bottom precedence is preserved by emitted z values, not by any Go-side ordering.
func (m Model) overlayCandidates() []overlayCandidate {
	completion, completionOK := m.completion()
	hover, hoverOK := m.hoverPopup()
	sig, sigOK := m.signatureHelp()
	float, floatOK := m.floatPopup()
	context, contextOK := m.agentContext()
	bottom, bottomOK := m.bottomPanel()
	ext, extOK := m.extensionPanel()
	obs, obsOK := m.observatory()
	notes, notesOK := m.notifications()
	overlay, overlayOK := m.extensionOverlay()
	help, helpOK := m.agentHelp()

	return []overlayCandidate{
		m.candidate(surfaceIDCompletionMenu, completionOK && completion.Visible && len(completion.Items) > 0, func() []string {
			rect, ok := m.surfaceScreenRect(surfaceIDCompletionMenu)
			if !ok || rect.Width == 0 || rect.Height == 0 {
				return nil
			}
			return m.renderCompletion(completion, rect.Width, rect.Height)
		}),
		m.candidate(surfaceIDHoverPopup, hoverOK && hover.Visible && len(hover.Lines) > 0, func() []string { return m.renderHover(hover) }),
		m.candidate(surfaceIDSignatureHelp, sigOK && sig.Visible && len(sig.Signatures) > 0, func() []string { return m.renderSignature(sig) }),
		m.candidate(surfaceIDFloatPopup, floatOK && float.Visible, func() []string { return m.renderFloat(float) }),
		m.candidate(surfaceIDAgentContext, contextOK && context.Visible, func() []string { return m.renderAgentContext(context) }),
		m.candidate(surfaceIDBottomPanel, bottomOK && bottom.Visible, func() []string { return m.renderBottomPanel(bottom) }),
		m.candidate(surfaceIDExtensionPanel, extOK && visiblePanelCount(ext) > 0, func() []string { return m.renderExtensionPanels(ext) }),
		m.candidate(surfaceIDObservatory, obsOK && obs.Visible, func() []string { return m.renderObservatory(obs) }),
		m.candidate(surfaceIDNotifications, notesOK && notes.Visible && len(notes.Items) > 0, func() []string { return m.renderNotifications(notes) }),
		m.candidate(surfaceIDExtensionOverlay, overlayOK && len(overlay.Entries) > 0, func() []string { return m.renderExtensionOverlay(overlay) }),
		m.candidate(surfaceIDAgentHelp, helpOK && help.Visible && !m.pickerVisible() && !m.whichKeyVisible(), func() []string { return m.renderAgentHelp(help) }),
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

func (m Model) surfaceScreenRect(surfaceID uint16) (uiRect, bool) {
	return m.surfaceRectOnGrid(surfaceID, m.layout.grid)
}

func (m Model) surfaceRectOnGrid(surfaceID uint16, grid uiRect) (uiRect, bool) {
	for _, p := range m.surfacePlacements {
		if p.SurfaceID == surfaceID {
			return grid.screenRect(p.Rect), true
		}
	}
	return uiRect{}, false
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
	if context.Progress.ToolCount > 0 || context.Progress.FileCount > 0 || context.Progress.ActiveAction != "" {
		items = append(items, componentItem{
			title:       "progress",
			description: fmt.Sprintf("%d tools / %d files / %s", context.Progress.ToolCount, context.Progress.FileCount, context.Progress.ActiveAction),
		})
	}
	for _, todo := range context.Todos {
		items = append(items, componentItem{title: todoStatusName(todo.Status), description: todo.Description})
	}
	if context.CanApprove {
		items = append(items, componentItem{title: "review", description: context.Progress.ReviewHint})
	}
	return takeLines(m.charmList("Agent context", items, 0, m.maxOverlayHeight(), true), m.maxOverlayHeight())
}

func todoStatusName(status byte) string {
	switch status {
	case 1:
		return "doing"
	case 2:
		return "done"
	default:
		return "todo"
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

// Messages use the protocol's debug, info, warning, and error severities, not job statuses.
func bottomPanelLevelBadge(level byte) string {
	switch level {
	case 0:
		return "DBG"
	case 1:
		return "INF"
	case 2:
		return "WRN"
	case 3:
		return "ERR"
	default:
		return "INF"
	}
}

func bottomPanelLevelColor(p palette, level byte) color.Color {
	switch level {
	case 0:
		return p.Muted()
	case 1:
		return p.Info()
	case 2:
		return p.Warning()
	case 3:
		return p.Error()
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
	rows := max(m.layout.grid.Height, 1)
	maxHeight := max(rows-1, 1)
	percent := int(panel.HeightPercent)
	if percent <= 0 {
		percent = 30
	}
	percent = min(max(percent, 1), 100)
	return min(max(rows*percent/100, 4), maxHeight)
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

// renderObservatory draws the observatory as directly-styled addressable rows
// rather than an opaque charm table so each node row can carry a lipgloss zone
// marker, mirroring how renderNotifications was converted (#2333) and the macOS
// ObservatoryView. A click on a node row sends observatory_inspect(node.pid),
// the same semantic the macOS info-circle button sends and the inspect intent
// the keyboard reaches (#2334). The row shape is unchanged from the charm table
// it replaces: a 1-line header plus one line per node (PID, depth-indented name,
// message-queue length), so the BEAM content-height model
// (FooterOverlays.content_height_observatory = 1 + node_count) is exact. The
// per-row tableCell columns reproduce the charm table's Padding(0,1) cell layout
// so the visual stays equivalent.
func (m Model) renderObservatory(obs protocol.Observatory) []string {
	height := m.maxOverlayHeight()
	theme := m.palette()
	pidWidth := 12
	qWidth := 6
	nameWidth := max(m.width-pidWidth-qWidth, 20)

	sep := panelSeparatorLine(theme, m.width, theme.PopupSurface())
	header := tableHeaderRow(theme, m.width, []tableCell{
		{text: fmt.Sprintf("󰐣 Observatory %d", max(int(obs.Count), len(obs.Nodes))), width: pidWidth},
		{text: "Process", width: nameWidth},
		{text: "Q", width: qWidth},
	})
	lines := []string{sep, header}
	for _, node := range obs.Nodes {
		row := tableDataRow(theme, m.width, false, []tableCell{
			{text: node.PID, width: pidWidth},
			{text: strings.Repeat("  ", int(node.Depth)) + node.Name, width: nameWidth},
			{text: fmt.Sprintf("%d", node.MessageQueueLen), width: qWidth},
		})
		lines = append(lines, m.zones.Mark(zoneIDObservatoryNode(node.PID), row))
	}
	return takeLines(lines, height)
}

// timelineLayer paints the full persistent chrome allocation at its committed
// origin. Unlike popups it has no shadow, trimming, or bottom alignment.
func (m Model) timelineLayer() *lipgloss.Layer {
	timeline, visible := m.editTimeline()
	rect := m.layout.timeline
	if !visible || rect.Width == 0 || rect.Height == 0 {
		return nil
	}
	content := m.zones.ScanInto(strings.Join(m.renderEditTimeline(timeline), "\n"), rect.X, rect.Y)
	return lipgloss.NewLayer(content).X(rect.X).Y(rect.Y).Z(2)
}

// renderEditTimeline keeps historical entry navigation separate from cumulative
// file Review. Both retain their BEAM-offered identities.
func (m Model) renderEditTimeline(timeline protocol.EditTimeline) []string {
	width, height := m.layout.timeline.Width, m.layout.timeline.Height
	if width <= 0 || height <= 0 {
		return nil
	}
	theme := m.palette()
	lines := make([]string, 0, height)
	lines = append(lines, panelSeparatorLine(theme, width, theme.PopupSurface()))
	if len(timeline.Files) > 0 || len(timeline.Entries) == 0 {
		lines = append(lines, m.renderEditTimelineFiles(timeline, theme, width)...)
	} else {
		idxWidth, ageWidth := 4, 8
		toolWidth := max(width-idxWidth-ageWidth, 1)
		lines = append(lines, tableHeaderRow(theme, width, []tableCell{
			{text: "󰋚 #", width: idxWidth},
			{text: "Tool", width: toolWidth},
			{text: "Age", width: ageWidth},
		}))
		for _, entry := range timeline.Entries[:min(len(timeline.Entries), m.timelineFileRows())] {
			row := tableDataRow(theme, width, uint16(entry.Index) == timeline.ViewingIndex, []tableCell{
				{text: fmt.Sprintf("%d", entry.Index), width: idxWidth},
				{text: entry.ToolName, width: toolWidth},
				{text: fmt.Sprintf("%d", entry.TimestampDelta), width: ageWidth},
			})
			lines = append(lines, m.zones.Mark(zoneIDTimelineEntry(timeline.Generation, entry.EntryID), row))
		}
	}
	lines = takeLines(lines, height)
	style := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface())
	blank := style.Render(strings.Repeat(" ", width))
	for len(lines) < height {
		lines = append(lines, blank)
	}
	return lines
}

// One separator and one header share the authored chrome budget with file rows.
func (m Model) timelineFileRows() int {
	return max(m.layout.timeline.Height-2, 0)
}

func (m Model) timelineFileStart(timeline protocol.EditTimeline) int {
	for index, file := range timeline.Files {
		if file.Path == m.timelineFirstPath {
			return min(index, max(len(timeline.Files)-m.timelineFileRows(), 0))
		}
	}
	return 0
}

func (m Model) renderEditTimelineFiles(timeline protocol.EditTimeline, theme palette, width int) []string {
	header := tableHeaderRow(theme, width, []tableCell{
		{text: fmt.Sprintf("Review files (%d)  [e prev  ]e next  wheel", len(timeline.Files)), width: width},
	})
	rows := m.timelineFileRows()
	start := m.timelineFileStart(timeline)
	end := min(start+rows, len(timeline.Files))
	lines := make([]string, 1, 1+end-start)
	lines[0] = header
	if len(timeline.Files) == 0 && rows > 0 {
		style := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface())
		lines = append(lines, renderPadded(style, "No changed files", width))
	}
	for _, file := range timeline.Files[start:end] {
		selected := file.ReviewStatus == 1
		rowStyle := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).ColorWhitespace(true)
		actionStyle := rowStyle.Bold(true).Foreground(theme.Accent())
		if selected {
			rowStyle = rowStyle.Bold(true).Foreground(theme.PopupSelectionText()).Background(theme.PopupSelection())
			actionStyle = rowStyle
		}
		label := actionStyle.Render(fit("[Review]", min(width, 8)))
		if timeline.Generation != 0 {
			label = m.zones.Mark(zoneIDTimelineReview(timeline.Generation, file.Path), label)
		}
		// Keep the action visible even in a narrow terminal.
		// Wider terminals also retain edit counts and diff totals without wrapping the file path.
		detailWidth := max(width-9, 0)
		withStats := detailWidth >= 32
		pathWidth := detailWidth
		if withStats {
			pathWidth -= 20
		}
		pathLabel := file.Path
		if overflow := xansi.StringWidth(pathLabel) - pathWidth; overflow > 0 {
			pathLabel = xansi.TruncateLeft(pathLabel, overflow+1, "…")
		}
		var detail string
		if withStats {
			detail = tableCellsText([]tableCell{
				{text: pathLabel, width: detailWidth - 18},
				{text: fmt.Sprintf("%d", file.EntryCount), width: 6},
				{text: fmt.Sprintf("+%d/-%d", file.LinesAdded, file.LinesRemoved), width: 12},
			})
		} else {
			detail = fit(pathLabel, detailWidth)
		}
		lines = append(lines, renderPadded(rowStyle, label+rowStyle.Render(" "+detail), width))
	}
	return lines
}

// tableCell is one column's content and total column width (including the
// Padding(0,1) the charm table applied: 1 leading + 1 trailing space).
type tableCell struct {
	text  string
	width int
}

// tableHeaderRow renders a charmTable-equivalent header row: each cell is bold
// accent text on the popup surface, left-padded one cell and clipped to its
// column width, with the row filled to the full overlay width so the band
// background stays solid.
func tableHeaderRow(theme palette, width int, cells []tableCell) string {
	style := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupSurface()).ColorWhitespace(true)
	rowStyle := lipgloss.NewStyle().Background(theme.PopupSurface()).Width(max(width, 1)).ColorWhitespace(true)
	return renderPadded(rowStyle, style.Render(tableCellsText(cells)), max(width, 1))
}

// tableDataRow renders a charmTable-equivalent data row. A selected row uses the
// popup-selection colors (bold selection text on the selection background),
// matching the charm table's Selected style; an unselected row uses popup text on
// the popup surface. The whole row is filled to the overlay width so the zone the
// caller marks over it covers the full clickable line.
func tableDataRow(theme palette, width int, selected bool, cells []tableCell) string {
	width = max(width, 1)
	text := tableCellsText(cells)
	if selected {
		style := lipgloss.NewStyle().Bold(true).Foreground(theme.PopupSelectionText()).Background(theme.PopupSelection()).Width(width).ColorWhitespace(true)
		return renderPadded(style, text, width)
	}
	cellStyle := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).ColorWhitespace(true)
	rowStyle := lipgloss.NewStyle().Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)
	return renderPadded(rowStyle, cellStyle.Render(text), width)
}

// tableCellsText lays out cells side by side, each clipped/padded to its column
// width with one leading and one trailing space (the charm table's Padding(0,1)).
func tableCellsText(cells []tableCell) string {
	var b strings.Builder
	for _, cell := range cells {
		inner := max(cell.width-2, 1)
		b.WriteString(" " + fit(cell.text, inner) + " ")
	}
	return b.String()
}

// renderNotifications draws the notification center as directly-styled rows
// rather than an opaque charm list so each interactive affordance can carry a
// lipgloss zone marker, mirroring how renderCompletion was converted (#2230).
// The clickable affordances match the macOS frontend exactly
// (NotificationCenterView.swift): the dismiss "x" on the title row sends
// notification_dismiss, and each inline action sends notification_action. There
// is no body-click "activate" gesture, because neither macOS nor the keyboard
// has one. The per-item base shape is a title row + a source/body row (2 lines),
// matching the BEAM content-height model (FooterOverlays.content_height_
// notifications = 1 + 2*items); an item with inline actions adds one actions
// row, the documented per-item slack the band ceiling clamps.
//
// The content is wrapped in a rounded border with drop shadow matching the
// picker/which-key popup styling (#2538). The border adds 2 to height and 4 to
// width (2 border chars + 2 padding chars); the BEAM placement rect must
// account for this overhead so overlayLayer does not clip the border frame.
func (m Model) renderNotifications(notes protocol.Notifications) []string {
	height := m.maxOverlayHeight()
	width := max(m.width, 1)
	theme := m.palette()

	// Content dimensions account for the rounded border frame. The border adds
	// 1 column on each side (2 total) and Padding(0,1) adds 1 column on each
	// side (2 more), for 4 columns of width overhead. Height adds 1 row for the
	// top border and 1 for the bottom border (2 total).
	contentWidth := max(width-4, 1)
	contentHeight := max(height-2, 1)

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupChrome()).Width(contentWidth).ColorWhitespace(true)
	lines := []string{renderPadded(titleStyle, " Notifications", contentWidth)}

	for _, note := range notes.Items {
		lines = append(lines, m.renderNotificationHeaderRow(note, contentWidth))
		lines = append(lines, m.renderNotificationBodyRow(note, contentWidth))
		if len(note.Actions) > 0 {
			lines = append(lines, m.renderNotificationActionsRow(note, contentWidth))
		}
	}
	lines = takeLines(lines, contentHeight)

	// Wrap in rounded border matching picker/which-key popup styling.
	content := strings.Join(lines, "\n")
	bordered := lipgloss.NewStyle().
		Width(contentWidth).
		Padding(0, 1).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.PopupBorder()).
		BorderBackground(theme.PopupSurface()).
		Background(theme.PopupSurface()).
		ColorWhitespace(true).
		Render(content)

	return strings.Split(bordered, "\n")
}

// renderNotificationHeaderRow draws a notification's title and, when the
// notification is dismissable, a trailing dismiss "x" affordance pinned to the
// right edge. Only the "x" cell carries the dismiss zone so a click on the title
// text itself misses every zone and is contained by the BEAM (matching macOS,
// where the title is not a button and only the "x" dismisses).
func (m Model) renderNotificationHeaderRow(note protocol.Notification, width int) string {
	theme := m.palette()
	rowStyle := lipgloss.NewStyle().Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.PopupText()).Background(theme.PopupSurface()).ColorWhitespace(true)

	if !note.Dismissable {
		return renderPadded(rowStyle, titleStyle.Render(" "+note.Title), width)
	}

	dismissGlyph := "x"
	dismissStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.PopupMutedText()).Background(theme.PopupSurface()).ColorWhitespace(true)
	dismiss := m.zones.Mark(zoneIDNotificationDismiss(note.ID), dismissStyle.Render(dismissGlyph))
	// Reserve the rightmost cell for the dismiss glyph; fit the title into the
	// remaining width so the glyph stays at a fixed, clickable column.
	titleWidth := max(width-2, 1)
	title := titleStyle.Render(" " + fit(note.Title, titleWidth))
	gap := max(width-lipgloss.Width(title)-lipgloss.Width(dismissGlyph)-1, 0)
	spacer := lipgloss.NewStyle().Background(theme.PopupSurface()).Render(strings.Repeat(" ", gap))
	return rowStyle.Render(title + spacer + dismiss + lipgloss.NewStyle().Background(theme.PopupSurface()).Render(" "))
}

// renderNotificationBodyRow draws the source + body summary line, the same text
// the prior charm-list description carried, so the visual stays a titled list.
func (m Model) renderNotificationBodyRow(note protocol.Notification, width int) string {
	theme := m.palette()
	rowStyle := lipgloss.NewStyle().Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)
	bodyStyle := lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(theme.PopupSurface()).ColorWhitespace(true)
	summary := strings.TrimSpace(note.Source + " " + note.Body)
	return renderPadded(rowStyle, bodyStyle.Render("   "+summary), width)
}

// renderNotificationActionsRow draws each inline action as a bracketed,
// addressable affordance marked with its action zone, mirroring the macOS
// per-action buttons. A click on an action sends notification_action(id,
// action_id); a click in the surrounding row padding misses every zone and is
// contained.
func (m Model) renderNotificationActionsRow(note protocol.Notification, width int) string {
	theme := m.palette()
	rowStyle := lipgloss.NewStyle().Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)
	actionStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupSurface()).ColorWhitespace(true)
	gapStyle := lipgloss.NewStyle().Background(theme.PopupSurface()).ColorWhitespace(true)
	rendered := gapStyle.Render("   ")
	for index, action := range note.Actions {
		if index > 0 {
			rendered += gapStyle.Render("  ")
		}
		label := actionStyle.Render("[" + action.Label + "]")
		rendered += m.zones.Mark(zoneIDNotificationAction(note.ID, action.ID), label)
	}
	return renderPadded(rowStyle, rendered, width)
}

func (m Model) renderExtensionOverlay(overlay protocol.ExtensionOverlay) []string {
	style := m.panelStyle()
	theme := m.palette()
	sep := panelSeparatorLine(theme, m.width, theme.Base())
	lines := []string{sep, style.Bold(true).Foreground(theme.Accent()).Render(fit(" Extension overlays", m.width))}
	for _, entry := range overlay.Entries[:min(len(overlay.Entries), max(m.maxOverlayHeight()-2, 0))] {
		lines = append(lines, style.Render(fit(fmt.Sprintf("%s %d:%d %s", entry.Extension, entry.Row+1, entry.Col+1, entry.Content), m.width)))
	}
	return lines
}
