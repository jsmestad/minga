package ui

import (
	"math/rand"
	"reflect"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestResidentRowsRandomizedSplicesMatchSliceModel(t *testing.T) {
	rng := rand.New(rand.NewSource(2743))
	model := make([]protocol.WindowRow, 5_000)
	for i := range model {
		model[i] = protocol.WindowRow{ID: uint64(i + 1), ContentHash: uint32(i + 1), Text: "base"}
	}
	store, err := newResidentRows(model, windowedRows)
	if err != nil {
		t.Fatal(err)
	}
	nextID := uint64(len(model) + 1)
	for iteration := 0; iteration < 2_000; iteration++ {
		start := rng.Intn(len(model) + 1)
		deleteCount := 0
		if start < len(model) {
			deleteCount = rng.Intn(min(3, len(model)-start) + 1)
		}
		insertCount := rng.Intn(3)
		if deleteCount == 0 && insertCount == 0 {
			insertCount = 1
		}
		inserted := make([]protocol.WindowRow, insertCount)
		for i := range inserted {
			inserted[i] = protocol.WindowRow{ID: nextID, ContentHash: uint32(nextID), Text: "new"}
			nextID++
		}
		delta := protocol.WindowContent{BaseRowCount: uint32(len(model)), ResultRowCount: uint32(len(model) - deleteCount + insertCount), RowSplices: []protocol.WindowRowSplice{{StartIndex: uint32(start), DeleteCount: uint32(deleteCount), InsertRows: inserted}}}
		next, miss, err := store.splice(delta, nil)
		if err != nil || miss {
			t.Fatalf("iteration %d: miss=%v err=%v", iteration, miss, err)
		}
		updated := make([]protocol.WindowRow, 0, int(delta.ResultRowCount))
		updated = append(updated, model[:start]...)
		updated = append(updated, inserted...)
		updated = append(updated, model[start+deleteCount:]...)
		model, store = updated, next
		if store.count() != len(model) || !reflect.DeepEqual(store.materialize(), model) {
			t.Fatalf("iteration %d: store diverged", iteration)
		}
		if len(model) > 0 {
			index := rng.Intn(len(model))
			if got, ok := store.get(index); !ok || !reflect.DeepEqual(got, model[index]) {
				t.Fatalf("iteration %d index %d mismatch", iteration, index)
			}
		}
	}
}

// Two edits far apart in one frame arrive as two splices of different sizes. Both address the rows the
// store held before the frame, so the second one lands after the shift the first one caused.
func TestResidentRowsApplyUnequalSplicesAgainstTheBase(t *testing.T) {
	base := make([]protocol.WindowRow, 300)
	for i := range base {
		base[i] = protocol.WindowRow{ID: uint64(i + 1), ContentHash: uint32(i + 1), Text: "base"}
	}
	fresh := func(first uint64, count int) []protocol.WindowRow {
		rows := make([]protocol.WindowRow, count)
		for i := range rows {
			rows[i] = protocol.WindowRow{ID: first + uint64(i), ContentHash: uint32(first) + uint32(i), Text: "new"}
		}
		return rows
	}
	cases := []struct {
		name    string
		splices []protocol.WindowRowSplice
	}{
		{"insert near the top and near the bottom", []protocol.WindowRowSplice{
			{StartIndex: 20, DeleteCount: 1, InsertRows: fresh(1_000, 3)},
			{StartIndex: 280, DeleteCount: 1, InsertRows: fresh(2_000, 2)},
		}},
		{"remove a block and append", []protocol.WindowRowSplice{
			{StartIndex: 100, DeleteCount: 101, InsertRows: fresh(1_000, 1)},
			{StartIndex: 299, DeleteCount: 1, InsertRows: fresh(2_000, 2)},
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, err := newResidentRows(base, windowedRows)
			if err != nil {
				t.Fatal(err)
			}
			want := make([]protocol.WindowRow, 0, len(base)+8)
			position := 0
			for _, splice := range tc.splices {
				want = append(want, base[position:splice.StartIndex]...)
				want = append(want, splice.InsertRows...)
				position = int(splice.StartIndex + splice.DeleteCount)
			}
			want = append(want, base[position:]...)
			delta := protocol.WindowContent{BaseRowCount: uint32(len(base)), ResultRowCount: uint32(len(want)), RowSplices: tc.splices}
			next, miss, err := store.splice(delta, nil)
			if err != nil || miss {
				t.Fatalf("miss=%v err=%v", miss, err)
			}
			if next.count() != len(want) || !reflect.DeepEqual(next.materialize(), want) {
				t.Fatalf("store has %d rows, want %d, or the rows differ", next.count(), len(want))
			}
			if store.count() != len(base) {
				t.Fatalf("the base store changed")
			}
		})
	}
}

func TestResidentRowsRefMissAndInvalidSplicePreserveValue(t *testing.T) {
	rows := []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "one"}, {ID: 2, ContentHash: 2, Text: "two"}}
	store, _ := newResidentRows(rows, windowedRows)
	cases := []protocol.WindowContent{
		{BaseRowCount: 2, ResultRowCount: 2, RowSplices: []protocol.WindowRowSplice{{StartIndex: 0, DeleteCount: 1, InsertRows: []protocol.WindowRow{{Ref: true, ID: 99, ContentHash: 99}}}}},
		{BaseRowCount: 2, ResultRowCount: 2, RowSplices: []protocol.WindowRowSplice{{StartIndex: 3, DeleteCount: 1}}},
	}
	for _, delta := range cases {
		if _, _, err := store.splice(delta, nil); err == nil {
			t.Fatal("invalid splice accepted")
		}
		if !reflect.DeepEqual(store.materialize(), rows) {
			t.Fatal("failed splice mutated committed value")
		}
	}
}

func TestResidentRowsRejectsDuplicateInsertionStartsTransactionally(t *testing.T) {
	rows := []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "one"}, {ID: 2, ContentHash: 2, Text: "two"}}
	store, err := newResidentRows(rows, windowedRows)
	if err != nil {
		t.Fatal(err)
	}
	delta := protocol.WindowContent{
		BaseRowCount: 2, ResultRowCount: 4,
		RowSplices: []protocol.WindowRowSplice{
			{StartIndex: 0, InsertRows: []protocol.WindowRow{{ID: 3, ContentHash: 3, Text: "inserted one"}}},
			{StartIndex: 0, InsertRows: []protocol.WindowRow{{ID: 4, ContentHash: 4, Text: "inserted two"}}},
		},
	}
	if _, _, err := store.splice(delta, nil); err == nil {
		t.Fatal("duplicate insertion-only start accepted")
	}
	if !reflect.DeepEqual(store.materialize(), rows) {
		t.Fatalf("duplicate insertion-only start mutated committed rows: %+v", store.materialize())
	}
}

func TestNewResidentRowsRejectsDecreasingBufferLines(t *testing.T) {
	rows := []protocol.WindowRow{
		{ID: 1, BufferLine: 10, Text: "ten"},
		{ID: 2, BufferLine: 9, Text: "nine"},
	}
	if _, err := newResidentRows(rows, windowedRows); err == nil {
		t.Fatal("decreasing buffer-line order accepted")
	}
}

func TestSequentialResidentRowsProjectBufferLinesAcrossStructuralSplices(t *testing.T) {
	rows := []protocol.WindowRow{
		{ID: 1, BufferLine: 0, Text: "zero"},
		{ID: 2, BufferLine: 1, Text: "one"},
		{ID: 3, BufferLine: 2, Text: "two"},
	}
	store, err := newResidentRows(rows, sequentialRows)
	if err != nil {
		t.Fatal(err)
	}
	insert := protocol.WindowContent{
		BaseRowCount: 3, ResultRowCount: 5,
		RowSplices: []protocol.WindowRowSplice{{
			StartIndex: 1,
			InsertRows: []protocol.WindowRow{{ID: 4, BufferLine: 1, Text: "inserted one"}, {ID: 5, BufferLine: 2, Text: "inserted two"}},
		}},
	}
	store, miss, err := store.splice(insert, nil)
	if err != nil || miss {
		t.Fatalf("sequential insert failed: miss=%v err=%v", miss, err)
	}
	for index, row := range store.materialize() {
		if row.BufferLine != uint32(index) {
			t.Fatalf("inserted row %d projects buffer line %d", index, row.BufferLine)
		}
	}
	deleteInserted := protocol.WindowContent{
		BaseRowCount: 5, ResultRowCount: 3,
		RowSplices: []protocol.WindowRowSplice{{StartIndex: 1, DeleteCount: 2}},
	}
	store, miss, err = store.splice(deleteInserted, nil)
	if err != nil || miss {
		t.Fatalf("sequential deletion failed: miss=%v err=%v", miss, err)
	}
	if got := store.materialize(); !reflect.DeepEqual(got, rows) {
		t.Fatalf("sequential deletion did not restore projected rows: %+v", got)
	}
}

func TestWrappedRowsRankSelectAndRefsAcrossLeaves(t *testing.T) {
	firstGroup := residentLeafRows + 2
	total := firstGroup + 1 + 5_000
	rows := make([]protocol.WindowRow, total)
	for i := range rows {
		// Retained BufferLine is not an input to grouped rank/select.
		rows[i] = protocol.WindowRow{ID: uint64(i + 1), ContentHash: uint32(i + 1), BufferLine: uint32(total - i), Kind: protocol.WindowRowWrapContinuation}
	}
	for _, rank := range []int{0, firstGroup, firstGroup + 1} {
		rows[rank].Kind = protocol.WindowRowNormal
	}
	store, err := newResidentRows(rows, wrappedRows)
	if err != nil {
		t.Fatal(err)
	}
	delta := protocol.WindowContent{
		BaseRowCount: uint32(total), ResultRowCount: uint32(total + 2),
		RowSplices: []protocol.WindowRowSplice{
			{StartIndex: 1, DeleteCount: 1, InsertRows: []protocol.WindowRow{
				{Ref: true, ID: rows[1].ID, ContentHash: rows[1].ContentHash},
				{ID: uint64(total + 1), Kind: protocol.WindowRowWrapContinuation},
			}},
			{StartIndex: uint32(firstGroup), InsertRows: []protocol.WindowRow{{ID: uint64(total + 2)}}},
		},
	}
	next, miss, err := store.splice(delta, nil)
	if err != nil || miss {
		t.Fatalf("grouped multi-splice failed: miss=%v err=%v", miss, err)
	}
	starts := []int{0, firstGroup + 1, firstGroup + 2, firstGroup + 3}
	if store.lineCount() != 3 || next.lineCount() != len(starts) {
		t.Fatalf("logical extents: old=%d new=%d", store.lineCount(), next.lineCount())
	}
	for line, rank := range starts {
		if got := next.lowerBoundBufferLine(uint32(line)); got != rank {
			t.Fatalf("logical line %d selected rank %d, want %d", line, got, rank)
		}
	}
	for i, row := range next.rangeRows(firstGroup-1, 6) {
		want := []uint32{0, 0, 1, 2, 3, 3}[i]
		if row.BufferLine != want {
			t.Fatalf("slice row %d projects line %d, want %d", i, row.BufferLine, want)
		}
	}
	anchor, ok := next.wrappedAnchor(protocol.ScrollPresentation{AnchorTop: 3, AnchorVisualRowOffset: 4_999})
	last, _ := next.get(anchor)
	originalLast, _ := store.get(total - 1)
	if !ok || anchor != next.count()-1 || last.ID != originalLast.ID || last.BufferLine != 3 || originalLast.BufferLine != 2 {
		t.Fatalf("retained continuation moved incorrectly: anchor=%d valid=%v old=%+v new=%+v", anchor, ok, originalLast, last)
	}
}
