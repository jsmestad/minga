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
	store, err := newResidentRows(model)
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

func TestResidentRowsRefMissAndInvalidSplicePreserveValue(t *testing.T) {
	rows := []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "one"}, {ID: 2, ContentHash: 2, Text: "two"}}
	store, _ := newResidentRows(rows)
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
	store, err := newResidentRows(rows)
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
	if _, err := newResidentRows(rows); err == nil {
		t.Fatal("decreasing buffer-line order accepted")
	}
}
