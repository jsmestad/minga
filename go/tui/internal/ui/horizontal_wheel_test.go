package ui

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	xansi "github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestHorizontalWheelPacketsMatchPaintedSteps(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(16, 7, out)
	model.gutters[7] = protocol.Gutter{SignColWidth: 2}
	model.putWindow(protocol.WindowContent{
		ID: 7, ContentEpoch: 9, GeometrySet: true, ScrollSet: true,
		CursorVisible: true, CursorCol: 2,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 1, Text: "a界c😀Z"},
			{ID: 2, ContentHash: 2, BufferLine: 1, Text: "other"},
			{ID: 3, ContentHash: 3, BufferLine: 2, Text: "last"},
		},
		Geometry: protocol.PaneGeometry{
			ContentRect: protocol.Rect{Width: 8, Height: 2},
			TextRect:    protocol.Rect{Col: 3, Width: 5, Height: 2},
			TotalLines:  3,
		},
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, VisibleEndLine: 2, OverscanEndLine: 3,
			CanPanHorizontally: true, HorizontalPanLimit: 3,
		},
	})
	model.textPresentations[7] = 70
	x, y := model.layout.body.X+3, model.layout.body.Y
	wheel := func(button tea.MouseButton, mod tea.KeyMod) tea.Msg {
		return tea.MouseWheelMsg(tea.Mouse{Button: button, Mod: mod, X: x, Y: y})
	}
	fragment := func(code int) tea.Msg {
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: fmt.Sprintf("<%d;%d;%dM", code, x+1, y+1)})
	}
	filter := NewInputFilter()
	for _, step := range []struct {
		name string
		msg  tea.Msg
		want []byte
		row  string
	}{
		{"left bound", wheel(tea.MouseWheelLeft, 0), nil, "   a界c▐"},
		{"shift down", wheel(tea.MouseWheelDown, tea.ModShift), protocol.EncodeHorizontalPan(7, 1, 1), "   界c ▐"},
		{"physical right", wheel(tea.MouseWheelRight, 0), protocol.EncodeHorizontalPan(7, 1, 2), "    c😀▐"},
		{"fragmented shift down", fragment(69), protocol.EncodeHorizontalPan(7, 1, 3), "   c😀Z▐"},
		{"right bound", wheel(tea.MouseWheelRight, 0), nil, "   c😀Z▐"},
		{"shift up", wheel(tea.MouseWheelUp, tea.ModShift), protocol.EncodeHorizontalPan(7, -1, 4), "    c😀▐"},
		{"physical left", wheel(tea.MouseWheelLeft, tea.ModShift), protocol.EncodeHorizontalPan(7, -1, 5), "   界c ▐"},
		{"fragmented shift up", fragment(68), protocol.EncodeHorizontalPan(7, -1, 6), "   a界c▐"},
	} {
		updated, _ := model.Update(filter.Filter(model, step.msg))
		model = updated.(Model)
		packets := drainPackets(out)
		if (step.want == nil && len(packets) != 0) || (step.want != nil && (len(packets) != 1 || !bytes.Equal(packets[0], step.want))) {
			t.Fatalf("%s: packets = %v, want %v", step.name, packets, step.want)
		}
		windows := model.windows[7]
		if painted := xansi.Strip(model.renderWindowRows(windows)[0]); painted != step.row {
			t.Fatalf("%s: first row = %q, want %q", step.name, painted, step.row)
		}
		if windows.ScrollLeft != 0 || windows.CursorRow != 0 || windows.CursorCol != 2 || !windows.CursorVisible {
			t.Fatalf("%s: local pan changed committed viewport or caret: left=%d cursor=%d,%d visible=%v", step.name, windows.ScrollLeft, windows.CursorRow, windows.CursorCol, windows.CursorVisible)
		}
		if step.name == "right bound" {
			assertTextTarget(t, model, x+3, y, 7, 70, 0, 1, 5)
			if target, ok := model.editorTextTargetAt(x+4, y, 0); ok {
				t.Fatalf("scrollbar cell was accepted as a text target: %+v", target)
			}
		}
	}
}

func TestHorizontalWheelIgnoresLongRowsOutsideCommittedViewport(t *testing.T) {
	out := make(chan []byte, 8)
	model := New(16, 7, out)
	model.putWindow(protocol.WindowContent{
		ID: 7, ContentEpoch: 9, GeometrySet: true, ScrollSet: true,
		Geometry: protocol.PaneGeometry{
			ContentRect: protocol.Rect{Width: 5, Height: 2},
			TextRect:    protocol.Rect{Width: 4, Height: 2},
			TotalLines:  4,
		},
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 1, Text: "abc"},
			{ID: 2, ContentHash: 2, BufferLine: 1, Text: "xy"},
			{ID: 3, ContentHash: 3, BufferLine: 2, Text: strings.Repeat("unseen ", 16)},
			{ID: 4, ContentHash: 4, BufferLine: 3, Text: strings.Repeat("overscan ", 16)},
		},
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, VisibleEndLine: 2, OverscanEndLine: 4,
			CanPanHorizontally: true, HorizontalPanLimit: 0,
		},
	})

	for _, wheel := range []tea.Mouse{
		{Button: tea.MouseWheelRight},
		{Button: tea.MouseWheelDown, Mod: tea.ModShift},
	} {
		wheel.X, wheel.Y = model.layout.body.X, model.layout.body.Y
		updated, _ := model.Update(tea.MouseWheelMsg(wheel))
		model = updated.(Model)
	}
	if packets := drainPackets(out); len(packets) != 0 {
		t.Fatalf("horizontal wheel sent pan past the zero limit: %v", packets)
	}
	rows := model.renderWindowRows(model.windows[7])
	for index, want := range []string{"abc", "xy"} {
		if got := strings.TrimRight(xansi.Strip(rows[index]), " ▐"); got != want {
			t.Fatalf("visible row %d after wheel = %q, want %q", index, got, want)
		}
	}
}

func horizontalWheelWindow() protocol.WindowContent {
	rect := protocol.Rect{Width: 4, Height: 1}
	return protocol.WindowContent{
		ID: 7, ContentEpoch: 9, GeometrySet: true, ScrollSet: true,
		Geometry: protocol.PaneGeometry{ContentRect: rect, TextRect: rect, TotalLines: 1},
		Rows:     []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "abcdefghi"}},
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, LayoutGeneration: 2, ScrollSeq: 5, ResetRequired: true,
			CanPanHorizontally: true, HorizontalPanLimit: 5,
		},
	}
}

func TestHorizontalWheelReversesFromPastCommittedExtent(t *testing.T) {
	out := make(chan []byte, 8)
	model := New(16, 7, out)
	window := horizontalWheelWindow()
	window.Rows[0].Text = "abcdef"
	window.ScrollLeft, window.Scroll.AnchorLeft, window.Geometry.ViewportLeft = 4, 4, 4
	window.Scroll.HorizontalPanLimit = 2
	model.putWindow(window)

	for _, step := range []struct {
		button tea.MouseButton
		left   int
		want   []byte
	}{
		{tea.MouseWheelRight, 4, nil},
		{tea.MouseWheelLeft, 3, protocol.EncodeHorizontalPan(7, -1, 1)},
		{tea.MouseWheelRight, 3, nil},
		{tea.MouseWheelLeft, 2, protocol.EncodeHorizontalPan(7, -1, 2)},
		{tea.MouseWheelRight, 2, nil},
		{tea.MouseWheelLeft, 1, protocol.EncodeHorizontalPan(7, -1, 3)},
		{tea.MouseWheelRight, 2, protocol.EncodeHorizontalPan(7, 1, 4)},
	} {
		wheel := tea.Mouse{Button: step.button, X: model.layout.body.X, Y: model.layout.body.Y}
		updated, _ := model.Update(tea.MouseWheelMsg(wheel))
		model = updated.(Model)
		packets := drainPackets(out)
		if (step.want == nil && len(packets) != 0) || (step.want != nil && (len(packets) != 1 || !bytes.Equal(packets[0], step.want))) {
			t.Fatalf("wheel %v to column %d: packets = %v, want %v", step.button, step.left, packets, step.want)
		}
		if got := model.presentationScrollEffectiveLeft(model.windows[7]); got != step.left {
			t.Fatalf("wheel %v: presented left = %d, want %d", step.button, got, step.left)
		}
	}
}

func TestHorizontalWheelEchoRebasesThenYieldsToAuthority(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(16, 7, out)
	window := horizontalWheelWindow()
	window.Scroll.HorizontalPanAck = 40
	window.Geometry.ContentRect.Width = 5 // Four text cells and one scrollbar cell.
	window.Geometry.TotalLines = 3
	window.Scroll.VisibleEndLine, window.Scroll.OverscanEndLine = 1, 3
	window.Rows = append(window.Rows,
		protocol.WindowRow{ID: 2, ContentHash: 2, BufferLine: 1, Text: "ABCDEFGHI"},
		protocol.WindowRow{ID: 3, ContentHash: 3, BufferLine: 2, Text: "012345678"},
	)
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, commitFrame(1))
	drainPackets(out)
	wheel := func(button tea.MouseButton, seq uint32) {
		t.Helper()
		updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{Button: button, X: model.layout.body.X, Y: model.layout.body.Y}))
		model = updated.(Model)
		delta := int16(1)
		if button == tea.MouseWheelLeft {
			delta = -1
		}
		packets := drainPackets(out)
		if want := protocol.EncodeHorizontalPan(7, delta, seq); len(packets) != 1 || !bytes.Equal(packets[0], want) {
			t.Fatalf("wheel sequence %d: packets = %v, want %v", seq, packets, want)
		}
	}
	frameID := uint32(1)
	echo := func(left uint16, presentation *protocol.ScrollPresentation) {
		t.Helper()
		frameID++
		delta := protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeftSet: true, ScrollLeft: left}
		if presentation != nil {
			delta.ScrollSet = true
			delta.Scroll = *presentation
			delta.Scroll.AnchorLeft = left
			delta.Scroll.VisibleStartLine = delta.Scroll.AnchorTop
			delta.Scroll.VisibleEndLine = delta.Scroll.AnchorTop + 1
			delta.GeometrySet = true
			delta.Geometry = window.Geometry
			delta.Geometry.ViewportTop = delta.Scroll.AnchorTop
			delta.Geometry.ViewportLeft = left
		}
		model = applyTo(t, model, beginFrame(frameID, frameID-1), protocol.Command{Kind: protocol.CommandWindowDelta, Window: delta}, commitFrame(frameID))
		if model.lastFrameOutcome != frameOutcomeApplied || model.windows[7].ScrollLeft != left {
			t.Fatalf("frame %d did not commit left %d", frameID, left)
		}
		drainPackets(out)
	}
	assertPaint := func(want string) {
		t.Helper()
		if got := strings.TrimRight(xansi.Strip(model.renderWindowRows(model.windows[7])[0]), " ▐"); got != want {
			t.Fatalf("frame %d painted %q, want %q", frameID, got, want)
		}
	}

	// A failed enqueue must not pan or consume the next sequence.
	model.out = nil
	updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelRight, X: model.layout.body.X, Y: model.layout.body.Y}))
	model = updated.(Model)
	model.out = out
	assertPaint("abcd")

	wheel(tea.MouseWheelRight, 41)
	wheel(tea.MouseWheelRight, 42)
	wheel(tea.MouseWheelLeft, 43)
	assertPaint("bcde")
	scroll := window.Scroll
	scroll.ResetRequired = false
	scroll.HorizontalPanAck = 41
	echo(1, &scroll) // The first echo lands at the same column as the last.
	assertPaint("bcde")
	scroll.HorizontalPanAck = 42
	echo(2, &scroll)
	assertPaint("bcde")
	scroll.AnchorTop++
	echo(2, &scroll) // Same-basis vertical movement must preserve pending X.
	assertPaint("BCDE")
	scroll.HorizontalPanAck = 43
	echo(1, &scroll)
	assertPaint("BCDE")

	wheel(tea.MouseWheelRight, 44)
	wheel(tea.MouseWheelRight, 45)
	assertPaint("DEFG")
	scroll.HorizontalPanAck = 45
	echo(2, &scroll) // A coalesced acknowledgement adopts the committed left.
	assertPaint("CDEF")

	wheel(tea.MouseWheelRight, 46)
	assertPaint("DEFG")
	echo(2, nil) // No horizontal acknowledgement in this delta.
	assertPaint("DEFG")
	scroll.ScrollSeq--
	scroll.AnchorTop++
	echo(2, &scroll) // A regressed authority sequence with a changed anchor invalidates.
	assertPaint("2345")
	wheel(tea.MouseWheelRight, 47)
	assertPaint("3456")
	scroll.ScrollSeq++
	echo(2, &scroll)
	assertPaint("2345")
	wheel(tea.MouseWheelRight, 48)
	assertPaint("3456")
	scroll.LayoutGeneration++
	echo(2, &scroll)
	assertPaint("2345")
	wheel(tea.MouseWheelRight, 49)
	assertPaint("3456")
	scroll.ResetRequired = true
	echo(2, &scroll)
	assertPaint("2345")

	wheel(tea.MouseWheelRight, 50)
	assertPaint("3456")
	scroll.ResetRequired = false
	scroll.CanPanHorizontally = false
	echo(2, &scroll)
	assertPaint("2345")
}

func TestHorizontalWheelDragDefersPaintAndHitUntilCommit(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(16, 7, out)
	window := horizontalWheelWindow()
	presentation := func(id uint64) protocol.Command {
		return protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: id}}
	}
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, presentation(70), commitFrame(1))
	drainPackets(out)

	mouse := tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + 1, Y: model.layout.body.Y}
	update := func(msg tea.MouseMsg) []byte {
		t.Helper()
		updated, _ := model.Update(msg)
		model = updated.(Model)
		packets := drainPackets(out)
		if len(packets) != 1 {
			t.Fatalf("%T sent %d packets, want one: %v", msg, len(packets), packets)
		}
		return packets[0]
	}
	assertPointer := func(msg tea.MouseMsg, eventType byte, id uint64, offset uint32) {
		t.Helper()
		packet := update(msg)
		if len(packet) != 33 || packet[0] != generated.OPEditorTextEvent ||
			binary.BigEndian.Uint16(packet[1:3]) != 7 || binary.BigEndian.Uint64(packet[3:11]) != id ||
			binary.BigEndian.Uint64(packet[15:23]) != 1 || binary.BigEndian.Uint32(packet[23:27]) != offset ||
			packet[29] != eventType {
			t.Fatalf("%T must hit presentation %d at offset %d: %v", msg, id, offset, packet)
		}
	}
	assertPaint := func(want string) {
		t.Helper()
		if got := xansi.Strip(model.renderWindowRows(model.windows[7])[0]); got != want {
			t.Fatalf("painted %q, want %q", got, want)
		}
	}
	commit := func(frameID uint32, left uint16, ack uint32, presentationID uint64) {
		t.Helper()
		scroll := window.Scroll
		scroll.ResetRequired = false
		scroll.AnchorLeft, scroll.HorizontalPanAck = left, ack
		delta := protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeftSet: true, ScrollLeft: left, ScrollSet: true, Scroll: scroll}
		model = applyTo(t, model, beginFrame(frameID, frameID-1), protocol.Command{Kind: protocol.CommandWindowDelta, Window: delta}, presentation(presentationID), commitFrame(frameID))
		if model.lastFrameOutcome != frameOutcomeApplied || model.windows[7].ScrollLeft != left {
			t.Fatalf("frame %d did not commit left %d", frameID, left)
		}
		drainPackets(out)
	}

	assertPointer(tea.MouseClickMsg(mouse), protocol.MousePress, 70, 1)
	if model.textDrag == nil || model.textDrag.windowID != 7 {
		t.Fatal("left press did not capture the pane")
	}
	for seq := uint32(1); seq <= 2; seq++ {
		wheel := tea.Mouse{Button: tea.MouseWheelRight, X: mouse.X, Y: mouse.Y}
		if packet, want := update(tea.MouseWheelMsg(wheel)), protocol.EncodeHorizontalPan(7, 1, seq); !bytes.Equal(packet, want) {
			t.Fatalf("drag wheel packet = %v, want %v", packet, want)
		}
	}
	assertPaint("abcd")
	assertPointer(tea.MouseMotionMsg(mouse), protocol.MouseDrag, 70, 1)

	commit(2, 1, 1, 71)
	assertPaint("bcde")
	assertPointer(tea.MouseMotionMsg(mouse), protocol.MouseDrag, 71, 2)
	assertPointer(tea.MouseReleaseMsg(mouse), protocol.MouseRelease, 71, 2)
	assertPaint("cdef") // Releasing the drag resumes the still-pending preview.

	commit(3, 2, 2, 72)
	assertPaint("cdef")
	assertTextTarget(t, model, mouse.X, mouse.Y, 7, 72, 0, 1, 3)
}

func TestHorizontalWheelRequiresEligibleUnwrappedPane(t *testing.T) {
	for _, tc := range []struct {
		name     string
		wrapped  bool
		resident bool
	}{
		{"wrapped windowed", true, false},
		{"wrapped resident", true, true},
		{"ineligible unwrapped", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			out := make(chan []byte, 8)
			model := New(20, 8, out)
			window := horizontalWheelWindow()
			window.Scroll.CanPanHorizontally = false
			if tc.wrapped {
				window = wrappedTestWindow(4, 6)
				window.Scroll.CanPanHorizontally = true
				window.Scroll.HorizontalPanLimit = 50
				window.Rows[0].Text = strings.Repeat("long row ", 8)
				window.WrappedResidentRows = tc.resident
				if !tc.resident {
					window.Geometry.TotalVisualRows = 0
				}
			}
			model.putWindow(window)
			initial := strings.Join(model.renderWindowRows(model.windows[7]), "\n")
			for _, wheel := range []tea.Mouse{
				{Button: tea.MouseWheelDown, Mod: tea.ModShift},
				{Button: tea.MouseWheelUp, Mod: tea.ModShift},
				{Button: tea.MouseWheelRight},
				{Button: tea.MouseWheelLeft},
			} {
				wheel.X, wheel.Y = model.layout.body.X+1, model.layout.body.Y
				updated, _ := model.Update(tea.MouseWheelMsg(wheel))
				model = updated.(Model)
			}
			if packets := drainPackets(out); len(packets) != 0 {
				t.Fatalf("horizontal wheel escaped pane eligibility: %v", packets)
			}
			if painted := strings.Join(model.renderWindowRows(model.windows[7]), "\n"); painted != initial {
				t.Fatal("horizontal wheel changed ineligible pane paint")
			}
		})
	}
}
