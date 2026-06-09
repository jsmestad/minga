package ui

import (
	"fmt"
	"net/url"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	zonePrefixFileTreeRow     = "file-tree:row:"
	zonePrefixModelineCommand = "modeline:command:"
	zonePrefixTab             = "tab:id:"
	bottomPanelWheelLines     = 3
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
	footerCount := len(m.footerLines())
	overlayCount := max(footerCount-1, 0)
	if overlayCount == 0 {
		return false
	}
	start := m.height - overlayCount
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
