package ui

import (
	"strconv"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func productionComplexityModel(t *testing.T, count int) Model {
	t.Helper()
	const visible = 24
	rows := make([]protocol.WindowRow, count)
	for i := range rows {
		rows[i] = protocol.WindowRow{ID: uint64(i + 1), BufferLine: uint32(i), ContentHash: uint32(i + 1), Text: "row"}
	}
	middle := count / 2
	geometry := protocol.PaneGeometry{
		WindowID: 1, ContentRect: protocol.Rect{Width: 80, Height: visible},
		TextRect: protocol.Rect{Width: 80, Height: visible}, ViewportRows: visible, ViewportTop: uint32(middle),
		TotalLines: uint32(count), TotalVisualRows: uint32(count),
	}
	scroll := protocol.ScrollPresentation{WindowID: 1, VisibleStartLine: uint32(middle), VisibleEndLine: uint32(middle + visible), OverscanStartLine: 0, OverscanEndLine: uint32(count), ContentEpoch: 1}
	model := New(80, visible, nil, nil)
	model = applyTo(t, model,
		beginFrame(1, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
			ID: 1, ContentEpoch: 1, Rows: rows, Geometry: geometry, GeometrySet: true, Scroll: scroll, ScrollSet: true,
		}}, commitFrame(1))
	_ = model.content() // warm the production composed-row cache
	model.renderWork.reset()
	return model
}

func applyProductionOrdinaryEdit(t *testing.T, model Model, count int) Model {
	t.Helper()
	middle := count / 2
	previous, ok := model.residentRows[1].get(middle)
	if !ok {
		t.Fatalf("missing resident row %d", middle)
	}
	replacement := previous
	replacement.ContentHash++
	replacement.Text = "edited"
	return applyTo(t, model,
		beginFrame(2, 1),
		protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{
			ID: 1, ContentEpoch: 1, BaseRowCount: uint32(count), ResultRowCount: uint32(count), RowSplicesSet: true,
			Scroll: protocol.ScrollPresentation{WindowID: 1, VisibleStartLine: uint32(middle), VisibleEndLine: uint32(middle + 24), OverscanStartLine: 0, OverscanEndLine: uint32(count), ContentEpoch: 1}, ScrollSet: true,
			RowSplices: []protocol.WindowRowSplice{{StartIndex: uint32(middle), DeleteCount: 1, InsertRows: []protocol.WindowRow{replacement}}},
		}}, commitFrame(2))
}

func TestOrdinaryEditComposeWorkIsIndependentOfResidentDocumentSize(t *testing.T) {
	for _, count := range []int{5_000, 65_536} {
		t.Run(strconv.Itoa(count), func(t *testing.T) {
			model := productionComplexityModel(t, count)
			model = applyProductionOrdinaryEdit(t, model, count)
			measurement := model.renderWork.measurement(24, 4)
			if failures := renderComplexityFailures(measurement); len(failures) != 0 {
				t.Fatalf("resident rows %d: %v (measurement=%+v)", count, failures, measurement)
			}
			row, ok := model.residentRows[1].get(count / 2)
			if !ok {
				t.Fatalf("missing edited resident row")
			}
			if got := row.Text; got != "edited" {
				t.Fatalf("production frame did not commit edited row: %q", got)
			}
			if measurement.rowsFetched > 8 || measurement.rowsComposed > 8 {
				t.Fatalf("fetch and compose bounds must be independent: %+v", measurement)
			}
		})
	}
}

func TestVisibleMiddleStructuralSpliceHasBoundedProductionWork(t *testing.T) {
	for _, count := range []int{5_000, 65_536} {
		t.Run(strconv.Itoa(count), func(t *testing.T) {
			model := productionComplexityModel(t, count)
			middle := count / 2
			inserted := protocol.WindowRow{ID: uint64(count + 1), BufferLine: uint32(middle), ContentHash: uint32(count + 1), Text: "inserted"}
			model = applyTo(t, model, beginFrame(2, 1), protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{
				ID: 1, ContentEpoch: 1, BaseRowCount: uint32(count), ResultRowCount: uint32(count + 1), RowSplicesSet: true,
				RowSplices: []protocol.WindowRowSplice{{StartIndex: uint32(middle), InsertRows: []protocol.WindowRow{inserted}}},
				Scroll:     protocol.ScrollPresentation{WindowID: 1, VisibleStartLine: uint32(middle), VisibleEndLine: uint32(middle + 24), OverscanStartLine: 0, OverscanEndLine: uint32(count + 1), ContentEpoch: 1}, ScrollSet: true,
			}}, commitFrame(2))
			measurement := model.renderWork.measurement(24, 4)
			if failures := renderComplexityFailures(measurement); len(failures) != 0 {
				t.Fatalf("resident rows %d: %v (%+v)", count, failures, measurement)
			}
			row, ok := model.residentRows[1].get(middle)
			if !ok || row.ID != inserted.ID {
				t.Fatal("structural splice did not publish")
			}
			if model.renderWork.rowChunksTouched > 8 {
				t.Fatalf("touched chunks %d exceeds 8", model.renderWork.rowChunksTouched)
			}
		})
	}
}

func TestRenderComplexityGateFailureSeamsPerturbProductionCollector(t *testing.T) {
	perturbations := []func(*renderWorkCollector){
		func(c *renderWorkCollector) { c.fullResets++ },
		func(c *renderWorkCollector) { c.rowUpdates++ },
		func(c *renderWorkCollector) { c.rowsFetched += 9 },
		func(c *renderWorkCollector) { c.rowChunksTouched += 9 },
		func(c *renderWorkCollector) { c.rowsComposed += 9 },
		func(c *renderWorkCollector) { c.editorRowVisits += 65_536 },
	}
	for i, perturb := range perturbations {
		model := productionComplexityModel(t, 5_000)
		model = applyProductionOrdinaryEdit(t, model, 5_000)
		perturb(model.renderWork)
		if failures := renderComplexityFailures(model.renderWork.measurement(24, 4)); len(failures) == 0 {
			t.Fatalf("production collector failure seam %d passed", i)
		}
	}
}
