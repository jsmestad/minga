package ui

import (
	"bytes"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func clickAt(zone *zoneInfo) tea.MouseClickMsg {
	return tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY})
}

func dragAt(zone *zoneInfo) tea.MouseMotionMsg {
	return tea.MouseMotionMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY})
}

func releaseAt(zone *zoneInfo) tea.MouseReleaseMsg {
	return tea.MouseReleaseMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY})
}

func tabDragModel(t *testing.T) Model {
	t.Helper()
	model := New(80, 12, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiTabBar: {Tabs: protocol.TabBar{Tabs: []protocol.Tab{
			{ID: 41, Icon: "󰈙", Label: "one.ex"},
			{ID: 42, Icon: "󰈙", Label: "two.ex"},
			{ID: 43, Icon: "󰈙", Label: "three.ex", Active: true},
		}}},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()
	return model
}

func TestChromeDragReordersTabOntoDifferentTab(t *testing.T) {
	model := tabDragModel(t)
	origin := waitForZone(t, model, zoneIDTab(41))
	target := waitForZone(t, model, zoneIDTab(43))

	model, _, _ = model.handleChromeDrag(clickAt(origin))
	model, _, _ = model.handleChromeDrag(dragAt(target))
	model, packet, handled := model.handleChromeDrag(releaseAt(target))

	if !handled {
		t.Fatal("release after a tab drag should be consumed")
	}
	// Tab 41 dropped onto the tab at index 2.
	want := protocol.EncodeGUITabReorder(41, 2)
	if !bytes.Equal(packet, want) {
		t.Fatalf("tab_reorder packet = %v, want %v", packet, want)
	}
	if model.mouseDrag != nil {
		t.Fatal("drag state should be cleared after release")
	}
}

func TestChromeDragWithoutMotionIsNotAReorder(t *testing.T) {
	model := tabDragModel(t)
	origin := waitForZone(t, model, zoneIDTab(41))

	// Press recorded but not consumed, so the normal select_tab click still fires.
	updated, packet, handled := model.handleChromeDrag(clickAt(origin))
	if handled || packet != nil {
		t.Fatal("a tab press should not be consumed so click-to-select still runs")
	}
	if updated.mouseDrag == nil {
		t.Fatal("a tab press should record a drag origin")
	}
	model = updated

	// Release on the same tab with no intervening motion: a plain click, no reorder.
	model, packet, _ = model.handleChromeDrag(releaseAt(origin))
	if packet != nil {
		t.Fatalf("a press-release without motion should not reorder, got %v", packet)
	}
}

func TestChromeDragOntoSameTabDoesNotReorder(t *testing.T) {
	model := tabDragModel(t)
	origin := waitForZone(t, model, zoneIDTab(42))

	model, _, _ = model.handleChromeDrag(clickAt(origin))
	model, _, _ = model.handleChromeDrag(dragAt(origin))
	model, packet, handled := model.handleChromeDrag(releaseAt(origin))

	if !handled {
		t.Fatal("release after a drag should be consumed even with no target change")
	}
	if packet != nil {
		t.Fatalf("dragging a tab onto itself should not reorder, got %v", packet)
	}
}

func fileTreeDragModel(t *testing.T) Model {
	t.Helper()
	model := New(80, 16, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 30, Rows: []protocol.FileTreeRow{
			{ID: "/p/src", Path: "src", PathHash: 0x11111111, Name: "src", Directory: true},
			{ID: "/p/a.ex", Path: "a.ex", PathHash: 0x22222222, Name: "a.ex"},
			{ID: "/p/b.ex", Path: "b.ex", PathHash: 0x33333333, Name: "b.ex"},
		}}},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()
	return model
}

func TestChromeDragDropsFileOntoDirectoryRow(t *testing.T) {
	model := fileTreeDragModel(t)
	// Drag row 1 (a.ex) onto row 0 (src directory).
	origin := waitForZone(t, model, zoneIDFileTreeRow(1))
	target := waitForZone(t, model, zoneIDFileTreeRow(0))

	model, _, _ = model.handleChromeDrag(clickAt(origin))
	model, _, _ = model.handleChromeDrag(dragAt(target))
	model, packet, handled := model.handleChromeDrag(releaseAt(target))

	if !handled {
		t.Fatal("release after a file-tree drag should be consumed")
	}
	want := protocol.EncodeGUIFileTreeDrop(0, 0x11111111, true, 0, "/p/src", "src", []string{"a.ex"})
	if !bytes.Equal(packet, want) {
		t.Fatalf("file_tree_drop packet = %v, want %v", packet, want)
	}
}

func TestChromeDragDropOntoSameRowDoesNothing(t *testing.T) {
	model := fileTreeDragModel(t)
	origin := waitForZone(t, model, zoneIDFileTreeRow(2))

	model, _, _ = model.handleChromeDrag(clickAt(origin))
	model, _, _ = model.handleChromeDrag(dragAt(origin))
	_, packet, _ := model.handleChromeDrag(releaseAt(origin))

	if packet != nil {
		t.Fatalf("dropping a row onto itself should not emit file_tree_drop, got %v", packet)
	}
}

func TestChromeDragMotionWithoutOriginIsIgnored(t *testing.T) {
	model := fileTreeDragModel(t)
	// Motion with no prior press over a draggable zone: not consumed, falls
	// through to the normal (buffer/hover) path.
	_, packet, handled := model.handleChromeDrag(tea.MouseMotionMsg(tea.Mouse{Button: tea.MouseLeft, X: 2, Y: 4}))
	if handled || packet != nil {
		t.Fatal("drag motion without a recorded origin should fall through")
	}
}
