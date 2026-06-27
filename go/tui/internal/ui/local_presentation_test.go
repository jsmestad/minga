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

	lp.discard(transformIdentity, 0)

	if lp.previewFileTreeIndex != nil {
		t.Fatal("discard(identity) should clear file-tree preview")
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
