package ui

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestTerminalGridReportsCommittedHeaderFit(t *testing.T) {
	out := make(chan []byte, 32)
	model := New(100, 16, out)
	if ready := model.ReadyPacket(); !bytes.Equal(ready, protocol.EncodeReady(100, 15)) {
		t.Fatalf("ready must exclude the startup title row: %x", ready)
	}
	assertResize := func(cols, rows uint16) {
		t.Helper()
		var resizes [][]byte
		for _, packet := range drainOutboundPackets(out) {
			if packet[0] == generated.OPResize {
				resizes = append(resizes, packet)
			}
		}
		if cols == 0 {
			if len(resizes) != 0 {
				t.Fatalf("unchanged grid emitted resize: %x", resizes)
			}
		} else if len(resizes) != 1 || !bytes.Equal(resizes[0], protocol.EncodeResize(cols, rows)) {
			t.Fatalf("resize packets = %x, want one %dx%d resize", resizes, cols, rows)
		}
	}
	resize := func(cols, rows int) {
		updated, _ := model.Update(tea.WindowSizeMsg{Width: cols, Height: rows})
		model = updated.(Model)
	}

	resize(100, 16)
	assertResize(0, 0)
	tabs := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiTabBar, Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Label: "document"}}},
	}}
	workspaces := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiWorkspaces, Spaces: protocol.WorkspaceBar{Spaces: []protocol.Workspace{{ID: 1, Label: "one"}, {ID: 2, Label: "two"}}},
	}}
	breadcrumb := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiBreadcrumb, Breadcrumb: protocol.Breadcrumb{Segments: []string{"here"}},
	}}
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), tabs, commitFrame(1))
	assertResize(0, 0) // The tab row replaces the title rather than expanding the header.
	model = applyTo(t, model, beginFrame(2, 1), workspaces)
	assertResize(0, 0) // Uncommitted chrome cannot change the measured grid.
	model = applyTo(t, model, commitFrame(2))
	assertResize(100, 14)
	model = applyTo(t, model, beginFrame(3, 2), breadcrumb, commitFrame(3))
	assertResize(100, 13)
	if model.layout.grid.Y != 3 || model.layout.body.Height != 12 || model.layout.footer.Y != 15 {
		t.Fatalf("three header rows and explicit footer do not fit 16 screen rows: %+v", model.layout)
	}
	model = applyTo(t, model, beginFrame(4, 3), breadcrumb, commitFrame(4))
	assertResize(0, 0)

	resize(99, 16) // The breadcrumb no longer renders below 100 columns.
	assertResize(99, 14)
	resize(99, 16)
	assertResize(0, 0)

	timeline := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiEditTimeline, Timeline: protocol.EditTimeline{Visible: true},
	}}
	placement := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiSurfaceLayout, Placements: []generated.SurfacePlacement{{
			SurfaceID: surfaceIDEditTimeline, Rect: generated.Rect{Row: 9, Width: 99, Height: 3},
		}},
	}}
	model = applyTo(t, model, beginFrame(5, 4), timelineMinibufferCommand(t, true), timeline, placement, commitFrame(5))
	assertResize(0, 0)
	if model.layout.body.Height != 9 || model.layout.timeline.Y != 11 || model.layout.footer.Y != 14 {
		t.Fatalf("timeline and minibuffer reservations must remain inside the grid: %+v", model.layout)
	}
	resize(99, 1)
	assertResize(99, 1)
	if model.layout.body.Height != 0 || len(strings.Split(renderedBody(model), "\n")) != 1 {
		t.Fatalf("one-row screen must not compose a phantom body or footer: %+v", model.layout)
	}
}

func TestTerminalFittedGridShowsLastWindowedWrappedRowAboveStatus(t *testing.T) {
	const width, height = 58, 16
	model := New(width, height, nil)
	ready := model.ReadyPacket()
	// Author the pane using the advertised primary grid, just as terminal layout
	// does. Its last row must be the last drawable screen row above the status.
	paneRows := binary.BigEndian.Uint16(ready[3:5]) - 1
	window := wrappedTestWindow(paneRows, 20)
	window.WrappedResidentRows = false
	window.Geometry.TotalVisualRows = 0
	window.Scroll.AnchorVisualRowOffset = uint16(len(window.Rows)) - paneRows
	window.Geometry.VisualRowOffset = uint32(window.Scroll.AnchorVisualRowOffset)
	window.Rows[len(window.Rows)-1].Text = "last wrapped row"
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, commitFrame(1))
	lines := strings.Split(renderedBody(model), "\n")
	if model.lastFrameOutcome != frameOutcomeApplied || len(lines) != height ||
		!strings.Contains(lines[height-2], "last wrapped row") || !strings.Contains(lines[height-1], "row 1 col 1") {
		t.Fatalf("fitted grid (%d pane rows) did not display the final wrapped row and status: %q", paneRows, lines)
	}
}
