package ui

import (
	"encoding/binary"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	xansi "github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestEditorTextTargetUsesPresentedWrappedRowAndComposedUTF16(t *testing.T) {
	model := New(30, 8, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID: 7, ContentEpoch: 9,
		Rows: []protocol.WindowRow{
			{ID: 91, BufferLine: 9, Text: "overscan"},
			{ID: 100, BufferLine: 10, Text: "first wrap"},
			{ID: 101, BufferLine: 10, Text: "a界e\u0301😀z"},
			{ID: 110, BufferLine: 11, Text: "next"},
		},
		GeometrySet: true,
		Geometry: protocol.PaneGeometry{
			ContentRect:  protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1},
			TextRect:     protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1},
			ViewportRows: 1,
		},
		ScrollLeft: 1, ScrollLeftSet: true, ScrollSet: true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 10, AnchorVisualRowOffset: 1,
			VisibleStartLine: 10, VisibleEndLine: 11, OverscanStartLine: 9, OverscanEndLine: 12,
			LayoutGeneration: 4,
		},
	})
	model.textPresentations[7] = 700

	// Row zero is the second wrapped row, not the payload's overscan row. The
	// effective left clip skips "a". Both cells of 界 resolve to its UTF-16 start,
	// and the combining cluster resolves to the start of "e\u0301".
	assertTextTarget(t, model, model.layout.body.X+0, model.layout.body.Y, 7, 700, 2, 101, 1)
	assertTextTarget(t, model, model.layout.body.X+1, model.layout.body.Y, 7, 700, 2, 101, 1)
	assertTextTarget(t, model, model.layout.body.X+2, model.layout.body.Y, 7, 700, 2, 101, 2)
	assertTextTarget(t, model, model.layout.body.X+3, model.layout.body.Y, 7, 700, 2, 101, 4)

	// A local horizontal presentation offset uses the same effective clipping as
	// renderRow. The partially clipped wide glyph remains the first rendered cell.
	model.localPresentation.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 0, contentEpoch: 9, layoutGeneration: 4, colOffset: 1}
	assertTextTarget(t, model, model.layout.body.X, model.layout.body.Y, 7, 700, 2, 101, 1)

	// Local vertical scroll advances the absolute payload-store rank.
	model.localPresentation.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 0, contentEpoch: 9, layoutGeneration: 4, rowOffset: 1}
	assertTextTarget(t, model, model.layout.body.X, model.layout.body.Y, 7, 700, 3, 110, 1)
}

func TestComposedUTF16OffsetRetainsRenderRowWideClipBehavior(t *testing.T) {
	model := New(10, 3, nil, nil)
	window := protocol.WindowContent{ScrollLeft: 1, ScrollLeftSet: true}
	row := protocol.WindowRow{Text: "界a"}
	rendered := xansi.Strip(model.renderRow(window, row, 0, 4, false, 0))
	if !strings.HasPrefix(rendered, "界a") {
		t.Fatalf("partially clipped wide grapheme changed render behavior: %q", rendered)
	}
	if got := composedUTF16OffsetAtCell(row.Text, 1, 0); got != 0 {
		t.Fatalf("first wide cell offset = %d, want 0", got)
	}
	if got := composedUTF16OffsetAtCell(row.Text, 1, 1); got != 0 {
		t.Fatalf("second wide cell offset = %d, want 0", got)
	}
	if got := composedUTF16OffsetAtCell(row.Text, 1, 2); got != 1 {
		t.Fatalf("cell after wide grapheme offset = %d, want 1", got)
	}
}

func TestEditorTextDragKeepsSplitOriginAndCleansUpTargetlessRelease(t *testing.T) {
	model := New(24, 6, nil, nil)
	model.putWindow(textMouseWindow(1, 0, "left", 11))
	model.putWindow(textMouseWindow(2, 10, "right", 22))
	model.textPresentations[1] = 101
	model.textPresentations[2] = 202

	updated, press, handled := model.handleEditorTextMouse(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + 1, Y: model.layout.body.Y}))
	if !handled || press[0] != generated.OPEditorTextEvent || updated.textDrag == nil || updated.textDrag.windowID != 1 {
		t.Fatalf("left split press did not capture text drag: handled=%v packet=%v drag=%+v", handled, press, updated.textDrag)
	}

	updated, drag, handled := updated.handleEditorTextMouse(tea.MouseMotionMsg(tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + 14, Y: model.layout.body.Y + 3}))
	if !handled || binary.BigEndian.Uint16(drag[1:3]) != 1 || binary.BigEndian.Uint64(drag[3:11]) != 101 || drag[29] != protocol.MouseDrag || int8(drag[31]) != 1 || int8(drag[32]) != 1 {
		t.Fatalf("cross-split drag must stay on origin with right and bottom edge scroll: handled=%v packet=%v", handled, drag)
	}

	delete(updated.textPresentations, 1)
	updated, release, handled := updated.handleEditorTextMouse(tea.MouseReleaseMsg(tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + 14, Y: model.layout.body.Y}))
	if !handled || updated.textDrag != nil {
		t.Fatalf("stale release must be handled and clear drag: handled=%v drag=%+v", handled, updated.textDrag)
	}
	if binary.BigEndian.Uint16(release[1:3]) != 1 || binary.BigEndian.Uint64(release[3:11]) != 0 || binary.BigEndian.Uint32(release[11:15]) != 0 || binary.BigEndian.Uint64(release[15:23]) != 0 || release[29] != protocol.MouseRelease {
		t.Fatalf("stale release must carry a zero target for the origin window: %v", release)
	}
}

func TestEditorTextHoverUsesPresentedTarget(t *testing.T) {
	model := New(20, 5, nil, nil)
	model.putWindow(textMouseWindow(3, 0, "hover", 33))
	model.textPresentations[3] = 303
	_, packet, handled := model.handleEditorTextMouse(tea.MouseMotionMsg(tea.Mouse{Button: tea.MouseNone, X: model.layout.body.X + 2, Y: model.layout.body.Y, Mod: tea.ModCtrl}))
	if !handled || packet[27] != 3 || packet[28] != protocol.ModCtrl || packet[29] != protocol.MouseMotion {
		t.Fatalf("hover event = handled %v packet %v", handled, packet)
	}
}

func TestEditorTextButtonAndEventSemantics(t *testing.T) {
	model := New(20, 5, nil, nil)
	model.putWindow(textMouseWindow(3, 0, "buttons", 33))
	model.textPresentations[3] = 303
	x, y := model.layout.body.X+1, model.layout.body.Y

	tests := []struct {
		name       string
		msg        tea.MouseMsg
		wantButton byte
		wantType   byte
	}{
		{name: "middle press", msg: tea.MouseClickMsg(tea.Mouse{Button: tea.MouseMiddle, X: x, Y: y}), wantButton: 1, wantType: protocol.MousePress},
		{name: "right press", msg: tea.MouseClickMsg(tea.Mouse{Button: tea.MouseRight, X: x, Y: y}), wantButton: 2, wantType: protocol.MousePress},
		{name: "free motion", msg: tea.MouseMotionMsg(tea.Mouse{Button: tea.MouseNone, X: x, Y: y}), wantButton: 3, wantType: protocol.MouseMotion},
		{name: "middle release", msg: tea.MouseReleaseMsg(tea.Mouse{Button: tea.MouseMiddle, X: x, Y: y}), wantButton: 1, wantType: protocol.MouseRelease},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, packet, handled := model.handleEditorTextMouse(tt.msg)
			if !handled || packet[27] != tt.wantButton || packet[29] != tt.wantType || packet[30] != 1 {
				t.Fatalf("event = handled %v packet %v", handled, packet)
			}
		})
	}
}

func TestEditorTextHitIgnoresStructuralSurfaceRegistryPlacements(t *testing.T) {
	model := New(20, 5, nil, nil)
	model.putWindow(textMouseWindow(3, 0, "visible", 33))
	model.textPresentations[3] = 303
	// SurfaceRegistry places editor_area and buffer_content. Its :window node is
	// the structural container represented here by the semantic WindowContent.
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: 1, Rect: generated.Rect{Row: uint16(model.layout.body.Y), Col: uint16(model.layout.body.X), Width: 20, Height: 5}, Z: 100, HitKind: 7},
		{SurfaceID: 3, Rect: generated.Rect{Row: uint16(model.layout.body.Y), Col: uint16(model.layout.body.X), Width: 8, Height: 2}, Z: 101, HitKind: 1},
	}
	_, packet, handled := model.handleEditorTextMouse(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + 1, Y: model.layout.body.Y}))
	if !handled || packet == nil || packet[0] != generated.OPEditorTextEvent {
		t.Fatalf("editor_area, semantic window, and buffer_content must allow text hit: handled=%v packet=%v", handled, packet)
	}
}

func TestEditorTextInitialHitDefersToVisiblePlacedOverlay(t *testing.T) {
	model := New(20, 5, nil, nil)
	model.putWindow(textMouseWindow(3, 0, "covered", 33))
	model.textPresentations[3] = 303
	model.chrome[generated.OPGuiCompletion] = protocol.ChromePayload{
		Opcode: generated.OPGuiCompletion,
		Complete: protocol.Completion{
			Visible: true,
			Items:   []protocol.CompletionItem{{ID: "item", Label: "item"}},
		},
	}
	model.surfacePlacements = []generated.SurfacePlacement{{
		SurfaceID: surfaceIDCompletionMenu,
		Rect:      generated.Rect{Row: uint16(model.layout.body.Y), Col: uint16(model.layout.body.X), Width: 8, Height: 2},
		Z:         301,
		HitKind:   8,
	}}
	_, packet, handled := model.handleEditorTextMouse(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + 1, Y: model.layout.body.Y}))
	if handled || packet != nil {
		t.Fatalf("visible placed overlay must keep initial hit priority: handled=%v packet=%v", handled, packet)
	}
}

func TestTextPresentationLifecycleActivatesBeforeDiscardingPastPresentation(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(20, 5, out, nil)
	model.textPresentations[7] = 70
	commands := []protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 2, BaseFrameSeq: 1, Generation: 1},
		{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 71}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 2},
	}
	model.lastCommittedSeq = 1
	model.lastCommittedGeneration = 1
	updated, _ := model.Update(port.PacketMsg{Commands: commands})
	model = updated.(Model)

	if applied := <-out; applied[0] != generated.OPFrameApplied {
		t.Fatalf("frame must be acknowledged before its presentation activates: %v", applied)
	}
	active := <-out
	discarded := <-out
	if active[0] != generated.OPTextPresentationState || binary.BigEndian.Uint64(active[3:11]) != 71 || active[11] != protocol.TextPresentationActive {
		t.Fatalf("first lifecycle packet should activate new presentation: %v", active)
	}
	if discarded[0] != generated.OPTextPresentationState || binary.BigEndian.Uint64(discarded[3:11]) != 70 || discarded[11] != protocol.TextPresentationDiscarded {
		t.Fatalf("second lifecycle packet should discard past presentation: %v", discarded)
	}
}

func TestTextPresentationLifecycleSkipsIntermediateCommittedModelInOneUpdate(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(20, 5, out, nil)
	model.textPresentations[7] = 70
	model.lastCommittedSeq = 1
	model.lastCommittedGeneration = 1
	commands := []protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 2, BaseFrameSeq: 1, Generation: 1},
		{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 71}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 2},
		{Kind: protocol.CommandBeginFrame, FrameSeq: 3, BaseFrameSeq: 2, Generation: 1},
		{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 72}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 3},
	}
	updated, _ := model.Update(port.PacketMsg{Commands: commands})
	model = updated.(Model)

	packets := drainPackets(out)
	active := presentationStateIDs(packets, protocol.TextPresentationActive)
	discarded := presentationStateIDs(packets, protocol.TextPresentationDiscarded)
	if len(active) != 1 || active[0] != 72 {
		t.Fatalf("only final input model should activate, active=%v packets=%v", active, packets)
	}
	if !containsUint64(discarded, 70) || !containsUint64(discarded, 71) {
		t.Fatalf("past and unused presentations should discard, discarded=%v packets=%v", discarded, packets)
	}
}

func TestRejectedTextPresentationIsDiscardedWithoutReplacingInputModel(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(20, 5, out, nil)
	model.textPresentations[7] = 70
	commands := []protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 3, BaseFrameSeq: 99, Generation: 1},
		{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 72}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 3},
	}
	model.lastCommittedSeq = 1
	updated, _ := model.Update(port.PacketMsg{Commands: commands})
	model = updated.(Model)

	packets := drainPackets(out)
	if len(packets) == 0 || packets[0][0] != generated.OPFrameRejected {
		t.Fatalf("expected frame rejection first, got %v", packets)
	}
	discarded := presentationStateIDs(packets, protocol.TextPresentationDiscarded)
	if len(discarded) != 1 || discarded[0] != 72 {
		t.Fatalf("rejected candidate should be discarded: %v", packets)
	}
	if model.textPresentations[7] != 70 {
		t.Fatalf("rejection replaced active input model: %+v", model.textPresentations)
	}
}

func presentationStateIDs(packets [][]byte, state byte) []uint64 {
	ids := make([]uint64, 0)
	for _, packet := range packets {
		if len(packet) == 12 && packet[0] == generated.OPTextPresentationState && packet[11] == state {
			ids = append(ids, binary.BigEndian.Uint64(packet[3:11]))
		}
	}
	return ids
}

func containsUint64(values []uint64, wanted uint64) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func drainPackets(out <-chan []byte) [][]byte {
	packets := make([][]byte, 0, len(out))
	for len(out) > 0 {
		packets = append(packets, <-out)
	}
	return packets
}

func assertTextTarget(t *testing.T, model Model, x, y int, wantWindow uint16, wantPresentation uint64, wantRowIndex uint32, wantRowID uint64, wantUTF16 uint32) {
	t.Helper()
	_, packet, handled := model.handleEditorTextMouse(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: x, Y: y}))
	if !handled {
		t.Fatal("text click was not handled")
	}
	if got := binary.BigEndian.Uint16(packet[1:3]); got != wantWindow {
		t.Fatalf("window_id = %d, want %d", got, wantWindow)
	}
	if got := binary.BigEndian.Uint64(packet[3:11]); got != wantPresentation {
		t.Fatalf("presentation_id = %d, want %d", got, wantPresentation)
	}
	if got := binary.BigEndian.Uint32(packet[11:15]); got != wantRowIndex {
		t.Fatalf("row_index = %d, want %d", got, wantRowIndex)
	}
	if got := binary.BigEndian.Uint64(packet[15:23]); got != wantRowID {
		t.Fatalf("row_id = %d, want %d", got, wantRowID)
	}
	if got := binary.BigEndian.Uint32(packet[23:27]); got != wantUTF16 {
		t.Fatalf("utf16_offset = %d, want %d", got, wantUTF16)
	}
}

func textMouseWindow(id uint16, col int, text string, rowID uint64) protocol.WindowContent {
	return protocol.WindowContent{
		ID: id, ContentEpoch: 1,
		Rows:        []protocol.WindowRow{{ID: rowID, BufferLine: 0, Text: text}},
		GeometrySet: true,
		Geometry: protocol.PaneGeometry{
			ContentRect:  protocol.Rect{Row: 0, Col: uint16(col), Width: 8, Height: 2},
			TextRect:     protocol.Rect{Row: 0, Col: uint16(col), Width: 8, Height: 2},
			ViewportRows: 2,
		},
	}
}
