package ui

import (
	"fmt"
	"net/url"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	zonePrefixFileTreeRow       = "file-tree:row:"
	zonePrefixModelineCommand   = "modeline:command:"
	zonePrefixTab               = "tab:id:"
	zonePrefixBreadcrumbSegment = "breadcrumb:segment:"
	zonePrefixCompletionItem    = "completion:item:"
	zonePrefixSidebarItem       = "sidebar:item:"
	zoneIDHoverAction           = "hover:action"
	bottomPanelWheelLines       = 3
)

func zoneIDFileTreeRow(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixFileTreeRow, index)
}

func zoneIDModelineCommand(command string) string {
	return zonePrefixModelineCommand + url.QueryEscape(command)
}

func zoneIDTab(id uint32) string {
	return fmt.Sprintf("%s%d", zonePrefixTab, id)
}

func zoneIDBreadcrumbSegment(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixBreadcrumbSegment, index)
}

func zoneIDCompletionItem(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixCompletionItem, index)
}

func zoneIDSidebarItem(id string) string {
	return zonePrefixSidebarItem + url.QueryEscape(id)
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
	if packet, ok := m.modelineMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.tabMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.fileTreeMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.breadcrumbMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.completionMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.sidebarMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.hoverActionMousePacket(msg); ok {
		return packet, true
	}
	return nil, false
}

func (m Model) breadcrumbMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	crumb, ok := m.breadcrumb()
	if !ok || len(crumb.Segments) == 0 {
		return nil, false
	}
	for index := range crumb.Segments {
		zoneInfo := m.zones.Get(zoneIDBreadcrumbSegment(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIBreadcrumbClick(byte(min(index, 0xFF))), true
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
