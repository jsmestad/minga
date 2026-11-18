package ui

import (
	"bytes"
	"fmt"
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func wrappedTestWindow(height uint16, groups ...int) protocol.WindowContent {
	window := protocol.WindowContent{
		ID: 7, ContentEpoch: 9, WrappedResidentRows: true, GeometrySet: true, ScrollSet: true,
		Geometry: protocol.PaneGeometry{
			WindowID: 7, ContentRect: protocol.Rect{Width: 20, Height: height},
			TextRect: protocol.Rect{Col: 5, Width: 14, Height: height}, ViewportRows: height,
			TotalLines: uint32(len(groups)),
		},
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, Wrapped: true, LayoutGeneration: 1, ScrollSeq: 5,
			VisibleEndLine: uint32(len(groups)), OverscanEndLine: uint32(len(groups)),
		},
	}
	for line, count := range groups {
		for ordinal := range count {
			kind := protocol.WindowRowNormal
			if ordinal > 0 {
				kind = protocol.WindowRowWrapContinuation
			}
			rank := len(window.Rows)
			window.Rows = append(window.Rows, protocol.WindowRow{
				Kind: kind, ID: uint64(rank + 1), ContentHash: uint32(rank + 11),
				BufferLine: uint32(line), Text: fmt.Sprintf("fragment %d", rank),
			})
		}
	}
	window.Geometry.TotalVisualRows = uint32(len(window.Rows))
	return window
}

func wrappedTestSemantics(window protocol.WindowContent) protocol.Command {
	count := uint32(len(window.Rows))
	return protocol.Command{Kind: protocol.CommandResidentSemantics, ResidentSemantics: protocol.ResidentSemantics{
		ResidentSemanticsHeader: protocol.ResidentSemanticsHeader{
			Version: 1, WindowID: window.ID, ContentEpoch: window.ContentEpoch, Revision: 1, TargetRowRevision: 1,
			RowCount: count, FirstRowID: window.Rows[0].ID, LastRowID: window.Rows[count-1].ID,
		},
		ResidentGuideUpdate: protocol.ResidentGuideUpdate{
			TabWidth: 2, ActiveGuideCol: 0xFFFF,
			GuideReplacements: []protocol.ResidentGuideReplacement{{
				Start: 0, End: count, Runs: []protocol.ResidentGuideRun{{Start: 0, End: count}},
			}},
		},
		ResidentDiagnosticUpdate: protocol.ResidentDiagnosticUpdate{DiagnosticMode: 1},
		ResidentAnnotationUpdate: protocol.ResidentAnnotationUpdate{AnnotationMode: 1},
	}}
}

func TestWrappedResidentWheelFillsEOFAndRebasesSameLineEcho(t *testing.T) {
	out := make(chan []byte, 32)
	model := New(20, 8, out)
	window := wrappedTestWindow(4, 6)
	window.Rows[2].Text = "a界e\u0301😀z"
	semantic := wrappedTestSemantics(window)
	semantic.ResidentSemantics.Cursor = protocol.ResidentCursor{Eligible: true, Row: 3, Col: 3}
	semantic.ResidentSemantics.Cursorline = protocol.ResidentCursorline{Present: true, Row: 2, BG: 0x223344}
	semantic.ResidentSemantics.Selection = protocol.ResidentSelection{Present: true, Type: 1, StartRow: 2, EndRow: 2, StartCol: 0, EndCol: 1}
	semantic.ResidentSemantics.Diagnostics = []protocol.ResidentDiagnostic{{StartRow: 2, EndRow: 2, StartCol: 1, EndCol: 3}}
	gutter := residentGutterCommand(7, 9, 1, false, map[uint32]protocol.GutterEntry{
		0: {BufferLine: 0, SignType: 8, SignText: "!"},
	})
	lease := protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 70}}
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, semantic, gutter, lease, commitFrame(1))
	if model.lastFrameOutcome != frameOutcomeApplied {
		t.Fatalf("wrapped hydration rejected: %v", model.lastFrameOutcome)
	}
	root := model.residentRows[7].root
	drainOutboundPackets(out)

	assertTop := func(want int) {
		t.Helper()
		if got := model.presentationSourceStart(model.windows[7], 4); got != want {
			t.Fatalf("displayed visual top = %d, want %d", got, want)
		}
	}
	wheel := func(button tea.MouseButton, delta int16, direction byte) {
		t.Helper()
		updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{Button: button, X: 5, Y: model.layout.body.Y}))
		model = updated.(Model)
		packets := drainOutboundPackets(out)
		if len(packets) != 1 || !bytes.Equal(packets[0], protocol.EncodeScrollBatch(7, delta, direction)) {
			t.Fatalf("wheel sent %v, want signed scroll_batch delta %d", packets, delta)
		}
	}
	echo := func(frame, authority uint32, ordinal uint16) {
		t.Helper()
		scroll := window.Scroll
		scroll.AnchorVisualRowOffset, scroll.ScrollSeq = ordinal, authority
		geometry := window.Geometry
		geometry.VisualRowOffset = uint32(ordinal)
		delta := protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{
			ID: 7, ContentEpoch: 9, BaseRowCount: 6, ResultRowCount: 6, RowSplicesSet: true,
			ScrollSet: true, Scroll: scroll,
			GeometrySet: true, Geometry: geometry,
		}}
		model = applyTo(t, model, beginFrame(frame, frame-1), delta, lease, commitFrame(frame))
		if model.lastFrameOutcome != frameOutcomeApplied || model.residentRows[7].root != root {
			t.Fatalf("scroll-only echo changed row storage or failed commit: %v", model.lastFrameOutcome)
		}
		drainOutboundPackets(out)
	}

	assertTop(0)
	initial := stripRenderedLines(model.renderWindowRows(model.windows[7]))
	if !strings.Contains(initial[0], "!") || strings.Contains(initial[1], "!") {
		t.Fatalf("only the source start should render its gutter sign: %q", initial)
	}
	wheel(tea.MouseWheelDown, 1, 0)
	assertTop(1)
	wheel(tea.MouseWheelDown, 1, 0)
	wheel(tea.MouseWheelDown, 1, 0)
	assertTop(2)
	visible := stripRenderedLines(model.renderWindowRows(model.windows[7]))
	if len(visible) != 4 || !strings.HasPrefix(visible[0], "     a界") || !strings.Contains(visible[3], "fragment 5") {
		t.Fatalf("EOF should be a full page beginning on a blank-gutter continuation: %q", visible)
	}
	if sb := computeScrollbar(model.windows[7], 4, 2); !sb.active || sb.thumbBot != 4 {
		t.Fatalf("scrollbar should reach its visual endpoint at EOF: %+v", sb)
	}
	assertTextTarget(t, model, model.layout.body.X+6, model.layout.body.Y, 7, 70, 2, 3, 1)
	if cursor := model.residentCursor(); cursor == nil || cursor.Y != 1 || cursor.X != 8 {
		t.Fatalf("resident cursor did not retain its visual rank: %+v", cursor)
	}
	windowAtEOF := model.windows[7]
	if lit, bg := model.cursorlineForRow(windowAtEOF, 2, 2); !lit || bg != 0x223344 {
		t.Fatal("resident cursorline did not follow its continuation")
	}
	if selection := model.applyWindowOverlaysAt(lipgloss.NewStyle(), windowAtEOF, 2, 2, 0); selection.GetBackground() != model.palette().Selection() {
		t.Fatal("resident selection did not follow its continuation")
	}
	if diagnostic := model.applyWindowOverlaysAt(lipgloss.NewStyle(), windowAtEOF, 2, 2, 1); !diagnostic.GetUnderline() {
		t.Fatal("resident diagnostic did not follow its continuation")
	}

	wheel(tea.MouseWheelUp, -1, 1)
	assertTop(1)
	echo(2, 5, 2) // Delayed EOF frame, committed before reversal.
	assertTop(1)
	echo(3, 5, 1)
	assertTop(1)
	wheel(tea.MouseWheelUp, -1, 1)
	wheel(tea.MouseWheelDown, 1, 0) // Net offset zero, but earlier echoes remain possible.
	echo(4, 5, 0)
	assertTop(1)
	echo(5, 5, 1)
	assertTop(1)
	echo(6, 6, 0)
	assertTop(0)
}

func TestWrappedWindowedWheelWaitsForCommittedTrimmedPayload(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(20, 8, out)
	window := wrappedTestWindow(4, 6)
	window.WrappedResidentRows = false
	window.Geometry.TotalVisualRows = 0 // Windowed has no exact global visual extent.
	window.Geometry.VisualRowOffset = 70_000
	window.Rows = window.Rows[1:] // Overscan starts inside the logical line.
	content := protocol.Command{Kind: protocol.CommandWindowContent, Window: window}
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), content, commitFrame(1))
	if model.lastFrameOutcome != frameOutcomeApplied {
		t.Fatalf("windowed first paint rejected: %v", model.lastFrameOutcome)
	}
	drainOutboundPackets(out)
	updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 5, Y: model.layout.body.Y}))
	model = updated.(Model)
	packets := drainOutboundPackets(out)
	if len(packets) != 1 || !bytes.Equal(packets[0], protocol.EncodeScrollBatch(7, 1, 0)) {
		t.Fatalf("windowed wheel did not forward visual motion: %v", packets)
	}
	if got := model.presentationSourceStart(model.windows[7], 4); got != 0 {
		t.Fatalf("windowed wheel predicted a local visual offset: %d", got)
	}
	content.Window.Scroll.AnchorVisualRowOffset = 1
	content.Window.Geometry.VisualRowOffset++
	model = applyTo(t, model, beginFrame(2, 1), content, commitFrame(2))
	visible := stripRenderedLines(model.renderWindowRows(model.windows[7]))
	if !strings.Contains(visible[0], "fragment 2") || !strings.Contains(visible[3], "fragment 5") {
		t.Fatalf("committed payload-relative continuation did not reach EOF: %q", visible)
	}

	// Promotion installs the full group and interprets the same wire field as
	// an ordinal within that group, not an offset into the trimmed payload.
	resident := wrappedTestWindow(4, 6)
	resident.Scroll.AnchorVisualRowOffset = 2
	resident.Geometry.VisualRowOffset = 2
	model = applyTo(t, model, beginFrame(3, 2),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: resident}, wrappedTestSemantics(resident), commitFrame(3))
	if model.lastFrameOutcome != frameOutcomeApplied || model.presentationSourceStart(model.windows[7], 4) != 2 {
		t.Fatalf("same-epoch wrapped promotion did not install the full group: %v", model.lastFrameOutcome)
	}
}

func TestWrappedResidentA2A9ResizeGroupAndShiftSparseGutter(t *testing.T) {
	model := New(20, 8, nil)
	window := wrappedTestWindow(3, 2, 1, 3)
	window.Scroll.AnchorTop = 1
	window.Scroll.VisibleStartLine = 1
	window.Geometry.ViewportTop = 1
	semantic := wrappedTestSemantics(window)
	gutter := residentGutterCommand(7, 9, 3, false, map[uint32]protocol.GutterEntry{
		1: {BufferLine: 1, SignType: 8, SignText: "!"},
	})
	lease := protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 70}}
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, semantic, gutter, lease, commitFrame(1))
	old := model.residentRows[7]
	oldSuffix, _ := old.get(2)
	if model.lastFrameOutcome != frameOutcomeApplied {
		t.Fatalf("wrapped fixture failed to hydrate: %v", model.lastFrameOutcome)
	}

	inserted := []protocol.WindowRow{
		window.Rows[0], window.Rows[1],
		{ID: 90, ContentHash: 90, Kind: protocol.WindowRowWrapContinuation, Text: "new wrap"},
		{ID: 91, ContentHash: 91, Kind: protocol.WindowRowNormal, Text: "new line"},
	}
	delta := residentTestRowsDelta(t, 7, 9, 6, 8, 0, 2, inserted)
	delta.Window.Geometry = window.Geometry
	delta.Window.Geometry.TotalLines, delta.Window.Geometry.TotalVisualRows = 4, 8
	delta.Window.Geometry.ViewportTop = 2
	delta.Window.Scroll = window.Scroll
	delta.Window.Scroll.AnchorTop = 2
	delta.Window.Scroll.AnchorVisualRowOffset = 0
	delta.Window.Scroll.VisibleStartLine = 2
	delta.Window.Scroll.VisibleEndLine, delta.Window.Scroll.OverscanEndLine = 4, 4
	semantic.ResidentSemantics.Mode = 1
	semantic.ResidentSemantics.BaseRevision, semantic.ResidentSemantics.Revision, semantic.ResidentSemantics.TargetRowRevision = 1, 2, 2
	semantic.ResidentSemantics.RowCount = 8
	semantic.ResidentSemantics.RowSplices = []protocol.ResidentRowSplice{{Start: 0, DeleteCount: 2, InsertCount: 4}}
	semantic.ResidentSemantics.GuideReplacements = []protocol.ResidentGuideReplacement{{
		Start: 0, End: 4, Runs: []protocol.ResidentGuideRun{{Start: 0, End: 4}},
	}}
	gutter = residentGutterCommand(7, 9, 4, false, map[uint32]protocol.GutterEntry{
		2: {BufferLine: 2, SignType: 8, SignText: "!"},
	})
	model = applyTo(t, model, beginFrame(2, 1), delta, semantic, gutter, lease, commitFrame(2))
	if model.lastFrameOutcome != frameOutcomeApplied {
		t.Fatalf("matching visual A2/A9 rejected: %v", model.lastFrameOutcome)
	}
	store := model.residentRows[7]
	shifted, _ := store.get(4)
	unchanged, _ := old.get(2)
	if shifted.ID != oldSuffix.ID || shifted.BufferLine != 2 || unchanged.BufferLine != 1 {
		t.Fatalf("stale line numbers or mutated retained snapshot: shifted=%+v old=%+v", shifted, unchanged)
	}
	if model.renderWork.rowUpdates != 1 || model.renderWork.rowsFetched != 6 {
		t.Fatalf("frame replayed the splice work: %+v", model.renderWork)
	}
	visible := stripRenderedLines(model.renderWindowRows(model.windows[7]))
	if !strings.Contains(visible[0], "!") || !strings.Contains(visible[0], "fragment 2") || strings.Contains(visible[1], "!") {
		t.Fatalf("sparse gutter did not align with shifted source start: %q", visible)
	}
	assertTextTarget(t, model, model.layout.body.X+5, model.layout.body.Y, 7, 70, 4, 3, 0)

	badDelta := delta
	badDelta.Window.BaseRowCount, badDelta.Window.ResultRowCount = 8, 8
	badDelta.Window.RowSplices = []protocol.WindowRowSplice{{StartIndex: 1, DeleteCount: 1, InsertRows: []protocol.WindowRow{inserted[1]}}}
	badA9 := semantic
	badA9.ResidentSemantics.BaseRevision, badA9.ResidentSemantics.Revision, badA9.ResidentSemantics.TargetRowRevision = 2, 3, 3
	badA9.ResidentSemantics.RowSplices = []protocol.ResidentRowSplice{{Start: 2, DeleteCount: 1, InsertCount: 1}}
	model = applyTo(t, model, beginFrame(3, 2), badDelta, badA9, commitFrame(3))
	if model.lastFrameOutcome != frameOutcomeRejected || model.lastCommittedSeq != 2 || model.residentRows[7].root != store.root {
		t.Fatal("mismatched visual A2/A9 splice was not rejected atomically")
	}
}

func TestWrappedResidentRejectsMalformedGeometryAndGroups(t *testing.T) {
	for name, mutate := range map[string]func(*protocol.WindowContent){
		"leading continuation": func(w *protocol.WindowContent) { w.Rows[0].Kind = protocol.WindowRowWrapContinuation },
		"unsupported kind":     func(w *protocol.WindowContent) { w.Rows[1].Kind = 1 },
		"logical extent":       func(w *protocol.WindowContent) { w.Geometry.TotalLines++ },
		"visual extent":        func(w *protocol.WindowContent) { w.Geometry.TotalVisualRows++ },
		"absent wrap flag":     func(w *protocol.WindowContent) { w.Scroll.Wrapped = false },
		"out-of-group anchor": func(w *protocol.WindowContent) {
			w.Scroll.AnchorVisualRowOffset = 3
			w.Geometry.VisualRowOffset = 3
		},
	} {
		t.Run(name, func(t *testing.T) {
			model := New(20, 8, nil)
			window := wrappedTestWindow(3, 3, 1, 4)
			semantic := wrappedTestSemantics(window)
			mutate(&window)
			model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(),
				protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, semantic, commitFrame(1))
			if model.lastFrameOutcome != frameOutcomeRejected || len(model.windows) != 0 {
				t.Fatal("malformed wrapped window published")
			}
		})
	}
}

func TestWrappedResidentRejectsInconsistentCommittedAnchor(t *testing.T) {
	for name, mutate := range map[string]func(*protocol.WindowContent){
		"logical top mismatch":  func(w *protocol.WindowContent) { w.Geometry.ViewportTop-- },
		"continuation mismatch": func(w *protocol.WindowContent) { w.Geometry.VisualRowOffset-- },
		"past last full page": func(w *protocol.WindowContent) {
			w.Scroll.AnchorVisualRowOffset++
			w.Geometry.VisualRowOffset++
		},
	} {
		t.Run(name, func(t *testing.T) {
			out := make(chan []byte, 16)
			model := New(20, 8, out)
			window := wrappedTestWindow(3, 3, 4, 1)
			// Rank 5 is the inclusive last full-page origin in this store.
			window.Scroll.AnchorTop, window.Scroll.AnchorVisualRowOffset = 1, 2
			window.Scroll.VisibleStartLine = 1
			window.Geometry.ViewportTop, window.Geometry.VisualRowOffset = 1, 2
			model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(),
				protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, wrappedTestSemantics(window), commitFrame(1))
			if model.lastFrameOutcome != frameOutcomeApplied {
				t.Fatalf("valid wrapped anchor rejected: %v", model.lastFrameOutcome)
			}
			drainOutboundPackets(out)
			committed := model.windows[7]
			root, semantics := model.residentRows[7].root, model.residentSemantics[7]

			delta := protocol.WindowContent{
				ID: window.ID, ContentEpoch: window.ContentEpoch,
				GeometrySet: true, Geometry: window.Geometry, ScrollSet: true, Scroll: window.Scroll,
			}
			mutate(&delta)
			model = applyTo(t, model, beginFrame(2, 1),
				protocol.Command{Kind: protocol.CommandWindowDelta, Window: delta}, commitFrame(2))
			if model.lastFrameOutcome != frameOutcomeRejected || model.lastCommittedSeq != 1 {
				t.Fatalf("bad anchor outcome=%v, committed sequence=%d", model.lastFrameOutcome, model.lastCommittedSeq)
			}
			if !reflect.DeepEqual(model.windows[7], committed) || model.residentRows[7].root != root ||
				model.residentSemantics[7] != semantics {
				t.Fatal("rejected anchor changed the last committed window, row store, or semantics")
			}
			if got := model.presentationSourceStart(model.windows[7], 3); got != 5 {
				t.Fatalf("rejected anchor changed the presented origin to %d, want 5", got)
			}
			want := protocol.EncodeFrameRejected(1, 2, 1, protocol.RejectInvalidRetainedRows, protocol.DispositionRetryable)
			rejections := 0
			for _, packet := range drainOutboundPackets(out) {
				switch packet[0] {
				case generated.OPFrameApplied, generated.OPWindowRefMiss:
					t.Fatalf("unexpected frame feedback: %v", packet)
				case generated.OPFrameRejected:
					if !bytes.Equal(packet, want) {
						t.Fatalf("rejection = %v, want %v", packet, want)
					}
					rejections++
				}
			}
			if rejections != 1 {
				t.Fatalf("sent %d frame rejections, want 1", rejections)
			}
		})
	}
}

func TestWrappedEOFFillDoesNotStartTextDrag(t *testing.T) {
	model := New(20, 8, nil)
	window := wrappedTestWindow(4, 2)
	lease := protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 70}}
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: window}, wrappedTestSemantics(window), lease, commitFrame(1))
	if model.lastFrameOutcome != frameOutcomeApplied {
		t.Fatalf("wrapped document shorter than its viewport rejected: %v", model.lastFrameOutcome)
	}
	x, y := model.layout.body.X+5, model.layout.body.Y+3
	updated, packet, handled := model.handleEditorTextMouse(tea.MouseClickMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseLeft}))
	if !handled || packet != nil || updated.textDrag != nil {
		t.Fatal("wrapped EOF fill fell through or started a text drag")
	}
	target, ok := model.editorTextTargetAt(x, y, 7)
	if !ok || target.rowIndex != 1 || target.rowID != 2 {
		t.Fatalf("captured drag should still clamp to the last row: %+v", target)
	}
}
