package ui

import (
	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// chromeDragKind distinguishes the draggable chrome surfaces (ticket #2229, AC3).
type chromeDragKind int

const (
	chromeDragNone chromeDragKind = iota
	chromeDragTab
	chromeDragFileTreeRow
)

// chromeDrag is the in-progress press-drag state for a draggable chrome zone.
// It is recorded on a left press over a tab or file-tree row and consumed on
// the matching release. `moved` gates the action: a press-release without
// intervening drag motion is a plain click (handled by semanticMousePacket),
// not a reorder/drop.
type chromeDrag struct {
	kind  chromeDragKind
	index int    // origin tab index or file-tree row index
	id    uint32 // origin tab id (chromeDragTab only)
	moved bool
}

// handleChromeDrag tracks press-drag-release over tabs and file-tree rows and
// emits a tab_reorder or file_tree_drop gui_action when a drag lands on a
// different valid target. It returns the (possibly updated) model, an optional
// packet to send, and whether the event was fully consumed (so the caller skips
// the single-click and raw-forward paths).
//
// A plain press is recorded but NOT consumed, so the existing select_tab /
// file_tree_click click path still fires on press (matching the macOS
// tap-to-select plus drag-to-reorder split). Motion during an active drag is
// consumed so it does not leak to the buffer as a selection drag. Release is
// consumed when a drag was active; it emits the reorder/drop only if the
// pointer moved onto a different valid target.
func (m Model) handleChromeDrag(msg tea.MouseMsg) (Model, []byte, bool) {
	switch msg.(type) {
	case tea.MouseClickMsg:
		if msg.Mouse().Button != tea.MouseLeft {
			return m, nil, false
		}
		m.mouseDrag = m.chromeDragOrigin(msg)
		// Not consumed: let the press also drive the normal click selection.
		return m, nil, false

	case tea.MouseMotionMsg:
		if m.mouseDrag == nil || msg.Mouse().Button == tea.MouseNone {
			return m, nil, false
		}
		m.mouseDrag.moved = true
		// Consume drag motion over chrome so it is not forwarded as a buffer
		// selection drag.
		return m, nil, true

	case tea.MouseReleaseMsg:
		drag := m.mouseDrag
		if drag == nil {
			return m, nil, false
		}
		m.mouseDrag = nil
		if !drag.moved {
			return m, nil, false
		}
		packet := m.chromeDropPacket(drag, msg)
		// Consume the release whether or not it produced an action: an
		// in-progress chrome drag should not fall through to a raw buffer event.
		return m, packet, true
	}
	return m, nil, false
}

// chromeDragOrigin resolves a left press to a draggable chrome origin, or nil if
// the press is not over a tab or file-tree row zone.
func (m Model) chromeDragOrigin(msg tea.MouseMsg) *chromeDrag {
	if tabs, ok := m.tabBar(); ok {
		for index, tab := range tabs.Tabs {
			zone := m.zones.Get(zoneIDTab(tab.ID))
			if zone != nil && zone.InBounds(msg) {
				return &chromeDrag{kind: chromeDragTab, index: index, id: tab.ID}
			}
		}
	}
	if tree, ok := m.fileTree(); ok && tree.Visible {
		for index := range tree.Rows {
			zone := m.zones.Get(zoneIDFileTreeRow(index))
			if zone != nil && zone.InBounds(msg) {
				return &chromeDrag{kind: chromeDragFileTreeRow, index: index}
			}
		}
	}
	return nil
}

// chromeDropPacket builds the gui_action for a completed drag landing on the
// target under the release point, or nil if there is no valid distinct target.
func (m Model) chromeDropPacket(drag *chromeDrag, msg tea.MouseMsg) []byte {
	switch drag.kind {
	case chromeDragTab:
		return m.tabReorderPacket(drag, msg)
	case chromeDragFileTreeRow:
		return m.fileTreeDropPacket(drag, msg)
	}
	return nil
}

// tabReorderPacket emits tab_reorder(origin_id, target_index) when the release
// lands on a different tab. new_index is the zero-based slot of the tab under
// the release point.
func (m Model) tabReorderPacket(drag *chromeDrag, msg tea.MouseMsg) []byte {
	tabs, ok := m.tabBar()
	if !ok {
		return nil
	}
	for index, tab := range tabs.Tabs {
		zone := m.zones.Get(zoneIDTab(tab.ID))
		if zone == nil || !zone.InBounds(msg) {
			continue
		}
		if index == drag.index {
			return nil
		}
		return protocol.EncodeGUITabReorder(drag.id, uint16(index))
	}
	return nil
}

// fileTreeDropPacket emits file_tree_drop when a row is dragged onto a different
// row. The BEAM resolves the actual destination directory (a file target drops
// into its parent), so any distinct target row is a valid drop; the BEAM
// validates the target against its own tree via the echoed path hash.
func (m Model) fileTreeDropPacket(drag *chromeDrag, msg tea.MouseMsg) []byte {
	tree, ok := m.fileTree()
	if !ok || !tree.Visible {
		return nil
	}
	if drag.index < 0 || drag.index >= len(tree.Rows) {
		return nil
	}
	source := tree.Rows[drag.index]
	for index, row := range tree.Rows {
		zone := m.zones.Get(zoneIDFileTreeRow(index))
		if zone == nil || !zone.InBounds(msg) {
			continue
		}
		if index == drag.index {
			return nil
		}
		return protocol.EncodeGUIFileTreeDrop(
			uint16(index),
			row.PathHash,
			row.Directory,
			0,
			row.ID,
			row.Path,
			[]string{source.Path},
		)
	}
	return nil
}
