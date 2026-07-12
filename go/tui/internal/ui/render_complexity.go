package ui

import "fmt"

// renderWorkCollector is production instrumentation attached to the same
// mutation/cache/compose operations used by View. Tests may reset or perturb
// this collector, but never manufacture a replacement measurement.
type renderWorkCollector struct {
	fullResets       int
	rowUpdates       int
	rowsFetched      int
	rowChunksTouched int
	rowsComposed     int
	editorRowVisits  int
	decorationVisits int
}

func (c *renderWorkCollector) reset() { *c = renderWorkCollector{} }

func (c *renderWorkCollector) measurement(visibleRows, overscanRows int) renderComplexityMeasurement {
	return renderComplexityMeasurement{
		fullResets: c.fullResets, rowUpdates: c.rowUpdates,
		rowsFetched: c.rowsFetched, rowChunksTouched: c.rowChunksTouched, rowsComposed: c.rowsComposed,
		editorRowVisits: c.editorRowVisits, visibleRows: visibleRows,
		overscanRows: overscanRows, decorations: c.decorationVisits,
	}
}

// renderComplexityMeasurement contains observed deterministic work from the
// production TUI delta and compose stages. Decorations are intentionally
// separate from editor-row traversal.
type renderComplexityMeasurement struct {
	fullResets       int
	rowUpdates       int
	rowsFetched      int
	rowChunksTouched int
	rowsComposed     int
	editorRowVisits  int
	visibleRows      int
	overscanRows     int
	decorations      int
}

func renderComplexityFailures(m renderComplexityMeasurement) []string {
	var failures []string
	if m.fullResets != 0 {
		failures = append(failures, fmt.Sprintf("full resets %d must equal 0", m.fullResets))
	}
	if m.rowUpdates != 1 {
		failures = append(failures, fmt.Sprintf("row updates %d must equal 1", m.rowUpdates))
	}
	if m.rowsFetched > 8 {
		failures = append(failures, fmt.Sprintf("rows fetched %d exceeds 8", m.rowsFetched))
	}
	if m.rowChunksTouched > 8 {
		failures = append(failures, fmt.Sprintf("row chunks touched %d exceeds 8", m.rowChunksTouched))
	}
	if m.rowsComposed > 8 {
		failures = append(failures, fmt.Sprintf("rows composed %d exceeds 8", m.rowsComposed))
	}
	if m.editorRowVisits > m.visibleRows+m.overscanRows {
		failures = append(failures, fmt.Sprintf("editor rows visited %d exceeds %d", m.editorRowVisits, m.visibleRows+m.overscanRows))
	}
	return failures
}
