package ui

import (
	"fmt"
	"net/url"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	zonePrefixFileTreeRow      = "file-tree:row:"
	zonePrefixModelineCommand  = "modeline:command:"
	zonePrefixTab              = "tab:id:"
	zonePrefixCompletionItem   = "completion:item:"
	zonePrefixSidebarItem      = "sidebar:item:"
	zonePrefixNotificationItem = "notification:dismiss:"
	zonePrefixNotificationAct  = "notification:action:"
	zonePrefixObservatoryNode  = "observatory:node:"
	zonePrefixTimelineEntry    = "timeline:entry:"
	zonePrefixEmptyStateItem   = "empty-state:item:"
	zoneIDHoverAction          = "hover:action"
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

func zoneIDModelineCommand(command string) string {
	return zonePrefixModelineCommand + url.QueryEscape(command)
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

// zoneIDTimelineEntry tags one edit-timeline row by its entry index, mirroring
// the macOS circle tap (EditTimelineView.swift:40 sendTimelineNavigate). A
// click routes timeline_navigate(index) to jump to that edit, the same
// destination the keyboard timeline_next_edit/timeline_prev_edit land on (#2335).
func zoneIDTimelineEntry(index byte) string {
	return fmt.Sprintf("%s%d", zonePrefixTimelineEntry, index)
}

func (m Model) localMouse(msg tea.MouseMsg) (Model, bool) {
	mouse := msg.Mouse()
	if mouse.Button != tea.MouseWheelUp && mouse.Button != tea.MouseWheelDown {
		return m, false
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

func (m Model) applyPresentationScrollDelta(msg tea.MouseMsg, delta int) Model {
	mouse := msg.Mouse()
	if !isWheelButton(mouse.Button) {
		return m
	}
	windowID, ok := m.presentationScrollWindowAt(mouse.X, mouse.Y)
	if !ok {
		return m
	}
	window := m.windows[windowID]
	if !window.ScrollSet || window.Scroll.ResetRequired {
		return m
	}
	scroll := m.localPresentation.scrolls[windowID]
	if !scroll.keysMatch(window.Scroll) {
		scroll = presentationScroll{anchorTop: window.Scroll.AnchorTop, anchorLeft: window.Scroll.AnchorLeft, contentEpoch: window.Scroll.ContentEpoch, layoutGeneration: window.Scroll.LayoutGeneration, scrollSeq: window.Scroll.ScrollSeq}
	}
	visibleRows := presentationVisibleRows(window)
	if body := m.bodyHeight(); visibleRows > body && body > 0 {
		visibleRows = body
	}
	before, after := m.presentationScrollRowBounds(window, visibleRows)
	switch mouse.Button {
	case tea.MouseWheelDown, tea.MouseWheelUp:
		if mouse.Mod.Contains(tea.ModShift) {
			// Horizontal scroll is 1-column-at-a-time regardless of coalesced magnitude.
			colDelta := 1
			if delta < 0 {
				colDelta = -1
			}
			scroll.colOffset = max(min(scroll.colOffset+colDelta, m.maxPresentationColOffset(window)), minPresentationColOffset(window))
		} else {
			scroll.rowOffset = max(min(scroll.rowOffset+delta, after), -before)
		}
	case tea.MouseWheelRight:
		scroll.colOffset = min(scroll.colOffset+1, m.maxPresentationColOffset(window))
	case tea.MouseWheelLeft:
		scroll.colOffset = max(scroll.colOffset-1, minPresentationColOffset(window))
	}
	if scroll.rowOffset == 0 && scroll.colOffset == 0 {
		delete(m.localPresentation.scrolls, windowID)
	} else {
		m.localPresentation.scrolls[windowID] = scroll
	}
	return m
}

func (m Model) maxPresentationColOffset(window protocol.WindowContent) int {
	return m.maxPresentationLeft(window) - int(window.ScrollLeft)
}

func minPresentationColOffset(window protocol.WindowContent) int {
	return -int(window.ScrollLeft)
}

func (m Model) maxPresentationLeft(window protocol.WindowContent) int {
	textWidth := int(window.Geometry.TextRect.Width)
	if textWidth <= 0 {
		textWidth = int(window.Geometry.ContentRect.Width)
	}
	textWidth = max(textWidth, 1)
	maxRowWidth := 0
	visible := max(presentationVisibleRows(window), 1)
	start := m.presentationSourceStart(window, visible)
	rows := window.Rows
	if store, ok := m.residentRows[window.ID]; ok {
		rows = store.rangeRows(start, visible+4)
	} else if start < len(rows) {
		rows = rows[start:min(start+visible+4, len(rows))]
	}
	for _, row := range rows {
		maxRowWidth = max(maxRowWidth, displayWidth(row.Text))
	}
	return max(maxRowWidth-textWidth, 0)
}

func (m Model) presentationScrollWindowAt(x int, y int) (uint16, bool) {
	bodyX, bodyY := m.layout.body.Translate(x, y)
	return m.presentationScrollWindowAtBody(bodyX, bodyY)
}

func (m Model) presentationScrollWindowAtBody(x int, y int) (uint16, bool) {
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

// mouseInHoverPopup reports whether screen coordinates (x, y) fall inside the
// hover popup's BEAM placement rect. The placement rect is composited at its
// row/col as screen coordinates (overlayLayer), so a raw mouse coordinate is
// compared directly, matching mouseInBottomPanel. Used to suppress free-motion
// forwarding so motion over the popup does not dismiss it (#2629).
func (m Model) mouseInHoverPopup(x int, y int) bool {
	rect, ok := m.surfacePlacementFor(surfaceIDHoverPopup)
	if !ok {
		return false
	}
	return y >= int(rect.Row) && y < int(rect.Row)+int(rect.Height) &&
		x >= int(rect.Col) && x < int(rect.Col)+int(rect.Width)
}

func (m Model) mouseInBottomPanel(y int) bool {
	// The bottom panel is composited at its BEAM placement rect now (#2281), not
	// footer-appended, so its on-screen band comes from the placement, not from a
	// footer line count. Use the placement rect's row span when present; fall back
	// to the locally computed panel height when no placement was emitted (older
	// BEAM) so frontend scroll still works.
	if rect, ok := m.surfacePlacementFor(surfaceIDBottomPanel); ok {
		return y >= int(rect.Row) && y < int(rect.Row)+int(rect.Height)
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
	// The launchpad takes over the whole editor body, so its clickable rows are
	// checked before the spatial header/left-pane/footer dispatch (#2689).
	if packet, ok := m.emptyStateMousePacket(msg); ok {
		return packet, true
	}
	mouse := msg.Mouse()
	switch {
	case m.layout.header.Contains(mouse.X, mouse.Y):
		return m.headerMousePacket(msg)
	case m.layout.leftPane.Contains(mouse.X, mouse.Y):
		return m.leftPaneMousePacket(msg)
	case m.layout.footer.Contains(mouse.X, mouse.Y):
		return m.footerMousePacket(msg)
	case m.layout.body.Contains(mouse.X, mouse.Y):
		return m.gutterFoldMousePacket(msg)
	}
	return nil, false
}

// overlayMousePacket is checked before spatial dispatch because overlays render
// above all layout zones and must intercept clicks regardless of position.
func (m Model) overlayMousePacket(msg tea.MouseMsg) ([]byte, bool) {
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
	if packet, ok := m.editTimelineMousePacket(msg); ok {
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
	if packet, ok := m.sidebarMousePacket(msg); ok {
		return packet, true
	}
	return nil, false
}

func (m Model) footerMousePacket(msg tea.MouseMsg) ([]byte, bool) {
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
	height := placement.height
	sourceStart := m.presentationSourceStart(window, height)
	sourceRowIndex := localY + sourceStart
	if sourceRowIndex < 0 || sourceRowIndex >= len(gutter.Entries) {
		return nil, false
	}
	entry := gutter.Entries[sourceRowIndex]
	if entry.DisplayType != 1 && entry.DisplayType != 4 {
		return nil, false
	}
	return protocol.EncodeGUIFoldToggleAtLine(gutter.WindowID, entry.BufferLine), true
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
	rect, ok := m.surfacePlacementFor(surfaceIDFloatPopup)
	if !ok {
		return nil, false
	}
	mouse := msg.Mouse()
	row, col := mouse.Y, mouse.X
	// Only clicks inside the band rect are ours; outside it the click is buffer
	// content (or another surface) and must not dismiss.
	if row < int(rect.Row) || row >= int(rect.Row)+int(rect.Height) ||
		col < int(rect.Col) || col >= int(rect.Col)+int(rect.Width) {
		return nil, false
	}
	// Content is bottom-aligned within the rect (overlayLayer): its top row is
	// rect.Row + rect.Height - contentLines. Rows above that are the phantom band,
	// where an outside-the-popup click dismisses; rows at/below it are the popup
	// box itself, which has no clickable affordance, so leave them for containment.
	contentLines := m.floatPopupContentLines(float, int(rect.Height))
	contentTop := int(rect.Row) + int(rect.Height) - contentLines
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

// editTimelineMousePacket maps a click on an edit-timeline row to the same
// semantic gui_action the macOS frontend sends (EditTimelineView.swift):
// timeline_navigate for the clicked entry's index. A click that hits no row zone
// returns ok=false so the overlay's BEAM containment swallows it (the surface is
// registry-placed, #2281), satisfying the AC2 containment fallback (#2335).
func (m Model) editTimelineMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	timeline, ok := m.editTimeline()
	if !ok || !timeline.Visible {
		return nil, false
	}
	for _, entry := range timeline.Entries {
		zoneInfo := m.zones.Get(zoneIDTimelineEntry(entry.Index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUITimelineNavigate(uint16(entry.Index)), true
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

// emptyStateMousePacket maps a click on an activatable launchpad row to
// empty_state_activate(id) (#2689), the same authoritative activation the
// keyboard jump keys reach on the BEAM. Hint rows (footer) carry no zone and
// are never activatable. A click that hits no row returns ok=false so it falls
// through to the raw mouse path.
func (m Model) emptyStateMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	state, ok := m.emptyState()
	if !ok || !state.Visible {
		return nil, false
	}
	for _, section := range state.Sections {
		for _, item := range section.Items {
			if item.Kind == emptyStateKindHint {
				continue
			}
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
	for index := range completion.Items {
		zoneInfo := m.zones.Get(zoneIDCompletionItem(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUICompletionSelect(uint16(index)), true
		}
	}
	return nil, false
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
	action, ok := m.hoverAction()
	if !ok || !action.Visible {
		return nil, false
	}
	zoneInfo := m.zones.Get(zoneIDHoverAction)
	if zoneInfo != nil && zoneInfo.InBounds(msg) {
		return protocol.EncodeGUIHoverOpenAction(), true
	}
	return nil, false
}

func (m Model) modelineMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	status, ok := m.statusBar()
	if !ok {
		return nil, false
	}
	segments := make([]protocol.StatusSegment, 0, len(status.Left)+len(status.Right))
	segments = append(segments, status.Left...)
	segments = append(segments, status.Right...)
	for _, segment := range segments {
		if segment.Command == "" {
			continue
		}
		zoneInfo := m.zones.Get(zoneIDModelineCommand(segment.Command))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
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
	for index := range tree.Rows {
		zoneInfo := m.zones.Get(zoneIDFileTreeRow(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIFileTreeClick(uint16(index)), true
		}
	}
	return nil, false
}
