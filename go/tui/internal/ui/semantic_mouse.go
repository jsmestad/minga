package ui

import (
	"fmt"
	"hash/maphash"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	zonePrefixFileTreeRow      = "file-tree:row:"
	zonePrefixModelineSegment  = "modeline:segment:"
	zonePrefixNoticeAction     = "notice:action:"
	zonePrefixEmptyListAction  = "empty-list:action:"
	zonePrefixTab              = "tab:id:"
	zonePrefixCompletionItem   = "completion:item:"
	zonePrefixSidebarItem      = "sidebar:item:"
	zonePrefixNotificationItem = "notification:dismiss:"
	zonePrefixNotificationAct  = "notification:action:"
	zonePrefixObservatoryNode  = "observatory:node:"
	zonePrefixTimelineEntry    = "timeline:entry:"
	zonePrefixTimelineReview   = "timeline:review:"
	zonePrefixEmptyStateItem   = "empty-state:item:"
	zoneIDGitRetry             = "git:retry"
	reviewModelineCommand      = "next_minga_change_at:"
	bottomPanelWheelLines      = 3
)

// zoneIDEmptyStateItem tags one activatable launchpad row by its stable item
// id (#2689). A click routes empty_state_activate(id), the same authoritative
// activation the keyboard jump keys reach on the BEAM.
func zoneIDEmptyStateItem(id string) string {
	return zonePrefixEmptyStateItem + url.QueryEscape(id)
}

func zoneIDFileTreeRow(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixFileTreeRow, index)
}

// zoneIDModelineSegment tags one modeline segment by its index in the BEAM's order (left, then right), so a click runs that segment's command and hover echoes that segment's meaning.
func zoneIDModelineSegment(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixModelineSegment, index)
}

// zoneIDEmptyListAction tags one next step of an empty panel by its index, so a click runs its command.
func zoneIDEmptyListAction(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixEmptyListAction, index)
}

// zoneIDNoticeAction tags one next step of the echo-line notice by its index, so a click runs its command.
func zoneIDNoticeAction(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixNoticeAction, index)
}

func zoneIDTab(id uint32) string {
	return fmt.Sprintf("%s%d", zonePrefixTab, id)
}

func zoneIDCompletionItem(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixCompletionItem, index)
}

func zoneIDSidebarItem(id string) string {
	return zonePrefixSidebarItem + url.QueryEscape(id)
}

// Slots identify only painted rows. Panel IDs and paths never enter the zone registry.
func zoneIDGitStatusRow(slot int) string {
	return "git:row:" + strconv.Itoa(slot)
}

// zoneIDNotificationDismiss tags the dismiss ("x") affordance of one
// notification by its stable id, mirroring the macOS dismiss button
// (NotificationCenterView.swift:48 sendNotificationDismiss).
func zoneIDNotificationDismiss(id string) string {
	return zonePrefixNotificationItem + url.QueryEscape(id)
}

// zoneIDNotificationAction tags one inline action affordance by its
// notification id and action id, mirroring the macOS per-action buttons
// (NotificationCenterView.swift:74 sendNotificationAction).
func zoneIDNotificationAction(notificationID, actionID string) string {
	return zonePrefixNotificationAct + url.QueryEscape(notificationID) + ":" + url.QueryEscape(actionID)
}

// zoneIDObservatoryNode tags one observatory row by its node PID string,
// mirroring the macOS info-circle button (ObservatoryView.swift:69
// sendObservatoryInspect). A click routes observatory_inspect(pid) to inspect
// that node, matching the keyboard/native inspect semantics (#2334).
func zoneIDObservatoryNode(pid string) string {
	return zonePrefixObservatoryNode + url.QueryEscape(pid)
}

// zoneIDTimelineEntry binds the rendered hit region to its offered identity.
func zoneIDTimelineEntry(generation uint32, entryID string) string {
	return fmt.Sprintf("%s%d:%s", zonePrefixTimelineEntry, generation, url.QueryEscape(entryID))
}

// zoneIDTimelineReview keeps full paths distinct even when basenames coincide.
func zoneIDTimelineReview(generation uint32, path string) string {
	return fmt.Sprintf("%s%d:%s", zonePrefixTimelineReview, generation, url.QueryEscape(path))
}

func (m Model) localMouse(msg tea.MouseMsg) (Model, bool) {
	mouse := msg.Mouse()
	if mouse.Button != tea.MouseWheelUp && mouse.Button != tea.MouseWheelDown {
		return m, false
	}
	if m.agentHelpWheel(mouse) {
		return m, true
	}
	if m.layout.timeline.Contains(mouse.X, mouse.Y) && !m.floatingOverlayContains(mouse.X, mouse.Y) {
		timeline, visible := m.editTimeline()
		if !visible {
			return m, false
		}
		rows := m.timelineFileRows()
		if len(timeline.Files) == 0 || rows == 0 {
			return m, true
		}
		start := m.timelineFileStart(timeline)
		if mouse.Button == tea.MouseWheelUp {
			start -= bottomPanelWheelLines
		} else {
			start += bottomPanelWheelLines
		}
		start = min(max(start, 0), max(len(timeline.Files)-rows, 0))
		m.timelineFirstPath = timeline.Files[start].Path
		return m, true
	}
	panel, ok := m.bottomPanel()
	if !ok || !panel.Visible || !m.mouseInBottomPanel(mouse.Y) {
		return m, false
	}
	if mouse.Button == tea.MouseWheelUp {
		m.bottomPanelScrollback += bottomPanelWheelLines
	} else {
		m.bottomPanelScrollback -= bottomPanelWheelLines
	}
	m.clampBottomPanelScrollback(panel)
	return m, true
}

func (m *Model) scrollWindowByWheel(mouse tea.Mouse, delta int, horizontal bool) bool {
	windowID, ok := m.presentationScrollWindowAt(mouse.X, mouse.Y)
	if !ok {
		return false
	}
	window := m.windows[windowID]
	delta = clampInt(delta, -0x8000, 0x7FFF)
	if horizontal {
		m.sendHorizontalPan(window, delta)
		return true
	}
	m.previewVerticalScroll(window, delta)
	direction := byte(0)
	if delta != 0 {
		if delta < 0 {
			direction++
		}
		m.send(protocol.EncodeScrollBatch(windowID, int16(delta), direction))
	}
	return true
}

func (m *Model) previewVerticalScroll(window protocol.WindowContent, delta int) {
	if !window.ScrollSet {
		return
	}
	// ResetRequired was consumed when this frame committed. It is not an
	// input gate for later wheel events.
	scroll := m.localPresentation.scrolls[window.ID]
	if window.Scroll.Wrapped {
		// A windowed payload has no complete visual-rank basis. It follows the
		// BEAM's committed vertical motion instead of predicting into overscan.
		if !window.WrappedResidentRows {
			return
		}
		gutter, hasGutter := m.windowGutter(window.ID)
		_, height := m.windowRenderDimensions(window, hasGutter, gutter)
		anchor := m.presentationPayloadStart(window)
		if !scroll.keysMatch(window.Scroll) {
			scroll = capturePresentationScroll(window, anchor)
		}
		maxTop := m.wrappedResidentMaxTop(window, height)
		start := clampInt(anchor+scroll.rowOffset, 0, maxTop)
		top := clampInt(start+delta, 0, maxTop)
		if top != start {
			scroll.rowOffset = top - anchor
			scroll.predictingWrapped = true
			m.localPresentation.scrolls[window.ID] = scroll
		}
		return
	}
	if !scroll.keysMatch(window.Scroll) {
		scroll = capturePresentationScroll(window, 0)
	}
	visibleRows := presentationVisibleRows(window)
	if body := m.bodyHeight(); visibleRows > body && body > 0 {
		visibleRows = body
	}
	before, after := m.presentationScrollRowBounds(window, visibleRows)
	scroll.rowOffset = clampInt(scroll.rowOffset+delta, -before, after)
	m.localPresentation.storeUnwrappedScroll(window.ID, scroll)
}

func (m *Model) sendHorizontalPan(window protocol.WindowContent, delta int) {
	if !window.ScrollSet || !window.Scroll.CanPanHorizontally || window.Scroll.Wrapped {
		return
	}
	scroll, ok := m.localPresentation.scrolls[window.ID]
	if !ok || !scroll.keysMatch(window.Scroll) {
		scroll = capturePresentationScroll(window, 0)
	}
	committed := int(window.ScrollLeft)
	// Use the pending left edge for bounds even when a text drag hides it.
	left := max(committed+scroll.colOffset, 0)
	if delta > 0 {
		// A smaller committed extent stops rightward motion without snapping left.
		delta = min(delta, max(int(window.Scroll.HorizontalPanLimit)-left, 0))
	}
	next := max(left+delta, 0)
	if next == left {
		return
	}
	seq := m.localPresentation.horizontalPanSeq + 1
	if seq == 0 || !m.send(protocol.EncodeHorizontalPan(window.ID, int16(next-left), seq)) {
		return
	}
	m.localPresentation.horizontalPanSeq = seq
	scroll.pendingPanSeq = seq
	scroll.colOffset = next - committed
	m.localPresentation.storeUnwrappedScroll(window.ID, scroll)
}

func (m Model) presentationScrollWindowAt(x int, y int) (uint16, bool) {
	bodyX, bodyY := m.layout.body.Translate(x, y)
	return m.presentationScrollWindowAtBody(bodyX, bodyY)
}

func (m Model) presentationScrollWindowAtBody(x int, y int) (uint16, bool) {
	if x < 0 || x >= m.layout.body.Width || y < 0 || y >= m.layout.body.Height {
		return 0, false
	}
	// Chat replaces the ordinary semantic canvas. Its transcript and source-backed prompt aperture have dedicated wheel routes; hidden editor geometry must not claim those physical cells.
	if m.agentChatVisible() {
		return 0, false
	}
	for _, id := range m.windowOrder {
		placement, ok := m.semanticWindowPlacement(m.windows[id])
		if !ok {
			continue
		}
		if y >= placement.row && y < placement.row+placement.height && x >= placement.col && x < placement.col+placement.width {
			return id, true
		}
	}
	return 0, false
}

// mouseInHoverPopup checks the same translated rect used to composite hover
// so free motion inside the popup does not dismiss it (#2629).
func (m Model) mouseInHoverPopup(x int, y int) bool {
	rect, ok := m.surfaceScreenRect(surfaceIDHoverPopup)
	return ok && rect.Contains(x, y)
}

func (m Model) mouseInBottomPanel(y int) bool {
	// The bottom panel is composited at its BEAM placement rect now (#2281), not
	// footer-appended, so its on-screen band comes from the placement, not from a
	// footer line count. Use the placement rect's row span when present; fall back
	// to the locally computed panel height when no placement was emitted (older
	// BEAM) so frontend scroll still works.
	if rect, ok := m.surfaceScreenRect(surfaceIDBottomPanel); ok {
		return y >= rect.Y && y < rect.Y+rect.Height
	}
	panel, ok := m.bottomPanel()
	if !ok || !panel.Visible {
		return false
	}
	height := m.bottomPanelHeight(panel)
	start := m.height - height
	return y >= start && y < m.height
}

func (m *Model) clampBottomPanelScrollback(panel protocol.BottomPanel) {
	if !panel.Visible {
		m.bottomPanelScrollback = 0
		return
	}
	m.bottomPanelScrollback = min(max(m.bottomPanelScrollback, 0), m.maxBottomPanelScrollback(panel))
}

func (m Model) maxBottomPanelScrollback(panel protocol.BottomPanel) int {
	return max(len(panel.Messages)-m.bottomPanelVisibleRows(panel), 0)
}

func (m Model) semanticMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	click, ok := msg.(tea.MouseClickMsg)
	if !ok || click.Button != tea.MouseLeft {
		return nil, false
	}
	if packet, ok := m.overlayMousePacket(msg); ok {
		return packet, true
	}
	mouse := msg.Mouse()
	if m.layout.timeline.Contains(mouse.X, mouse.Y) {
		if !m.floatingOverlayContains(mouse.X, mouse.Y) {
			if packet, ok := m.editTimelineMousePacket(msg); ok {
				return packet, true
			}
		}
		// Empty, separator, header, and summary cells never fall through to text.
		return nil, true
	}
	if m.layout.drawer.Contains(mouse.X, mouse.Y) {
		if !m.floatingOverlayContains(mouse.X, mouse.Y) {
			if packet, ok := m.tasksDrawerMousePacket(msg); ok {
				return packet, true
			}
		}
		// Borders, counts and empty rows never fall through to text.
		return nil, true
	}
	if m.queueViewport.box.Contains(mouse.X, mouse.Y) && !m.floatingOverlayContains(mouse.X, mouse.Y) {
		return nil, true // The flushed View alone can activate queue targets.
	}
	if packet, ok := m.agentDisplayedControlPacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.agentComposerControlPacket(msg); ok {
		return packet, true
	}
	// The launchpad takes over the whole editor body, so its clickable rows are
	// checked before the spatial header/left-pane/footer dispatch (#2689).
	if packet, ok := m.emptyStateMousePacket(msg); ok {
		return packet, true
	}
	switch {
	case m.layout.header.Contains(mouse.X, mouse.Y):
		return m.headerMousePacket(msg)
	case m.layout.leftPane.Contains(mouse.X, mouse.Y):
		return m.leftPaneMousePacket(msg)
	case m.layout.footer.Contains(mouse.X, mouse.Y):
		return m.footerMousePacket(msg)
	case m.layout.body.Contains(mouse.X, mouse.Y):
		if m.agentChatVisible() {
			return nil, false
		}
		return m.gutterFoldMousePacket(msg)
	}
	return nil, false
}

// overlayMousePacket is checked before spatial dispatch because overlays render
// above all layout zones and must intercept clicks regardless of position.
func (m Model) overlayMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	if packet, ok := m.whichKeyMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.agentHelpMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.completionMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.hoverActionMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.floatPopupMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.notificationMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.observatoryMousePacket(msg); ok {
		return packet, true
	}
	return nil, false
}

func (m Model) headerMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	if packet, ok := m.tabMousePacket(msg); ok {
		return packet, true
	}
	return nil, false
}

func (m Model) leftPaneMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	if packet, ok := m.fileTreeMousePacket(msg); ok {
		return packet, true
	}
	mouse := msg.Mouse()
	if m.gitStatusHits != nil && m.gitStatusHits.box.Contains(mouse.X, mouse.Y) {
		// Only the flushed view may activate Git. Don't forward a raw click into
		// the latest panel when it wasn't claimed by the displayed view.
		return nil, true
	}
	if packet, ok := m.sidebarMousePacket(msg); ok {
		return packet, true
	}
	return nil, false
}

func (m Model) footerMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	if packet, ok := m.promptChoiceMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.reviewStatusMousePacket(msg); ok {
		return packet, true
	}
	return m.modelineMousePacket(msg)
}

// gutterFoldMousePacket maps a click on a fold chevron in the gutter to
// fold_toggle_at_line, the same gui_action the macOS frontend sends
// (EditorNSView.swift handleFoldChevronClick). A click that does not land on a
// foldable gutter entry returns ok=false so it falls through to the raw mouse
// path.
func (m Model) gutterFoldMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	mouse := msg.Mouse()
	bodyX, bodyY := m.layout.body.Translate(mouse.X, mouse.Y)
	windowID, ok := m.presentationScrollWindowAtBody(bodyX, bodyY)
	if !ok {
		return nil, false
	}
	window := m.windows[windowID]
	gutter, ok := m.windowGutter(windowID)
	if !ok || gutter.SignColWidth < 2 {
		return nil, false
	}
	placement, ok := m.semanticWindowPlacement(window)
	if !ok {
		return nil, false
	}
	localX := bodyX - placement.col
	if localX < 0 || localX >= int(gutter.SignColWidth) {
		return nil, false
	}
	localY := bodyY - placement.row
	_, height := m.windowRenderDimensions(window, true, gutter)
	if localY < 0 || localY >= height {
		return nil, false
	}
	sourceStart := m.presentationSourceStart(window, height)
	sourceRowIndex := localY + sourceStart
	row, hasRow := m.windowRow(window, sourceRowIndex)
	entry, ok := presentedGutterEntry(window.WrappedResidentRows, gutter, sourceRowIndex, row, hasRow)
	if !ok {
		return nil, false
	}
	if entry.DisplayType != 1 && entry.DisplayType != 4 {
		return nil, false
	}
	return protocol.EncodeGUIFoldToggleAtLine(gutter.WindowID, window.AccessibilityGeneration, entry.BufferLine), true
}

// floatPopupMousePacket maps a click in the float popup's overlay band but
// OUTSIDE the rendered popup content to float_popup_dismiss (#2338), the same
// dismiss intent the keyboard quit key reaches (MingaEditor.Input.Popup) and the
// historical TUI outside-click-dismiss the registry-placement OverlaySink
// otherwise swallows. The float popup model (RenderModel.UI.FloatPopup) carries
// only title + lines: no links, no dismiss affordance, so a click INSIDE the
// rendered box has no semantic to send (matching the display-only macOS
// FloatPopupOverlay) and returns ok=false, falling through to the raw mouse path
// where the BEAM OverlaySink keeps it contained (AC2). The popup renders
// full-width and bottom-aligned within its band rect (overlayLayer), so "outside
// the box but in band" is the phantom rows ABOVE the rendered content; a click
// there dismisses. A click outside the band rect entirely is not ours and reaches
// the buffer underneath.
func (m Model) floatPopupMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	float, ok := m.floatPopup()
	if !ok || !float.Visible {
		return nil, false
	}
	rect, ok := m.surfaceScreenRect(surfaceIDFloatPopup)
	if !ok {
		return nil, false
	}
	mouse := msg.Mouse()
	row, col := mouse.Y, mouse.X
	// Only clicks inside the band rect are ours; outside it the click is buffer
	// content (or another surface) and must not dismiss.
	if !rect.Contains(col, row) {
		return nil, false
	}
	// Content is bottom-aligned within the rect (overlayLayer): its top row is
	// rect.Y + rect.Height - contentLines. Rows above that are the phantom band,
	// where an outside-the-popup click dismisses; rows at/below it are the popup
	// box itself, which has no clickable affordance, so leave them for containment.
	contentLines := m.floatPopupContentLines(float, rect.Height)
	contentTop := rect.Y + rect.Height - contentLines
	if row < contentTop {
		return protocol.EncodeGUIFloatPopupDismiss(), true
	}
	return nil, false
}

// floatPopupContentLines returns how many rows renderFloat draws for this popup
// after overlayLayer's trim/clamp, kept in lockstep with renderFloat so the
// inside/outside split matches what the user sees: a title row plus up to
// maxOverlayHeight-1 content lines, capped by the band height. The string-built
// renderFloat emits no trailing blanks, so no trim adjustment is needed here.
func (m Model) floatPopupContentLines(float protocol.FloatPopup, bandHeight int) int {
	lineRows := min(len(float.Lines), max(m.maxOverlayHeight()-1, 0))
	return min(1+lineRows, bandHeight)
}

// observatoryMousePacket maps a click on an observatory row to the same semantic
// gui_action the macOS frontend sends (ObservatoryView.swift): observatory_inspect
// for the clicked node's PID. A click that hits no row zone returns ok=false so
// the overlay's BEAM containment swallows it (the surface is registry-placed,
// #2281), satisfying the AC2 containment fallback (#2334).
func (m Model) observatoryMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	obs, ok := m.observatory()
	if !ok || !obs.Visible {
		return nil, false
	}
	for _, node := range obs.Nodes {
		zoneInfo := m.zones.Get(zoneIDObservatoryNode(node.PID))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIObservatoryInspect(node.PID), true
		}
	}
	return nil, false
}

const timelineBrowseZone = "timeline-browse-files"

// editTimelineMousePacket preserves historical entry navigation (intent 1) and exposes explicit cumulative file Review (intent 2).
// Only rendered exact identities may activate; blank chrome is contained by spatial dispatch.
func (m Model) editTimelineMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	mouse := msg.Mouse()
	if !m.layout.timeline.Contains(mouse.X, mouse.Y) || m.floatingOverlayContains(mouse.X, mouse.Y) {
		return nil, false
	}
	timeline, ok := m.editTimeline()
	if !ok || !timeline.Visible {
		return nil, false
	}
	if zone := m.zones.Get(timelineBrowseZone); timeline.Generation != 0 && zone != nil && zone.InBounds(msg) {
		return protocol.EncodeGUIExecuteCommand("timeline_browse_files"), true
	}
	if len(timeline.Files) > 0 {
		if timeline.Generation == 0 {
			return nil, false
		}
		for _, file := range timeline.Files {
			zoneInfo := m.zones.Get(zoneIDTimelineReview(timeline.Generation, file.Path))
			if zoneInfo != nil && zoneInfo.InBounds(msg) {
				return protocol.EncodeGUISemanticItemActivate(5, 2, timeline.Generation, []byte(file.Path)), true
			}
		}
		return nil, false
	}
	for _, entry := range timeline.Entries {
		zoneInfo := m.zones.Get(zoneIDTimelineEntry(timeline.Generation, entry.EntryID))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUISemanticItemActivate(5, 1, timeline.Generation, []byte(entry.EntryID)), true
		}
	}
	return nil, false
}

// notificationMousePacket maps a click on a notification's dismiss affordance or
// one of its inline actions to the same semantic gui_action the macOS frontend
// sends (NotificationCenterView.swift): notification_dismiss for the "x", and
// notification_action(id, action_id) for an inline action. The dismiss zone is
// checked first because the "x" sits on the same header row as the title. A
// click that hits no notification zone returns ok=false so the overlay's BEAM
// containment swallows it (the surface is registry-placed, #2281), exactly as a
// click in the body region does.
func (m Model) notificationMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	notes, ok := m.notifications()
	if !ok || !notes.Visible {
		return nil, false
	}
	for _, note := range notes.Items {
		if note.Dismissable {
			zoneInfo := m.zones.Get(zoneIDNotificationDismiss(note.ID))
			if zoneInfo != nil && zoneInfo.InBounds(msg) {
				return protocol.EncodeGUINotificationDismiss(note.ID), true
			}
		}
		for _, action := range note.Actions {
			zoneInfo := m.zones.Get(zoneIDNotificationAction(note.ID, action.ID))
			if zoneInfo != nil && zoneInfo.InBounds(msg) {
				return protocol.EncodeGUINotificationAction(note.ID, action.ID), true
			}
		}
	}
	return nil, false
}

// emptyStateMousePacket maps a click on a project home row to
// empty_state_activate(id) (#4056), the same authoritative activation `↩` and
// the number keys reach on the BEAM. A click that hits no row returns ok=false
// so it falls through to the raw mouse path.
func (m Model) emptyStateMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	state, ok := m.emptyState()
	if !ok || !state.Visible {
		return nil, false
	}
	for _, section := range state.Sections {
		for _, item := range section.Items {
			zoneInfo := m.zones.Get(zoneIDEmptyStateItem(item.ID))
			if zoneInfo != nil && zoneInfo.InBounds(msg) {
				return protocol.EncodeGUIEmptyStateActivate(item.ID), true
			}
		}
	}
	return nil, false
}

func (m Model) completionMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	completion, ok := m.completion()
	if !ok || !completion.Visible {
		return nil, false
	}
	rect, placed := m.surfaceScreenRect(surfaceIDCompletionMenu)
	mouse := msg.Mouse()
	if !placed || !rect.Contains(mouse.X, mouse.Y) {
		return nil, false
	}
	winner, active := m.overlayWinner()
	if !active || winner.surfaceID != surfaceIDCompletionMenu {
		return nil, false
	}
	for index := range completion.Items {
		zoneInfo := m.zones.Get(zoneIDCompletionItem(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUISemanticItemActivate(byte(presentationCompletion), 1, completion.Generation, []byte(completion.Items[index].ID)), true
		}
	}
	// Title, documentation, and other non-item cells must not become a raw
	// click that the BEAM interprets as an item index.
	return nil, true
}

type presentedMouseClick struct {
	packet        []byte
	claimed       bool
	maskedGit     bool
	epoch         *atomic.Uint64
	observedEpoch uint64
}

func (c *presentedMouseClick) take() presentedMouseClick {
	if c == nil {
		return presentedMouseClick{}
	}
	hit := *c
	*c = presentedMouseClick{}
	return hit
}

func (c presentedMouseClick) publicationChanged() bool {
	return c.epoch != nil && (c.observedEpoch&1 != 0 || c.epoch.Load() != c.observedEpoch)
}

// Bubble Tea invokes OnMouse from the last flushed View, synchronously before
// Update receives the input. Each handler captures only what that view showed.
func (m Model) presentedMouseHandler(layers []*lipgloss.Layer, menu actMenuPresentation, gutter []gutterActHit) (func(tea.MouseMsg) tea.Cmd, uint64) {
	claim := m.presentedClick
	if claim == nil {
		return nil, 0
	}
	if menu.offer != 0 {
		return func(msg tea.MouseMsg) tea.Cmd {
			if click, ok := msg.(tea.MouseClickMsg); ok && (click.Button == tea.MouseLeft || click.Button == tea.MouseRight) {
				claim.claimed = true
				claim.packet = menu.click(click)
			}
			return nil
		}, 0
	}
	actTarget, targetStamp := m.presentedActMenuTargetHandler(layers, gutter)
	git := m.presentedGitStatusHandler(layers)
	var agent func(tea.MouseClickMsg)
	if !m.pickerVisible() {
		agent = m.presentedConflictHandler()
		if agent == nil {
			agent = m.presentedComposerHandler()
		}
	}
	queue := m.presentedAgentQueueHandler(layers)
	peek := m.presentedSubagentPeekHandler(layers)
	review := m.presentedReviewModelineHandler(layers)
	if git == nil && agent == nil && queue == nil && peek == nil && review == nil && actTarget == nil {
		return nil, 0
	}
	return func(msg tea.MouseMsg) tea.Cmd {
		click, ok := msg.(tea.MouseClickMsg)
		if ok && actTarget != nil && (click.Button == tea.MouseLeft || click.Button == tea.MouseRight) {
			if packet, exact := actTarget(click); exact {
				claim.claimed = true
				claim.packet = packet
				return nil
			}
		}
		if ok && click.Button == tea.MouseLeft {
			if git != nil {
				git(click)
			}
			if !claim.claimed && queue != nil {
				queue(click)
			}
			if !claim.claimed && peek != nil {
				peek(click)
			}
			if !claim.claimed && agent != nil {
				agent(click)
			}
			if !claim.claimed && review != nil {
				review(click)
			}
		}
		return nil
	}, targetStamp
}

type gutterActHit struct {
	x, y     int
	glyph    string
	window   uint16
	revision uint64 // Authorship for a twist; text generation for a fold.
	head     protocol.AuthoredGutterRegion
	foldLine uint32
	authored bool
}

type actMenuTargetKind uint8

const (
	actMenuTargetPicker actMenuTargetKind = iota
	actMenuTargetTree
	actMenuTargetApproval
	actMenuTargetTask
)

type actMenuChromeHit struct {
	box      uiRect
	kind     actMenuTargetKind
	key      string // A file-tree item ID, approval zone identity, or task row ID.
	pickerID uint32
}

var actMenuHitSeed = maphash.MakeSeed()

func (m Model) presentedActMenuTargetHandler(layers []*lipgloss.Layer, gutter []gutterActHit) (func(tea.MouseClickMsg) ([]byte, bool), uint64) {
	if m.whichKeyVisible() {
		return nil, 0
	}
	var rows []actMenuChromeHit
	picker := m.zones.picker
	pickerVisible := m.pickerVisible()
	generation := picker.generation
	if pickerVisible {
		if generation == 0 {
			return nil, 0
		}
		for slot, id := range picker.items {
			if zone := m.zones.Get(pickerPointerZone(slot)); id != 0 && zone != nil {
				rows = append(rows, actMenuChromeHit{box: actMenuZoneRect(zone), kind: actMenuTargetPicker, pickerID: id})
			}
		}
		gutter = nil // The picker owns the full pointer surface while visible.
	} else {
		if tree, ok := m.fileTree(); ok && tree.Visible && tree.Generation != 0 && m.width >= 50 {
			generation = tree.Generation
			first := fileTreeScrollOffset(tree, m.layout.body.Height)
			for index := first; index < min(first+m.layout.body.Height, len(tree.Rows)); index++ {
				if zone := m.zones.Get(zoneIDFileTreeRow(index)); zone != nil && tree.Rows[index].ID != "" {
					rows = append(rows, actMenuChromeHit{box: actMenuZoneRect(zone), kind: actMenuTargetTree, key: tree.Rows[index].ID})
				}
			}
		}
		if m.agentChatVisible() {
			for id, zone := range m.zones.zones {
				if strings.HasPrefix(id, zonePrefixAgentApproval) && m.layout.body.Contains(zone.StartX, zone.StartY) {
					rows = append(rows, actMenuChromeHit{box: actMenuZoneRect(zone), kind: actMenuTargetApproval, key: id})
				}
			}
		}
		rows = m.appendTasksActMenuHits(rows)
	}
	if len(gutter) == 0 && len(rows) == 0 {
		return nil, 0
	}
	var stamp uint64
	if len(rows) != 0 {
		// Order-independent for scanned transcript zones, but includes their
		// bounds and exact identities for visually identical replacements.
		stamp = uint64(generation)
		for _, row := range rows {
			stamp ^= maphash.Comparable(actMenuHitSeed, row)
		}
	}
	// Do not capture Model: its maps may already hold the next commit.
	gridY, drawer := m.layout.grid.Y, m.layout.drawer
	return func(click tea.MouseClickMsg) ([]byte, bool) {
		layerZ := 1 // Main body content.
		switch {
		case pickerVisible:
			layerZ = pickerLayerZ
		case drawer.Contains(click.X, click.Y):
			layerZ = tasksDrawerLayerZ
		}
		for _, layer := range layers {
			if layer.GetZ() <= layerZ {
				continue
			}
			box := uiRect{X: layer.GetX(), Y: layer.GetY(), Width: layer.Width(), Height: layer.Height()}
			if box.Contains(click.X, click.Y) {
				return nil, false
			}
		}
		for _, hit := range gutter {
			if hit.x != click.X || hit.y != click.Y {
				continue
			}
			if hit.head.Unit != 0 {
				return protocol.EncodeGUIReviewRibbonAct(hit.window, hit.revision, hit.head, uint16(click.Y-gridY), uint16(click.X)), true
			}
			if click.Button == tea.MouseRight {
				if hit.authored {
					return nil, true // Do not retarget a non-head mark to the text under it.
				}
				return protocol.EncodeGUIActMenuFoldTarget(hit.window, hit.revision, hit.foldLine), true
			}
		}
		if click.Button == tea.MouseRight {
			for _, row := range rows {
				if !row.box.Contains(click.X, click.Y) {
					continue
				}
				switch row.kind {
				case actMenuTargetPicker:
					return protocol.EncodeGUIActMenuPickerTarget(generation, row.pickerID), true
				case actMenuTargetTree:
					return protocol.EncodeGUIActMenuFileTreeTarget(uint64(generation), row.key), true
				case actMenuTargetApproval:
					target, _ := agentApprovalZoneTarget(row.key)
					return protocol.EncodeGUIActMenuAgentApprovalTarget(target), true
				case actMenuTargetTask:
					return protocol.EncodeGUIActMenuTasksTarget(row.key), true
				}
			}
		}
		return nil, false
	}, stamp
}

func actMenuZoneRect(zone *zoneInfo) uiRect {
	return uiRect{X: zone.StartX, Y: zone.StartY, Width: zone.EndX - zone.StartX + 1, Height: zone.EndY - zone.StartY + 1}
}

type gitStatusHits struct {
	box     uiRect
	panelID uint64
	retryID uint64
	rows    []gitStatusRowTarget
	// actions are the commands of a clean tree's next steps, by row of its action list.
	actions []string
}

type gitStatusRowTarget struct {
	row     int
	path    string
	section byte
}

func (hits *gitStatusHits) sameTargets(other *gitStatusHits) bool {
	if hits == nil || other == nil {
		return hits == other
	}
	return hits.box == other.box && hits.panelID == other.panelID &&
		hits.retryID == other.retryID && slices.Equal(hits.rows, other.rows) && slices.Equal(hits.actions, other.actions)
}

func (m Model) presentedGitStatusHandler(layers []*lipgloss.Layer) func(tea.MouseClickMsg) {
	hits := m.gitStatusHits
	if hits == nil || hits.box.Height == 0 {
		return nil
	}
	var mask uiRect
	modal := m.pickerVisible() || m.whichKeyVisible()
	if !modal {
		if winner, ok := m.overlayWinner(); ok {
			mask, _ = m.surfaceScreenRect(winner.surfaceID)
		}
	}
	// A layer can paint past its authored hit rect (e.g. padded hover text or
	// a shadow). Neither those cells nor the authored mask may activate Git.
	var paintedMasks []uiRect
	if !modal && len(layers) > 0 {
		paintedMasks = make([]uiRect, 0, len(layers))
		for _, layer := range layers {
			paintedMasks = append(paintedMasks, uiRect{X: layer.GetX(), Y: layer.GetY(), Width: layer.Width(), Height: layer.Height()})
		}
	}
	// Scan replaces the zone map on each View; the individual bounds we keep
	// here are read-only. They include viewport clipping and header placement.
	zones := make([]*zoneInfo, len(hits.rows))
	for i, target := range hits.rows {
		zones[i] = m.zones.Get(zoneIDGitStatusRow(target.row))
	}
	retryZone := m.zones.Get(zoneIDGitRetry)
	actionZones := make([]*zoneInfo, len(hits.actions))
	for i := range hits.actions {
		actionZones[i] = m.zones.Get(zoneIDEmptyListAction(i))
	}
	claim := m.presentedClick
	return func(click tea.MouseClickMsg) {
		if !hits.box.Contains(click.X, click.Y) {
			return
		}
		claim.claimed = true
		if modal || mask.Contains(click.X, click.Y) {
			claim.maskedGit = true
			return
		}
		for _, rect := range paintedMasks {
			if rect.Contains(click.X, click.Y) {
				claim.maskedGit = true
				return
			}
		}
		if hits.retryID != 0 && retryZone.InBounds(click) {
			claim.packet = protocol.EncodeGUIGitPullAndRetry(hits.retryID)
			return
		}
		for i, zone := range actionZones {
			if zone.InBounds(click) {
				claim.packet = protocol.EncodeGUIExecuteCommand(hits.actions[i])
				return
			}
		}
		for i, zone := range zones {
			if zone.InBounds(click) {
				target := hits.rows[i]
				claim.packet = protocol.EncodeGUIGitOpenDiff(hits.panelID, target.path, target.section)
				return
			}
		}
	}
}

func (m Model) sidebarMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	sidebars, ok := m.sidebars()
	if !ok {
		return nil, false
	}
	for _, item := range visibleSidebars(sidebars) {
		zoneInfo := m.zones.Get(zoneIDSidebarItem(item.ID))
		if zoneInfo == nil || !zoneInfo.InBounds(msg) {
			continue
		}
		// Mirror the macOS primary action: "toggle" when the clicked sidebar is
		// already the active one, "activate" otherwise (ActivityBar.swift:39,
		// NativeSidebarRegistry.swift:64).
		action := "activate"
		if item.ID == sidebars.ActiveID {
			action = "toggle"
		}
		return protocol.EncodeGUISidebarAction(item.ID, item.SemanticKind, action), true
	}
	return nil, false
}

func (m Model) hoverActionMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	hover, visible := m.hoverPopup()
	action, ok := m.hoverAction()
	if !visible || !hover.Visible || !ok || action.Offer == 0 {
		return nil, false
	}
	if action.OpenLabel != "" {
		if packet, hit := m.hoverActionAt(msg, action.Offer, 0); hit {
			return packet, true
		}
	}
	if action.Actions {
		if packet, hit := m.hoverActionAt(msg, action.Offer, 1); hit {
			return packet, true
		}
	}
	for _, line := range hover.Lines[min(int(hover.ScrollOffset), len(hover.Lines)):] {
		for _, segment := range line.Segments {
			if segment.LinkID >= 2 {
				if packet, hit := m.hoverActionAt(msg, action.Offer, segment.LinkID); hit {
					return packet, true
				}
			}
		}
	}
	return nil, false
}

func (m Model) hoverActionAt(msg tea.MouseMsg, offer uint64, action uint16) ([]byte, bool) {
	zone := m.zones.Get(zoneIDHoverAction(offer, action))
	if zone != nil && zone.InBounds(msg) {
		return protocol.EncodeGUIHoverOpenAction(offer, action), true
	}
	return nil, false
}

func zoneIDHoverAction(offer uint64, action uint16) string {
	return fmt.Sprintf("hover:%d:%d", offer, action)
}

func reviewModelineTarget(status protocol.StatusBar) (string, int) {
	for index, segment := range status.Left {
		if strings.HasPrefix(segment.Command, reviewModelineCommand) {
			return segment.Command, index
		}
	}
	for index, segment := range status.Right {
		if strings.HasPrefix(segment.Command, reviewModelineCommand) {
			return segment.Command, len(status.Left) + index
		}
	}
	return "", 0
}

// The exact review target belongs to the same flushed view as its hit bounds.
func (m Model) presentedReviewModelineHandler(layers []*lipgloss.Layer) func(tea.MouseClickMsg) {
	status, ok := m.statusBar()
	if !ok || m.pickerVisible() || m.whichKeyVisible() {
		return nil
	}
	command, index := reviewModelineTarget(status)
	if command == "" {
		return nil
	}
	zone := m.zones.Get(zoneIDModelineSegment(index))
	if zone == nil {
		return nil
	}
	claim := m.presentedClick
	return func(click tea.MouseClickMsg) {
		if !zone.InBounds(click) {
			return
		}
		for _, layer := range layers {
			bounds := uiRect{X: layer.GetX(), Y: layer.GetY(), Width: layer.Width(), Height: layer.Height()}
			if bounds.Contains(click.X, click.Y) {
				return
			}
		}
		claim.claimed = true
		claim.packet = protocol.EncodeGUIExecuteCommand(command)
	}
}

func (m Model) modelineMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	status, ok := m.statusBar()
	if !ok {
		return nil, false
	}
	segments := make([]protocol.StatusSegment, 0, len(status.Left)+len(status.Right))
	segments = append(segments, status.Left...)
	segments = append(segments, status.Right...)
	for index, segment := range segments {
		if segment.Command == "" {
			continue
		}
		zoneInfo := m.zones.Get(zoneIDModelineSegment(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			if strings.HasPrefix(segment.Command, reviewModelineCommand) {
				return nil, true // The flushed View alone can activate the review target.
			}
			return protocol.EncodeGUIExecuteCommand(segment.Command), true
		}
	}
	for index, action := range status.MessageActions {
		zoneInfo := m.zones.Get(zoneIDNoticeAction(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIExecuteCommand(action.ID), true
		}
	}
	return nil, false
}

// emptyListMousePacket runs the command of the empty panel's next step under the pointer.
func (m Model) emptyListMousePacket(empty generated.EmptyList, msg tea.MouseMsg) ([]byte, bool) {
	for index, action := range empty.Actions {
		zoneInfo := m.zones.Get(zoneIDEmptyListAction(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIExecuteCommand(action.ID), true
		}
	}
	return nil, false
}

// modePillMousePacket answers a click on the mode pill even while a picker is open: the pill opens the picker's own
// keys over it (docs/design/surfaces.md, Mouse), so the click must not count as a click outside the picker.
func (m Model) modePillMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	status, ok := m.statusBar()
	if !ok {
		return nil, false
	}
	for index, segment := range status.Left {
		if segment.Name != "mode" || segment.Command == "" {
			continue
		}
		if zoneInfo := m.zones.Get(zoneIDModelineSegment(index)); zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIExecuteCommand(segment.Command), true
		}
	}
	return nil, false
}

func (m Model) tabMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	tabs, ok := m.tabBar()
	if !ok {
		return nil, false
	}
	for _, tab := range tabs.Tabs {
		zoneInfo := m.zones.Get(zoneIDTab(tab.ID))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUISelectTab(tab.ID), true
		}
	}
	return nil, false
}

func (m Model) fileTreeMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	tree, ok := m.fileTree()
	if !ok || !tree.Visible {
		return nil, false
	}
	if tree.Empty != nil {
		return m.emptyListMousePacket(*tree.Empty, msg)
	}
	for index := range tree.Rows {
		zoneInfo := m.zones.Get(zoneIDFileTreeRow(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUISemanticItemActivate(byte(presentationFileTree), 1, tree.Generation, []byte(tree.Rows[index].ID)), true
		}
	}
	return nil, false
}
