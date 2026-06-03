package protocol

import (
	"reflect"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// Round-trip coverage for the schema-generated decoders. The byte fixtures here
// are exactly what the Elixir encoders produce (the matching assertions live in
// protocol_schema_validation_test.exs), so together they pin encoder and
// generated decoder to the same wire format. They also exercise the primitive
// ([]uint16) and string ([]string) counted_array element paths.
//
// This test lives in the protocol package (not internal/generated) so that
// mix protocol.gen, which rewrites the generated/ directory, can never clobber
// it. Keep the fixtures in sync with the Rust twins in rust/tui/src/protocol.rs
// and the encoder assertions in protocol_schema_validation_test.exs.

func TestDecodeGuiCompletionFieldsWithItems(t *testing.T) {
	bytes := []byte{1, 0, 3, 0, 7, 0, 1, 0, 1, 1, 0, 3, 'f', 'o', 'o', 0, 3, 'b', 'a', 'r'}
	f, consumed, err := generated.DecodeGuiCompletionFields(bytes, 0)
	if err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if consumed != len(bytes) {
		t.Fatalf("consumed %d, want %d", consumed, len(bytes))
	}
	if f.Visible != 1 || f.CursorRow != 3 || f.CursorCol != 7 || f.SelectedOffset != 1 {
		t.Fatalf("header mismatch: %+v", f)
	}
	if len(f.Items) != 1 || f.Items[0].Kind != 1 || f.Items[0].Label != "foo" || f.Items[0].Detail != "bar" {
		t.Fatalf("items mismatch: %+v", f.Items)
	}
}

func TestDecodeHiddenCompletionSkipsTail(t *testing.T) {
	f, consumed, err := generated.DecodeGuiCompletionFields([]byte{0}, 0)
	if err != nil || consumed != 1 || f.Visible != 0 || len(f.Items) != 0 {
		t.Fatalf("hidden completion: f=%+v consumed=%d err=%v", f, consumed, err)
	}
}

func TestDecodePickerItemU16MatchPositions(t *testing.T) {
	bytes := []byte{
		0xAA, 0xBB, 0xCC, 0, 0, 7, 'f', 'i', 'l', 'e', '.', 'e', 'x', 0, 4, 'd', 'e',
		's', 'c', 0, 3, 'a', 'n', 'n', 2, 0, 1, 0, 4,
	}
	item, consumed, err := generated.DecodePickerItem(bytes, 0)
	if err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if consumed != len(bytes) {
		t.Fatalf("consumed %d, want %d", consumed, len(bytes))
	}
	if item.IconColor != 0x00AABBCC || item.Label != "file.ex" || item.Description != "desc" || item.Annotation != "ann" {
		t.Fatalf("item mismatch: %+v", item)
	}
	if !reflect.DeepEqual(item.MatchPositions, []uint16{1, 4}) {
		t.Fatalf("match_positions: %v", item.MatchPositions)
	}
}

func TestDecodePickerItemEmptyMatchPositions(t *testing.T) {
	// match_positions present but count==0: icon(0), flags(0), label "x",
	// empty desc/ann, count 0.
	bytes := []byte{0, 0, 0, 0, 0, 1, 'x', 0, 0, 0, 0, 0}
	item, consumed, err := generated.DecodePickerItem(bytes, 0)
	if err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if consumed != len(bytes) {
		t.Fatalf("consumed %d, want %d", consumed, len(bytes))
	}
	if item.Label != "x" || len(item.MatchPositions) != 0 {
		t.Fatalf("expected empty match_positions, got %+v", item)
	}
}

func TestDecodePickerHeaderFullLayout(t *testing.T) {
	bytes := []byte{1, 0, 2, 0, 10, 0, 100, 1, 0, 5, 'F', 'i', 'l', 'e', 's', 0, 3}
	h, consumed, err := generated.DecodeGuiPickerHeader(bytes, 0)
	if err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if consumed != len(bytes) {
		t.Fatalf("consumed %d, want %d", consumed, len(bytes))
	}
	if h.SelectedIndex != 2 || h.FilteredCount != 10 || h.TotalCount != 100 || h.HasPreview != 1 || h.Title != "Files" || h.MarkedCount != 3 {
		t.Fatalf("header mismatch: %+v", h)
	}
}

func TestDecodeActionMenuStringActions(t *testing.T) {
	bytes := []byte{1, 1, 2, 0, 4, 'O', 'p', 'e', 'n', 0, 6, 'D', 'e', 'l', 'e', 't', 'e'}
	m, consumed, err := generated.DecodeGuiPickerActionMenu(bytes, 0)
	if err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if consumed != len(bytes) {
		t.Fatalf("consumed %d, want %d", consumed, len(bytes))
	}
	if m.Visible != 1 || m.SelectedIndex != 1 || !reflect.DeepEqual(m.Actions, []string{"Open", "Delete"}) {
		t.Fatalf("action menu mismatch: %+v", m)
	}
}

func TestDecodeActionMenuEmptyActions(t *testing.T) {
	// visible with zero actions: the []string tail is present but empty.
	m, consumed, err := generated.DecodeGuiPickerActionMenu([]byte{1, 5, 0}, 0)
	if err != nil || consumed != 3 || m.Visible != 1 || m.SelectedIndex != 5 || len(m.Actions) != 0 {
		t.Fatalf("empty action menu: m=%+v consumed=%d err=%v", m, consumed, err)
	}
}

func TestDecodeHiddenActionMenuSkipsTail(t *testing.T) {
	m, consumed, err := generated.DecodeGuiPickerActionMenu([]byte{0}, 0)
	if err != nil || consumed != 1 || m.Visible != 0 || len(m.Actions) != 0 {
		t.Fatalf("hidden action menu: m=%+v consumed=%d err=%v", m, consumed, err)
	}
}

func TestDecodeLoadStatusErrorTail(t *testing.T) {
	s, consumed, err := generated.DecodeGuiPickerLoadStatus([]byte{2, 0, 4, 'b', 'o', 'o', 'm'}, 0)
	if err != nil || consumed != 7 || s.Status != 2 || s.Message != "boom" {
		t.Fatalf("error load status: s=%+v consumed=%d err=%v", s, consumed, err)
	}
}

func TestDecodeReadyLoadStatusSkipsTail(t *testing.T) {
	s, consumed, err := generated.DecodeGuiPickerLoadStatus([]byte{0}, 0)
	if err != nil || consumed != 1 || s.Status != 0 || s.Message != "" {
		t.Fatalf("ready load status: s=%+v consumed=%d err=%v", s, consumed, err)
	}
}

func TestDecodeTruncatedPickerItemElementsRejected(t *testing.T) {
	// count claims 2 match positions but only 1 u16 follows: the count*stride
	// require_len fails.
	bytes := []byte{0xAA, 0xBB, 0xCC, 0, 0, 1, 'x', 0, 0, 0, 0, 2, 0, 1}
	if _, _, err := generated.DecodePickerItem(bytes, 0); err == nil {
		t.Fatal("expected error for truncated match_positions, got nil")
	}
}

func TestDecodeTruncatedPickerItemCountByteRejected(t *testing.T) {
	// Buffer ends exactly before the match_positions count byte: the
	// count-prefix require_len (a separate bounds path) must reject it.
	bytes := []byte{0xAA, 0xBB, 0xCC, 0, 0, 1, 'x', 0, 0, 0, 0}
	if _, _, err := generated.DecodePickerItem(bytes, 0); err == nil {
		t.Fatal("expected error for missing match_positions count byte, got nil")
	}
}
