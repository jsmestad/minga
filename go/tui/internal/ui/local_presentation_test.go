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

func TestReconcileFileTreeClearsPreview(t *testing.T) {
	lp := newLocalPresentation()
	idx := 2
	lp.previewFileTreeIndex = &idx

	lp.reconcileFileTree()

	if lp.previewFileTreeIndex != nil {
		t.Fatal("file-tree preview should be cleared on BEAM update")
	}
}

func TestReconcileFileTreeNoopWhenNoPreview(t *testing.T) {
	lp := newLocalPresentation()
	lp.reconcileFileTree()
	if lp.previewFileTreeIndex != nil {
		t.Fatal("reconcileFileTree should be safe to call with no preview set")
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
	idx := 2
	lp.previewFileTreeIndex = &idx
	cIdx := 3
	lp.previewCompletionIndex = &cIdx

	lp.discard(transformIdentity, 0)

	if lp.previewFileTreeIndex != nil {
		t.Fatal("discard(identity) should clear file-tree preview")
	}
	if lp.previewCompletionIndex != nil {
		t.Fatal("discard(identity) should clear completion preview")
	}
}

func TestReconcileCompletionClearsPreview(t *testing.T) {
	lp := newLocalPresentation()
	idx := 5
	lp.previewCompletionIndex = &idx

	lp.reconcileCompletion()

	if lp.previewCompletionIndex != nil {
		t.Fatal("completion preview should be cleared on BEAM update")
	}
}

func TestReconcileCompletionNoopWhenNoPreview(t *testing.T) {
	lp := newLocalPresentation()
	lp.reconcileCompletion()
	if lp.previewCompletionIndex != nil {
		t.Fatal("reconcileCompletion should be safe to call with no preview set")
	}
}

func TestReconcilePickerClearsPreview(t *testing.T) {
	lp := newLocalPresentation()
	idx := 3
	lp.previewPickerIndex = &idx

	lp.reconcilePicker()

	if lp.previewPickerIndex != nil {
		t.Fatal("picker preview should be cleared on BEAM update")
	}
}

func TestDiscardIdentityClearsPickerPreview(t *testing.T) {
	lp := newLocalPresentation()
	idx := 2
	lp.previewPickerIndex = &idx

	lp.discard(transformIdentity, 0)

	if lp.previewPickerIndex != nil {
		t.Fatal("discard(identity) should clear picker preview")
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
