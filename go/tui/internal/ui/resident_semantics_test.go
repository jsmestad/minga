package ui

import (
	"reflect"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
	xansi "github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func residentSemanticFixture(t *testing.T) (Model, protocol.WindowContent) {
	t.Helper()
	rows := make([]protocol.WindowRow, 8)
	for i := range rows {
		rows[i] = protocol.WindowRow{ID: uint64(i + 1), BufferLine: uint32(i), ContentHash: uint32(i + 11), Text: "  row"}
	}
	rows[4].Spans = []generated.Span{{StartCol: 0, EndCol: 1, BG: 0x112233}}
	window := protocol.WindowContent{
		ID: 7, ContentEpoch: 9, CursorShape: 1, SequentialRows: true,
		Rows: rows, GeometrySet: true,
		Geometry:  protocol.PaneGeometry{WindowID: 7, ContentRect: protocol.Rect{Width: 12, Height: 3}, TextRect: protocol.Rect{Width: 12, Height: 3}, ViewportRows: 3, TotalLines: 8, TotalVisualRows: 8},
		ScrollSet: true,
		Scroll:    protocol.ScrollPresentation{WindowID: 7, ContentEpoch: 9, LayoutGeneration: 1, VisibleStartLine: 0, VisibleEndLine: 3, OverscanStartLine: 0, OverscanEndLine: 8},
	}
	model := New(12, 8, nil, nil)
	model.putWindow(window)
	semantic, err := applyResidentSemantics(nil, protocol.ResidentSemantics{
		ResidentSemanticsHeader: protocol.ResidentSemanticsHeader{
			Version: 1, Mode: 0, WindowID: 7, ContentEpoch: 9, Revision: 1, TargetRowRevision: 1,
			RowCount: 8, FirstRowID: 1, LastRowID: 8,
		},
		Cursor:     protocol.ResidentCursor{Eligible: true, Row: 4, Col: 3},
		Cursorline: protocol.ResidentCursorline{Present: true, Row: 4, BG: 0x223344},
		Selection:  protocol.ResidentSelection{Present: true, Type: 1, StartRow: 4, StartCol: 3, EndRow: 5, EndCol: 2},
		ResidentGuideUpdate: protocol.ResidentGuideUpdate{
			TabWidth: 2, ActiveGuideCol: 0, GuideCols: []uint16{0},
			GuideReplacements: []protocol.ResidentGuideReplacement{{Start: 0, End: 8, Runs: []protocol.ResidentGuideRun{{Start: 0, End: 4, Level: 0}, {Start: 4, End: 6, Level: 2}, {Start: 6, End: 8, Level: 0}}}},
		},
		ResidentDiagnosticUpdate: protocol.ResidentDiagnosticUpdate{
			DiagnosticMode: 1, Diagnostics: []protocol.ResidentDiagnostic{{StartRow: 4, StartCol: 4, EndRow: 5, EndCol: 1, Severity: 0}},
		},
		ResidentAnnotationUpdate: protocol.ResidentAnnotationUpdate{
			AnnotationMode: 1, Annotations: []protocol.ResidentAnnotation{{Row: 4, Kind: 0, FG: 0xABCDEF, Text: "hint"}},
		},
	}, window, model.residentRows[7])
	if err != nil {
		t.Fatalf("keyframe: %v", err)
	}
	model.residentSemantics[7] = semantic
	return model, window
}

func TestResidentSemanticsDriveLocallyScrolledPresentation(t *testing.T) {
	model, window := residentSemanticFixture(t)
	model.localPresentation.scrolls[7] = presentationScroll{contentEpoch: 9, layoutGeneration: 1, rowOffset: 3}
	lines := model.renderWindowRows(window)
	if len(lines) != 3 || !strings.Contains(xansi.Strip(lines[1]), "│") || !strings.Contains(xansi.Strip(lines[1]), "hint") {
		t.Fatalf("resident guide and annotation were not projected onto local row 1: %#v", lines)
	}
	selectionStyle := model.applyWindowOverlaysAt(lipgloss.NewStyle(), window, 4, 1, 3)
	if selectionStyle.GetBackground() != model.palette().Selection() {
		t.Fatal("absolute resident selection did not reach the locally visible row")
	}
	diagnosticStyle := model.applyWindowOverlaysAt(lipgloss.NewStyle(), window, 4, 1, 4)
	if !diagnosticStyle.GetUnderline() {
		t.Fatal("absolute resident diagnostic did not underline the locally visible row")
	}
	if visible, bg := model.cursorlineForRow(window, 4, 1); !visible || bg != 0x223344 {
		t.Fatalf("resident cursorline missing after local scroll: visible=%v bg=%06x", visible, bg)
	}
	cursor, authority := model.residentCursor()
	if !authority || cursor == nil || cursor.X != 3 || cursor.Y != 1 {
		t.Fatalf("resident cursor was not rebased into the local slice: authority=%v cursor=%+v", authority, cursor)
	}
}

func TestResidentCursorClipsOffscreenAndReturnsWithoutBackendFrame(t *testing.T) {
	model, _ := residentSemanticFixture(t)
	if cursor, authority := model.residentCursor(); !authority || cursor != nil {
		t.Fatalf("offscreen resident cursor must be hidden while retaining authority: authority=%v cursor=%+v", authority, cursor)
	}
	model.localPresentation.scrolls[7] = presentationScroll{contentEpoch: 9, layoutGeneration: 1, rowOffset: 3}
	if cursor, authority := model.residentCursor(); !authority || cursor == nil {
		t.Fatalf("resident cursor must return from the same committed semantics after local scroll: authority=%v cursor=%+v", authority, cursor)
	}
}

func TestResidentRecoveryKeyframeAcceptsPositiveRowRevisionAndPointDiagnostic(t *testing.T) {
	model, window := residentSemanticFixture(t)
	recovery := protocol.ResidentSemantics{
		ResidentSemanticsHeader: protocol.ResidentSemanticsHeader{
			Version: 1, Mode: 0, WindowID: 7, ContentEpoch: 9, Revision: 2, TargetRowRevision: 7,
			RowCount: 8, FirstRowID: 1, LastRowID: 8,
		},
		Cursor: protocol.ResidentCursor{Eligible: true, Row: 4},
		ResidentGuideUpdate: protocol.ResidentGuideUpdate{
			TabWidth: 2,
			GuideReplacements: []protocol.ResidentGuideReplacement{{
				Start: 0, End: 8, Runs: []protocol.ResidentGuideRun{{Start: 0, End: 8}},
			}},
		},
		ResidentDiagnosticUpdate: protocol.ResidentDiagnosticUpdate{
			DiagnosticMode: 1,
			Diagnostics: []protocol.ResidentDiagnostic{{
				StartRow: 4, StartCol: 3, EndRow: 4, EndCol: 3, Severity: 1,
			}},
		},
		ResidentAnnotationUpdate: protocol.ResidentAnnotationUpdate{AnnotationMode: 1},
	}

	recovered, err := applyResidentSemantics(model.residentSemantics[7], recovery, window, model.residentRows[7])
	if err != nil {
		t.Fatalf("recovery keyframe with point diagnostic: %v", err)
	}
	if recovered.rowRevision != 7 || len(recovered.rowDiagnostics(4)) != 1 {
		t.Fatalf("recovery keyframe did not publish canonical revision and diagnostic: %+v", recovered)
	}
}

func TestResidentTextSpansRemainSearchAndDocumentHighlightAuthority(t *testing.T) {
	model, window := residentSemanticFixture(t)
	row, _ := model.residentRows[7].get(4)
	withBakedSpan := model.renderRowAt(window, row, 4, 1, 12, false, 0)
	row.Spans = nil
	withoutBakedSpan := model.renderRowAt(window, row, 4, 1, 12, false, 0)
	if withBakedSpan == withoutBakedSpan || xansi.Strip(withBakedSpan) != xansi.Strip(withoutBakedSpan) {
		t.Fatal("resident rendering must preserve baked search/document span styling without duplicate viewport overlays")
	}
}

func TestResidentSemanticOnlyUpdatePreservesRowsAndRejectedUpdatePreservesStore(t *testing.T) {
	model, window := residentSemanticFixture(t)
	beforeRows := model.residentRows[7].materialize()
	base := model.residentSemantics[7]
	delta := protocol.ResidentSemantics{
		ResidentSemanticsHeader: protocol.ResidentSemanticsHeader{
			Version: 1, Mode: 1, WindowID: 7, ContentEpoch: 9, BaseRevision: 1, Revision: 2, TargetRowRevision: 1,
			RowCount: 8, FirstRowID: 1, LastRowID: 8,
		},
		Cursor:              protocol.ResidentCursor{Row: 4},
		ResidentGuideUpdate: protocol.ResidentGuideUpdate{TabWidth: 2, GuideCols: []uint16{0}},
	}
	next, err := applyResidentSemantics(base, delta, window, model.residentRows[7])
	if err != nil {
		t.Fatalf("semantic-only delta: %v", err)
	}
	if !reflect.DeepEqual(beforeRows, model.residentRows[7].materialize()) {
		t.Fatal("semantic-only delta changed resident text identities or hashes")
	}
	for name, mutate := range map[string]func(*protocol.ResidentSemantics){
		"epoch": func(value *protocol.ResidentSemantics) { value.ContentEpoch++ },
		"base":  func(value *protocol.ResidentSemantics) { value.BaseRevision++ },
		"count": func(value *protocol.ResidentSemantics) { value.RowCount++ },
		"id":    func(value *protocol.ResidentSemantics) { value.FirstRowID++ },
	} {
		t.Run(name, func(t *testing.T) {
			invalid := delta
			invalid.BaseRevision = next.revision
			invalid.Revision = next.revision + 1
			mutate(&invalid)
			if _, err := applyResidentSemantics(next, invalid, window, model.residentRows[7]); err == nil {
				t.Fatal("invalid candidate was accepted")
			}
			if next.revision != 2 || base.revision != 1 {
				t.Fatal("rejected candidate mutated committed semantic revisions")
			}
		})
	}
}

func TestResidentTextChangeRequiresMatchingSemanticCandidateAfterInitialization(t *testing.T) {
	model, _ := residentSemanticFixture(t)
	beforeRows := model.residentRows[7].materialize()
	replacement := protocol.WindowRow{ID: 99, BufferLine: 4, ContentHash: 99, Text: "replacement"}
	textDelta := protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{
		ID: 7, ContentEpoch: 9, RowSplicesSet: true, BaseRowCount: 8, ResultRowCount: 8,
		RowSplices: []protocol.WindowRowSplice{{StartIndex: 4, DeleteCount: 1, InsertRows: []protocol.WindowRow{replacement}}},
	}}

	model.staging = &frameStaging{commands: []protocol.Command{textDelta}}
	if _, failure := model.validateWindowReferences(); failure == nil || failure.reason != protocol.RejectInvalidRetainedRows {
		t.Fatalf("resident text delta without A9 must reject: %+v", failure)
	}
	if !reflect.DeepEqual(beforeRows, model.residentRows[7].materialize()) || model.residentSemantics[7].revision != 1 {
		t.Fatal("rejected text delta changed the committed text or semantic store")
	}

	semanticDelta := protocol.Command{Kind: protocol.CommandResidentSemantics, ResidentSemantics: protocol.ResidentSemantics{
		ResidentSemanticsHeader: protocol.ResidentSemanticsHeader{
			Version: 1, Mode: 1, WindowID: 7, ContentEpoch: 9, BaseRevision: 1, Revision: 2, TargetRowRevision: 2,
			RowCount: 8, FirstRowID: 1, LastRowID: 8,
		},
		Cursor: protocol.ResidentCursor{Row: 4},
		ResidentGuideUpdate: protocol.ResidentGuideUpdate{
			TabWidth: 2, GuideCols: []uint16{0},
			RowSplices:        []protocol.ResidentRowSplice{{Start: 4, DeleteCount: 1, InsertCount: 1}},
			GuideReplacements: []protocol.ResidentGuideReplacement{{Start: 4, End: 5, Runs: []protocol.ResidentGuideRun{{Start: 4, End: 5, Level: 2}}}},
		},
	}}
	model.staging = &frameStaging{commands: []protocol.Command{textDelta, semanticDelta}}
	snapshot, failure := model.validateWindowReferences()
	if failure != nil {
		t.Fatalf("matching text and semantic candidates must validate: %+v", failure)
	}
	row, ok := snapshot.stores[7].get(4)
	if !ok || row.ID != 99 || snapshot.semantics[7].revision != 2 {
		t.Fatalf("validated candidates did not pair atomically: row=%+v semantic=%+v", row, snapshot.semantics[7])
	}
}

func TestResidentStructuralSpliceAndSparseDiagnosticReplacement(t *testing.T) {
	model, window := residentSemanticFixture(t)
	base := model.residentSemantics[7]
	inserted := protocol.WindowRow{ID: 99, BufferLine: 2, ContentHash: 99, Text: "new"}
	rows, _, err := model.residentRows[7].splice(protocol.WindowContent{BaseRowCount: 8, ResultRowCount: 9, RowSplices: []protocol.WindowRowSplice{{StartIndex: 2, InsertRows: []protocol.WindowRow{inserted}}}}, model.renderWork)
	if err != nil {
		t.Fatalf("row splice: %v", err)
	}
	window.Geometry.TotalLines, window.Geometry.TotalVisualRows = 9, 9
	delta := protocol.ResidentSemantics{
		ResidentSemanticsHeader: protocol.ResidentSemanticsHeader{
			Version: 1, Mode: 1, WindowID: 7, ContentEpoch: 9, BaseRevision: 1, Revision: 2, TargetRowRevision: 2,
			RowCount: 9, FirstRowID: 1, LastRowID: 8,
		},
		Cursor: protocol.ResidentCursor{Row: 5},
		ResidentGuideUpdate: protocol.ResidentGuideUpdate{
			TabWidth: 2, GuideCols: []uint16{0},
			RowSplices:        []protocol.ResidentRowSplice{{Start: 2, InsertCount: 1}},
			GuideReplacements: []protocol.ResidentGuideReplacement{{Start: 2, End: 3, Runs: []protocol.ResidentGuideRun{{Start: 2, End: 3, Level: 0}}}},
		},
		ResidentDiagnosticUpdate: protocol.ResidentDiagnosticUpdate{
			DiagnosticMode:   2,
			DiagnosticRanges: []protocol.ResidentDiagnosticReplacement{{Start: 5, End: 6, Diagnostics: []protocol.ResidentDiagnostic{{StartRow: 5, StartCol: 1, EndRow: 6, EndCol: 1, Severity: 1}}}},
		},
		ResidentAnnotationUpdate: protocol.ResidentAnnotationUpdate{AnnotationMode: 2},
	}
	next, err := applyResidentSemantics(base, delta, window, rows)
	if err != nil {
		t.Fatalf("semantic splice: %v", err)
	}
	if got := next.rowAnnotations(5); len(got) != 1 || got[0].Text != "hint" {
		t.Fatalf("annotation suffix did not shift: %+v", got)
	}
	if got := next.rowDiagnostics(5); len(got) != 1 || got[0].Severity != 1 {
		t.Fatalf("sparse diagnostic replacement did not publish at shifted rank: %+v", got)
	}
}
