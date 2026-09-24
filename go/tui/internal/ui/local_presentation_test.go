package ui

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestReconcileScrollDiscardsOnKeyMismatch(t *testing.T) {
	lp := newLocalPresentation()
	lp.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 0, contentEpoch: 42, layoutGeneration: 1, rowOffset: 3}

	lp.reconcileScroll(protocol.WindowContent{
		ID:        7,
		ScrollSet: true,
		Scroll:    protocol.ScrollPresentation{ContentEpoch: 42, LayoutGeneration: 2, AnchorTop: 10, AnchorLeft: 0},
	})

	if _, ok := lp.scrolls[7]; ok {
		t.Fatal("scroll should be discarded on layoutGeneration mismatch")
	}
}

func TestReconcileScrollSurvivesOnMatchingKey(t *testing.T) {
	lp := newLocalPresentation()
	lp.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 0, contentEpoch: 42, layoutGeneration: 1, rowOffset: 3}

	lp.reconcileScroll(protocol.WindowContent{
		ID:        7,
		ScrollSet: true,
		Scroll:    protocol.ScrollPresentation{ContentEpoch: 42, LayoutGeneration: 1, AnchorTop: 10, AnchorLeft: 0},
	})

	scroll, ok := lp.scrolls[7]
	if !ok {
		t.Fatal("scroll should survive when keys match")
	}
	if scroll.rowOffset != 3 {
		t.Fatalf("scroll rowOffset should be preserved, got %d", scroll.rowOffset)
	}
}

func TestReconcileScrollDiscardsOnResetRequired(t *testing.T) {
	lp := newLocalPresentation()
	lp.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 0, contentEpoch: 42, layoutGeneration: 1, rowOffset: 3}

	lp.reconcileScroll(protocol.WindowContent{
		ID:        7,
		ScrollSet: true,
		Scroll:    protocol.ScrollPresentation{ContentEpoch: 42, LayoutGeneration: 1, AnchorTop: 10, AnchorLeft: 0, ResetRequired: true},
	})

	if _, ok := lp.scrolls[7]; ok {
		t.Fatal("scroll should be discarded on resetRequired")
	}
}

// TestReconcileScrollScrollSeq covers the #2671 scroll_seq discard rule, which
// runs ahead of the anchor-key check: a strictly-newer scroll_seq (an
// authoritative BEAM jump) discards the local offset even when the anchor key is
// identical, while an equal or older scroll_seq with a matching key is an echo
// and preserves the offset.
func TestReconcileScrollScrollSeq(t *testing.T) {
	base := presentationScroll{anchorTop: 10, anchorLeft: 0, contentEpoch: 42, layoutGeneration: 1, scrollSeq: 5, rowOffset: 3}

	tests := []struct {
		name          string
		frameSeq      uint32
		wantPreserved bool
	}{
		{"strictly newer seq discards on identical anchor key", 6, false},
		{"equal seq is an echo and preserves the offset", 5, true},
		{"older seq preserves the offset", 4, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lp := newLocalPresentation()
			lp.scrolls[7] = base

			lp.reconcileScroll(protocol.WindowContent{
				ID:        7,
				ScrollSet: true,
				Scroll: protocol.ScrollPresentation{
					ContentEpoch: 42, LayoutGeneration: 1, AnchorTop: 10, AnchorLeft: 0, ScrollSeq: tt.frameSeq,
				},
			})

			_, ok := lp.scrolls[7]
			if ok != tt.wantPreserved {
				t.Fatalf("offset preserved = %v, want %v (frame scroll_seq %d vs captured 5)", ok, tt.wantPreserved, tt.frameSeq)
			}
		})
	}
}

// TestReconcileScrollSeqOrderVsAnchorKey pins the rule ordering: a strictly-newer
// scroll_seq discards even though the anchor key still matches (jump landed on the
// same top), which is exactly the seam the Go windowed reconciler used to miss.
func TestReconcileScrollSeqOrderVsAnchorKey(t *testing.T) {
	lp := newLocalPresentation()
	lp.scrolls[7] = presentationScroll{anchorTop: 0, anchorLeft: 0, contentEpoch: 1, layoutGeneration: 9, scrollSeq: 5, rowOffset: 3}

	lp.reconcileScroll(protocol.WindowContent{
		ID:        7,
		ScrollSet: true,
		// Same anchor key as the captured offset, only scroll_seq advanced.
		Scroll: protocol.ScrollPresentation{ContentEpoch: 1, LayoutGeneration: 9, AnchorTop: 0, AnchorLeft: 0, ScrollSeq: 6},
	})

	if _, ok := lp.scrolls[7]; ok {
		t.Fatal("a strictly-newer scroll_seq must discard even on a matching anchor key")
	}
}

func TestReconcileIdentityRetainsSameGenerationItemAcrossReorder(t *testing.T) {
	lp := newLocalPresentation()
	lp.setIdentityPreview(presentationFileTree, 7, "b")

	effective := lp.reconcileIdentity(presentationFileTree, 7, "a", map[string]struct{}{"b": {}, "a": {}}, true)

	if effective != "b" {
		t.Fatalf("same-generation retained preview = %q, want b", effective)
	}
	if preview, ok := lp.identityPreview(presentationFileTree); !ok || preview.itemID != "b" {
		t.Fatalf("retained preview = %+v, %v", preview, ok)
	}
}

func TestReconcileIdentityDiscardsGenerationChangeAndRetainedMiss(t *testing.T) {
	tests := []struct {
		name       string
		generation uint32
		retained   map[string]struct{}
	}{
		{"generation change", 8, map[string]struct{}{"b": {}}},
		{"retained item miss", 7, map[string]struct{}{"a": {}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lp := newLocalPresentation()
			lp.setIdentityPreview(presentationCompletion, 7, "b")
			if effective := lp.reconcileIdentity(presentationCompletion, tt.generation, "a", tt.retained, true); effective != "a" {
				t.Fatalf("effective identity = %q, want committed a", effective)
			}
			if _, ok := lp.identityPreview(presentationCompletion); ok {
				t.Fatal("stale identity preview should be discarded")
			}
		})
	}
}

func TestDiscardOffset(t *testing.T) {
	lp := newLocalPresentation()
	lp.scrolls[7] = presentationScroll{rowOffset: 3}
	lp.scrolls[8] = presentationScroll{rowOffset: 5}

	lp.discard(transformOffset, 7)

	if _, ok := lp.scrolls[7]; ok {
		t.Fatal("discard(offset, 7) should remove scroll for window 7")
	}
	if _, ok := lp.scrolls[8]; !ok {
		t.Fatal("discard(offset, 7) should not affect window 8")
	}
}

func TestDiscardIdentity(t *testing.T) {
	lp := newLocalPresentation()
	lp.setIdentityPreview(presentationFileTree, 1, "tree")
	lp.setIdentityPreview(presentationCompletion, 2, "completion")

	lp.discard(transformIdentity, 0)

	if len(lp.identityPreviews) != 0 {
		t.Fatalf("discard(identity) left previews: %+v", lp.identityPreviews)
	}
}

func TestRemoveWindowCleansUpScroll(t *testing.T) {
	lp := newLocalPresentation()
	lp.scrolls[7] = presentationScroll{rowOffset: 3}

	lp.removeWindow(7)

	if _, ok := lp.scrolls[7]; ok {
		t.Fatal("removeWindow should clear scroll state")
	}
}

func TestKeysMatchComparesFullAnchorKey(t *testing.T) {
	scroll := presentationScroll{anchorTop: 10, anchorLeft: 2, contentEpoch: 42, layoutGeneration: 1}

	match := protocol.ScrollPresentation{ContentEpoch: 42, LayoutGeneration: 1, AnchorTop: 10, AnchorLeft: 2}
	if !scroll.keysMatch(match) {
		t.Fatal("keysMatch should return true for identical keys")
	}

	epochMismatch := protocol.ScrollPresentation{ContentEpoch: 43, LayoutGeneration: 1, AnchorTop: 10, AnchorLeft: 2}
	if scroll.keysMatch(epochMismatch) {
		t.Fatal("keysMatch should return false for epoch mismatch")
	}

	layoutMismatch := protocol.ScrollPresentation{ContentEpoch: 42, LayoutGeneration: 2, AnchorTop: 10, AnchorLeft: 2}
	if scroll.keysMatch(layoutMismatch) {
		t.Fatal("keysMatch should return false for layoutGeneration mismatch")
	}

	anchorTopMismatch := protocol.ScrollPresentation{ContentEpoch: 42, LayoutGeneration: 1, AnchorTop: 11, AnchorLeft: 2}
	if scroll.keysMatch(anchorTopMismatch) {
		t.Fatal("keysMatch should return false for anchorTop mismatch")
	}

	anchorLeftMismatch := protocol.ScrollPresentation{ContentEpoch: 42, LayoutGeneration: 1, AnchorTop: 10, AnchorLeft: 3}
	if scroll.keysMatch(anchorLeftMismatch) {
		t.Fatal("keysMatch should return false for anchorLeft mismatch")
	}
}
